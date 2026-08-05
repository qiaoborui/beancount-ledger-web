from __future__ import annotations

import asyncio
import hashlib
import json
import os
from collections import defaultdict
from collections.abc import AsyncIterator, Awaitable, Callable
from datetime import date
from decimal import Decimal, InvalidOperation
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
from bub.hooks.interception import LlmCallDecision, LlmCallRequest, ToolCall, ToolCallDecision, ToolCallResult
from bub.streaming import AsyncStreamEvents, StreamState
from bub.tape import AsyncTapeStoreAdapter, TapeContext, TapeEntry, TapeQuery
from bub.tools import REGISTRY, Tool, ToolContext
from .capabilities import LedgerCapabilities
from .config import Settings
from .interactions import InteractionBroker
from .onboarding import default_draft, is_ready, normalize_draft, onboarding_tools, prompt as onboarding_prompt
from .protocol import OnboardingRequest, ToolSpec, TurnRequest
from .web_channel import LedgerWebChannel, WebTurn

CONFIRM_PHRASES = {"确认写入", "确认入账", "confirm write"}
_PLUGINS: WeakKeyDictionary[BubFramework, LedgerPlugin] = WeakKeyDictionary()
_GATEWAY_SETTINGS: WeakKeyDictionary[BubFramework, Settings] = WeakKeyDictionary()


