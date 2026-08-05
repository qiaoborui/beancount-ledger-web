from __future__ import annotations

from collections.abc import AsyncIterator

import pytest
from bub.channels.message import ChannelMessage
from bub.streaming import StreamEvent

from ledger_agent_service.web_channel import LedgerWebChannel, WebTurn


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
