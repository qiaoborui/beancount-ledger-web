from __future__ import annotations

import asyncio
import json
import os
import socket
from contextlib import asynccontextmanager
from pathlib import Path
from types import SimpleNamespace

import pytest
import uvicorn
from bub.channels.admission import TurnSnapshot
from bub.channels.message import ChannelMessage
from bub.builtin.model_runner import ModelRunner
from bub.errors import BubError, ErrorKind
from bub.hooks.interception import LlmCallRequest, ToolCall
from bub.skills import discover_skills
from bub.streaming import AsyncStreamEvents, StreamEvent
from bub.tools import REGISTRY, Tool, ToolContext
from fastmcp import FastMCP

from ledger_agent_service.config import Settings
from ledger_agent_service.protocol import OnboardingRequest, ToolSpec, TurnRequest
from ledger_agent_service.runtime import (
    TELEGRAM_SEND_RICH_TOOL,
    TELEGRAM_SEND_TOOL,
    AgentGateway,
    LedgerPlugin,
    LedgerTelegramChannel,
)


@pytest.fixture
async def ledger_mcp_url() -> str:
    server = FastMCP("ledger-test")

    @server.tool(name="ledger_get_accounts")
    def get_accounts() -> str:
        return json.dumps({"modelOutput": {"accounts": []}, "clientOutput": {"accounts": []}, "artifacts": [], "refreshLedger": False})

    @server.tool(name="ledger_append_transactions")
    def append_transactions() -> str:
        return json.dumps({"modelOutput": {"ok": True}, "clientOutput": {"ok": True}, "artifacts": [], "refreshLedger": True})

    @server.tool(name="ledger_agent_context")
    def agent_context(
        channel: str,
        page: str = "",
        path: str = "",
        start: str = "",
        end: str = "",
        valuationCurrency: str = "",
        bqlQuery: str = "",
    ) -> str:
        del page, path, start, end, valuationCurrency, bqlQuery
        prompt = f"{channel} prompt: use ledger_get_accounts"
        return json.dumps({"modelOutput": {"systemPrompt": prompt}, "clientOutput": {"systemPrompt": prompt}, "artifacts": [], "refreshLedger": False})

    app = server.http_app(path="/mcp", stateless_http=True, json_response=True)
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    port = listener.getsockname()[1]
    uvicorn_server = uvicorn.Server(uvicorn.Config(app, log_level="error", lifespan="on"))
    task = asyncio.create_task(uvicorn_server.serve(sockets=[listener]))
    while not uvicorn_server.started:
        if task.done():
            await task
        await asyncio.sleep(0.01)
    try:
        yield f"http://127.0.0.1:{port}"
    finally:
        uvicorn_server.should_exit = True
        await task


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
async def test_telegram_channel_keeps_model_output_null_but_returns_comma_commands(monkeypatch) -> None:
    from bub.channels.telegram import TelegramChannel

    async def build_message(_self, message: ChannelMessage) -> ChannelMessage:
        return message

    monkeypatch.setattr(TelegramChannel, "_build_message", build_message)
    channel = LedgerTelegramChannel.create(lambda _message: None)

    normal = await channel._build_message(ChannelMessage(
        session_id="telegram:123",
        channel="telegram",
        chat_id="123",
        content='{"message":"本月支出"}',
        output_channel="null",
    ))
    command = await channel._build_message(ChannelMessage(
        session_id="telegram:123",
        channel="telegram",
        chat_id="123",
        content=",env",
        output_channel="null",
    ))

    assert normal.output_channel == "null"
    assert command.output_channel == "telegram"


