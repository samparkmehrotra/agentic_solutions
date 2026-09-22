import asyncio
import os

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client


GATEWAY_URL = os.environ["GATEWAY_URL"]
ACCESS_TOKEN = os.environ["ACCESS_TOKEN"]


async def main():
    headers = {
        "Authorization": f"Bearer {ACCESS_TOKEN}"
    }

    async with streamablehttp_client(
        GATEWAY_URL,
        headers=headers,
    ) as (read_stream, write_stream, _):

        async with ClientSession(
            read_stream,
            write_stream,
        ) as session:

            # Initialize MCP session
            await session.initialize()

            # List available tools
            result = await session.list_tools()

            print("\n=== TOOLS ===")

            for tool in result.tools:
                print(f"- {tool.name}: {tool.description}")

            # Call AgentCore Gateway tool
            print("\n=== CALL get_travel_plan ===")

            result = await session.call_tool(
                "travel-planner-lambda___get_travel_plan",
                arguments={
                    "city": "London"
                },
            )

            print("\n=== RESULT ===")
            print(result)


if __name__ == "__main__":
    asyncio.run(main())
