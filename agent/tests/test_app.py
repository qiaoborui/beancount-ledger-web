from __future__ import annotations

import httpx

from ledger_agent_service.config import Settings


def test_runtime_is_injected_instead_of_exposed_as_query_parameter(monkeypatch) -> None:
    monkeypatch.setenv("AGENT_SERVICE_TOKEN", "test-token")
    monkeypatch.setenv("DATABASE_URL", "postgresql://unused")
    monkeypatch.setenv("LEDGER_API_URL", "http://server")
    monkeypatch.setenv("BUB_MODEL", "openai:test")
    monkeypatch.setenv("BUB_API_BASE", "http://server/model")

    from ledger_agent_service.app import create_app

    app = create_app(
        Settings(database_url="postgresql://unused", ledger_api_url="http://server", service_token="test-token")
    )
    schema = app.openapi()
    operations = (
        schema["paths"]["/v1/channels/web/messages"]["post"],
        schema["paths"]["/v1/channels/telegram/updates"]["post"],
        schema["paths"]["/v1/onboarding/turn"]["post"],
        schema["paths"]["/v1/sessions/{session_id}/timeline"]["get"],
        schema["paths"]["/v1/sessions/{session_id}"]["delete"],
    )

    for operation in operations:
        parameters = operation.get("parameters", [])
        assert all(parameter["name"] != "agent" for parameter in parameters)


async def test_telegram_updates_endpoint_requires_service_token_and_forwards_payload() -> None:
    received: list[bytes] = []

    class FakeGateway:
        async def telegram_update(self, raw: bytes) -> None:
            received.append(raw)

    from ledger_agent_service.app import create_app

    app = create_app(
        Settings(database_url="postgresql://unused", ledger_api_url="http://server", service_token="test-token")
    )
    app.state.runtime = FakeGateway()
    transport = httpx.ASGITransport(app=app)

    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        missing = await client.post(
            "/v1/channels/telegram/updates",
            content=b'{"update_id": 7}',
        )
        assert missing.status_code == 401
        assert received == []

        wrong = await client.post(
            "/v1/channels/telegram/updates",
            content=b'{"update_id": 7}',
            headers={"X-Agent-Service-Token": "wrong-token"},
        )
        assert wrong.status_code == 401
        assert received == []

        ok = await client.post(
            "/v1/channels/telegram/updates",
            content=b'{"update_id": 7}',
            headers={"X-Agent-Service-Token": "test-token"},
        )
        assert ok.status_code == 204
        assert received == [b'{"update_id": 7}']

        large = await client.post(
            "/v1/channels/telegram/updates",
            content=b"x" * (1 << 20) + b'{"update_id": 8}',
            headers={"X-Agent-Service-Token": "test-token"},
        )
        assert large.status_code == 413
        assert len(received) == 1
