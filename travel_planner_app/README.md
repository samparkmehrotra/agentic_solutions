# AI Travel Planner

CrewAI travel planner running on Amazon Bedrock AgentCore with a Streamlit
client. The low-cost test configuration uses Amazon Nova Micro, disables CrewAI
memory/planning/delegation, and limits agent iterations and output tokens.

## Requirements

- Python 3.10-3.13
- `uv`
- AWS CLI configured for the target account
- Docker with `buildx` and an ARM64 builder
- AWS credentials with permission to create IAM, Lambda, ECR, AgentCore, and
  CloudWatch resources

## Local development

```bash
cd /path/to/agentic_solutions/travel_planner_app
uv sync
```

Run the FastAPI UI:

```bash
uv run uvicorn server:app --reload
```

Run the Streamlit Lambda client after deployment:

```bash
.venv/bin/python -m streamlit run app.py
```

## AWS test deployment

The deployment flow is:

```text
Streamlit -> Lambda -> AgentCore Runtime -> CrewAI -> Bedrock Nova Micro
```

The scripts use these defaults:

| Resource | Default name |
| --- | --- |
| Lambda | `test-planner-function` |
| AgentCore runtime | `travel_planner_runtime` |
| ECR repository | `travel-planner-app` |
| Lambda IAM role | `travel-planner-lambda-role` |
| AgentCore IAM role | `travel-planner-agentcore-role` |

The scripts always use the project directory as their working directory, so
they can be run from any location.

### Create or update resources

Set the region if needed, then run the create script:

```bash
export AWS_REGION=ap-south-1
./deploy_resources.sh
```

By default, the image is pushed to the mutable ECR tag `test`. Every run
rebuilds the current source, pushes that tag, and updates the existing
AgentCore runtime to use it. For an immutable test image, choose a unique tag
before running the script:

```bash
export IMAGE_TAG=$(date +%Y%m%d-%H%M%S)
./deploy_resources.sh
```

The script updates an existing runtime; it does not create a second runtime
with the same name. This makes repeated test deployments safe.

`deploy_resources.sh` performs these steps in order:

1. Resolves the AWS account and deployment names.
2. Creates or reuses the Lambda and AgentCore IAM roles.
3. Applies the policies from `policies/`.
4. Creates or reuses the ECR repository.
5. Builds and pushes the ARM64 AgentCore image.
6. Creates or updates the named AgentCore runtime.
7. Generates and applies the Lambda invoke policy for the actual runtime ARN.
8. Packages and creates or updates the Lambda function.
9. Configures Lambda with `AGENT_RUNTIME_ARN`.

The script waits for Lambda updates to finish before changing its
configuration, so it can be safely rerun while iterating on the code.

The script does not set the reserved Lambda variable `AWS_REGION`.

If AWS reports that a Lambda update is already in progress, rerun the script.
The script waits for normal code-creation and code-update transitions before
changing Lambda configuration.

### Test the deployed Lambda

The test payload is already included as `test-payload.json`. From the project
directory:

```bash
aws lambda invoke \
  --region "$AWS_REGION" \
  --function-name test-planner-function \
  --payload fileb://test-payload.json \
  --cli-binary-format raw-in-base64-out \
  lambda-test-response.json

cat lambda-test-response.json
```

For a malformed destination such as `abdjbcjdbcd`, the runtime returns a
validation error before calling CrewAI or Bedrock. Valid-looking names pass
the local plausibility check; this is not live geocoding.

The payload shape is:

```json
{
  "destination": "Ooty",
  "requirements": "Nature, local food, and sightseeing",
  "travelers": 2,
  "budget": "Budget",
  "start_date": "2026-10-07",
  "end_date": "2026-10-10",
  "transport_priority": "Cheapest overall"
}
```

Run the UI:

```bash
.venv/bin/python -m streamlit run app.py
```

### Destroy all test resources

Run this when testing is complete. It is safe to rerun if a resource is
already absent:

```bash
export AWS_REGION=ap-south-1
./destroy_all_resources.sh
```

The cleanup script removes:

- The AgentCore runtime
- The Lambda function
- The ECR repository and all images
- The Lambda inline and managed policies
- The Lambda IAM role
- The AgentCore inline policy and IAM role
- The Lambda CloudWatch log group
- Local generated ZIP and response artifacts

