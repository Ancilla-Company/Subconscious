"""Model configuration domain and camelCase API models."""

from dataclasses import dataclass
from typing import Any

from pydantic import BaseModel, ConfigDict, Field

from subconscious_engine.capabilities import ModelCapabilities


class _ApiModel(BaseModel):
    model_config = ConfigDict(extra="ignore", populate_by_name=True)


class ModelConfigurationDto(_ApiModel):
    """Redacted model configuration; credentials are intentionally absent."""

    id: str
    provider: str
    model: str
    alias: str | None = None
    base_url: str | None = Field(default=None, alias="baseUrl")
    region: str | None = None
    context_window: int | None = Field(default=None, alias="contextWindow")
    has_api_key: bool = Field(alias="hasApiKey")
    # The user's explicit capability flags (a subset); the rest is inferred.
    capabilities: dict[str, bool] | None = None


class UpsertModelConfigurationRequest(_ApiModel):
    """Create/update payload with write-only API and Bedrock credentials."""

    provider: str
    model: str
    alias: str | None = None
    base_url: str | None = Field(default=None, alias="baseUrl")
    region: str | None = None
    context_window: int | None = Field(default=None, alias="contextWindow")
    api_key: str | None = Field(default=None, alias="apiKey")
    aws_access_key_id: str | None = Field(default=None, alias="awsAccessKeyId")
    aws_secret_access_key: str | None = Field(default=None, alias="awsSecretAccessKey")
    aws_session_token: str | None = Field(default=None, alias="awsSessionToken")
    clear_api_key: bool = Field(default=False, alias="clearApiKey")
    # Explicit capability flags. Omit to keep what is stored; send {} to clear them.
    capabilities: dict[str, bool] | None = None


class ModelDto(_ApiModel):
    id: str
    name: str
    provider: str
    description: str | None = None
    capabilities: ModelCapabilities | None = None


@dataclass(frozen=True, slots=True)
class ModelConfig:
    """Complete engine-only configuration returned by resolution."""

    id: str
    provider: str
    model: str
    api_key: str | None = None
    system_prompt: str | None = None
    base_url: str | None = None
    region: str | None = None
    aws_access_key_id: str | None = None
    aws_secret_access_key: str | None = None
    aws_session_token: str | None = None
    context_window: int | None = None
    stream_timeout_seconds: float | None = None
    extra: dict[str, Any] | None = None
