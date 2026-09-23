import json
import os
import uuid

import boto3


agentcore = boto3.client("bedrock-agentcore")


def lambda_handler(event, context):
    payload = event

    session_id = f"{uuid.uuid4().hex}-travel-planner-session"

    response = agentcore.invoke_agent_runtime(
        agentRuntimeArn=os.environ["AGENT_RUNTIME_ARN"],
        runtimeSessionId=session_id,
        payload=json.dumps(payload).encode("utf-8"),
    )

    body = response["response"].read()

    if isinstance(body, bytes):
        body = body.decode("utf-8")

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": body,
    }
