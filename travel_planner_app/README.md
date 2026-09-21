# AI Travel Planner

A JSON-configured CrewAI project that researches travel options and produces a practical day-by-day itinerary. The repo now includes multiple ways to run the same travel planner: direct CrewAI execution, a local FastAPI web app, a Streamlit demo that calls an AWS Lambda, and an AWS Bedrock AgentCore entrypoint for deployment.

## Quick start

1. Install dependencies:

```bash
uv sync
```

2. Set the required environment variables:

```bash
export AWS_REGION=ap-south-1
export SERPER_API_KEY=<your-serper-key>

# Agent observability / OpenTelemetry
export AGENT_OBSERVABILITY_ENABLED=true

# AWS OpenTelemetry (AWS Distro for OpenTelemetry)
export OTEL_PYTHON_DISTRO=aws_distro
export OTEL_PYTHON_CONFIGURATOR=aws_opentelemetry
export OTEL_SERVICE_NAME=travel-planner-app
export OTEL_TRACES_EXPORTER=otlp
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
```

For local development you can point `OTEL_EXPORTER_OTLP_ENDPOINT` at a running OTLP collector or CloudWatch-compatible endpoint. In Docker, these values are set as defaults so traces, metrics, and logs are exported automatically when the AWS OpenTelemetry distro is active. The container starts via `opentelemetry-instrument python main.py` so the AWS distro can auto-instrument the Python process. The default Docker value uses `http://host.docker.internal:4318` rather than `localhost` so a collector running on the host machine is reachable from inside the container on Docker Desktop for macOS/Windows.

3. Choose a runtime:

```bash
# Direct crew execution
uv run crewai run

# FastAPI app + browser UI
uv run uvicorn server:app --reload

# Streamlit demo (requires a Lambda function already deployed)
uv run streamlit run streamlit.py

# AgentCore entrypoint
uv run python main.py
```

## Requirements