@pytest.mark.asyncio
async def test_telegram_channel_sends_rich_payload_through_bot_api() -> None:
    requests: list[tuple[str, dict]] = []

    class Bot:
        async def _post(self, endpoint: str, data: dict):
            requests.append((endpoint, data))
            return {"message_id": 456}

    channel = LedgerTelegramChannel.create(lambda _message: None)
    channel._app = SimpleNamespace(bot=Bot())

    message_id = await channel.send_agent_rich(
        "123",
        "<table><tr><td>餐饮</td><td>237.30</td></tr></table>",
        "html",
        1207,
    )

    assert message_id == 456
    assert requests == [(
        "sendRichMessage",
        {
            "chat_id": "123",
            "rich_message": '{"html": "<table><tr><td>餐饮</td><td>237.30</td></tr></table>"}',
            "reply_to_message_id": 1207,
        },
    )]


@pytest.mark.asyncio
async def test_telegram_send_tool_is_bound_to_current_turn_and_finishes_loop() -> None:
    calls: list[tuple[str, str, int | None]] = []

    class TelegramChannel:
        async def send_agent_text(self, chat_id: str, text: str, reply_to: int | None) -> int:
            calls.append((chat_id, text, reply_to))
            return 321

    plugin = object.__new__(LedgerPlugin)
    plugin.telegram_channel = TelegramChannel()
    state = {
        "channel": "telegram",
        "chat_id": "123",
        "telegram_message_id": 1207,
    }
    context = ToolContext(tape=SimpleNamespace(), run_id="run-1", state=state)

    first = await plugin._telegram_send_handler(context=context, text="处理完成")
    second = await plugin._telegram_send_handler(context=context, text="不应重复发送")
    decision = plugin.before_llm_call(
        LlmCallRequest("run-2", "openai:ledger-agent", [], (TELEGRAM_SEND_TOOL,)),
        state,
    )

    assert calls == [("123", "处理完成", 1207)]
    assert first == {"sent": True, "messageId": 321, "format": "text"}
    assert second == {"sent": True, "alreadySent": True}
    assert decision is not None and decision.text == ""


@pytest.mark.asyncio
async def test_parallel_telegram_send_calls_emit_only_one_message() -> None:
    calls: list[str] = []

    class TelegramChannel:
        async def send_agent_text(self, _chat_id: str, text: str, _reply_to: int | None) -> int:
            await asyncio.sleep(0)
            calls.append(text)
            return 321

    plugin = object.__new__(LedgerPlugin)
    plugin.telegram_channel = TelegramChannel()
    state = {
        "channel": "telegram",
        "chat_id": "123",
        "telegram_message_id": 1207,
        "_telegram_send_lock": asyncio.Lock(),
    }
    context = ToolContext(tape=SimpleNamespace(), run_id="run-parallel", state=state)

    results = await asyncio.gather(
        plugin._telegram_send_handler(context=context, text="第一条"),
        plugin._telegram_send_handler(context=context, text="第二条"),
    )

    assert len(calls) == 1
    assert sum(result.get("alreadySent") is True for result in results) == 1


@pytest.mark.asyncio
async def test_telegram_rich_tool_sends_structured_final_reply() -> None:
    calls: list[tuple[str, str, str, int | None]] = []

    class TelegramChannel:
        async def send_agent_rich(
            self,
            chat_id: str,
            content: str,
            format: str,
            reply_to: int | None,
        ) -> int:
            calls.append((chat_id, content, format, reply_to))
            return 654

    plugin = object.__new__(LedgerPlugin)
    plugin.telegram_channel = TelegramChannel()
    state = {"channel": "telegram", "chat_id": "123", "telegram_message_id": 1207}
    context = ToolContext(tape=SimpleNamespace(), run_id="run-rich", state=state)

    result = await plugin._telegram_send_rich_handler(
        context=context,
        content="<table><tr><td>餐饮</td><td>237.30</td></tr></table>",
        format="html",
    )

    assert calls == [("123", "<table><tr><td>餐饮</td><td>237.30</td></tr></table>", "html", 1207)]
    assert result == {"sent": True, "messageId": 654, "format": "html"}


