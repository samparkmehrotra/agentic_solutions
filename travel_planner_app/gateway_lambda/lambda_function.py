import json
import os

import boto3


table = boto3.resource("dynamodb").Table(os.environ["TRAVEL_TABLE_NAME"])


def lambda_handler(event, context):
    """Return the predefined travel plan for the requested city."""
    arguments = event
    if isinstance(event, dict):
        arguments = event.get("arguments", event.get("body", event))
    if isinstance(arguments, str):
        arguments = json.loads(arguments)

    city = arguments.get("city") if isinstance(arguments, dict) else None
    if not isinstance(city, str) or not city.strip():
        return {"statusCode": 400, "body": json.dumps({"error": "city is required"})}

    normalized_city = city.strip()
    item = table.get_item(Key={"city": normalized_city}).get("Item")
    if not item:
        return {
            "statusCode": 404,
            "body": json.dumps({"city": normalized_city, "found": False}),
        }

    return {
        "statusCode": 200,
        "body": json.dumps({"found": True, **item}, default=str),
    }
