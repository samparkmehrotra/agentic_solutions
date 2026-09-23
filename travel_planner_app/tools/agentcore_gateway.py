"""Optional CrewAI tool for the AgentCore Gateway travel lookup."""

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
    """Small CrewAI adapter required by the JSON crew loader."""

    name: str = "AgentCore gateway database lookup"
    description: str = (
        "Look up a travel destination in the AgentCore Gateway database. "
        "This lookup is required before planning. If no record is available or "
        "the Gateway is unavailable, report the lookup failure and do not invent "
        "database results."
    )
    args_schema: type[BaseModel] = GatewayRequest

    def _run(self, request: str) -> str:
        try:
            return lookup_destination(request)
        except Exception as exc:
            return unavailable_message(request, f"{type(exc).__name__}: {exc}")


def lookup_destination(destination: str) -> str:
    """Authenticate and call the configured Gateway MCP tool."""
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
        auth=(get_setting("cognito_client_id"), get_setting("cognito_client_secret")),
        timeout=15,
    )
    response.raise_for_status()
    token = response.json().get("access_token")
    if not token:
        raise RuntimeError("Cognito response did not contain access_token")
    return token


async def call_gateway(
    *,
    gateway_url: str,
    tool_name: str,
    input_key: str,
    destination: str,
    token: str,
) -> str:
    """Call one MCP tool and convert its result to text for CrewAI."""
    async with streamablehttp_client(
        gateway_url,
        headers={"Authorization": f"Bearer {token}"},
    ) as (read_stream, write_stream, _):
        async with ClientSession(read_stream, write_stream) as session:
            await session.initialize()
            result = await session.call_tool(
                tool_name,
                arguments={input_key: destination},
            )

    if result.isError:
        return unavailable_message(destination, content_text(result.content))

    structured = getattr(result, "structuredContent", None)
    if structured:
        return json.dumps(structured, ensure_ascii=True)
    return content_text(result.content)


def content_text(content: list[Any]) -> str:
    """Extract readable text from MCP content items."""
    return "\n".join(getattr(item, "text", str(item)) for item in content)


def unavailable_message(destination: str, reason: str) -> str:
    """Tell the researcher to continue without database facts."""
    return (
        f"Database data is unavailable for {destination!r}. "
        "Continue with a best-effort plan and label assumptions clearly. "
        f"Details: {reason}"
    )
