from __future__ import annotations

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
        schema["paths"]["/v1/onboarding/turn"]["post"],
        schema["paths"]["/v1/sessions/{session_id}/timeline"]["get"],
        schema["paths"]["/v1/sessions/{session_id}"]["delete"],
    )

    for operation in operations:
        parameters = operation.get("parameters", [])
        assert all(parameter["name"] != "agent" for parameter in parameters)
