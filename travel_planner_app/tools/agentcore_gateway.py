"""CrewAI tool for the AgentCore Gateway travel lookup."""

import asyncio
import json
from typing import Any

import httpx
from crewai.tools import BaseTool
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client
from pydantic import BaseModel, Field

from tools.integration_secrets import get_setting


class GatewayRequest(BaseModel):
    request: str = Field(description="City or travel destination to look up.")


class AgentCoreGatewayTool(BaseTool):
    """CrewAI adapter for the AgentCore Gateway travel database."""

    name: str = "AgentCore travel database lookup"

    description: str = (
        "Look up a travel destination in the AgentCore Gateway travel database. "
        "This must be used as the first step when researching a destination. "
        "The tool returns whether the destination was found. "
        "If found is true, use the returned database information. "
        "If found is false, the destination is not in the database and you "
        "must continue with web research instead of stopping."
    )

    args_schema: type[BaseModel] = GatewayRequest

    def _run(self, request: str) -> str:
        try:
            return lookup_destination(request)
        except Exception as exc:
            return (
                f"DATABASE_LOOKUP_ERROR: Destination={request!r}. "
                f"The database lookup failed with {type(exc).__name__}: {exc}. "
                "Continue with web research. Do not treat this as proof that "
                "the destination does not exist."
            )


def lookup_destination(destination: str) -> str:
    """Authenticate and call the configured AgentCore Gateway MCP tool."""

    destination = destination.strip()

    gateway_url = get_setting("agentcore_gateway_url")
    token = get_access_token()
    tool_name = get_setting("agentcore_gateway_tool_name")
    input_key = get_setting("agentcore_gateway_tool_input_key")

    return asyncio.run(
        call_gateway(
            gateway_url=gateway_url,
            tool_name=tool_name,
            input_key=input_key,
            destination=destination,
            token=token,
        )
    )


def get_access_token() -> str:
    """Get a Cognito client-credentials token."""

    response = httpx.post(
        get_setting("cognito_token_url"),
        data={
            "grant_type": "client_credentials",
            "scope": get_setting("cognito_scope"),
        },
        auth=(
            get_setting("cognito_client_id"),
            get_setting("cognito_client_secret"),
        ),
        timeout=15,
    )

    response.raise_for_status()

    token = response.json().get("access_token")

    if not token:
        raise RuntimeError(
            "Cognito response did not contain access_token"
        )

    return token


async def call_gateway(
    *,
    gateway_url: str,
    tool_name: str,
    input_key: str,
    destination: str,
    token: str,
) -> str:
    """Call the MCP Gateway tool and normalize its response."""

    async with streamablehttp_client(
        gateway_url,
        headers={"Authorization": f"Bearer {token}"},
    ) as (read_stream, write_stream, _):

        async with ClientSession(
            read_stream,
            write_stream,
        ) as session:

            await session.initialize()

            result = await session.call_tool(
                tool_name,
                arguments={
                    input_key: destination,
                },
            )

    if result.isError:
        return (
            f"DATABASE_LOOKUP_ERROR: Destination={destination!r}. "
            f"Gateway returned an error: {content_text(result.content)}. "
            "Continue with web research."
        )

    raw = extract_gateway_response(result)

    return normalize_database_response(
        destination,
        raw,
    )


def extract_gateway_response(result: Any) -> Any:
    """Extract structured data or JSON text from the MCP result."""

    structured = getattr(result, "structuredContent", None)

    if structured:
        return structured

    text = content_text(result.content)

    # Try to decode JSON returned as text.
    try:
        return json.loads(text)
    except (json.JSONDecodeError, TypeError):
        return text


def normalize_database_response(
    destination: str,
    response: Any,
) -> str:
    """
    Normalize the Lambda/MCP response into an explicit result
    that the CrewAI agent can reason about.
    """

    # Handle:
    #
    # {
    #   "statusCode": 200,
    #   "body": "{\"found\": true, ...}"
    # }
    #
    if isinstance(response, dict):

        body = response.get("body")

        if isinstance(body, str):

            try:
                body = json.loads(body)
            except json.JSONDecodeError:
                body = None

            if isinstance(body, dict):
                response = body

    if isinstance(response, dict):

        found = response.get("found")

        if found is True:
            return (
                "DATABASE_LOOKUP_RESULT: FOUND\n"
                f"Destination: {response.get('city', destination)}\n"
                f"Budget: {response.get('budget', 'Not provided')}\n"
                f"Duration: {response.get('duration', 'Not provided')} days\n"
                f"Itinerary: {response.get('itinerary', 'Not provided')}\n"
                "Instruction: Use this database information as trusted "
                "predefined travel information."
            )

        if found is False:
            return (
                "DATABASE_LOOKUP_RESULT: NOT_FOUND\n"
                f"Destination: {destination}\n"
                "Instruction: The destination is not present in the travel "
                "database. DO NOT STOP. Continue by researching the "
                "destination using the available web-search capability."
            )

    # Unexpected response
    return (
        "DATABASE_LOOKUP_RESULT: UNKNOWN\n"
        f"Destination: {destination}\n"
        f"Raw response: {response}\n"
        "Instruction: Do not assume the destination is unavailable. "
        "Continue with web research."
    )


def content_text(content: list[Any]) -> str:
    """Extract readable text from MCP content items."""

    return "\n".join(
        getattr(item, "text", str(item))
        for item in content
    )