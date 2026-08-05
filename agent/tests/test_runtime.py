from __future__ import annotations

import asyncio
from collections import defaultdict
from pathlib import Path
from types import SimpleNamespace

import pytest
from bub.channels.admission import TurnSnapshot
from bub.channels.message import ChannelMessage
from bub.hooks.interception import ToolCall
from bub.streaming import AsyncStreamEvents, StreamEvent

from ledger_agent_service.config import Settings
from ledger_agent_service.interactions import InteractionBroker
from ledger_agent_service.protocol import ToolSpec, TurnRequest
from ledger_agent_service.runtime import AgentGateway, CONFIRM_PHRASES, LedgerPlugin, LedgerTelegramChannel


class FakeBroker:
    def __init__(self) -> None:
        self.pending = True
        self.resolutions: list[bool] = []

    async def has_pending_session(self, session_id: str, subject: str | None = None) -> bool:
        return self.pending and session_id == "telegram:123" and subject in {None, "user-1"}

    async def resolve_session(self, session_id: str, approved: bool, subject: str = "") -> None:
        assert session_id == "telegram:123"
        assert subject == "user-1"
        self.resolutions.append(approved)


@pytest.mark.asyncio
@pytest.mark.parametrize("phrase", sorted(CONFIRM_PHRASES))
async def test_telegram_only_consumes_exact_write_confirmations(phrase: str) -> None:
    plugin = object.__new__(LedgerPlugin)
    plugin.broker = FakeBroker()
    message = ChannelMessage(
        session_id="telegram:123",
        channel="telegram",
        chat_id="123",
        content=phrase,
        context={"_ledger_sender_id": "user-1"},
    )

    decision = await plugin.admit_message(
        "telegram:123",
        message,
        TurnSnapshot("telegram:123", True, 1, 0),
    )

    assert plugin.broker.resolutions == [True]
    assert decision is not None and decision.action == "drop"


@pytest.mark.asyncio
@pytest.mark.parametrize("phrase", ["好", "OK", "👍"])
async def test_telegram_short_acknowledgements_never_confirm_writes(phrase: str) -> None:
    plugin = object.__new__(LedgerPlugin)
    plugin.broker = FakeBroker()
    message = ChannelMessage(
        session_id="telegram:123",
        channel="telegram",
        chat_id="123",
        content=phrase,
        context={"_ledger_sender_id": "user-1"},
    )

    decision = await plugin.admit_message(
        "telegram:123",
        message,
        TurnSnapshot("telegram:123", True, 1, 0),
    )

    assert plugin.broker.resolutions == [False]
    assert decision is not None and decision.action == "follow_up"


@pytest.mark.asyncio
async def test_telegram_confirmation_cannot_be_resolved_by_another_sender() -> None:
    plugin = object.__new__(LedgerPlugin)
    plugin.broker = InteractionBroker(30)
    interaction, future = await plugin.broker.create("telegram:group", "user-a")
    message = ChannelMessage(
        session_id="telegram:group",
        channel="telegram",
        chat_id="group",
        content="确认写入",
        context={"_ledger_sender_id": "user-b"},
    )

    decision = await plugin.admit_message(
        "telegram:group",
        message,
        TurnSnapshot("telegram:group", True, 1, 0),
    )

    assert decision is not None and decision.action == "drop"
    assert not future.done()
    await plugin.broker.discard(interaction.id)


@pytest.mark.asyncio
async def test_concurrent_telegram_writes_are_confirmed_one_at_a_time() -> None:
    plugin = object.__new__(LedgerPlugin)
    plugin.broker = InteractionBroker(30)
    plugin.approval_locks = defaultdict(asyncio.Lock)
    sent: list[str] = []

    class Capabilities:
        async def preview(self, _tool: str, arguments: dict, _token: str):
            return SimpleNamespace(confirmation_token=f"token-{arguments['index']}", artifacts=[])

    plugin.capabilities = Capabilities()

    async def send_approval(_state: dict, _spec: ToolSpec, _artifacts: list[dict]) -> None:
        sent.append("approval")

    plugin._send_telegram_approval = send_approval
    spec = ToolSpec.model_validate({
        "name": "append_transactions",
        "description": "write",
        "parameters": {},
        "title": "写入",
        "requiresApproval": True,
        "readOnly": False,
    })
    plugin.tool_specs = {spec.name: spec}
    state = {
        "mode": "ledger",
        "session_id": "telegram:123",
        "channel": "telegram",
        "sender_id": "user-1",
        "capability_token": "capability",
        "confirmation_tokens": {},
        "allowed_tools": [spec.name],
        "approval_policy": "on-write",
    }
    first = asyncio.create_task(plugin.before_tool_call(
        ToolCall("run-1", "append_transactions", {"index": 1}), state,
    ))
    while len(sent) < 1:
        await asyncio.sleep(0)
    second = asyncio.create_task(plugin.before_tool_call(
        ToolCall("run-2", "append_transactions", {"index": 2}), state,
    ))
    await asyncio.sleep(0)

    assert sent == ["approval"]
    await plugin.broker.resolve_session("telegram:123", True, "user-1")
    assert (await first).action == "proceed"
    while len(sent) < 2:
        await asyncio.sleep(0)
    await plugin.broker.resolve_session("telegram:123", True, "user-1")
    assert (await second).action == "proceed"


