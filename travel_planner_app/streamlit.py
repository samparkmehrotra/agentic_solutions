import json
import boto3
import streamlit as st
from botocore.exceptions import ClientError, BotoCoreError


# ============================================================
# Configuration
# ============================================================

AWS_REGION = "ap-south-1"
LAMBDA_FUNCTION_NAME = "test-planner-function"


# ============================================================
# Page configuration
# ============================================================

st.set_page_config(
    page_title="AI Travel Planner",
    page_icon="✈️",
    layout="wide",
    initial_sidebar_state="expanded",
)


# ============================================================
# Custom CSS
# ============================================================

st.markdown(
    """
    <style>
        .main-title {
            font-size: 2.5rem;
            font-weight: 700;
            margin-bottom: 0.2rem;
        }

        .subtitle {
            font-size: 1.05rem;
            color: #666;
            margin-bottom: 2rem;
        }

        .result-box {
            padding: 1.5rem;
            border-radius: 12px;
            border: 1px solid #e5e7eb;
            background-color: #fafafa;
            margin-top: 1rem;
        }

        .status-box {
            padding: 0.8rem 1rem;
            border-radius: 8px;
            background-color: #f5f7fa;
            border: 1px solid #e1e5ea;
            margin-bottom: 1rem;
        }

        .stButton > button {
            width: 100%;
            border-radius: 8px;
            font-weight: 600;
            padding: 0.65rem 1rem;
        }

        [data-testid="stSidebar"] {
            border-right: 1px solid #e5e7eb;
        }
    </style>
    """,
    unsafe_allow_html=True,
)


# ============================================================
# AWS Lambda client
# ============================================================

@st.cache_resource
def get_lambda_client():
    """
    Create and cache the boto3 Lambda client.

    boto3 will use the AWS credential chain:
      - Environment variables
      - ~/.aws/credentials
      - IAM role, if running on AWS
      - Other standard AWS credential providers
    """
    return boto3.client(
        "lambda",
        region_name=AWS_REGION,
    )


# ============================================================
# Lambda invocation
# ============================================================

def invoke_lambda(topic: str):
    """
    Invoke the Lambda function synchronously and return the result.
    """

    lambda_client = get_lambda_client()

    payload = {
        "topic": topic
    }

    response = lambda_client.invoke(
        FunctionName=LAMBDA_FUNCTION_NAME,
        InvocationType="RequestResponse",
        Payload=json.dumps(payload).encode("utf-8"),
    )

    # --------------------------------------------------------
    # Check Lambda function-level errors
    # --------------------------------------------------------

    if response.get("FunctionError"):
        raw_payload = response["Payload"].read().decode("utf-8")

        try:
            error_payload = json.loads(raw_payload)
        except json.JSONDecodeError:
            error_payload = raw_payload

        raise RuntimeError(
            f"Lambda returned an error:\n\n{error_payload}"
        )

    # --------------------------------------------------------
    # Read Lambda response
    # --------------------------------------------------------

    raw_payload = response["Payload"].read().decode("utf-8")

    if not raw_payload:
        return None

    try:
        result = json.loads(raw_payload)
    except json.JSONDecodeError:
        return raw_payload

    return result


# ============================================================
# Extract useful response from Lambda
# ============================================================

def extract_lambda_output(result):
    """
    Try to handle common Lambda response formats.

    Examples:

    1. Direct string:
       "London itinerary..."

    2. Dictionary:
       {"result": "London itinerary..."}

    3. API-style response:
       {
           "statusCode": 200,
           "body": "..."
       }

    4. CrewAI/custom response:
       {
           "output": "..."
       }
    """

    if result is None:
        return "Lambda returned an empty response."

    # Direct string
    if isinstance(result, str):
        return result

    # Dictionary
    if isinstance(result, dict):

        # API Gateway style response
        if "body" in result:
            body = result["body"]

            if isinstance(body, str):
                try:
                    body_json = json.loads(body)

                    if isinstance(body_json, dict):
                        for key in [
                            "result",
                            "output",
                            "response",
                            "message",
                        ]:
                            if key in body_json:
                                return body_json[key]

                    return body_json

                except json.JSONDecodeError:
                    return body

            return body

        # Common application response fields
        for key in [
            "result",
            "output",
            "response",
            "answer",
            "message",
        ]:
            if key in result:
                return result[key]

    # Fallback
    return result