- Python 3.10–3.13
- [uv](https://docs.astral.sh/uv/)
- AWS credentials with access to `apac.amazon.nova-pro-v1:0` through Amazon Bedrock
- `SERPER_API_KEY` for the agents' web-search tool
- AWS OpenTelemetry instrumentation via `aws-opentelemetry-distro` for tracing and monitoring support in the project runtime and Docker image
- OpenTelemetry runtime variables for traces, metrics, and logs (`AGENT_OBSERVABILITY_ENABLED`, `OTEL_PYTHON_DISTRO`, `OTEL_PYTHON_CONFIGURATOR`, `OTEL_SERVICE_NAME`, `OTEL_TRACES_EXPORTER`, `OTEL_METRICS_EXPORTER`, `OTEL_LOGS_EXPORTER`, `OTEL_EXPORTER_OTLP_PROTOCOL`, `OTEL_EXPORTER_OTLP_ENDPOINT`)

## Install CrewAI and create a project

Install the CrewAI CLI once with `uv`:

```bash
uv tool install crewai
crewai version
```

Create a new JSON-configured crew project (the same configuration style used here):

```bash
crewai create crew travel-planner-app
cd travel-planner-app
uv sync
```

Use `crewai create crew <name> --classic` only when you want the older Python/YAML project structure. You can also run the CLI once without installing it globally:

```bash
uvx crewai create crew travel-planner-app
```

## Install

```bash
git clone <repository-url>
cd travel_planner_app
uv sync
```

Configure credentials in your shell (or use your normal AWS credential provider):

```bash
export AWS_REGION=<aws-region>
export SERPER_API_KEY=<serper-api-key>
```

`uv sync` installs the locked project dependencies, including the AWS OpenTelemetry distro used for traces and instrumentation. Alternatively, use `pip install -r requirements.txt`.

## Run

This project supports several local entrypoints depending on how you want to use the planner.

### 1) Run the CrewAI project directly

```bash
uv run crewai run
```

This prompts for a `topic` and runs the configured travel-planning crew.

### 2) Start the local web API and UI

```bash
uv run uvicorn server:app --reload
```

The app serves the static browser UI from `web/index.html` and exposes the JSON API:

```bash
curl -X POST http://127.0.0.1:8000/api/plan \
  -H 'Content-Type: application/json' \
  -d '{"topic":"A 4-day trip to Kyoto for two people in April"}'
```

Open `http://127.0.0.1:8000` in the browser to use the UI.

### 3) Run the Streamlit demo

`streamlit.py` is a lightweight demo UI that calls an AWS Lambda function. It is useful when testing an AWS deployment without exposing the CrewAI code directly.

```bash
uv run streamlit run streamlit.py
```

This file expects a Lambda function named `test-planner-function` in the configured AWS region. If you are using a different function name, update `LAMBDA_FUNCTION_NAME` in `streamlit.py` before starting it.

### 4) Run the Bedrock AgentCore entrypoint

`main.py` is the AWS Bedrock AgentCore runtime entrypoint, not the local FastAPI server:

```bash
uv run python main.py
```

This is the production-style deployment entrypoint used for AgentCore and Docker packaging.

## Entrypoints and local testing

| File | Role | Local command |
| --- | --- | --- |
| `server.py` | FastAPI server for the browser UI and HTTP API. It serves `/`, accepts itinerary requests at `POST /api/plan`, and provides `GET /health`. | `uv run uvicorn server:app --reload` |
| `main.py` | AWS Bedrock AgentCore handler. Its `invoke(payload)` function validates `payload.topic`, runs the crew, and returns the itinerary result. | `uv run python main.py` |
| `streamlit.py` | Streamlit demo that invokes an AWS Lambda function and renders the returned itinerary. | `uv run streamlit run streamlit.py` |
| `web/index.html` | Browser UI used by the FastAPI app. | Served automatically by `server.py` |

Test the FastAPI server after starting it:

```bash
curl http://127.0.0.1:8000/health
# {"status":"healthy"}
```

Generate an itinerary through the HTTP API:

```bash
curl -X POST http://127.0.0.1:8000/api/plan \
  -H 'Content-Type: application/json' \
  -d '{"topic":"A 3-day trip to Goa for two people"}'
```

The FastAPI interactive API documentation is available at `http://127.0.0.1:8000/docs`. To test the AgentCore handler directly without starting its runtime, run:

```bash
uv run python -c "from main import invoke; print(invoke({'topic': 'A 3-day trip to Goa for two people'}))"
```

`/health` does not contact external services. Crew and itinerary requests require valid AWS Bedrock credentials and `SERPER_API_KEY`.

## Docker and Amazon ECR

The included `Dockerfile` packages the AgentCore entrypoint in `main.py`; it is not the FastAPI UI container. It uses the locked dependencies in `uv.lock`, builds a Linux ARM64 image, runs as a non-root user on port `8080`, and lets `BedrockAgentCoreApp` serve the required `/ping` and `/invocations` endpoints. `.dockerignore` ensures local credentials, virtual environments, and Git data are excluded from the image.

### Prerequisites

- Docker Desktop running, with the `desktop-linux` Buildx builder available
- AWS CLI installed and authenticated (`aws configure`, AWS SSO, or another credential provider)
- AWS permissions for `sts:GetCallerIdentity`, `ecr:CreateRepository`, `ecr:GetAuthorizationToken`, and pushing ECR image layers
- An AWS region that supports the Bedrock model and AgentCore runtime you intend to use

For a new machine, authenticate before continuing:

```bash
aws configure
# Or, for AWS IAM Identity Center / SSO:
aws configure sso
aws sso login
```

Confirm the local tools, builder name, and AWS identity before building. Substitute the builder name from `docker buildx ls` if it differs from `desktop-linux`.

```bash
docker buildx ls
aws sts get-caller-identity
```

### Build and test locally

Build the ARM64 image required by AgentCore:

```bash
docker buildx build --builder desktop-linux --platform linux/arm64 --load \
  -t travel-planner-agent:local .
```

Run and test the container locally. The mounted AWS profile is read-only; use environment variables instead if that is how you authenticate locally.

```bash
docker run --rm -p 8080:8080 \
  -e AWS_REGION \
  -e SERPER_API_KEY \
  -v "$HOME/.aws:/home/bedrock_agentcore/.aws:ro" \
  travel-planner-agent:local

curl http://127.0.0.1:8080/ping
curl -X POST http://127.0.0.1:8080/invocations \
  -H 'Content-Type: application/json' \
  -d '{"topic":"A 3-day trip to Goa for two people"}'
```

Stop the temporary local container with `Ctrl+C` if it is running in the foreground.

### First upload to Amazon ECR

Set the target region, ECR repository name, and image tag. Change the values as needed:

```bash
export AWS_REGION=ap-south-1
export ECR_REPOSITORY=travel-planner-agent
export IMAGE_TAG=latest
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}"
```

Create the repository once:

```bash
aws ecr create-repository \
  --repository-name "$ECR_REPOSITORY" \
  --image-scanning-configuration scanOnPush=true \
  --region "$AWS_REGION"
```

If you do not know whether it already exists, check first:

```bash
aws ecr describe-repositories \
  --repository-names "$ECR_REPOSITORY" \
  --region "$AWS_REGION"
```

Authenticate Docker to ECR. Repeat this login whenever the ECR authorization token expires or Docker credentials have been cleared:

```bash
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
```

Build and push the image directly to ECR:

```bash
docker buildx build --builder desktop-linux --platform linux/arm64 \
  --tag "${ECR_URI}:${IMAGE_TAG}" --push .
```

Verify the uploaded image and print its URI:

```bash
aws ecr describe-images --repository-name "$ECR_REPOSITORY" --region "$AWS_REGION"
echo "${ECR_URI}:${IMAGE_TAG}"
```

### Re-upload to an existing ECR repository

Do not run `create-repository` again. Set the same variables, log in again, choose a new tag, then build and push:

```bash
export AWS_REGION=ap-south-1
export ECR_REPOSITORY=travel-planner-agent
export IMAGE_TAG=v1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}"

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

docker buildx build --builder desktop-linux --platform linux/arm64 \
  --tag "${ECR_URI}:${IMAGE_TAG}" --push .
```

Use unique tags such as `v1`, `v2`, or a Git commit SHA for deployable versions. Reusing `latest` is supported, but it replaces the image associated with that tag.

### Important deployment notes

- The Dockerfile and ECR image contain application code and dependencies only. Do not copy `.env` files, AWS keys, API keys, or `SERPER_API_KEY` into the image.
- For local testing, pass credentials at runtime as shown above. For AgentCore, provide AWS access through its execution role and manage third-party secrets through an AWS secret-management solution.
- Uploading an image to ECR does not deploy it. To run this image in Bedrock AgentCore, create or update an AgentCore runtime separately and reference the printed ECR image URI and tag.
- For another project, replace `main.py` in the Dockerfile command with that project’s AgentCore entrypoint, and ensure it listens on port `8080` and implements the AgentCore `/ping` and `/invocations` contract.

### Serper key in Secrets Manager

`main.py` retrieves the plaintext value of the `travel-planner/serper-api-key` Secrets Manager secret before each crew invocation, then supplies it to `SerperDevTool` through the container process environment. The key is not stored in the Docker image, ECR, or AgentCore runtime environment-variable configuration.

The AgentCore execution role needs this least-privilege policy (replace the region and account ID):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:<region>:<account-id>:secret:travel-planner/serper-api-key-*"
    }
  ]
}
```

If the secret uses a customer-managed KMS key, also allow `kms:Decrypt` for that key. No `SERPER_API_KEY` AgentCore environment variable is required; optionally set `SERPER_SECRET_ID` only when using a different secret name.

## CrewAI commands

Run every command through `uv run crewai` so it uses this project's environment.

| Command | Purpose |
| --- | --- |
| `run` | Run the configured crew. |
| `test -n <iterations> -m <openai-model>` | Evaluate a crew; CrewAI currently accepts OpenAI models for this command. |
| `train -n <iterations> -f <file>` | Train agents and save suggestions to a file. |
| `run -f <file>` | Run using a training file created by `train`. |
| `replay -t <task-id>` | Resume an execution from a task. |
| `log-tasks-outputs` | Show outputs from the latest kickoff. |
| `memory` | Browse saved memory. |
| `reset-memories --all` | Delete saved CrewAI memory and outputs. |
| `version` | Show the installed CrewAI version. |
| `create`, `flow`, `tool`, `skill`, `template`, `deploy` | Scaffold or manage additional CrewAI resources. |

Use `uv run crewai --help` or `uv run crewai <command> --help` for complete options.

## Project layout

- `crew.jsonc` — top-level CrewAI configuration, tasks, process, and runtime inputs
- `agents/` — travel researcher and itinerary planner definitions
- `tools/` — custom CrewAI tools used by the crew
- `skills/` — reusable CrewAI skills used in the project
- `knowledge/` — local reference material and context for planning
- `server.py` — FastAPI app that serves the browser UI and the JSON API (`/`, `/api/plan`, `/health`)
- `main.py` — Bedrock AgentCore handler for deployment/runtime use
- `streamlit.py` — Streamlit demo app that invokes an AWS Lambda and renders the result
- `web/` — static browser UI used by the FastAPI app
- `Dockerfile` — container setup for the AgentCore runtime image
- `requirements.txt` / `uv.lock` — pinned dependencies for local and containerized execution
- `.env` — local environment configuration, if present on a developer machine