@pytest.mark.asyncio
async def test_web_prompt_cannot_enter_bub_comma_command_mode() -> None:
    plugin = object.__new__(LedgerPlugin)
    message = ChannelMessage(session_id="session-1", channel="web", content=",env")

    prompt = await plugin.build_prompt(message, "session-1", {"mode": "ledger"})

    assert prompt == [{"role": "user", "content": ",env"}]


@pytest.mark.asyncio
async def test_gateway_loads_ledger_plugin_channels_and_sqlalchemy_store(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.delenv("BUB_TELEGRAM_TOKEN", raising=False)
    settings = Settings(
        database_url=f"sqlite+pysqlite:///{tmp_path / 'tapes.db'}",
        ledger_api_url="https://ledger.example",
        service_token="service-token",
    )

    async with AgentGateway(settings) as gateway:
        assert gateway.framework is not None
        assert gateway.framework._plugin_status["ledger-web"].is_success
        assert gateway.framework._plugin_status["tapestore-sqlalchemy"].is_success
        assert gateway.manager is not None
        assert gateway.manager.get_channel("web") is gateway.web
        assert type(gateway.manager.get_channel("telegram")).__name__ == "OutboundTelegramChannel"
        assert type(gateway.framework.get_tape_store()).__name__ == "SQLAlchemyTapeStore"
        assert gateway.healthy


@pytest.mark.asyncio
async def test_gateway_startup_fails_when_a_channel_does_not_start(tmp_path: Path, monkeypatch) -> None:
    class FailingTelegramChannel:
        name = "telegram"
        enabled = True
        needs_debounce = False

        async def start(self, _stop_event: asyncio.Event) -> None:
            raise RuntimeError("telegram startup failed")

        async def stop(self) -> None:
            return None

        async def send(self, _message: ChannelMessage) -> None:
            return None

        def stream_events(self, _message: ChannelMessage, stream):
            return stream

        async def admit_message(self, **_kwargs):
            return None

    monkeypatch.setattr(LedgerTelegramChannel, "create", staticmethod(lambda _handler: FailingTelegramChannel()))
    settings = Settings(
        database_url=f"sqlite+pysqlite:///{tmp_path / 'failed-start.db'}",
        ledger_api_url="https://ledger.example",
        service_token="service-token",
    )

    with pytest.raises(RuntimeError, match="telegram startup failed"):
        async with AgentGateway(settings):
            pytest.fail("gateway must not become ready")


@pytest.mark.asyncio
async def test_web_turn_runs_through_bub_channel_manager_and_persists_timeline(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.delenv("BUB_TELEGRAM_TOKEN", raising=False)
    settings = Settings(
        database_url=f"sqlite+pysqlite:///{tmp_path / 'turns.db'}",
        ledger_api_url="https://ledger.example",
        service_token="service-token",
    )

    async def events():
        yield StreamEvent("text", {"delta": "已完成"})

    async with AgentGateway(settings) as gateway:
        assert gateway.plugin is not None

        async def ensure_tools(_specs=None) -> None:
            return None

        async def run_stream(**_kwargs) -> AsyncStreamEvents:
            return AsyncStreamEvents(events())

        monkeypatch.setattr(gateway.plugin, "ensure_ledger_tools", ensure_tools)
        monkeypatch.setattr(gateway.plugin.agent, "run_stream", run_stream)
        request = TurnRequest.model_validate({
            "sessionId": "session_test",
            "message": "看看本月支出",
            "capabilityToken": "capability",
            "systemPrompt": "ledger prompt",
        })
        received = [event async for event in gateway.turn(request)]

        assert any(name == "message_delta" and payload["text"] == "已完成" for name, payload in received)
        assert received[-1][0] == "final"
        assert received[-1][1]["message"] == "已完成"
        timeline = await gateway.timeline("session_test", 0)
        assert [item["role"] if item["kind"] == "message" else item["kind"] for item in timeline["items"]] == [
            "user",
            "assistant",
        ]


@pytest.mark.asyncio
async def test_web_turn_closes_with_an_error_when_bub_model_fails(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.delenv("BUB_TELEGRAM_TOKEN", raising=False)
    settings = Settings(
        database_url=f"sqlite+pysqlite:///{tmp_path / 'error-turn.db'}",
        ledger_api_url="https://ledger.example",
        service_token="service-token",
    )

    async with AgentGateway(settings) as gateway:
        assert gateway.plugin is not None

        async def ensure_tools(_specs=None) -> None:
            return None

        async def fail_stream(**_kwargs) -> AsyncStreamEvents:
            raise RuntimeError("model failed")

        monkeypatch.setattr(gateway.plugin, "ensure_ledger_tools", ensure_tools)
        monkeypatch.setattr(gateway.plugin.agent, "run_stream", fail_stream)
        request = TurnRequest.model_validate({
            "sessionId": "session_error",
            "message": "触发错误",
            "capabilityToken": "capability",
            "systemPrompt": "ledger prompt",
        })

        async def collect():
            return [event async for event in gateway.turn(request)]

        received = await asyncio.wait_for(collect(), timeout=2)

        assert received[-1] == ("error", {"error": "model failed"})