class LedgerTelegramChannel:
    """Factory wrapper that keeps Bub's Telegram implementation and enables normal outbound replies."""

    @staticmethod
    def create(on_receive: MessageHandler):
        from bub.channels.telegram import TelegramChannel

        class OutboundTelegramChannel(TelegramChannel):
            @property
            def needs_debounce(self) -> bool:
                # A chat may contain multiple allowed users. Keep each sender's
                # identity attached to its own message for write confirmation.
                return False

            async def _build_message(self, message):
                inbound = await super()._build_message(message)
                inbound.output_channel = self.name
                if message.from_user is not None:
                    inbound.context["_ledger_sender_id"] = str(message.from_user.id)
                return inbound

            async def stop(self) -> None:
                if not hasattr(self, "_app"):
                    return
                await super().stop()

        return OutboundTelegramChannel(on_receive=on_receive)


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
        self.broker = InteractionBroker(self.settings.approval_timeout_seconds)
        self.approval_locks: defaultdict[str, asyncio.Lock] = defaultdict(asyncio.Lock)
        self.ready = asyncio.Event()
        self.agent = Agent(framework)
        self.tool_specs: dict[str, ToolSpec] = {}
        self.tools_lock = asyncio.Lock()
        self.async_store: AsyncTapeStoreAdapter | None = None
        self.web_channel: LedgerWebChannel | None = None
        self._register_onboarding_tools()
        _PLUGINS[framework] = self

    @hookimpl
    def build_tape_context(self) -> TapeContext:
        return default_tape_context()

    @hookimpl
    def provide_channels(self, message_handler: MessageHandler) -> list[Any]:
        web = LedgerWebChannel(message_handler, self.tool_specs, self.record_ui_event)
        self.web_channel = web
        return [web, LedgerTelegramChannel.create(message_handler), GatewayReadiness(self.ready)]

    @hookimpl
    async def load_state(self, message: ChannelMessage, session_id: str) -> dict[str, Any]:
        mode = str(message.context.get("_ledger_mode") or "ledger")
        state: dict[str, Any] = {
            "mode": mode,
            "session_id": session_id,
            "confirmation_tokens": {},
            "channel": message.channel,
            "chat_id": message.chat_id,
            "sender_id": str(message.context.get("_ledger_sender_id") or ""),
        }
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
                "approval_policy": str(message.context.get("_ledger_approval_policy") or "on-write"),
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
                "approval_policy": "on-write",
                "allowed_tools": [spec.name for spec in bootstrap.tools],
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
            return "$telegram-ledger-agent $telegram\n" + content_of(message)
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
    def before_llm_call(self, request: LlmCallRequest, state: dict[str, Any]) -> LlmCallDecision | None:
        del request
        reply = state.pop("_ledger_telegram_summary_reply", None)
        return LlmCallDecision.finish(reply) if isinstance(reply, str) and reply else None

    @hookimpl
    async def after_tool_call(self, call: ToolCall, result: ToolCallResult, state: dict[str, Any]) -> None:
        if state.get("channel") != "telegram" or call.tool != "get_ledger_summary" or result.error is not None:
            return
        reply = _telegram_summary_reply(result.result)
        if reply:
            state["_ledger_telegram_summary_reply"] = reply

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
    async def before_tool_call(self, call: ToolCall, state: dict[str, Any]) -> ToolCallDecision | None:
        if state.get("mode") != "ledger":
            return None
        spec = self.tool_specs.get(call.tool)
        if spec is None or call.tool not in set(state.get("allowed_tools") or []):
            return ToolCallDecision.deny(f"当前 Channel 不允许工具：{call.tool}")
        if not spec.requires_approval and state.get("approval_policy") != "always":
            return None

        session_id = str(state["session_id"])
        async with self.approval_locks[session_id]:
            return await self._approve_tool_call(call, state, spec, session_id)

    async def _approve_tool_call(
        self,
        call: ToolCall,
        state: dict[str, Any],
        spec: ToolSpec,
        session_id: str,
    ) -> ToolCallDecision:
        preview = None
        confirmation_key = f"{call.tool}:{_arguments_hash(call.arguments)}"
        if spec.requires_approval:
            try:
                preview = await self.capabilities.preview(
                    call.tool,
                    call.arguments,
                    str(state["capability_token"]),
                )
            except Exception as exc:
                return ToolCallDecision.deny(str(exc))
            state.setdefault("confirmation_tokens", {})[confirmation_key] = preview.confirmation_token

        interaction, future = await self.broker.create(session_id, str(state.get("sender_id") or ""))
        approval = {
            "id": interaction.id,
            "sessionId": session_id,
            "toolCallId": f"{call.run_id}:{call.tool}:{_arguments_hash(call.arguments)}",
            "toolName": call.tool,
            "toolTitle": spec.title,
            "summary": spec.approval_message or _approval_summary(call.tool, call.arguments),
            "createdAt": interaction.created_at.isoformat(),
            "expiresAt": interaction.expires_at.isoformat(),
        }
        emit = state.get("emit")
        try:
            if state.get("channel") == "telegram":
                await self._send_telegram_approval(state, spec, preview.artifacts if preview else [])
            else:
                if not callable(emit):
                    await self.broker.discard(interaction.id)
                    state.setdefault("confirmation_tokens", {}).pop(confirmation_key, None)
                    return ToolCallDecision.deny("当前 Channel 不支持写入确认")
                if preview:
                    for artifact in preview.artifacts:
                        await emit("artifact", artifact)
                await emit("approval_required", approval)
            approved = await self.broker.wait(interaction, future)
        except TimeoutError:
            if callable(emit):
                await emit("approval_resolution", {"id": interaction.id, "approved": False})
            state.setdefault("confirmation_tokens", {}).pop(confirmation_key, None)
            return ToolCallDecision.deny("确认已超时，工具未执行")
        except BaseException:
            await self.broker.discard(interaction.id)
            state.setdefault("confirmation_tokens", {}).pop(confirmation_key, None)
            raise
        if callable(emit):
            await emit("approval_resolution", {"id": interaction.id, "approved": approved})
        if not approved:
            state.setdefault("confirmation_tokens", {}).pop(confirmation_key, None)
        return ToolCallDecision.proceed() if approved else ToolCallDecision.deny("用户取消了这次工具调用")

    @hookimpl
    async def admit_message(
        self,
        session_id: str,
        message: ChannelMessage,
        turn: TurnSnapshot,
    ) -> AdmitDecision | None:
        if message.channel == "telegram" and await self.broker.has_pending_session(session_id):
            sender_id = str(message.context.get("_ledger_sender_id") or "")
            if not sender_id or not await self.broker.has_pending_session(session_id, sender_id):
                return AdmitDecision("drop", "telegram confirmation sender does not match pending write")
            text = _channel_text(message.content).strip().casefold()
            approved = text in {phrase.casefold() for phrase in CONFIRM_PHRASES}
            await self.broker.resolve_session(session_id, approved, sender_id)
            if approved:
                return AdmitDecision("drop", "telegram write confirmation consumed")
        if turn.is_running:
            return AdmitDecision("follow_up", "serialize messages for the same ledger session")
        return None

    async def ensure_ledger_tools(self, specs: list[ToolSpec] | None = None) -> None:
        if specs is None and self.tool_specs:
            return
        async with self.tools_lock:
            resolved = specs or (await self.capabilities.specs())
            for spec in resolved:
                self.tool_specs[spec.name] = spec
                REGISTRY[spec.name] = Tool(
                    name=spec.name,
                    description=spec.description,
                    parameters=spec.parameters,
                    context=True,
                    handler=self._ledger_tool_handler(spec.name),
                )

    def _ledger_tool_handler(self, name: str) -> Callable[..., Awaitable[dict[str, Any]]]:
        async def execute(*, context: ToolContext, **arguments: Any) -> dict[str, Any]:
            confirmation_key = f"{name}:{_arguments_hash(arguments)}"
            confirmation_token = context.state.setdefault("confirmation_tokens", {}).pop(confirmation_key, "")
            result = await self.capabilities.execute(
                name,
                arguments,
                str(context.state["capability_token"]),
                confirmation_token,
            )
            return result.model_dump(by_alias=True)

        return execute

    def _register_onboarding_tools(self) -> None:
        for name, tool in onboarding_tools().items():
            REGISTRY[name] = tool

    async def _send_telegram_approval(
        self,
        state: dict[str, Any],
        spec: ToolSpec,
        artifacts: list[dict[str, Any]],
    ) -> None:
        summary = spec.approval_message or "待确认账本写入"
        if artifacts:
            summary += "\n\n" + json.dumps(artifacts[0].get("data"), ensure_ascii=False, indent=2)
        summary += "\n\n确认无误请回复：确认写入"
        await self.framework.dispatch_via_channel_router(ChannelMessage(
            session_id=str(state["session_id"]),
            channel="telegram",
            output_channel="telegram",
            chat_id=str(state.get("chat_id") or "default"),
            content=summary,
        ))

    def bind_store(self) -> None:
        store = self.framework.get_tape_store()
        self.async_store = AsyncTapeStoreAdapter(store)

    async def timeline(self, session_id: str, before: int, limit: int = 80) -> dict[str, Any]:
        entries = list(await self._store().fetch_all(
            TapeQuery(tape=self._tape_name(session_id), store=self._store()).kinds("event")
        ))
        items: list[dict[str, Any]] = []
        positions: dict[str, int] = {}
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
                positions[str(payload.get("id"))] = len(items)
                items.append({"id": payload.get("id"), "kind": "approval", "approval": payload})
            elif event == "approval_resolution":
                index = positions.get(str(payload.get("id")))
                if index is not None:
                    items[index]["resolved"] = True
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
    def broker(self) -> InteractionBroker:
        if self.plugin is None:
            raise RuntimeError("ledger plugin is not available")
        return self.plugin.broker

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


