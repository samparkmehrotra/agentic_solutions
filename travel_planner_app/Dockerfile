# Amazon Bedrock AgentCore requires Linux ARM64 images and an HTTP service on port 8080.
FROM --platform=linux/arm64 ghcr.io/astral-sh/uv:python3.12-bookworm-slim AS dependencies

WORKDIR /app

# Some transitive Python packages may need native compilation on ARM64.
RUN apt-get update \
    && apt-get install --yes --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

# Keep dependency installation in a cacheable layer. The application source is copied later.
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev --no-install-project \
    && uv pip install --python /app/.venv/bin/python aws-opentelemetry-distro

FROM --platform=linux/arm64 ghcr.io/astral-sh/uv:python3.12-bookworm-slim

WORKDIR /app

ARG AWS_REGION=ap-south-1

ENV PATH="/app/.venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    HOME=/home/bedrock_agentcore \
    AWS_REGION=${AWS_REGION} \
    AGENT_OBSERVABILITY_ENABLED=true \
    OTEL_PYTHON_DISTRO=aws_distro \
    OTEL_PYTHON_CONFIGURATOR=aws_opentelemetry \
    OTEL_SERVICE_NAME=travel-planner-app \
    OTEL_TRACES_EXPORTER=otlp \
    OTEL_METRICS_EXPORTER=otlp \
    OTEL_LOGS_EXPORTER=otlp \
    OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
    OTEL_EXPORTER_OTLP_ENDPOINT=http://host.docker.internal:4318

# Do not run the agent process as root.
RUN groupadd --gid 1000 bedrock_agentcore \
    && useradd --uid 1000 --gid bedrock_agentcore --create-home --shell /usr/sbin/nologin bedrock_agentcore

COPY --from=dependencies /app/.venv /app/.venv
COPY --chown=bedrock_agentcore:bedrock_agentcore . .

USER bedrock_agentcore

EXPOSE 8080

# BedrockAgentCoreApp in main.py provides the required /ping and /invocations endpoints.
# Start the process through the AWS OpenTelemetry Python launcher so the distro can
# auto-instrument the Python runtime and exported spans/metrics/logs.
CMD ["opentelemetry-instrument", "python", "main.py"]