@pytest.mark.asyncio
async def test_telegram_send_tools_are_allowed_only_when_exposed_to_the_turn() -> None:
    plugin = object.__new__(LedgerPlugin)
    plugin.tool_specs = {}
    call = ToolCall("run-1", TELEGRAM_SEND_RICH_TOOL, {"content": "<p>ok</p>", "format": "html"})

    allowed = await plugin.before_tool_call(
        call,
        {"mode": "ledger", "allowed_tools": [TELEGRAM_SEND_RICH_TOOL]},
    )
    denied = await plugin.before_tool_call(call, {"mode": "ledger", "allowed_tools": []})

    assert allowed is None
    assert denied is not None and denied.action == "deny"


@pytest.mark.asyncio
async def test_telegram_state_exposes_bound_send_tools_and_source_message() -> None:
    plugin = object.__new__(LedgerPlugin)
    plugin.tool_specs = {
        "mcp.ledger_get_accounts": ToolSpec(
            name="mcp.ledger_get_accounts",
            description="accounts",
            parameters={"type": "object", "properties": {}},
            title="accounts",
        )
    }

    async def ensure_ledger_tools(**_kwargs) -> None:
        return None

    plugin.ensure_ledger_tools = ensure_ledger_tools
    plugin._mcp_agent_context = lambda *_args, **_kwargs: asyncio.sleep(0, result="prompt")
    message = ChannelMessage(
        session_id="telegram:123",
        channel="telegram",
        chat_id="123",
        content='{"message":"发个表格","message_id":1207}',
        output_channel="null",
    )

    state = await plugin.load_state(message, "telegram:123")

    assert state["chat_id"] == "123"
    assert state["telegram_message_id"] == 1207
    assert set(state["allowed_tools"]) == {
        "mcp.ledger_get_accounts",
        TELEGRAM_SEND_TOOL,
        TELEGRAM_SEND_RICH_TOOL,
    }
    assert state["allowed_skills"] == ["telegram-ledger-agent", "telegram"]


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("sensitive_unlocked", "expected"),
    [
        (False, {"open_page"}),
        (True, {"open_page", "mcp.ledger_get_accounts"}),
    ],
)
async def test_web_state_keeps_mcp_tools_behind_sensitive_unlock(sensitive_unlocked: bool, expected: set[str]) -> None:
    plugin = object.__new__(LedgerPlugin)
    plugin.tool_specs = {
        "open_page": ToolSpec(name="open_page", description="navigation", parameters={}, title="打开页面"),
        "mcp.ledger_get_accounts": ToolSpec(name="mcp.ledger_get_accounts", description="accounts", parameters={}, title="accounts"),
    }

    async def ensure_ledger_tools(**_kwargs) -> None:
        return None

    plugin.ensure_ledger_tools = ensure_ledger_tools
    message = ChannelMessage(
        session_id="web:1",
        channel="web",
        content="查询账户",
        context={
            "_ledger_system_prompt": "use ledger_get_accounts",
            "page": {"sensitiveUnlocked": sensitive_unlocked},
        },
    )

    state = await plugin.load_state(message, "web:1")

    assert set(state["allowed_tools"]) == expected
    assert "mcp.ledger_get_accounts" in state["system_prompt"]


def test_project_telegram_skill_uses_restricted_final_response_tools() -> None:
    workspace = Path(__file__).resolve().parents[2]
    skill = next(item for item in discover_skills(workspace) if item.name == "telegram")
    body = skill.body()

    assert skill.source == "project"
    assert "telegram_send" in body
    assert "telegram_send_rich" in body
    assert "Do not send an acknowledgment before doing the work" in body
    assert "telegram_rich.py" not in body


def _telegram_update_payload(chat_id: int = 123, user_id: int = 456, text: str = "本月支出") -> bytes:
    return json.dumps({
        "update_id": 7,
        "message": {
            "message_id": 1207,
            "date": 1750000000,
            "chat": {"id": chat_id, "type": "private"},
            "from": {"id": user_id, "is_bot": False, "first_name": "Test", "username": "tester"},
            "text": text,
        },
    }).encode()


