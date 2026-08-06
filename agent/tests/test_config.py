import os

import pytest

from ledger_agent_service.config import Settings


def test_service_token_defaults_bub_api_key(monkeypatch) -> None:
    monkeypatch.setenv("DATABASE_URL", "postgresql://ledger@example/ledger")
    monkeypatch.setenv("LEDGER_API_URL", "https://ledger.example/")
    monkeypatch.setenv("AGENT_SERVICE_TOKEN", "shared-token")
    monkeypatch.delenv("BUB_API_KEY", raising=False)

    settings = Settings.load()

    assert settings.ledger_api_url == "https://ledger.example"
    assert os.environ["BUB_API_KEY"] == "shared-token"


def test_telegram_requires_an_explicit_allow_list(monkeypatch) -> None:
    monkeypatch.setenv("LEDGER_API_URL", "https://ledger.example")
    monkeypatch.setenv("AGENT_SERVICE_TOKEN", "shared-token")
    monkeypatch.setenv("BUB_TELEGRAM_TOKEN", "bot-token")
    monkeypatch.delenv("BUB_TELEGRAM_ALLOW_USERS", raising=False)
    monkeypatch.delenv("BUB_TELEGRAM_ALLOW_CHATS", raising=False)

    with pytest.raises(RuntimeError, match="BUB_TELEGRAM_ALLOW_USERS or BUB_TELEGRAM_ALLOW_CHATS"):
        Settings.load()


def test_telegram_mode_defaults_to_polling_and_validates_value(monkeypatch) -> None:
    monkeypatch.setenv("LEDGER_API_URL", "https://ledger.example")
    monkeypatch.setenv("AGENT_SERVICE_TOKEN", "shared-token")
    monkeypatch.delenv("BUB_TELEGRAM_MODE", raising=False)

    assert Settings.load().telegram_mode == "polling"

    monkeypatch.setenv("BUB_TELEGRAM_MODE", "webhook")
    assert Settings.load().telegram_mode == "webhook"

    monkeypatch.setenv("BUB_TELEGRAM_MODE", "WebHook")
    assert Settings.load().telegram_mode == "webhook"

    monkeypatch.setenv("BUB_TELEGRAM_MODE", "invalid")
    with pytest.raises(RuntimeError, match="BUB_TELEGRAM_MODE"):
        Settings.load()
