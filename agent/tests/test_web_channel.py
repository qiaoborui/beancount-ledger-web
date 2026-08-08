from __future__ import annotations

from collections.abc import AsyncIterator

import pytest
from bub.channels.message import ChannelMessage
from bub.streaming import StreamEvent

from ledger_agent_service.protocol import ToolSpec
from ledger_agent_service.web_channel import LedgerWebChannel, WebTurn, _tool_result_payload


async def _empty_stream(event: StreamEvent) -> AsyncIterator[StreamEvent]:
    yield event


@pytest.mark.asyncio
async def test_stream_errors_are_forwarded_once_by_bub_error_dispatch() -> None:
    async def receive(_: ChannelMessage) -> None:
        return None

    async def record(_: str, __: str, ___: dict) -> None:
        return None

    channel = LedgerWebChannel(receive, {}, record)
    turn = WebTurn(id="turn-1", session_id="session-1", mode="ledger")
    message = ChannelMessage(
        session_id="session-1",
        channel="web",
        content="hello",
        context={"_ledger_web_turn": turn},
    )
    stream = channel.stream_events(message, _empty_stream(StreamEvent("error", {"message": "failed"})))

    assert [event async for event in stream] == [StreamEvent("error", {"message": "failed"})]
    assert turn.queue.empty()


@pytest.mark.asyncio
async def test_outbound_messages_are_correlated_to_the_exact_web_turn() -> None:
    async def receive(_: ChannelMessage) -> None:
        return None

    async def record(_: str, __: str, ___: dict) -> None:
        return None

    channel = LedgerWebChannel(receive, {}, record)
    first = WebTurn(id="turn-1", session_id="shared", mode="ledger")
    second = WebTurn(id="turn-2", session_id="shared", mode="ledger")
    channel._turns = {first.id: first, second.id: second}

    await channel.send(ChannelMessage(
        session_id="shared",
        channel="web",
        content="failed",
        kind="error",
        context={"_ledger_web_turn": first},
    ))
    await channel.send(ChannelMessage(
        session_id="shared",
        channel="web",
        content="stale final",
        context={"_ledger_web_turn": first},
    ))
    await channel.send(ChannelMessage(
        session_id="shared",
        channel="web",
        content="second final",
        context={"_ledger_web_turn": second},
    ))

    second_events = []
    while not second.queue.empty():
        second_events.append(second.queue.get_nowait())
    assert ("final", {
        "sessionId": "shared",
        "message": "second final",
        "status": "completed",
        "refreshLedger": False,
    }) in second_events
    assert all(not event or "stale final" not in str(event) for event in second_events)


def test_mcp_string_results_restore_client_artifacts_and_refresh_state() -> None:
    spec = ToolSpec(
        name="mcp.ledger_run_bql",
        description="query",
        parameters={"type": "object", "properties": {}},
        title="运行 BQL",
    )
    payload, artifacts, changed = _tool_result_payload(
        {"id": "tool-1", "name": spec.name, "arguments": {}},
        spec,
        '{"modelOutput":{"rows":[]},"clientOutput":{"columns":[]},"artifacts":[{"id":"a1"}],"refreshLedger":true}',
    )

    assert payload["output"] == {"columns": []}
    assert artifacts == [{"id": "a1"}]
    assert changed is True