@pytest.mark.asyncio
async def test_telegram_webhook_update_dispatches_to_webhook_processor() -> None:
    processed: list[ChannelMessage] = []

    async def webhook_processor(message: ChannelMessage) -> None:
        processed.append(message)

    channel = LedgerTelegramChannel.create(
        lambda _message: None,
        webhook_processor=webhook_processor,
        mode="webhook",
    )
    channel._app = SimpleNamespace(bot=SimpleNamespace(id=123, username="bub_bot"))

    await channel.process_raw_update(_telegram_update_payload())

    assert len(processed) == 1
    message = processed[0]
    assert message.channel == "telegram"
    assert message.chat_id == "123"
    assert message.output_channel == "null"
    assert json.loads(message.content)["message"] == "本月支出"
    assert json.loads(message.content)["sender_id"] == "456"


@pytest.mark.asyncio
async def test_telegram_webhook_sends_model_output_when_send_tool_was_not_called() -> None:
    calls: list[tuple[str, str, int | None]] = []

    class Framework:
        async def process_inbound(self, _message, stream_output: bool):
            assert stream_output is True
            return SimpleNamespace(model_output="这是最终回复", state={"_telegram_reply_sent": False})

    class TelegramChannel:
        async def send_agent_text(self, chat_id: str, text: str, reply_to: int | None) -> int:
            calls.append((chat_id, text, reply_to))
            return 321

    plugin = object.__new__(LedgerPlugin)
    plugin.framework = Framework()
    plugin.telegram_channel = TelegramChannel()
    message = ChannelMessage(
        session_id="telegram:123",
        channel="telegram",
        chat_id="123",
        content='{"message":"测试","message_id":1207}',
        output_channel="null",
    )

    await plugin._telegram_webhook_processor(message)

    assert calls == [("123", "这是最终回复", 1207)]


@pytest.mark.asyncio
async def test_telegram_webhook_does_not_duplicate_send_tool_reply() -> None:
    calls: list[tuple[str, str, int | None]] = []

    class Framework:
        async def process_inbound(self, _message, stream_output: bool):
            assert stream_output is True
            return SimpleNamespace(model_output="不应再次发送", state={"_telegram_reply_sent": True})

    class TelegramChannel:
        async def send_agent_text(self, chat_id: str, text: str, reply_to: int | None) -> int:
            calls.append((chat_id, text, reply_to))
            return 321

    plugin = object.__new__(LedgerPlugin)
    plugin.framework = Framework()
    plugin.telegram_channel = TelegramChannel()
    message = ChannelMessage(
        session_id="telegram:123",
        channel="telegram",
        chat_id="123",
        content='{"message":"测试","message_id":1207}',
        output_channel="null",
    )

    await plugin._telegram_webhook_processor(message)

    assert calls == []


@pytest.mark.asyncio
async def test_telegram_webhook_comma_commands_keep_bub_channel_output() -> None:
    processed: list[ChannelMessage] = []

    async def webhook_processor(message: ChannelMessage) -> None:
        processed.append(message)

    channel = LedgerTelegramChannel.create(
        lambda _message: None,
        webhook_processor=webhook_processor,
        mode="webhook",
    )
    channel._app = SimpleNamespace(bot=SimpleNamespace(id=123, username="bub_bot"))

    await channel.process_raw_update(_telegram_update_payload(text=",env"))

    assert len(processed) == 1
    assert processed[0].content == ",env"
    assert processed[0].output_channel == "telegram"


@pytest.mark.asyncio
async def test_telegram_webhook_enforces_allow_lists() -> None:
    sent: list[dict] = []

    class Bot:
        async def send_message(self, **kwargs) -> SimpleNamespace:
            sent.append(kwargs)
            return SimpleNamespace(message_id=1)

    processed: list[ChannelMessage] = []

    async def webhook_processor(message: ChannelMessage) -> None:
        processed.append(message)

    channel = LedgerTelegramChannel.create(
        lambda _message: None,
        webhook_processor=webhook_processor,
        mode="webhook",
    )
    channel._app = SimpleNamespace(bot=Bot())
    channel._allow_users = {"999"}
    channel._allow_chats = set()

    await channel.process_raw_update(_telegram_update_payload())

    assert processed == []
    assert sent and sent[0]["chat_id"] == 123
    assert "Access denied." in sent[0]["text"]


