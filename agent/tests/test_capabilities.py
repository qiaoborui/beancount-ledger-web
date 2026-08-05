import json

import httpx
import pytest

from ledger_agent_service.capabilities import LedgerCapabilities


def _bootstrap_response() -> dict:
    return {
        "capabilityToken": "capability",
        "systemPrompt": "prompt",
        "tools": [],
        "expiresAt": "2026-08-05T00:00:00Z",
    }


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("service_token", "access_token", "path", "header", "value"),
    [
        ("service-token", "", "/api/internal/agent/bootstrap", "X-Agent-Service-Token", "service-token"),
        ("", "access-token", "/api/agent/bootstrap", "Authorization", "Bearer access-token"),
    ],
)
async def test_bootstrap_uses_the_matching_gateway_authentication(
    service_token: str,
    access_token: str,
    path: str,
    header: str,
    value: str,
) -> None:
    async def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == path
        assert request.headers[header] == value
        assert json.loads(request.content) == {
            "sessionId": "telegram:123",
            "channel": "telegram",
            "context": {"page": "home"},
        }
        return httpx.Response(200, json=_bootstrap_response())

    capabilities = LedgerCapabilities(
        "https://ledger.example",
        service_token=service_token,
        access_token=access_token,
    )
    await capabilities.client.aclose()
    capabilities.client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    try:
        result = await capabilities.bootstrap(
            session_id="telegram:123",
            channel="telegram",
            context={"page": "home"},
        )
    finally:
        await capabilities.close()
    assert result.capability_token == "capability"


@pytest.mark.asyncio
async def test_execute_forwards_tool_arguments_without_approval_metadata() -> None:
    async def handler(request: httpx.Request) -> httpx.Response:
        payload = json.loads(request.content)
        assert payload == {"arguments": {"value": 1}}
        return httpx.Response(200, json={"modelOutput": {"ok": True}, "clientOutput": {"ok": True}})

    capabilities = LedgerCapabilities("https://ledger.example", "service-token")
    await capabilities.client.aclose()
    capabilities.client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    try:
        result = await capabilities.execute("write_tool", {"value": 1}, "capability")
    finally:
        await capabilities.close()
    assert result.model_output == {"ok": True}


@pytest.mark.asyncio
async def test_execute_accepts_null_artifacts_from_older_gateway() -> None:
    async def handler(_: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "modelOutput": {"ok": True},
                "clientOutput": {"ok": True},
                "artifacts": None,
                "refreshLedger": False,
            },
        )

    capabilities = LedgerCapabilities("https://ledger.example", "service-token")
    await capabilities.client.aclose()
    capabilities.client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    try:
        result = await capabilities.execute("read_tool", {}, "capability")
    finally:
        await capabilities.close()
    assert result.artifacts == []
