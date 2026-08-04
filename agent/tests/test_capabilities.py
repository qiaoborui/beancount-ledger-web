import json

import httpx
import pytest

from ledger_agent_service.capabilities import LedgerCapabilities


@pytest.mark.asyncio
async def test_execute_forwards_preview_confirmation_token() -> None:
    async def handler(request: httpx.Request) -> httpx.Response:
        payload = json.loads(request.content)
        assert payload == {"arguments": {"value": 1}, "confirmationToken": "confirmed-preview"}
        return httpx.Response(200, json={"modelOutput": {"ok": True}, "clientOutput": {"ok": True}})

    capabilities = LedgerCapabilities("https://ledger.example", "service-token")
    await capabilities.client.aclose()
    capabilities.client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    try:
        result = await capabilities.execute("write_tool", {"value": 1}, "capability", "confirmed-preview")
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