@pytest.mark.asyncio
async def test_telegram_webhook_rejects_malformed_payloads() -> None:
    channel = LedgerTelegramChannel.create(lambda _message: None, mode="webhook")
    channel._app = SimpleNamespace(bot=SimpleNamespace(id=123, username="bub_bot"))

    with pytest.raises(ValueError, match="invalid Telegram update payload"):
        await channel.process_raw_update(b"not json")

    with pytest.raises(ValueError, match="invalid Telegram update payload"):
        await channel.process_raw_update(b"[]")


@pytest.mark.asyncio
async def test_telegram_webhook_requires_a_running_channel() -> None:
    channel = LedgerTelegramChannel.create(lambda _message: None, mode="webhook")

    with pytest.raises(RuntimeError, match="Telegram channel is not running"):
        await channel.process_raw_update(_telegram_update_payload())


@pytest.mark.asyncio
async def test_bub_mcp_catalog_is_loaded_without_registering_custom_handlers() -> None:
    plugin = object.__new__(LedgerPlugin)
    plugin.tool_specs = {}
    plugin.complete_tool_catalog_loaded = False
    plugin.tools_lock = asyncio.Lock()
    existing = {name: tool for name, tool in REGISTRY.items() if name.startswith("mcp.ledger_")}
    for name in existing:
        REGISTRY.pop(name, None)
    context_tool = Tool(name="mcp.ledger_agent_context", handler=lambda **_kwargs: "{}")
    ledger_tool = Tool(
        name="mcp.ledger_get_accounts",
        description="accounts",
        parameters={"type": "object", "properties": {}},
        handler=lambda: "{}",
    )
    REGISTRY[context_tool.name] = context_tool
    REGISTRY[ledger_tool.name] = ledger_tool
    try:
        await plugin.ensure_ledger_tools()
        assert set(plugin.tool_specs) == {"mcp.ledger_get_accounts"}
        assert REGISTRY[ledger_tool.name] is ledger_tool
        assert plugin.complete_tool_catalog_loaded is True
    finally:
        REGISTRY.pop(context_tool.name, None)
        REGISTRY.pop(ledger_tool.name, None)
        REGISTRY.update(existing)


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
async def test_gateway_loads_ledger_plugin_channels_and_sqlalchemy_store(tmp_path: Path, monkeypatch, ledger_mcp_url: str) -> None:
    monkeypatch.delenv("BUB_TELEGRAM_TOKEN", raising=False)
    settings = Settings(
        database_url=f"sqlite+pysqlite:///{tmp_path / 'tapes.db'}",
        ledger_api_url=ledger_mcp_url,
        service_token="service-token",
    )

    async with AgentGateway(settings) as gateway:
        assert gateway.framework is not None
        assert gateway.framework._plugin_status["ledger-web"].is_success
        assert gateway.framework._plugin_status["mcp"].is_success
        assert gateway.framework._plugin_status["tapestore-sqlalchemy"].is_success
        assert gateway.manager is not None
        assert gateway.manager.get_channel("web") is gateway.web
        assert type(gateway.manager.get_channel("telegram")).__name__ == "SkillTelegramChannel"
        assert type(gateway.framework.get_tape_store()).__name__ == "SQLAlchemyTapeStore"
        assert await gateway.plugin._mcp_agent_context("telegram", {}) == "telegram prompt: use mcp.ledger_get_accounts"
        assert gateway.healthy


