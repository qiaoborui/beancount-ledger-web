from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from pathlib import Path
from types import SimpleNamespace

import pytest
from bub.channels.admission import TurnSnapshot
from bub.channels.message import ChannelMessage
from bub.builtin.model_runner import ModelRunner
from bub.errors import BubError, ErrorKind
from bub.streaming import AsyncStreamEvents, StreamEvent

from ledger_agent_service.config import Settings
from ledger_agent_service.protocol import OnboardingRequest, ToolSpec, TurnRequest
from ledger_agent_service.runtime import AgentGateway, LedgerPlugin, LedgerTelegramChannel


@pytest.mark.asyncio
async def test_model_stream_converts_frozen_bub_errors_before_channel_cleanup() -> None:
    plugin = object.__new__(LedgerPlugin)

    async def events():
        raise BubError(ErrorKind.TOOL, "Unknown tool name: open_page.")
        yield

    class FailingAgent:
        async def run_stream(self, **_kwargs) -> AsyncStreamEvents:
            return AsyncStreamEvents(events())

    @asynccontextmanager
    async def channel_lifespan():
        yield

    plugin.agent = FailingAgent()
    stream = await plugin.run_model_stream(
        prompt="查询本月支出",
        session_id="telegram:123",
        state={"allowed_tools": [], "allowed_skills": []},
    )

    with pytest.raises(RuntimeError, match=r"\[tool\] Unknown tool name: open_page\.") as caught:
        async with channel_lifespan():
            async for _event in stream:
                pass

    assert isinstance(caught.value.__cause__, BubError)
    assert "cannot assign to field '__traceback__'" not in str(caught.value)


@pytest.mark.asyncio
async def test_telegram_unknown_tool_starts_fresh_context_and_retries_once() -> None:
    plugin = object.__new__(LedgerPlugin)
    handoffs: list[tuple[str, dict]] = []

    class SessionTape:
        async def handoff(self, *, name: str, state: dict) -> None:
            handoffs.append((name, state))

    class TapeRoot:
        def session_tape(self, session_id: str, workspace: Path) -> SessionTape:
            assert session_id == "telegram:123"
            assert workspace == Path("/workspace")
            return SessionTape()

    class RecoveringAgent:
        def __init__(self) -> None:
            self.attempts = 0
            self.tape = TapeRoot()

        async def run_stream(self, **_kwargs) -> AsyncStreamEvents:
            self.attempts += 1

            async def events():
                if self.attempts == 1:
                    raise BubError(ErrorKind.TOOL, "Unknown tool name: open_page.")
                yield StreamEvent("text", {"delta": "本月支出已查到"})
                yield StreamEvent("final", {"ok": True, "text": "本月支出已查到"})

            return AsyncStreamEvents(events())

    agent = RecoveringAgent()
    plugin.agent = agent
    plugin.framework = SimpleNamespace(workspace=Path("/workspace"))
    state = {
        "channel": "telegram",
        "allowed_tools": ["query_ledger"],
        "allowed_skills": ["telegram-ledger-agent", "telegram"],
    }

    stream = await plugin.run_model_stream("查询本月支出", "telegram:123", state)
    received = [event async for event in stream]

    assert agent.attempts == 2
    assert handoffs == [("recovery/unknown_tool", {"tool": "open_page"})]
    assert [event.data.get("delta") for event in received if event.kind == "text"] == ["本月支出已查到"]


@pytest.mark.asyncio
async def test_telegram_confirmation_is_a_normal_model_turn() -> None:
    plugin = object.__new__(LedgerPlugin)
    message = ChannelMessage(
        session_id="telegram:123",
        channel="telegram",
        chat_id="123",
        content="确认写入",
    )

    idle = await plugin.admit_message(
        "telegram:123",
        message,
        TurnSnapshot("telegram:123", False, 0, 0),
    )
    running = await plugin.admit_message(
        "telegram:123",
        message,
        TurnSnapshot("telegram:123", True, 1, 0),
    )

    assert idle is None
    assert running is not None and running.action == "follow_up"


