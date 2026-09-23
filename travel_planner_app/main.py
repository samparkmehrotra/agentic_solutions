import os
import re
import json
from pathlib import Path

from bedrock_agentcore.runtime import BedrockAgentCoreApp
from crewai.project import load_crew_and_kickoff
from opentelemetry import trace
from opentelemetry.trace import Status, StatusCode
from tools.agentcore_gateway import lookup_destination


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


def is_plausible_destination(destination: str) -> bool:
    normalized = " ".join(destination.split())
    if not 2 <= len(normalized) <= 80:
        return False
    if not re.fullmatch(r"[A-Za-z][A-Za-z .,'-]*", normalized):
        return False
    if not re.search(r"[aeiouy]", normalized.lower()):
        return False
    return not re.search(r"[bcdfghjklmnpqrstvwxz]{5,}", normalized.lower())


def run_crew(travel_request: dict, gateway_record: str) -> str:
    topic = (
        f"Destination: {travel_request['destination']}\n"
        f"Dates: {travel_request['start_date']} to {travel_request['end_date']}\n"
        f"Travelers: {travel_request['travelers']}\n"
        f"Budget: {travel_request['budget']}\n"
        f"Transport priority: {travel_request['transport_priority']}\n"
        f"Verified Gateway record: {gateway_record}\n"
        f"Requirements: {travel_request['requirements']}"
    )
    result = load_crew_and_kickoff(str(CREW_FILE), {"topic": topic})
    return result.raw


def _invoke_impl(payload: dict) -> dict:
    if not isinstance(payload, dict):
        return {"error": "Payload must be a JSON object."}

    required_fields = (
        "destination",
        "requirements",
        "travelers",
        "budget",
        "start_date",
        "end_date",
        "transport_priority",
    )
    if "topic" in payload:
        travel_request = {
            "destination": "Unspecified destination",
            "requirements": payload["topic"],
            "travelers": 1,
            "budget": "Unspecified",
            "start_date": "Unspecified",
            "end_date": "Unspecified",
            "transport_priority": "Cheapest overall",
        }
    else:
        missing_fields = [name for name in required_fields if name not in payload]
        if missing_fields:
            return {"error": f"Missing required input: {', '.join(missing_fields)}"}
        travel_request = payload

    if not isinstance(travel_request["destination"], str) or not travel_request["destination"].strip():
        return {"error": "Destination must be a non-empty string."}
    if not is_plausible_destination(travel_request["destination"]):
        return {
            "error": (
                f"Invalid destination: {travel_request['destination']!r}. "
                "Enter a real city, region, or country name."
            )
        }
    if not isinstance(travel_request["requirements"], str) or not travel_request["requirements"].strip():
        return {"error": "Requirements must be a non-empty string."}
    if not isinstance(travel_request["travelers"], int) or not 1 <= travel_request["travelers"] <= 12:
        return {"error": "Travelers must be an integer between 1 and 12."}

    try:
        gateway_record = lookup_destination(travel_request["destination"].strip())
    except Exception as exc:
        return {"error": f"Destination verification failed: {type(exc).__name__}: {exc}"}

    if gateway_record.startswith("Database data is unavailable"):
        return {"error": gateway_record}
    try:
        parsed_record = json.loads(gateway_record)
    except json.JSONDecodeError:
        return {"error": "Destination verification returned an invalid database response."}
    if not isinstance(parsed_record, dict) or parsed_record.get("found") is not True:
        return {
            "error": (
                f"Destination {travel_request['destination']!r} was not found in the "
                "travel database. No itinerary was generated."
            )
        }

    if not CREW_FILE.exists():
        return {"error": f"Crew configuration file not found: {CREW_FILE}"}

    try:
        return {"result": run_crew(travel_request, gateway_record)}
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
