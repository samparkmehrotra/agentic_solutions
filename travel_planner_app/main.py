import os
from pathlib import Path

import boto3
from bedrock_agentcore.runtime import BedrockAgentCoreApp
from crewai.project import load_crew_and_kickoff
from opentelemetry import trace
from opentelemetry.trace import Status, StatusCode


# ============================================================
# Configuration
# ============================================================

AWS_REGION = "ap-south-1"

BASE_DIR = Path(__file__).resolve().parent

CREW_FILE = BASE_DIR / "crew.jsonc"

SERPER_SECRET_ID = os.getenv(
    "SERPER_SECRET_ID",
    "travel-planner/serper-api-key",
)

AGENT_OBSERVABILITY_ENABLED = os.getenv(
    "AGENT_OBSERVABILITY_ENABLED",
    "true",
).lower() not in {"0", "false", "no", "off"}

tracer = trace.get_tracer("travel_planner_agent")


# ============================================================
# AgentCore application
# ============================================================

app = BedrockAgentCoreApp()


# ============================================================
# Load Serper API key from AWS Secrets Manager
# ============================================================

def load_serper_api_key() -> None:
    """
    Load the Serper API key from AWS Secrets Manager.

    The AgentCore execution role must have permission to call:

        secretsmanager:GetSecretValue

    on the configured secret.

    The key is then placed into the SERPER_API_KEY environment
    variable so that CrewAI's SerperDevTool can use it.
    """

    print("Loading Serper API key from Secrets Manager...")
    print(f"Secret ID: {SERPER_SECRET_ID}")
    print(f"AWS Region: {AWS_REGION}")

    try:

        secrets_client = boto3.client(
            "secretsmanager",
            region_name=AWS_REGION,
        )

        response = secrets_client.get_secret_value(
            SecretId=SERPER_SECRET_ID,
        )

    except Exception as e:

        print(
            "SERPER_SECRET_ERROR: "
            f"{type(e).__name__}: {e}"
        )

        raise RuntimeError(
            "Unable to retrieve Serper API key from "
            "AWS Secrets Manager."
        ) from e

    api_key = response.get("SecretString", "").strip()

    if not api_key:

        print(
            "SERPER_SECRET_ERROR: "
            "SecretString is empty."
        )

        raise RuntimeError(
            f"Secrets Manager secret "
            f"{SERPER_SECRET_ID!r} does not contain "
            "a plaintext SecretString."
        )

    # --------------------------------------------------------
    # Do NOT print the actual API key.
    # --------------------------------------------------------

    os.environ["SERPER_API_KEY"] = api_key

    print(
        "SERPER_API_KEY loaded successfully. "
        "Key is available to the CrewAI process."
    )


# ============================================================
# AgentCore entrypoint
# ============================================================

@app.entrypoint
def invoke(payload):
    """
    AgentCore entrypoint.

    Expected payload:

    {
        "topic": "Plan a trip to London for 2 adults and 1 infant..."
    }
    """

    if not AGENT_OBSERVABILITY_ENABLED:
        return _invoke_impl(payload)

    with tracer.start_as_current_span("travel_planner.invoke") as span:
        span.set_attribute("travel_planner.payload_type", type(payload).__name__)

        try:
            result = _invoke_impl(payload)
            span.set_attribute("travel_planner.success", True)
            return result
        except Exception as exc:  # pragma: no cover - defensive instrumentation
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR, str(exc)))
            raise


def _invoke_impl(payload):
    print("========================================")
    print("AgentCore invocation started")
    print("========================================")

    # --------------------------------------------------------
    # Validate payload
    # --------------------------------------------------------

    if not isinstance(payload, dict):

        print(
            f"Invalid payload type: {type(payload).__name__}"
        )

        return {
            "error": "Payload must be a JSON object."
        }

    topic = payload.get("topic")

    if not isinstance(topic, str) or not topic.strip():

        print("Missing required input: topic")

        return {
            "error": "Missing required input: topic"
        }

    topic = topic.strip()

    print(f"Received topic: {topic}")

    # --------------------------------------------------------
    # Load Serper API key
    # --------------------------------------------------------

    try:

        load_serper_api_key()

    except Exception as e:

        print(
            "Unable to initialize Serper API access."
        )

        return {
            "error": "Unable to initialize Serper API access.",
            "details": str(e),
        }

    # --------------------------------------------------------
    # Verify environment variable exists
    # --------------------------------------------------------

    serper_available = bool(
        os.getenv("SERPER_API_KEY")
    )

    print(
        f"SERPER_API_KEY available: {serper_available}"
    )

    if not serper_available:

        print(
            "SERPER_ERROR: SERPER_API_KEY is not "
            "available after loading the secret."
        )

        return {
            "error": (
                "SERPER_API_KEY is not available "
                "to the CrewAI process."
            )
        }

    # --------------------------------------------------------
    # Verify crew file
    # --------------------------------------------------------

    print(f"Crew file: {CREW_FILE}")

    if not CREW_FILE.exists():

        print(
            f"CREW_FILE_ERROR: {CREW_FILE} does not exist."
        )

        return {
            "error": (
                f"Crew configuration file not found: "
                f"{CREW_FILE}"
            )
        }

    # --------------------------------------------------------
    # Start CrewAI
    # --------------------------------------------------------

    print("Starting CrewAI...")
    print("----------------------------------------")

    try:

        result = load_crew_and_kickoff(
            str(CREW_FILE),
            {
                "topic": topic,
            },
        )

    except Exception as e:

        print(
            "CREW_ERROR: "
            f"{type(e).__name__}: {e}"
        )

        return {
            "error": "CrewAI execution failed.",
            "details": str(e),
        }

    # --------------------------------------------------------
    # Get CrewAI output
    # --------------------------------------------------------

    output = result.raw

    print("----------------------------------------")
    print("CrewAI execution completed.")
    print("----------------------------------------")

    print("Agent response:")
    print(output)

    # --------------------------------------------------------
    # Return final response
    # --------------------------------------------------------

    return {
        "result": output,
    }


# ============================================================
# Local / container startup
# ============================================================

if __name__ == "__main__":
    app.run()