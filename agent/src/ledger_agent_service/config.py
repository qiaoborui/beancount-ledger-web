from __future__ import annotations

import os
from dataclasses import dataclass


def _required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"{name} is required")
    return value


@dataclass(frozen=True)
class Settings:
    database_url: str
    ledger_api_url: str
    service_token: str
    approval_timeout_seconds: int = 600

    @classmethod
    def load(cls) -> "Settings":
        timeout = int(os.environ.get("AGENT_APPROVAL_TIMEOUT_SECONDS", "600"))
        if timeout < 30 or timeout > 720:
            raise RuntimeError("AGENT_APPROVAL_TIMEOUT_SECONDS must be between 30 and 720")
        service_token = _required("AGENT_SERVICE_TOKEN")
        os.environ.setdefault("BUB_API_KEY", service_token)
        return cls(
            database_url=_required("DATABASE_URL"),
            ledger_api_url=_required("LEDGER_API_URL").rstrip("/"),
            service_token=service_token,
            approval_timeout_seconds=timeout,
        )