@pytest.mark.asyncio
async def test_web_loads_complete_catalog_after_telegram_subset() -> None:
    plugin = object.__new__(LedgerPlugin)
    plugin.tool_specs = {}
    plugin.complete_tool_catalog_loaded = False
    plugin.tools_lock = asyncio.Lock()
    telegram_tool = ToolSpec.model_validate({
        "name": "telegram_test_tool",
        "description": "telegram",
        "parameters": {"type": "object", "properties": {}},
        "title": "Telegram test",
        "readOnly": True,
    })
    web_tool = ToolSpec.model_validate({
        "name": "web_test_tool",
        "description": "web",
        "parameters": {"type": "object", "properties": {}},
        "title": "Web test",
        "readOnly": True,
    })

    class Capabilities:
        async def specs(self) -> list[ToolSpec]:
            return [telegram_tool, web_tool]

    plugin.capabilities = Capabilities()
    await plugin.ensure_ledger_tools([telegram_tool])
    await plugin.ensure_ledger_tools()

    assert set(plugin.tool_specs) == {"telegram_test_tool", "web_test_tool"}
    assert plugin.complete_tool_catalog_loaded is True


@pytest.mark.asyncio
async def test_web_prompt_exposes_bub_comma_command_mode() -> None:
    plugin = object.__new__(LedgerPlugin)
    message = ChannelMessage(session_id="session-1", channel="web", content=",env")

    prompt = await plugin.build_prompt(message, "session-1", {"mode": "ledger"})

    assert prompt == ",env"


@pytest.mark.asyncio
async def test_telegram_prompt_exposes_bub_comma_command_mode() -> None:
    plugin = object.__new__(LedgerPlugin)
    message = ChannelMessage(session_id="telegram:123", channel="telegram", content=",env")

    prompt = await plugin.build_prompt(message, "telegram:123", {"mode": "ledger"})

    assert prompt == ",env"


@pytest.mark.asyncio
async def test_web_prompt_reaches_the_model_as_plain_text() -> None:
    plugin = object.__new__(LedgerPlugin)
    message = ChannelMessage(session_id="session-1", channel="web", content="查询本月支出")

    prompt = await plugin.build_prompt(message, "session-1", {"mode": "ledger"})

    class EmptyTape:
        async def read_messages(self) -> list[dict]:
            return []

    runner = object.__new__(ModelRunner)
    messages, _ = await runner.build_messages(
        tape=EmptyTape(),
        run_id="test-run",
        system_prompt="system",
        prompt=prompt,
        model="openai:ledger-agent",
    )
    assert messages[1] == {"role": "user", "content": "查询本月支出"}


@pytest.mark.asyncio
async def test_onboarding_history_is_rendered_as_typed_text_content() -> None:
    plugin = object.__new__(LedgerPlugin)
    request = OnboardingRequest.model_validate({
        "message": "工资",
        "messages": [
            {"role": "assistant", "content": "你的收入来源是什么？"},
            {"role": "user", "content": "每月有固定收入"},
        ],
    })
    message = ChannelMessage(
        session_id="onboarding-1",
        channel="web",
        content=request.message,
        context={"_ledger_onboarding_request": request},
    )

    prompt = await plugin.build_prompt(message, "onboarding-1", {"mode": "onboarding"})

    assert isinstance(prompt, list) and len(prompt) == 1
    assert prompt[0]["type"] == "text"
    assert "助手：你的收入来源是什么？" in prompt[0]["text"]
    assert "用户：每月有固定收入" in prompt[0]["text"]
    assert prompt[0]["text"].endswith("当前用户消息：\n工资")


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

        await gateway.plugin.record_ui_event(
            "legacy_pending",
            "message",
            {"id": "legacy-user", "kind": "message", "role": "user", "content": "写入这笔交易"},
        )
        await gateway.plugin.record_ui_event(
            "legacy_pending",
            "approval_required",
            {"id": "approval-old", "toolName": "append_transactions"},
        )
        await gateway.plugin.record_ui_event(
            "legacy_pending",
            "message",
            {"id": "new-user", "kind": "message", "role": "user", "content": "查询余额"},
        )
        await gateway.plugin.record_ui_event(
            "legacy_pending",
            "message",
            {"id": "new-assistant", "kind": "message", "role": "assistant", "content": "余额已查询"},
        )
        legacy_timeline = await gateway.timeline("legacy_pending", 0)
        assert legacy_timeline["items"][1] == {
            "id": "legacy-approval-approval-old",
            "kind": "message",
            "role": "assistant",
            "content": "旧版待确认操作已结束，请重新发送请求并按新的对话确认流程操作。",
        }
        assert legacy_timeline["items"][-1]["content"] == "余额已查询"
        await gateway.plugin.record_ui_event(
            "legacy_resolved",
            "approval_required",
            {"id": "approval-resolved", "toolName": "append_transactions"},
        )
        await gateway.plugin.record_ui_event(
            "legacy_resolved",
            "approval_resolution",
            {"id": "approval-resolved", "approved": True},
        )
        resolved_timeline = await gateway.timeline("legacy_resolved", 0)
        assert resolved_timeline["items"] == []


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
