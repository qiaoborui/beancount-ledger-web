from __future__ import annotations

import asyncio
import json
import os
from collections.abc import AsyncIterator, Awaitable, Callable
from pathlib import Path
from typing import Any
from weakref import WeakKeyDictionary

from bub.channels.admission import AdmitDecision, TurnSnapshot
from bub.channels.base import Lifecycle
from bub.channels.contracts import MessageHandler
from bub.channels.manager import ChannelManager
from bub.channels.message import ChannelMessage
from bub.builtin.agent import Agent
from bub.builtin.context import default_tape_context
from bub.envelope import content_of
from bub.errors import BubError, ErrorKind
from bub.framework import BubFramework
from bub.hooks import hookimpl
from bub.hooks.interception import LlmCallDecision, LlmCallRequest, ToolCall, ToolCallDecision
from bub.streaming import AsyncStreamEvents, StreamState
from bub.tape import AsyncTapeStoreAdapter, TapeContext, TapeEntry, TapeQuery
from bub.tools import REGISTRY, Tool, ToolContext
from .capabilities import LedgerCapabilities
from .config import Settings
from .onboarding import default_draft, is_ready, normalize_draft, onboarding_tools, prompt as onboarding_prompt
from .protocol import OnboardingRequest, ToolSpec, TurnRequest
from .web_channel import LedgerWebChannel, WebTurn

_PLUGINS: WeakKeyDictionary[BubFramework, LedgerPlugin] = WeakKeyDictionary()
_GATEWAY_SETTINGS: WeakKeyDictionary[BubFramework, Settings] = WeakKeyDictionary()
TELEGRAM_SEND_TOOL = "telegram_send"
TELEGRAM_SEND_RICH_TOOL = "telegram_send_rich"
TELEGRAM_TOOL_NAMES = {TELEGRAM_SEND_TOOL, TELEGRAM_SEND_RICH_TOOL}


class LedgerTelegramChannel:
    """Keep Bub's transport while making model replies explicit Telegram tool calls."""

    @staticmethod
    def create(on_receive: MessageHandler):
        from bub.channels.telegram import TelegramChannel

        class SkillTelegramChannel(TelegramChannel):
            @property
            def needs_debounce(self) -> bool:
                # Keep each Telegram message as its own model turn.
                return False

            async def _build_message(self, message):
                inbound = await super()._build_message(message)
                if content_of(inbound).strip().startswith(","):
                    # Comma commands bypass the model and therefore cannot use
                    # the Telegram response skill.
                    inbound.output_channel = self.name
                return inbound

            async def send_agent_text(self, chat_id: str, text: str, reply_to: int | None) -> int | None:
                from telegram.error import BadRequest

                try:
                    sent = await self._app.bot.send_message(
                        chat_id=chat_id,
                        text=text,
                        reply_to_message_id=reply_to,
                    )
                except BadRequest:
                    if reply_to is None:
                        raise
                    sent = await self._app.bot.send_message(chat_id=chat_id, text=text)
                return getattr(sent, "message_id", None)

            async def send_agent_rich(
                self,
                chat_id: str,
                content: str,
                format: str,
                reply_to: int | None,
            ) -> int | None:
                from telegram.error import BadRequest

                rich_message = json.dumps({format: content}, ensure_ascii=False)
                payload = {
                    "chat_id": chat_id,
                    "rich_message": rich_message,
                    "reply_to_message_id": reply_to,
                }
                try:
                    sent = await self._app.bot._post("sendRichMessage", data=payload)
                except BadRequest:
                    if reply_to is None:
                        raise
                    payload.pop("reply_to_message_id", None)
                    sent = await self._app.bot._post("sendRichMessage", data=payload)
                if not isinstance(sent, dict):
                    return None
                message_id = sent.get("message_id")
                if not isinstance(message_id, int):
                    nested = sent.get("result")
                    message_id = nested.get("message_id") if isinstance(nested, dict) else None
                return message_id if isinstance(message_id, int) else None

            async def stop(self) -> None:
                if not hasattr(self, "_app"):
                    return
                await super().stop()

        return SkillTelegramChannel(on_receive=on_receive)


