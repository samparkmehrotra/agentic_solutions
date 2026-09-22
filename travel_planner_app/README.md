# AI Travel Planner

CrewAI travel planner running with Amazon Bedrock. The researcher can optionally use an AgentCore Gateway backed by Lambda and DynamoDB. Serper is kept as a future integration placeholder but is disabled in the active crew because the current key returns `403`.

## Requirements

- Python 3.10-3.13
- `uv`
- AWS credentials with Amazon Bedrock access
- `secretsmanager:GetSecretValue` for `travel-planner/integrations` when using the Gateway

## Install and run

```bash
uv sync
export AWS_REGION=ap-south-1
```

Run CrewAI directly:

```bash
uv run crewai run
```

Run the FastAPI UI:

```bash
uv run uvicorn server:app --reload
```

Open `http://127.0.0.1:8000` or call the API:

```bash
curl -X POST http://127.0.0.1:8000/api/plan \
  -H 'Content-Type: application/json' \
  -d '{"topic":"Plan a 4-day trip to Ooty for two adults"}'
```

Run the Streamlit Lambda demo:

```bash
uv run streamlit run app.py
```

## AgentCore deployment

`main.py` is the AgentCore entrypoint and accepts:

```json
{"topic":"Plan a 4-day trip to Ooty for two adults"}
```

Build and push an ARM64 image, then update the AgentCore runtime to use it:

```bash
docker buildx build \
  --platform linux/arm64 \
  --tag YOUR_ECR_URI:YOUR_TAG \
  --push .
```

## Secrets Manager

The Gateway tool reads `travel-planner/integrations`. Keep the Gateway and Cognito values in this JSON secret. The Serper field is optional and is not used while Serper is disabled.

```json
{
  "serper_api_key": "OPTIONAL_FUTURE_SERPER_KEY",
  "agentcore_gateway_url": "https://.../mcp",
  "agentcore_gateway_tool_name": "travel-planner-lambda___get_travel_plan",
  "agentcore_gateway_tool_input_key": "city",
  "cognito_token_url": "https://.../oauth2/token",
  "cognito_client_id": "...",
  "cognito_client_secret": "...",
  "cognito_scope": "..."
}
```

The Gateway lookup is optional at runtime:

- A matching DynamoDB city is returned to the researcher.
- A missing city returns an unavailable-data message, then the researcher continues with a best-effort itinerary.
- Assumptions are not presented as DynamoDB facts.
- The final itinerary can be worded differently from the stored record because the LLM synthesizes the result.

## Crew workflow

1. `travel_researcher` optionally calls the Gateway and writes a research report.
2. `itinerary_planner` converts the report into a day-by-day itinerary.
3. Serper is not called currently. Its key remains documented for later re-enablement.

## Python files

- `main.py`: AgentCore runtime entrypoint. Validates the request and starts the CrewAI workflow.
- `server.py`: Local FastAPI server. Serves the browser UI and exposes `POST /api/plan`.
- `app.py`: Streamlit demo. Invokes the configured AWS Lambda and displays its response.
- `test_gateway.py`: Manual MCP client for listing Gateway tools and testing the Lambda-backed tool.
- `tools/agentcore_gateway.py`: CrewAI adapter for Cognito-authenticated AgentCore Gateway calls.
- `tools/integration_secrets.py`: Reads and caches Gateway settings from Secrets Manager.

## Other files

- `crew.jsonc`: CrewAI tasks and execution order.
- `agents/`: Agent roles and active tools.
- `web/index.html`: Browser UI served by FastAPI.
- `Dockerfile`: AgentCore runtime container image.

## Validation

```bash
uv run python -m py_compile main.py server.py tools/integration_secrets.py tools/agentcore_gateway.py
uv run python -c "from pathlib import Path; from crewai.project import load_crew; load_crew(Path('crew.jsonc')); print('crew loaded')"
```
