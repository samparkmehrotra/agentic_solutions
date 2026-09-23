import os
import re
from pathlib import Path

from bedrock_agentcore.runtime import BedrockAgentCoreApp
from crewai.project import load_crew_and_kickoff
from opentelemetry import trace
from opentelemetry.trace import Status, StatusCode

from tools.agentcore_gateway import lookup_destination
from tools.travel_web_search import TravelWebSearchTool


BASE_DIR = Path(__file__).resolve().parent
CREW_FILE = BASE_DIR / "crew.jsonc"

OBSERVABILITY_ENABLED = os.getenv(
    "AGENT_OBSERVABILITY_ENABLED",
    "true",
).lower() not in {
    "0",
    "false",
    "no",
    "off",
}

LLM_MODEL = "bedrock/apac.amazon.nova-micro-v1:0"


app = BedrockAgentCoreApp()
tracer = trace.get_tracer("travel_planner_agent")


# ---------------------------------------------------------------------------
# Destination validation
# ---------------------------------------------------------------------------

def is_plausible_destination(destination: str) -> bool:
    normalized = " ".join(destination.split())

    if not 2 <= len(normalized) <= 80:
        return False

    if not re.fullmatch(
        r"[A-Za-z][A-Za-z .,'-]*",
        normalized,
    ):
        return False

    if not re.search(
        r"[aeiouy]",
        normalized.lower(),
    ):
        return False

    return not re.search(
        r"[bcdfghjklmnpqrstvwxz]{5,}",
        normalized.lower(),
    )


# ---------------------------------------------------------------------------
# Web research
# ---------------------------------------------------------------------------

def perform_web_research(
    destination: str,
    requirements: str,
) -> dict:

    search_tool = TravelWebSearchTool()

    queries = [
        f"{destination} top attractions things to do",
        f"{destination} transportation train bus car flight travel",
        f"{destination} best areas to stay accommodation",
        f"{destination} travel budget costs itinerary",
    ]

    searches = []
    sources = []

    for query in queries:

        try:
            result = search_tool.run(query)

            if "WEB_SEARCH_RESULT: FOUND" in result:
                status = "FOUND"

            elif "WEB_SEARCH_RESULT: NO_USEFUL_RESULTS" in result:
                status = "NO_USEFUL_RESULTS"

            elif "WEB_SEARCH_RESULT: ERROR" in result:
                status = "ERROR"

            else:
                status = "UNKNOWN"

            searches.append(
                {
                    "query": query,
                    "status": status,
                    "result": result,
                }
            )

            if status == "FOUND":
                sources.extend(
                    extract_sources(
                        result,
                        query,
                    )
                )

        except Exception as exc:

            searches.append(
                {
                    "query": query,
                    "status": "ERROR",
                    "result": (
                        "WEB_SEARCH_RESULT: ERROR\n"
                        f"Query: {query}\n"
                        f"Error: {type(exc).__name__}: {exc}"
                    ),
                }
            )

    # Remove duplicate source URLs while preserving order.
    unique_sources = []
    seen_urls = set()

    for source in sources:

        url = source.get("url", "").strip()

        if not url:
            continue

        normalized_url = url.rstrip("/").lower()

        if normalized_url in seen_urls:
            continue

        seen_urls.add(normalized_url)
        unique_sources.append(source)

    successful_searches = sum(
        1
        for item in searches
        if item["status"] == "FOUND"
    )

    return {
        "status": (
            "FOUND"
            if successful_searches > 0
            else "NO_USEFUL_RESULTS"
        ),
        "successful_searches": successful_searches,
        "total_searches": len(searches),
        "searches": searches,
        "sources": unique_sources,
    }