def _arguments_hash(arguments: dict[str, Any]) -> str:
    raw = json.dumps(arguments, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


def _approval_summary(name: str, arguments: dict[str, Any]) -> str:
    if name == "append_transactions":
        return f"写入 {len(arguments.get('entries') or [])} 条账本记录"
    if name == "apply_account_operations":
        return f"执行 {len(arguments.get('operations') or [])} 个账户操作"
    return "确认执行工具调用"


def _channel_text(content: str) -> str:
    try:
        payload = json.loads(content)
    except json.JSONDecodeError:
        return content
    if isinstance(payload, dict) and isinstance(payload.get("message"), str):
        return payload["message"]
    return content


def _unknown_tool_name(error: BubError) -> str | None:
    prefix = "Unknown tool name: "
    if error.kind != ErrorKind.TOOL or not error.message.startswith(prefix) or not error.message.endswith("."):
        return None
    return error.message.removeprefix(prefix).removesuffix(".").strip() or None


def _telegram_summary_reply(result: Any) -> str | None:
    if not isinstance(result, dict):
        return None
    output = result.get("modelOutput")
    if not isinstance(output, dict) or not isinstance(output.get("summary"), dict):
        return None
    summary = output["summary"]
    currency = str(summary.get("currency") or output.get("valuationCurrency") or "CNY")
    start = str(output.get("start") or "")
    try:
        month = date.fromisoformat(start).strftime("%Y 年 %-m 月")
    except ValueError:
        month = "本期"

    def amount(name: str) -> str:
        try:
            return f"{Decimal(str(summary.get(name, 0))):.2f}"
        except InvalidOperation:
            return str(summary.get(name) or "0.00")

    categories = summary.get("categories")
    ranked: list[tuple[Decimal, str]] = []
    if isinstance(categories, dict):
        for account, raw in categories.items():
            try:
                ranked.append((abs(Decimal(str(raw))), str(account).rsplit(":", 1)[-1]))
            except InvalidOperation:
                continue
    ranked.sort(reverse=True)
    lines = [
        f"{month}账本汇总：",
        f"- 支出 {amount('expense')} {currency}",
        f"- 收入 {amount('income')} {currency}",
        f"- 净额 {amount('net')} {currency}",
    ]
    if ranked:
        lines.extend(["", "主要支出："])
        lines.extend(f"- {label} {value:.2f} {currency}" for value, label in ranked[:3])
    return "\n".join(lines)