The script deletes resources with the fixed names above. If you customized any
names, export the same variables before running it:

```bash
export LAMBDA_NAME=my-test-lambda
export RUNTIME_NAME=my_test_runtime
export ECR_REPOSITORY=my-test-repository
export LAMBDA_ROLE_NAME=my-test-lambda-role
export AGENTCORE_ROLE_NAME=my-test-agentcore-role
./destroy_all_resources.sh
```

## IAM policies

All deployment policy documents are under [policies](policies):

- `lambda-trust-policy.json`
- `lambda-agentcore-policy.json`
- `agentcore-trust-policy.json`
- `agentcore-runtime-policy.json`
- `gateway-lambda-policy.json`
- `gateway-trust-policy.json`

The Lambda invoke policy is a template. The create script replaces
`__RUNTIME_ARN__` with the runtime ARN before applying it.

The Lambda policy allows both the parent runtime ARN and its `DEFAULT` runtime
endpoint ARN because AgentCore authorization can report either resource form.

## AgentCore Gateway and DynamoDB lookup

The Gateway stack is separate from the planner runtime. It provides this flow:

```text
Travel Researcher -> Cognito client credentials -> AgentCore Gateway
  -> Lambda target -> DynamoDB travel-plans table
```

Create the Gateway stack after the base runtime deployment:

```bash
export AWS_REGION=ap-south-1
./deploy_resources.sh
```

`deploy_resources.sh` creates or updates:

- A `travel-plans` DynamoDB table with sample `Ooty` and `London` records.
- A Lambda target that reads a city record from DynamoDB.
- IAM roles for the Gateway and its Lambda target.
- A Cognito user pool, domain, resource-server scope, and M2M app client.
- A Cognito OAuth2 credential provider for AgentCore.
- An AgentCore Gateway using `CUSTOM_JWT` authorization.
- An inline MCP tool named `get_travel_plan`.
- The `travel-planner/integrations` Secrets Manager secret used by the agent.

The researcher is instructed to call `get_travel_plan` before planning. If the
city is missing or the Gateway lookup fails, it returns a verification error
instead of inventing a plan.

Destroy this Gateway stack separately when testing is complete:

```bash
export AWS_REGION=ap-south-1
./destroy_all_resources.sh
```

This removes the Gateway targets and Gateway, OAuth provider, Cognito pool,
Gateway Lambda, DynamoDB table, Gateway IAM roles, the
`travel-planner/integrations` secret, and the local Gateway ZIP. The secret is
force-deleted for immediate test cleanup; do not run this script if another
deployment still uses that shared secret.

The Gateway client reads the `travel-planner/integrations` secret. Its shape is:

```json
{
  "agentcore_gateway_url": "https://.../mcp",
  "agentcore_gateway_tool_name": "travel-planner-lambda___get_travel_plan",
  "agentcore_gateway_tool_input_key": "city",
  "cognito_token_url": "https://.../oauth2/token",
  "cognito_client_id": "...",
  "cognito_client_secret": "...",
  "cognito_scope": "..."
}
```

The Gateway lookup is required for a verified itinerary. Live transportation
pricing is still not included; fares remain model estimates.

## Project files

- `main.py`: AgentCore runtime entrypoint.
- `app.py`: Streamlit client that invokes Lambda.
- `server.py`: Local FastAPI UI.
- `deploy_resources.sh`: Creates or updates the complete runtime and Gateway stack.
- `destroy_all_resources.sh`: Removes the complete test stack.
- `policies/`: IAM policies and trust policies.
- `crew.jsonc`: CrewAI tasks and execution order.
- `agents/`: Agent definitions.
- `Dockerfile`: ARM64 AgentCore runtime image.

## Validation

```bash
python3 -m json.tool policies/agentcore-runtime-policy.json >/dev/null
python3 -m json.tool policies/lambda-agentcore-policy.json >/dev/null
python3 -m py_compile main.py server.py app.py lambda/lambda_function.py gateway_lambda/lambda_function.py tools/integration_secrets.py tools/agentcore_gateway.py
bash -n deploy_resources.sh destroy_all_resources.sh
python3 -m json.tool gateway_tools.json >/dev/null
uv run python -c "from pathlib import Path; from crewai.project import load_crew; load_crew(Path('crew.jsonc')); print('crew loaded')"
```