def extract_sources(
    result: str,
    query: str,
) -> list[dict]:

    sources = []

    current_title = None
    current_source = None
    current_url = None

    for line in result.splitlines():

        line = line.strip()

        if not line:
            continue

        if re.match(
            r"^\d+\.\s+",
            line,
        ):

            if current_url:

                sources.append(
                    {
                        "query": query,
                        "title": current_title,
                        "url": current_url,
                        "domain": current_source,
                    }
                )

            current_title = re.sub(
                r"^\d+\.\s+",
                "",
                line,
            )

            current_source = None
            current_url = None

        elif line.startswith("Source: "):

            current_source = line[
                len("Source: "):
            ].strip()

        elif line.startswith("URL: "):

            current_url = line[
                len("URL: "):
            ].strip()

    if current_url:

        sources.append(
            {
                "query": query,
                "title": current_title,
                "url": current_url,
                "domain": current_source,
            }
        )

    return sources


# ---------------------------------------------------------------------------
# CrewAI execution
# ---------------------------------------------------------------------------

def run_crew(
    travel_request: dict,
    gateway_record: str,
    web_research: dict,
) -> str:

    web_research_text = "\n\n".join(
        (
            f"=== WEB SEARCH QUERY ===\n"
            f"{item['query']}\n\n"
            f"=== STATUS ===\n"
            f"{item['status']}\n\n"
            f"=== RESULT ===\n"
            f"{item['result']}"
        )
        for item in web_research["searches"]
    )

    topic = (
        f"Destination: {travel_request['destination']}\n"
        f"Dates: {travel_request['start_date']} to "
        f"{travel_request['end_date']}\n"
        f"Travelers: {travel_request['travelers']}\n"
        f"Budget: {travel_request['budget']}\n"
        f"Transport priority: "
        f"{travel_request['transport_priority']}\n"
        f"Requirements: {travel_request['requirements']}\n\n"

        "=== VERIFIED GATEWAY DATABASE RESULT ===\n"
        f"{gateway_record}\n\n"

        "=== VERIFIED WEB RESEARCH ===\n"
        f"{web_research_text}\n\n"

        "=== SOURCE AND RESEARCH RULES ===\n"
        "The Gateway result and web-search results above were obtained "
        "by the Python orchestration layer before the CrewAI workflow.\n\n"

        "Gateway information is database information.\n"
        "Web-search information is external web research.\n\n"

        "Use these sources as the primary evidence for the itinerary.\n"
        "Do not claim that you performed a tool call yourself.\n"
        "Do not invent dates, prices, bookings, availability, or "
        "user preferences.\n"
        "Clearly identify estimates and information requiring confirmation.\n"
        "Do not claim live pricing or live availability unless explicitly "
        "provided by the supplied research."
    )

    result = load_crew_and_kickoff(
        str(CREW_FILE),
        {"topic": topic},
    )

    return result.raw


# ---------------------------------------------------------------------------
# Provenance / execution trace
# ---------------------------------------------------------------------------

def build_provenance(
    gateway_status: str,
    web_research: dict,
) -> dict:

    return {
        "database": {
            "source": "AgentCore Gateway",
            "backend": "DynamoDB",
            "status": gateway_status,
        },

        "web_search": {
            "source": "DDGS Python library",
            "provider": "DuckDuckGo",
            "status": web_research["status"],
            "successful_searches": (
                web_research["successful_searches"]
            ),
            "total_searches": (
                web_research["total_searches"]
            ),
            "queries": [
                item["query"]
                for item in web_research["searches"]
            ],
            "source_count": len(
                web_research.get("sources", [])
            ),
            "sources": web_research.get(
                "sources",
                [],
            ),
        },

        "llm": {
            "framework": "CrewAI",
            "model": LLM_MODEL,
            "agents": [
                "Travel Researcher",
                "Itinerary Planner",
            ],
        },

        "orchestration": {
            "component": "main.py",
            "flow": (
                "Gateway → DDGS → CrewAI → "
                "Nova Micro"
            ),
            "tool_execution": "deterministic",
        },
    }


# ---------------------------------------------------------------------------
# Main application logic
# ---------------------------------------------------------------------------

