import json

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


def invoke_lambda(topic: str):
    response = lambda_client().invoke(
        FunctionName=LAMBDA_FUNCTION_NAME,
        InvocationType="RequestResponse",
        Payload=json.dumps({"topic": topic}).encode(),
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
        result = result.get("result", result.get("output", result))

    st.markdown(result if isinstance(result, str) else "")
    if not isinstance(result, str):
        st.json(result)


st.title("AI Travel Planner")
st.caption("Streamlit demo that invokes the configured AWS Lambda.")

request = st.text_area(
    "Travel request",
    "Plan a 4-day trip to Ooty for two adults.",
    height=120,
)

if st.button("Generate itinerary", type="primary"):
    if not request.strip():
        st.warning("Enter a travel request first.")
    else:
        try:
            with st.spinner("Generating itinerary..."):
                result = invoke_lambda(request.strip())
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
