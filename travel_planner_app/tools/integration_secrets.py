"""Read optional Gateway settings from one AWS Secrets Manager secret."""

import json
import os
from functools import lru_cache
from typing import Any

import boto3


SECRET_ID = "travel-planner/integrations"


@lru_cache(maxsize=1)
def read_settings() -> dict[str, Any]:
    """Read and cache the integration JSON secret for this process."""
    region = os.getenv("AWS_REGION", "ap-south-1")
    response = boto3.client("secretsmanager", region_name=region).get_secret_value(
        SecretId=SECRET_ID
    )
    raw_secret = response.get("SecretString", "").strip()
    if not raw_secret:
        raise RuntimeError(f"Secret {SECRET_ID!r} has no SecretString")

    settings = json.loads(raw_secret)
    if not isinstance(settings, dict):
        raise RuntimeError(f"Secret {SECRET_ID!r} must contain a JSON object")
    return settings


def get_setting(name: str) -> str:
    """Return one required string setting from the integration secret."""
    value = read_settings().get(name)
    if not isinstance(value, str) or not value.strip():
        raise RuntimeError(f"Secret {SECRET_ID!r} is missing {name!r}")
    return value.strip()
