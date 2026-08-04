from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


class PageContext(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    page: str = ""
    path: str = ""
    start: str = ""
    end: str = ""
    valuation_currency: str = Field("", alias="valuationCurrency")
    bql_query: str = Field("", alias="bqlQuery")


class TurnRequest(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    session_id: str = Field(alias="sessionId")
    message: str
    context: PageContext = Field(default_factory=PageContext)
    approval_policy: Literal["on-write", "always"] = Field("on-write", alias="approvalPolicy")
    capability_token: str = Field(alias="capabilityToken")
    system_prompt: str = Field(alias="systemPrompt")

    @field_validator("session_id")
    @classmethod
    def validate_session_id(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("sessionId is required")
        return value


class InteractionResponse(BaseModel):
    approved: bool


class OnboardingMessage(BaseModel):
    role: Literal["user", "assistant"]
    content: str


class OnboardingRequest(BaseModel):
    start: bool = False
    message: str = ""
    messages: list[OnboardingMessage] = Field(default_factory=list)
    draft: dict[str, Any] | None = None
    ready: bool = False

    @field_validator("message")
    @classmethod
    def validate_message(cls, value: str) -> str:
        if len(value) > 4000:
            raise ValueError("onboarding message is too long")
        return value.strip()


class ToolSpec(BaseModel):
    name: str
    description: str
    parameters: dict[str, Any]
    title: str
    requires_approval: bool = Field(alias="requiresApproval")
    approval_message: str = Field("", alias="approvalMessage")
    execution_status: str = Field("", alias="executionStatus")
    read_only: bool = Field(alias="readOnly")


class CapabilityResult(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    model_output: Any = Field(None, alias="modelOutput")
    client_output: Any = Field(None, alias="clientOutput")
    artifacts: list[dict[str, Any]] = Field(default_factory=list)
    refresh_ledger: bool = Field(False, alias="refreshLedger")
    confirmation_token: str = Field("", alias="confirmationToken")

    @field_validator("artifacts", mode="before")
    @classmethod
    def normalize_artifacts(cls, value: Any) -> Any:
        return [] if value is None else value