class GatewayReadiness(Lifecycle):
    """Marks the manager ready only after all preceding channels started successfully."""

    name = "ledger-gateway-readiness"

    def __init__(self, ready: asyncio.Event) -> None:
        self.ready = ready

    async def start(self, stop_event: asyncio.Event) -> None:
        del stop_event
        self.ready.set()

    async def stop(self) -> None:
        self.ready.clear()


class LedgerPlugin:
    def __init__(self, framework: BubFramework) -> None:
        self.framework = framework
        self.settings = _GATEWAY_SETTINGS.get(framework) or Settings.load()
        self.capabilities = LedgerCapabilities(
            self.settings.ledger_api_url,
            service_token=self.settings.service_token,
            access_token=self.settings.access_token,
        )
        self.ready = asyncio.Event()
        self.agent = Agent(framework)
        self.tool_specs: dict[str, ToolSpec] = {}
        self.complete_tool_catalog_loaded = False
        self.tools_lock = asyncio.Lock()
        self.async_store: AsyncTapeStoreAdapter | None = None
        self.web_channel: LedgerWebChannel | None = None
        self.telegram_channel: Any | None = None
        self._register_onboarding_tools()
        self._register_telegram_tools()
        _PLUGINS[framework] = self

    @hookimpl
    def build_tape_context(self) -> TapeContext:
        return default_tape_context()

    @hookimpl
    def provide_channels(self, message_handler: MessageHandler) -> list[Any]:
        web = LedgerWebChannel(message_handler, self.tool_specs, self.record_ui_event)
        telegram = LedgerTelegramChannel.create(message_handler)
        self.web_channel = web
        self.telegram_channel = telegram
        return [web, telegram, GatewayReadiness(self.ready)]

    @hookimpl
    async def load_state(self, message: ChannelMessage, session_id: str) -> dict[str, Any]:
        mode = str(message.context.get("_ledger_mode") or "ledger")
        state: dict[str, Any] = {
            "mode": mode,
            "session_id": session_id,
            "channel": message.channel,
        }
        if message.channel == "telegram":
            state.update({
                "chat_id": message.chat_id,
                "telegram_message_id": _telegram_message_id(message),
                "_telegram_send_lock": asyncio.Lock(),
            })
        if mode == "onboarding":
            request = message.context.get("_ledger_onboarding_request")
            if not isinstance(request, OnboardingRequest):
                raise RuntimeError("onboarding request is missing")
            draft = normalize_draft(request.draft or default_draft())
            state.update({
                "onboarding_draft": draft,
                "onboarding_ready": request.ready and is_ready(draft),
                "system_prompt": onboarding_prompt(draft),
                "allowed_tools": list(onboarding_tools()),
                "allowed_skills": [],
            })
        elif message.channel == "web":
            await self.ensure_ledger_tools()
            state.update({
                "capability_token": str(message.context.get("_ledger_capability_token") or ""),
                "system_prompt": str(message.context.get("_ledger_system_prompt") or ""),
                "allowed_tools": list(self.tool_specs),
                "allowed_skills": [],
            })
        else:
            bootstrap = await self.capabilities.bootstrap(
                session_id=session_id,
                channel=message.channel,
                context={key: value for key, value in message.context.items() if not key.startswith("_")},
            )
            await self.ensure_ledger_tools(bootstrap.tools)
            state.update({
                "capability_token": bootstrap.capability_token,
                "system_prompt": bootstrap.system_prompt,
                "allowed_tools": [
                    *[spec.name for spec in bootstrap.tools],
                    *(sorted(TELEGRAM_TOOL_NAMES) if message.channel == "telegram" else []),
                ],
                "allowed_skills": ["telegram-ledger-agent", "telegram"] if message.channel == "telegram" else [],
            })
        turn = message.context.get("_ledger_web_turn")
        if isinstance(turn, WebTurn):
            turn.state = state
            state["emit"] = lambda event, payload: self.web_channel.emit(turn, event, payload)  # type: ignore[union-attr]
        return state

    @hookimpl
    async def build_prompt(
        self,
        message: ChannelMessage,
        session_id: str,
        state: dict[str, Any],
    ) -> str | list[dict[str, Any]] | None:
        del session_id
        if state.get("mode") == "onboarding":
            request = message.context.get("_ledger_onboarding_request")
            if isinstance(request, OnboardingRequest):
                prompt = request.message or "请主动开始这次建账引导。"
                if request.messages:
                    history = "\n".join(
                        f"{'用户' if item.role == 'user' else '助手'}：{item.content}"
                        for item in request.messages
                    )
                    prompt = f"此前建账对话：\n{history}\n\n当前用户消息：\n{prompt}"
                return [{"type": "text", "text": prompt}]
        if message.channel == "telegram":
            content = content_of(message)
            if content.strip().startswith(","):
                return content
            return "$telegram-ledger-agent $telegram\n" + content
        if message.channel == "web":
            return content_of(message)
        return None

    @hookimpl
    def system_prompt(self, prompt: str | list[dict[str, Any]], state: dict[str, Any]) -> str:
        del prompt
        return str(state.get("system_prompt") or "")

    @hookimpl
    def render_outbound(
        self,
        message: ChannelMessage,
        session_id: str,
        state: dict[str, Any],
        model_output: str,
    ) -> list[ChannelMessage] | None:
        del state
        turn = message.context.get("_ledger_web_turn")
        if message.channel != "web" or not isinstance(turn, WebTurn):
            return None
        return [ChannelMessage(
            session_id=session_id,
            channel="web",
            chat_id=message.chat_id,
            content=model_output,
            context={"_ledger_web_turn": turn},
        )]

    @hookimpl
    async def on_error(self, stage: str, error: Exception, message: ChannelMessage | None) -> None:
        del stage
        if message is None or message.channel != "web" or self.web_channel is None:
            return
        turn = message.context.get("_ledger_web_turn")
        if not isinstance(turn, WebTurn):
            return
        await self.web_channel.send(ChannelMessage(
            session_id=message.session_id,
            channel="web",
            chat_id=message.chat_id,
            content=str(error),
            kind="error",
            context={"_ledger_web_turn": turn},
        ))

    @hookimpl
    async def run_model_stream(
        self,
        prompt: str | list[dict[str, Any]],
        session_id: str,
        state: dict[str, Any],
    ) -> AsyncStreamEvents:
        async def start_stream() -> AsyncStreamEvents:
            return await self.agent.run_stream(
                session_id=session_id,
                prompt=prompt,
                state=state,
                model=state.get("model"),
                allowed_tools=list(state.get("allowed_tools") or []),
                allowed_skills=list(state.get("allowed_skills") or []),
            )

        stream = await start_stream()
        adapted_state = StreamState()

        async def events():
            nonlocal stream
            recovered = False
            try:
                while True:
                    try:
                        async for event in stream:
                            yield event
                        return
                    except BubError as error:
                        tool_name = _unknown_tool_name(error)
                        if state.get("channel") == "telegram" and tool_name and not recovered:
                            recovered = True
                            tape = self.agent.tape.session_tape(session_id, self.framework.workspace)
                            await tape.handoff(name="recovery/unknown_tool", state={"tool": tool_name})
                            stream = await start_stream()
                            continue
                        raise RuntimeError(str(error)) from error
            finally:
                adapted_state.error = stream.error
                adapted_state.usage = stream.usage

        return AsyncStreamEvents(events(), state=adapted_state)

    @hookimpl
    def before_llm_call(self, request: LlmCallRequest, state: dict[str, Any]) -> LlmCallDecision | None:
        del request
        if state.get("channel") == "telegram" and state.get("_telegram_reply_sent"):
            return LlmCallDecision.finish("")
        return None

    @hookimpl
    async def before_tool_call(self, call: ToolCall, state: dict[str, Any]) -> ToolCallDecision | None:
        if state.get("mode") != "ledger":
            return None
        if call.tool in TELEGRAM_TOOL_NAMES and call.tool in set(state.get("allowed_tools") or []):
            return None
        spec = self.tool_specs.get(call.tool)
        if spec is None or call.tool not in set(state.get("allowed_tools") or []):
            return ToolCallDecision.deny(f"当前 Channel 不允许工具：{call.tool}")
        return None

    @hookimpl
    async def admit_message(
        self,
        session_id: str,
        message: ChannelMessage,
        turn: TurnSnapshot,
    ) -> AdmitDecision | None:
        del session_id, message
        if turn.is_running:
            return AdmitDecision("follow_up", "serialize messages for the same ledger session")
        return None

    async def ensure_ledger_tools(self, specs: list[ToolSpec] | None = None) -> None:
        if specs is None and self.complete_tool_catalog_loaded:
            return
        async with self.tools_lock:
            if specs is None:
                if self.complete_tool_catalog_loaded:
                    return
                resolved = await self.capabilities.specs()
            else:
                resolved = specs
            for spec in resolved:
                self.tool_specs[spec.name] = spec
                REGISTRY[spec.name] = Tool(
                    name=spec.name,
                    description=spec.description,
                    parameters=spec.parameters,
                    context=True,
                    handler=self._ledger_tool_handler(spec.name),
                )
            if specs is None:
                self.complete_tool_catalog_loaded = True

    def _ledger_tool_handler(self, name: str) -> Callable[..., Awaitable[dict[str, Any]]]:
        async def execute(*, context: ToolContext, **arguments: Any) -> dict[str, Any]:
            result = await self.capabilities.execute(
                name,
                arguments,
                str(context.state["capability_token"]),
            )
            return result.model_dump(by_alias=True)

        return execute

    def _register_onboarding_tools(self) -> None:
        for name, tool in onboarding_tools().items():
            REGISTRY[name] = tool

    def _register_telegram_tools(self) -> None:
        REGISTRY[TELEGRAM_SEND_TOOL] = Tool(
            name=TELEGRAM_SEND_TOOL,
            description=(
                "向当前 Telegram 会话发送一条简短纯文本最终回复。"
                "目标 chat 和回复消息由运行时绑定，模型不能指定。"
                "成功后立即结束当前 turn，不要再次调用任何工具。"
            ),
            parameters={
                "type": "object",
                "properties": {"text": {"type": "string", "description": "要发送的最终纯文本回复"}},
                "required": ["text"],
                "additionalProperties": False,
            },
            context=True,
            handler=self._telegram_send_handler,
        )
        REGISTRY[TELEGRAM_SEND_RICH_TOOL] = Tool(
            name=TELEGRAM_SEND_RICH_TOOL,
            description=(
                "向当前 Telegram 会话发送一条结构化富文本最终回复，支持 rich HTML 或 rich Markdown。"
                "适合标题、列表、表格、引用和代码块。"
                "成功后立即结束当前 turn，不要再次调用任何工具。"
            ),
            parameters={
                "type": "object",
                "properties": {
                    "content": {"type": "string", "description": "完整的富文本内容"},
                    "format": {
                        "type": "string",
                        "enum": ["html", "markdown"],
                        "description": "富文本格式",
                    },
                },
                "required": ["content", "format"],
                "additionalProperties": False,
            },
            context=True,
            handler=self._telegram_send_rich_handler,
        )

    async def _telegram_send_handler(self, *, context: ToolContext, text: str) -> dict[str, Any]:
        text = text.strip()
        if not text:
            raise ValueError("Telegram reply cannot be empty")
        if len(text) > 4096:
            raise ValueError("Telegram plain reply exceeds 4096 characters; use a shorter reply")
        return await self._send_telegram_reply(context, text=text)

    async def _telegram_send_rich_handler(
        self,
        *,
        context: ToolContext,
        content: str,
        format: str,
    ) -> dict[str, Any]:
        content = content.strip()
        if not content:
            raise ValueError("Telegram rich reply cannot be empty")
        if len(content) > 16000:
            raise ValueError("Telegram rich reply exceeds 16000 characters")
        if format not in {"html", "markdown"}:
            raise ValueError("Telegram rich reply format must be html or markdown")
        return await self._send_telegram_reply(context, content=content, format=format)

    async def _send_telegram_reply(
        self,
        context: ToolContext,
        *,
        text: str | None = None,
        content: str | None = None,
        format: str | None = None,
    ) -> dict[str, Any]:
        state = context.state
        if state.get("channel") != "telegram":
            raise RuntimeError("Telegram send tools are only available in Telegram turns")
        lock = state.get("_telegram_send_lock")
        if not isinstance(lock, asyncio.Lock):
            lock = asyncio.Lock()
            state["_telegram_send_lock"] = lock
        async with lock:
            if state.get("_telegram_reply_sent"):
                return {"sent": True, "alreadySent": True}
            if self.telegram_channel is None:
                raise RuntimeError("Telegram channel is not running")
            chat_id = str(state.get("chat_id") or "").strip()
            if not chat_id or chat_id == "default":
                raise RuntimeError("Telegram chat is missing")
            reply_to = state.get("telegram_message_id")
            reply_to = reply_to if isinstance(reply_to, int) else None
            if text is not None:
                message_id = await self.telegram_channel.send_agent_text(chat_id, text, reply_to)
                output_format = "text"
            else:
                assert content is not None and format is not None
                message_id = await self.telegram_channel.send_agent_rich(chat_id, content, format, reply_to)
                output_format = format
            state["_telegram_reply_sent"] = True
            return {"sent": True, "messageId": message_id, "format": output_format}

    def bind_store(self) -> None:
        store = self.framework.get_tape_store()
        self.async_store = AsyncTapeStoreAdapter(store)

    async def timeline(self, session_id: str, before: int, limit: int = 80) -> dict[str, Any]:
        entries = list(await self._store().fetch_all(
            TapeQuery(tape=self._tape_name(session_id), store=self._store()).kinds("event")
        ))
        items: list[dict[str, Any]] = []
        positions: dict[str, int] = {}
        pending_legacy_approvals: set[str] = set()
        for entry in entries:
            if entry.payload.get("name") != "ui":
                continue
            data = entry.payload.get("data") or {}
            event, payload = data.get("event"), data.get("payload")
            if not isinstance(payload, dict):
                continue
            if event == "message":
                items.append(payload)
            elif event in {"tool_call", "tool_result"}:
                item = {"id": payload.get("id"), "kind": "tool", "tool": payload}
                item_id = str(item["id"])
                if item_id in positions:
                    old = items[positions[item_id]].get("tool", {})
                    item["tool"] = {**old, **payload}
                    items[positions[item_id]] = item
                else:
                    positions[item_id] = len(items)
                    items.append(item)
            elif event == "artifact":
                items.append({"id": payload.get("id"), "kind": "artifact", "artifact": payload})
            elif event == "approval_required":
                approval_id = str(payload.get("id") or "unknown")
                pending_legacy_approvals.add(approval_id)
                items.append({
                    "id": f"legacy-approval-{approval_id}",
                    "kind": "message",
                    "role": "assistant",
                    "content": "旧版待确认操作已结束，请重新发送请求并按新的对话确认流程操作。",
                    "_legacy_approval_id": approval_id,
                })
            elif event == "approval_resolution":
                pending_legacy_approvals.discard(str(payload.get("id") or "unknown"))
        items = [
            {key: value for key, value in item.items() if key != "_legacy_approval_id"}
            for item in items
            if "_legacy_approval_id" not in item or item["_legacy_approval_id"] in pending_legacy_approvals
        ]
        end = min(before, len(items)) if before > 0 else len(items)
        start = max(0, end - min(max(limit, 1), 80))
        return {"items": items[start:end], "nextBefore": start if start > 0 else None}

    async def delete_session(self, session_id: str) -> None:
        await self._store().reset(self._tape_name(session_id))

    async def record_ui_event(self, session_id: str, event: str, payload: dict[str, Any]) -> None:
        await self._store().append(
            self._tape_name(session_id),
            TapeEntry.event("ui", {"event": event, "payload": payload}),
        )

    async def close(self) -> None:
        await self.capabilities.close()

    def _store(self) -> AsyncTapeStoreAdapter:
        if self.async_store is None:
            raise RuntimeError("Bub tape store is not running")
        return self.async_store

    def _tape_name(self, session_id: str) -> str:
        return self.agent.tape.session_tape(session_id, self.framework.workspace).name


