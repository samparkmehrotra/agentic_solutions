import os
from pathlib import Path

from bedrock_agentcore.runtime import BedrockAgentCoreApp
from crewai.project import load_crew_and_kickoff
from opentelemetry import trace
from opentelemetry.trace import Status, StatusCode


BASE_DIR = Path(__file__).resolve().parent
CREW_FILE = BASE_DIR / "crew.jsonc"
OBSERVABILITY_ENABLED = os.getenv("AGENT_OBSERVABILITY_ENABLED", "true").lower() not in {
    "0",
    "false",
    "no",
    "off",
}

app = BedrockAgentCoreApp()
tracer = trace.get_tracer("travel_planner_agent")


def run_crew(topic: str) -> str:
    result = load_crew_and_kickoff(str(CREW_FILE), {"topic": topic})
    return result.raw


def _invoke_impl(payload: dict) -> dict:
    if not isinstance(payload, dict):
        return {"error": "Payload must be a JSON object."}

    topic = payload.get("topic")
    if not isinstance(topic, str) or not topic.strip():
        return {"error": "Missing required input: topic"}

    if not CREW_FILE.exists():
        return {"error": f"Crew configuration file not found: {CREW_FILE}"}

    try:
        return {"result": run_crew(topic.strip())}
    except Exception as exc:
        print(f"CrewAI execution failed: {type(exc).__name__}: {exc}")
        return {"error": "CrewAI execution failed.", "details": str(exc)}


@app.entrypoint
def invoke(payload):
    if not OBSERVABILITY_ENABLED:
        return _invoke_impl(payload)

    with tracer.start_as_current_span("travel_planner.invoke") as span:
        span.set_attribute("travel_planner.payload_type", type(payload).__name__)
        try:
            result = _invoke_impl(payload)
            span.set_attribute("travel_planner.success", "error" not in result)
            return result
        except Exception as exc:  # pragma: no cover
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR, str(exc)))
            raise


if __name__ == "__main__":
    app.run()