def _invoke_impl(payload: dict) -> dict:

    # -----------------------------------------------------------------------
    # Input validation
    # -----------------------------------------------------------------------

    if not isinstance(payload, dict):

        return {
            "error": "Payload must be a JSON object."
        }

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

        missing_fields = [
            name
            for name in required_fields
            if name not in payload
        ]

        if missing_fields:

            return {
                "error": (
                    "Missing required input: "
                    + ", ".join(missing_fields)
                )
            }

        travel_request = payload

    destination_value = travel_request["destination"]

    if not isinstance(
        destination_value,
        str,
    ):

        return {
            "error": "Destination must be a non-empty string."
        }

    destination = destination_value.strip()

    if not destination:

        return {
            "error": "Destination must be a non-empty string."
        }

    if not is_plausible_destination(destination):

        return {
            "error": (
                f"Invalid destination: "
                f"{destination_value!r}. "
                "Enter a real city, region, or country name."
            )
        }

    if not isinstance(
        travel_request["requirements"],
        str,
    ) or not travel_request["requirements"].strip():

        return {
            "error": "Requirements must be a non-empty string."
        }

    if not isinstance(
        travel_request["travelers"],
        int,
    ) or not 1 <= travel_request["travelers"] <= 12:

        return {
            "error": (
                "Travelers must be an integer between 1 and 12."
            )
        }

    if not CREW_FILE.exists():

        return {
            "error": (
                f"Crew configuration file not found: "
                f"{CREW_FILE}"
            )
        }

    # -----------------------------------------------------------------------
    # Step 1: AgentCore Gateway
    # -----------------------------------------------------------------------

    print("=" * 70)
    print("TRAVEL PLANNER")
    print("=" * 70)

    print(
        f"[1/3] AgentCore Gateway lookup: "
        f"{destination}"
    )

    try:

        gateway_record = lookup_destination(
            destination
        )

    except Exception as exc:

        return {
            "error": (
                "Destination verification failed: "
                f"{type(exc).__name__}: {exc}"
            )
        }

    gateway_found = (
        "DATABASE_LOOKUP_RESULT: FOUND"
        in gateway_record
    )

    gateway_not_found = (
        "DATABASE_LOOKUP_RESULT: NOT_FOUND"
        in gateway_record
    )

    gateway_unknown = (
        "DATABASE_LOOKUP_RESULT: UNKNOWN"
        in gateway_record
        or "DATABASE_LOOKUP_ERROR:"
        in gateway_record
    )

    if gateway_found:
        gateway_status = "FOUND"

    elif gateway_not_found:
        gateway_status = "NOT_FOUND"

    elif gateway_unknown:
        gateway_status = "ERROR"

    else:
        gateway_status = "UNKNOWN"

    print(
        f"      Gateway result: "
        f"{gateway_status}"
    )

    # -----------------------------------------------------------------------
    # Step 2: Web research
    # -----------------------------------------------------------------------

    print("[2/3] DDGS web research...")

    try:

        web_research = perform_web_research(
            destination,
            travel_request["requirements"],
        )

    except Exception as exc:

        return {
            "error": (
                "Web research failed: "
                f"{type(exc).__name__}: {exc}"
            )
        }

    print(
        "      Web searches: "
        f"{web_research['successful_searches']}/"
        f"{web_research['total_searches']} successful"
    )

    print(
        "      Useful sources: "
        f"{len(web_research.get('sources', []))}"
    )

    if (
        gateway_not_found
        and web_research["successful_searches"] == 0
    ):

        return {
            "error": (
                f"Destination {destination!r} was not found "
                "in the travel database and web research "
                "returned no useful results."
            ),
            "provenance": {
                "database": {
                    "source": "AgentCore Gateway",
                    "backend": "DynamoDB",
                    "status": gateway_status,
                },
                "web_search": {
                    "source": "DDGS Python library",
                    "provider": "DuckDuckGo",
                    "status": web_research["status"],
                    "successful_searches": (
                        web_research["successful_searches"]
                    ),
                    "total_searches": (
                        web_research["total_searches"]
                    ),
                    "queries": [
                        item["query"]
                        for item in web_research["searches"]
                    ],
                    "source_count": len(
                        web_research.get("sources", [])
                    ),
                    "sources": web_research.get(
                        "sources",
                        [],
                    ),
                },
            },
        }

    if (
        gateway_unknown
        and web_research["successful_searches"] == 0
    ):

        return {
            "error": (
                f"Gateway lookup for {destination!r} "
                "was inconclusive and web research "
                "returned no useful results."
            ),
            "provenance": {
                "database": {
                    "source": "AgentCore Gateway",
                    "backend": "DynamoDB",
                    "status": gateway_status,
                },
                "web_search": {
                    "source": "DDGS Python library",
                    "provider": "DuckDuckGo",
                    "status": web_research["status"],
                    "successful_searches": (
                        web_research["successful_searches"]
                    ),
                    "total_searches": (
                        web_research["total_searches"]
                    ),
                    "queries": [
                        item["query"]
                        for item in web_research["searches"]
                    ],
                    "source_count": len(
                        web_research.get("sources", [])
                    ),
                    "sources": web_research.get(
                        "sources",
                        [],
                    ),
                },
            },
        }

    if (
        not gateway_found
        and not gateway_not_found
        and not gateway_unknown
    ):

        return {
            "error": (
                "Gateway returned an unrecognized response."
            )
        }

    # -----------------------------------------------------------------------
    # Step 3: CrewAI / LLM synthesis
    # -----------------------------------------------------------------------

    print("[3/3] CrewAI + Nova Micro synthesis...")

    try:

        itinerary = run_crew(
            travel_request,
            gateway_record,
            web_research,
        )

    except Exception as exc:

        print(
            "CrewAI execution failed: "
            f"{type(exc).__name__}: {exc}"
        )

        return {
            "error": "CrewAI execution failed.",
            "details": str(exc),
            "provenance": build_provenance(
                gateway_status,
                web_research,
            ),
        }

    print("      CrewAI synthesis completed.")

    # -----------------------------------------------------------------------
    # Provenance
    # -----------------------------------------------------------------------

    provenance = build_provenance(
        gateway_status,
        web_research,
    )

    # -----------------------------------------------------------------------
    # Final response
    # -----------------------------------------------------------------------

    return {
        "result": itinerary,
        "provenance": provenance,
    }