# ============================================================
# Sidebar
# ============================================================

with st.sidebar:

    st.markdown("## ✈️ Travel Planner")

    st.markdown("---")

    st.markdown("### Configuration")

    st.text_input(
        "AWS Region",
        value=AWS_REGION,
        disabled=True,
    )

    st.text_input(
        "Lambda Function",
        value=LAMBDA_FUNCTION_NAME,
        disabled=True,
    )

    st.markdown("---")

    st.markdown("### Architecture")

    st.code(
        """
Streamlit
    ↓
boto3
    ↓
AWS Lambda
    ↓
CrewAI
    ↓
Amazon Bedrock
    ↓
Travel Itinerary
        """,
        language="text",
    )

    st.markdown("---")

    st.caption(
        "Direct Lambda invocation is used here "
        "to avoid the API Gateway ~29 second timeout "
        "during testing."
    )


# ============================================================
# Main UI
# ============================================================

st.markdown(
    '<div class="main-title">✈️ AI Travel Planner</div>',
    unsafe_allow_html=True,
)

st.markdown(
    '<div class="subtitle">'
    "Describe your travel requirements and let the AI "
    "create an itinerary for you."
    "</div>",
    unsafe_allow_html=True,
)


# ============================================================
# Travel request input
# ============================================================

st.markdown("### 📝 Your Travel Request")

default_request = (
    "Plan an itinerary for Sitapur with 2 adults and 1 infant. "
    "There is no limit on budget."
)

topic = st.text_area(
    "What would you like to plan?",
    value=default_request,
    height=140,
    placeholder=(
        "Example: Plan a 5-day trip to London for 2 adults "
        "and 1 child with a comfortable budget."
    ),
)


# ============================================================
# Example prompts
# ============================================================

with st.expander("💡 Example requests"):

    examples = [
        "Plan a 5-day trip to London for 2 adults and 1 infant.",
        "Plan a weekend trip to Jaipur for 2 adults with a luxury budget.",
        "Plan a 7-day family vacation to Kerala for 2 adults and 1 child.",
        "Plan a 10-day Europe trip covering Paris, Amsterdam and Switzerland.",
    ]

    for example in examples:
        st.markdown(f"- {example}")


# ============================================================
# Generate button
# ============================================================

generate = st.button(
    "🚀 Generate Travel Itinerary",
    type="primary",
)


# ============================================================
# Process request
# ============================================================

if generate:

    if not topic.strip():
        st.warning("Please enter your travel requirements.")
        st.stop()

    # --------------------------------------------------------
    # Request preview
    # --------------------------------------------------------

    st.markdown("### 📋 Request")

    st.info(topic)

    # --------------------------------------------------------
    # Invoke Lambda
    # --------------------------------------------------------

    with st.spinner(
        "🤖 AI travel planner is working... "
        "This may take a minute because CrewAI is performing research."
    ):

        try:

            result = invoke_lambda(topic)

        except ClientError as e:

            error_code = e.response.get(
                "Error", {}
            ).get(
                "Code",
                "Unknown",
            )

            error_message = e.response.get(
                "Error", {}
            ).get(
                "Message",
                str(e),
            )

            st.error(
                f"AWS error: {error_code}\n\n"
                f"{error_message}"
            )

            st.stop()

        except BotoCoreError as e:

            st.error(
                f"AWS connection error:\n\n{str(e)}"
            )

            st.stop()

        except Exception as e:

            st.error(
                f"Application error:\n\n{str(e)}"
            )

            st.stop()

    # --------------------------------------------------------
    # Extract final output
    # --------------------------------------------------------

    output = extract_lambda_output(result)

    # --------------------------------------------------------
    # Display result
    # --------------------------------------------------------

    st.markdown("### 🗺️ Your Travel Itinerary")

    st.markdown(
        '<div class="result-box">',
        unsafe_allow_html=True,
    )

    if isinstance(output, str):

        st.markdown(output)

    elif isinstance(output, dict):

        # If output itself contains useful structured data
        st.json(output)

    elif isinstance(output, list):

        for item in output:
            st.markdown(f"- {item}")

    else:

        st.write(output)

    st.markdown("</div>", unsafe_allow_html=True)

    # --------------------------------------------------------
    # Debug information
    # --------------------------------------------------------

    with st.expander("🔍 Lambda Response (Debug)"):

        st.json(result)

    st.success("✅ Travel itinerary generated successfully.")