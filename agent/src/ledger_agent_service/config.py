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
    service_token: str = ""
    access_token: str = ""

    @classmethod
    def load(cls) -> "Settings":
        service_token = os.environ.get("AGENT_SERVICE_TOKEN", "").strip()
        access_token = os.environ.get("LEDGER_AGENT_TOKEN", "").strip()
        if not service_token and not access_token:
            raise RuntimeError("AGENT_SERVICE_TOKEN or LEDGER_AGENT_TOKEN is required")
        telegram_token = os.environ.get("BUB_TELEGRAM_TOKEN", "").strip()
        telegram_users = os.environ.get("BUB_TELEGRAM_ALLOW_USERS", "").strip()
        telegram_chats = os.environ.get("BUB_TELEGRAM_ALLOW_CHATS", "").strip()
        if telegram_token and not telegram_users and not telegram_chats:
            raise RuntimeError("BUB_TELEGRAM_ALLOW_USERS or BUB_TELEGRAM_ALLOW_CHATS is required when Telegram is enabled")
        credential = service_token or access_token
        ledger_api_url = _required("LEDGER_API_URL").rstrip("/")
        os.environ.setdefault("BUB_MODEL", "openai:ledger-agent")
        os.environ.setdefault(
            "BUB_API_BASE",
            f"{ledger_api_url}/api/internal/agent/model" if service_token else f"{ledger_api_url}/api/agent/model",
        )
        os.environ.setdefault("BUB_API_KEY", credential)
        return cls(
            database_url=os.environ.get("DATABASE_URL", "").strip(),
            ledger_api_url=ledger_api_url,
            service_token=service_token,
            access_token=access_token,
        )

    @property
    def hosted(self) -> bool:
        return bool(self.service_token)