# ---------------------------------------------------------------------------
# AgentCore Runtime entry point
# ---------------------------------------------------------------------------

@app.entrypoint
def invoke(payload):

    if not OBSERVABILITY_ENABLED:

        return _invoke_impl(payload)

    with tracer.start_as_current_span(
        "travel_planner.invoke"
    ) as span:

        span.set_attribute(
            "travel_planner.payload_type",
            type(payload).__name__,
        )

        try:

            result = _invoke_impl(payload)

            span.set_attribute(
                "travel_planner.success",
                "error" not in result,
            )

            if "provenance" in result:

                provenance = result["provenance"]

                span.set_attribute(
                    "travel_planner.gateway_status",
                    provenance["database"]["status"],
                )

                span.set_attribute(
                    "travel_planner.web_search_status",
                    provenance["web_search"]["status"],
                )

                span.set_attribute(
                    "travel_planner.web_search_successful",
                    provenance["web_search"][
                        "successful_searches"
                    ],
                )

                span.set_attribute(
                    "travel_planner.web_source_count",
                    provenance["web_search"][
                        "source_count"
                    ],
                )

            return result

        except Exception as exc:

            span.record_exception(exc)

            span.set_status(
                Status(
                    StatusCode.ERROR,
                    str(exc),
                )
            )

            raise


# ---------------------------------------------------------------------------
# Local AgentCore runtime
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    app.run()