class AgentGateway:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.framework: BubFramework | None = None
        self.plugin: LedgerPlugin | None = None
        self.manager: ChannelManager | None = None
        self.task: asyncio.Task | None = None

    async def __aenter__(self) -> AgentGateway:
        if self.settings.database_url:
            os.environ["BUB_TAPESTORE_SQLALCHEMY_URL"] = _sqlalchemy_url(self.settings.database_url)
        framework = BubFramework(config_file=Path("/nonexistent/ledger-agent-bub.yml"))
        _GATEWAY_SETTINGS[framework] = self.settings
        framework.load_hooks()
        plugin = plugin_for(framework)
        manager = ChannelManager(
            framework,
            enabled_channels=["web", "telegram"],
            stream_output=True,
        )
        self.framework, self.plugin, self.manager = framework, plugin, manager
        self.task = asyncio.create_task(manager.listen_and_run())
        ready_task = asyncio.create_task(plugin.ready.wait())
        try:
            done, _ = await asyncio.wait({self.task, ready_task}, timeout=30, return_when=asyncio.FIRST_COMPLETED)
            if self.task in done:
                await self.task
            if ready_task not in done or framework.get_tape_store() is None:
                raise RuntimeError("Bub ChannelManager did not become ready")
        except BaseException:
            ready_task.cancel()
            if not self.task.done():
                self.task.cancel()
            await asyncio.gather(ready_task, self.task, return_exceptions=True)
            await plugin.close()
            raise
        plugin.bind_store()
        return self

    async def __aexit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        if self.task is not None:
            self.task.cancel()
            try:
                await self.task
            except asyncio.CancelledError:
                pass
        if self.plugin is not None:
            await self.plugin.close()

    @property
    def web(self) -> LedgerWebChannel:
        if self.plugin is None or self.plugin.web_channel is None:
            raise RuntimeError("web channel is not available")
        return self.plugin.web_channel

    @property
    def healthy(self) -> bool:
        return bool(
            self.task is not None
            and not self.task.done()
            and self.plugin is not None
            and self.plugin.ready.is_set()
            and self.framework is not None
            and self.framework.get_tape_store() is not None
        )

    def ensure_healthy(self) -> None:
        if not self.healthy:
            raise RuntimeError("Bub ChannelManager is not running")

    async def turn(self, request: TurnRequest) -> AsyncIterator[tuple[str, dict[str, Any]]]:
        self.ensure_healthy()
        async for item in self.web.turn(request):
            yield item

    async def onboarding_turn(self, request: OnboardingRequest) -> AsyncIterator[tuple[str, dict[str, Any]]]:
        self.ensure_healthy()
        async for item in self.web.onboarding(request):
            yield item

    async def timeline(self, session_id: str, before: int) -> dict[str, Any]:
        assert self.plugin is not None
        return await self.plugin.timeline(session_id, before)

    async def delete_session(self, session_id: str) -> None:
        assert self.plugin is not None
        await self.plugin.delete_session(session_id)


def plugin_for(framework: BubFramework) -> LedgerPlugin:
    plugin = _PLUGINS.get(framework)
    if plugin is None:
        raise RuntimeError("ledger-web Bub plugin did not load")
    return plugin


def _sqlalchemy_url(database_url: str) -> str:
    if database_url.startswith("postgres://"):
        return "postgresql+psycopg://" + database_url.removeprefix("postgres://")
    if database_url.startswith("postgresql://"):
        return "postgresql+psycopg://" + database_url.removeprefix("postgresql://")
    return database_url


def _unknown_tool_name(error: BubError) -> str | None:
    prefix = "Unknown tool name: "
    if error.kind != ErrorKind.TOOL or not error.message.startswith(prefix) or not error.message.endswith("."):
        return None
    return error.message.removeprefix(prefix).removesuffix(".").strip() or None


def _telegram_message_id(message: ChannelMessage) -> int | None:
    try:
        payload = json.loads(content_of(message))
    except (json.JSONDecodeError, TypeError):
        return None
    message_id = payload.get("message_id") if isinstance(payload, dict) else None
    return message_id if isinstance(message_id, int) else None
