import json
from datetime import date, timedelta

import boto3
import streamlit as st
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError, ReadTimeoutError


AWS_REGION = "ap-south-1"
LAMBDA_FUNCTION_NAME = "test-planner-function"

st.set_page_config(page_title="AI Travel Planner", page_icon="✈️", layout="wide")


@st.cache_resource
def lambda_client():
    return boto3.client(
        "lambda",
        region_name=AWS_REGION,
        config=Config(
            connect_timeout=10,
            read_timeout=910,
            retries={"max_attempts": 2, "mode": "standard"},
        ),
    )


def invoke_lambda(travel_request: dict):
    response = lambda_client().invoke(
        FunctionName=LAMBDA_FUNCTION_NAME,
        InvocationType="RequestResponse",
        Payload=json.dumps(travel_request).encode(),
    )
    raw = response["Payload"].read().decode()
    result = json.loads(raw) if raw else None
    if response.get("FunctionError"):
        raise RuntimeError(result or "Lambda returned an error")
    return result


def display_result(result):
    if result is None:
        st.info("Lambda returned no result.")
        return

    if isinstance(result, dict) and "body" in result:
        body = result["body"]
        result = json.loads(body) if isinstance(body, str) else body

    if isinstance(result, dict):
        if result.get("error"):
            st.error(result["error"])
            return
        result = result.get("result", result.get("output", result))

    st.markdown(result if isinstance(result, str) else "")
    if not isinstance(result, str):
        st.json(result)


st.title("AI Travel Planner")
st.caption("Streamlit demo that invokes the configured AWS Lambda.")

request = st.text_area(
    "Trip interests and requirements",
    "Plan a relaxed trip focused on nature, local food, and sightseeing.",
    height=120,
)
destination = st.text_input("Destination", "Ooty")
travelers = st.number_input("Number of travelers", min_value=1, max_value=12, value=2, step=1)
budget = st.selectbox("Budget", ["Budget", "Mid-range", "Premium"])
start_date = st.date_input("Starting date", value=date.today() + timedelta(days=14))
end_date = st.date_input(
    "Ending date",
    value=date.today() + timedelta(days=17),
    min_value=start_date,
)
transport_priority = st.selectbox(
    "Travel priority",
    ["Cheapest overall", "Prefer car", "Prefer bus", "Prefer train", "Prefer flight"],
    help="The preferred mode is compared with alternatives; prices remain estimates without a live pricing API.",
)

if st.button("Generate itinerary", type="primary"):
    if not destination.strip():
        st.warning("Enter a destination first.")
    elif not request.strip():
        st.warning("Enter trip interests or requirements first.")
    elif end_date < start_date:
        st.warning("The ending date must be on or after the starting date.")
    else:
        try:
            with st.spinner("Generating itinerary..."):
                result = invoke_lambda(
                    {
                        "destination": destination.strip(),
                        "requirements": request.strip(),
                        "travelers": int(travelers),
                        "budget": budget,
                        "start_date": start_date.isoformat(),
                        "end_date": end_date.isoformat(),
                        "transport_priority": transport_priority,
                    }
                )
            display_result(result)
        except ReadTimeoutError as exc:
            st.error(
                "The Lambda request timed out while waiting for a response. "
                "Check the Lambda and AgentCore logs to see whether it completed.\n\n"
                f"{exc}"
            )
        except (ClientError, BotoCoreError, RuntimeError) as exc:
            st.error(str(exc))
        except Exception as exc:
            st.error(f"Unexpected error: {exc}")
