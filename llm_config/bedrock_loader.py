"""Utilities for loading Amazon Bedrock configuration and clients."""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Optional

import boto3


@dataclass
class BedrockConfig:
    """Configuration settings for connecting to Amazon Bedrock."""

    region: str
    model_id: str


def load_bedrock_config() -> BedrockConfig:
    """Load Bedrock configuration from environment variables.

    Returns
    -------
    BedrockConfig
        Populated configuration object with region and model identifier.
    """

    region = os.getenv("AWS_REGION", "us-east-1")
    model_id = os.getenv("BEDROCK_MODEL_ID", "")
    return BedrockConfig(region=region, model_id=model_id)


def get_bedrock_client(config: Optional[BedrockConfig] = None):
    """Create a boto3 Bedrock client using provided configuration.

    Parameters
    ----------
    config: Optional[BedrockConfig]
        Pre-loaded configuration. If ``None``, :func:`load_bedrock_config` is used.

    Returns
    -------
    botocore.client.BaseClient
        Configured Bedrock client.
    """

    cfg = config or load_bedrock_config()
    return boto3.client("bedrock-runtime", region_name=cfg.region)