@pytest.mark.asyncio
async def test_gateway_restores_process_globals_and_rejects_overlap(tmp_path: Path, monkeypatch, ledger_mcp_url: str) -> None:
    monkeypatch.delenv("BUB_TELEGRAM_TOKEN", raising=False)
    monkeypatch.setenv("BUB_TAPESTORE_SQLALCHEMY_URL", "sqlite+pysqlite:///existing.db")
    sentinel = Tool(name="mcp.ledger_existing", description="existing", parameters={}, handler=lambda: None)
    previous = REGISTRY.get(sentinel.name)
    REGISTRY[sentinel.name] = sentinel
    settings = Settings(
        database_url=f"sqlite+pysqlite:///{tmp_path / 'globals.db'}",
        ledger_api_url=ledger_mcp_url,
        service_token="service-token",
    )

    try:
        async with AgentGateway(settings):
            assert os.environ["BUB_TAPESTORE_SQLALCHEMY_URL"].endswith("globals.db")
            with pytest.raises(RuntimeError, match="already active"):
                async with AgentGateway(settings):
                    pytest.fail("overlapping gateways must be rejected")
        assert os.environ["BUB_TAPESTORE_SQLALCHEMY_URL"] == "sqlite+pysqlite:///existing.db"
        assert REGISTRY.get(sentinel.name) is sentinel
    finally:
        if previous is None:
            REGISTRY.pop(sentinel.name, None)
        else:
            REGISTRY[sentinel.name] = previous


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

    monkeypatch.setattr(
        LedgerTelegramChannel,
        "create",
        staticmethod(lambda _handler, **_kwargs: FailingTelegramChannel()),
    )
    settings = Settings(
        database_url=f"sqlite+pysqlite:///{tmp_path / 'failed-start.db'}",
        ledger_api_url="https://ledger.example",
        service_token="service-token",
    )

    with pytest.raises(RuntimeError, match="telegram startup failed"):
        async with AgentGateway(settings):
            pytest.fail("gateway must not become ready")


@pytest.mark.asyncio
async def test_web_turn_runs_through_bub_channel_manager_and_persists_timeline(tmp_path: Path, monkeypatch, ledger_mcp_url: str) -> None:
    monkeypatch.delenv("BUB_TELEGRAM_TOKEN", raising=False)
    settings = Settings(
        database_url=f"sqlite+pysqlite:///{tmp_path / 'turns.db'}",
        ledger_api_url=ledger_mcp_url,
        service_token="service-token",
    )

    async def events():
        yield StreamEvent("text", {"delta": "已完成"})

    async with AgentGateway(settings) as gateway:
        assert gateway.plugin is not None

        async def ensure_tools(**_kwargs) -> None:
            return None

        async def run_stream(**_kwargs) -> AsyncStreamEvents:
            return AsyncStreamEvents(events())

        monkeypatch.setattr(gateway.plugin, "ensure_ledger_tools", ensure_tools)
        monkeypatch.setattr(gateway.plugin.agent, "run_stream", run_stream)
        request = TurnRequest.model_validate({
            "sessionId": "session_test",
            "message": "看看本月支出",
            "systemPrompt": "ledger prompt",
            "context": {"sensitiveUnlocked": True},
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
async def test_web_turn_closes_with_an_error_when_bub_model_fails(tmp_path: Path, monkeypatch, ledger_mcp_url: str) -> None:
    monkeypatch.delenv("BUB_TELEGRAM_TOKEN", raising=False)
    settings = Settings(
        database_url=f"sqlite+pysqlite:///{tmp_path / 'error-turn.db'}",
        ledger_api_url=ledger_mcp_url,
        service_token="service-token",
    )

    async with AgentGateway(settings) as gateway:
        assert gateway.plugin is not None

        async def ensure_tools(**_kwargs) -> None:
            return None

        async def fail_stream(**_kwargs) -> AsyncStreamEvents:
            raise RuntimeError("model failed")

        monkeypatch.setattr(gateway.plugin, "ensure_ledger_tools", ensure_tools)
        monkeypatch.setattr(gateway.plugin.agent, "run_stream", fail_stream)
        request = TurnRequest.model_validate({
            "sessionId": "session_error",
            "message": "触发错误",
            "systemPrompt": "ledger prompt",
        })

        async def collect():
            return [event async for event in gateway.turn(request)]

        received = await asyncio.wait_for(collect(), timeout=2)

        assert received[-1] == ("error", {"error": "model failed"})
