from __future__ import annotations

import asyncio
import hashlib
import json
import os
import secrets
from collections import defaultdict
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import AbstractAsyncContextManager
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from bub.builtin.agent import Agent
from bub.builtin.context import default_tape_context
from bub.framework import BubFramework
from bub.hooks import hookimpl
from bub.hooks.interception import ToolCall, ToolCallDecision
from bub.streaming import StreamEvent
from bub.tape import AsyncTapeStoreAdapter, TapeContext, TapeEntry, TapeQuery
from bub.tools import REGISTRY, Tool, ToolContext
from bub_tapestore_sqlalchemy import SQLAlchemyTapeStore

from .capabilities import LedgerCapabilities
from .config import Settings
from .interactions import InteractionBroker
from .onboarding import default_draft, is_ready, normalize_draft, onboarding_tools, prompt as onboarding_prompt
from .protocol import OnboardingRequest, ToolSpec, TurnRequest

EventSink = Callable[[str, dict[str, Any]], Awaitable[None]]


class LedgerPlugin:
    def __init__(
        self,
        capabilities: LedgerCapabilities,
        broker: InteractionBroker,
        tool_specs: dict[str, ToolSpec],
    ) -> None:
        self.capabilities = capabilities
        self.broker = broker
        self.tool_specs = tool_specs
        self.approval_locks: defaultdict[str, asyncio.Lock] = defaultdict(asyncio.Lock)

    @hookimpl
    def build_tape_context(self) -> TapeContext:
        return default_tape_context()

    @hookimpl
    def system_prompt(self, prompt: str | list[dict[str, Any]], state: dict[str, Any]) -> str:
        return str(state.get("system_prompt") or "")

    @hookimpl
    async def before_tool_call(self, call: ToolCall, state: dict[str, Any]) -> ToolCallDecision | None:
        if state.get("mode") != "ledger":
            return None
        spec = self.tool_specs.get(call.tool)
        if spec is None:
            return ToolCallDecision.deny(f"未知账本工具：{call.tool}")
        if not spec.requires_approval and state.get("approval_policy") != "always":
            return None

        session_id = str(state["session_id"])
        emit: EventSink = state["emit"]
        async with self.approval_locks[session_id]:
            if spec.requires_approval:
                try:
                    preview = await self.capabilities.preview(
                        call.tool,
                        call.arguments,
                        str(state["capability_token"]),
                    )
                except Exception as exc:
                    return ToolCallDecision.deny(str(exc))
                for artifact in preview.artifacts:
                    await emit("artifact", artifact)
                state.setdefault("confirmation_tokens", {})[
                    f"{call.tool}:{_arguments_hash(call.arguments)}"
                ] = preview.confirmation_token

            interaction, future = await self.broker.create(session_id)
            tool_call_id = f"{call.run_id}:{call.tool}:{_arguments_hash(call.arguments)}"
            approval = {
                "id": interaction.id,
                "sessionId": session_id,
                "toolCallId": tool_call_id,
                "toolName": call.tool,
                "toolTitle": spec.title,
                "summary": spec.approval_message or _approval_summary(call.tool, call.arguments),
                "createdAt": interaction.created_at.isoformat(),
                "expiresAt": interaction.expires_at.isoformat(),
            }
            await emit("approval_required", approval)
            try:
                approved = await self.broker.wait(interaction, future)
            except TimeoutError:
                await emit("approval_resolution", {"id": interaction.id, "approved": False})
                return ToolCallDecision.deny("确认已超时，工具未执行")
            await emit("approval_resolution", {"id": interaction.id, "approved": approved})
            if not approved:
                return ToolCallDecision.deny("用户取消了这次工具调用")
            return ToolCallDecision.proceed()


class AgentRuntime:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.store: SQLAlchemyTapeStore | None = None
        self.async_store: AsyncTapeStoreAdapter | None = None
        self.capabilities = LedgerCapabilities(settings.ledger_api_url, settings.service_token)
        self.broker = InteractionBroker(settings.approval_timeout_seconds)
        self.framework: BubFramework | None = None
        self.agent: Agent | None = None
        self.plugin: LedgerPlugin | None = None
        self.running_context: AbstractAsyncContextManager | None = None
        self.tool_specs: dict[str, ToolSpec] = {}
        self.tools_lock = asyncio.Lock()
        self.session_locks: defaultdict[str, asyncio.Lock] = defaultdict(asyncio.Lock)

    async def __aenter__(self) -> "AgentRuntime":
        os.environ["BUB_TAPESTORE_SQLALCHEMY_URL"] = _sqlalchemy_url(self.settings.database_url)
        framework = BubFramework(config_file=Path("/nonexistent/ledger-agent-bub.yml"))
        framework.load_hooks()
        plugin = LedgerPlugin(self.capabilities, self.broker, self.tool_specs)
        framework._plugin_manager.register(plugin, name="ledger-web")
        self.framework = framework
        self.plugin = plugin
        self.agent = Agent(framework)
        self.running_context = framework.running()
        await self.running_context.__aenter__()
        store = framework.get_tape_store()
        if not isinstance(store, SQLAlchemyTapeStore):
            raise RuntimeError("bub-tapestore-sqlalchemy did not provide the active tape store")
        self.store = store
        self.async_store = AsyncTapeStoreAdapter(store)
        self._register_onboarding_tools()
        return self

    async def __aexit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        if self.running_context is not None:
            await self.running_context.__aexit__(exc_type, exc, traceback)
        await self.capabilities.close()

    async def ensure_ledger_tools(self) -> None:
        if self.tool_specs:
            return
        async with self.tools_lock:
            if self.tool_specs:
                return
            specs = await self.capabilities.specs()
            for spec in specs:
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

    async def turn(self, request: TurnRequest) -> AsyncIterator[tuple[str, dict[str, Any]]]:
        await self.ensure_ledger_tools()
        assert self.agent is not None
        queue: asyncio.Queue[tuple[str, dict[str, Any]] | None] = asyncio.Queue()
        tape_name = self._tape_name(request.session_id)
        refresh_ledger = False

        async def emit(event: str, payload: dict[str, Any]) -> None:
            await self._append_ui(tape_name, event, payload)
            await queue.put((event, payload))

        state: dict[str, Any] = {
            "_runtime_workspace": str(Path.cwd()),
            "mode": "ledger",
            "session_id": request.session_id,
            "capability_token": request.capability_token,
            "approval_policy": request.approval_policy,
            "system_prompt": request.system_prompt,
            "emit": emit,
            "confirmation_tokens": {},
        }

        async def produce() -> None:
            nonlocal refresh_ledger
            try:
                async with self.session_locks[request.session_id]:
                    await emit(
                        "message",
                        {"id": _id("message"), "kind": "message", "role": "user", "content": request.message},
                    )
                    await queue.put(("status", {"text": "正在分析请求"}))
                    stream = await self.agent.run_stream(
                        session_id=request.session_id,
                        prompt=request.message,
                        state=state,
                        allowed_tools=list(self.tool_specs),
                        allowed_skills=[],
                    )
                    text = ""
                    active_calls: list[dict[str, Any]] = []
                    async for event in stream:
                        if event.kind == "text":
                            text += str(event.data.get("delta", ""))
                            await queue.put(("message_delta", {"text": text}))
                        elif event.kind == "tool_call":
                            active_calls = _normalize_tool_calls(event)
                            for call in active_calls:
                                spec = self.tool_specs.get(call["name"])
                                payload = {
                                    "id": call["id"],
                                    "name": call["name"],
                                    "title": spec.title if spec else call["name"],
                                    "status": "running",
                                    "input": call["arguments"],
                                }
                                await emit("tool_call", payload)
                        elif event.kind == "tool_result":
                            results = list(event.data.get("tool_results") or [])
                            for index, result in enumerate(results):
                                call = active_calls[index] if index < len(active_calls) else {"id": _id("tool"), "name": "tool"}
                                spec = self.tool_specs.get(call["name"])
                                payload, artifacts, changed = _tool_result_payload(call, spec, result)
                                refresh_ledger = refresh_ledger or changed
                                await emit("tool_result", payload)
                                for artifact in artifacts:
                                    await emit("artifact", artifact)
                            await queue.put(("status", {"text": "正在整理工具结果"}))
                    message = text.strip() or "处理完成。"
                    await emit(
                        "message",
                        {"id": _id("message"), "kind": "message", "role": "assistant", "content": message},
                    )
                    await queue.put(
                        (
                            "final",
                            {
                                "sessionId": request.session_id,
                                "message": message,
                                "status": "completed",
                                "refreshLedger": refresh_ledger,
                            },
                        )
                    )
            except Exception as exc:
                await queue.put(("error", {"error": str(exc)}))
            finally:
                await queue.put(None)

        asyncio.create_task(produce())
        while True:
            item = await queue.get()
            if item is None:
                return
            yield item

    async def onboarding_turn(self, request: OnboardingRequest) -> AsyncIterator[tuple[str, dict[str, Any]]]:
        assert self.agent is not None
        if not request.start and not request.message:
            raise ValueError("message is required unless start is true")
        draft = normalize_draft(request.draft or default_draft())
        session_id = "temp/onboarding-" + secrets.token_hex(12)
        state: dict[str, Any] = {
            "_runtime_workspace": str(Path.cwd()),
            "mode": "onboarding",
            "session_id": session_id,
            "onboarding_draft": draft,
            "onboarding_ready": request.ready and is_ready(draft),
            "system_prompt": onboarding_prompt(draft),
        }
        history = [{"role": item.role, "content": item.content} for item in request.messages]
        prompt: str | list[dict[str, Any]] = request.message or "请主动开始这次建账引导。"
        if history:
            prompt = [*history, {"role": "user", "content": prompt}]
        yield "status", {"text": "正在分析建账信息"}
        stream = await self.agent.run_stream(
            session_id=session_id,
            prompt=prompt,
            state=state,
            allowed_tools=list(onboarding_tools()),
            allowed_skills=[],
        )
        text = ""
        active_calls: list[dict[str, Any]] = []
        async for event in stream:
            if event.kind == "text":
                text += str(event.data.get("delta", ""))
                yield "message_delta", {"text": text}
            elif event.kind == "tool_call":
                active_calls = _normalize_tool_calls(event)
                for call in active_calls:
                    yield "tool_call", {"id": call["id"], "name": call["name"], "title": call["name"], "status": "running", "input": call["arguments"]}
            elif event.kind == "tool_result":
                for index, result in enumerate(list(event.data.get("tool_results") or [])):
                    call = active_calls[index] if index < len(active_calls) else {"id": _id("tool"), "name": "tool"}
                    is_error = isinstance(result, dict) and "message" in result and "kind" in result
                    payload = {"id": call["id"], "name": call["name"], "title": call["name"], "status": "error" if is_error else "completed"}
                    if is_error:
                        payload["error"] = str(result.get("message"))
                    else:
                        payload["output"] = result
                    yield "tool_result", payload
                yield "onboarding_draft", {"draft": state["onboarding_draft"], "ready": bool(state["onboarding_ready"])}
        message = text.strip() or "我已经更新了这份财务地图。接下来想先确认哪一部分？"
        yield "final", {
            "sessionId": "",
            "message": message,
            "status": "completed",
            "draft": state["onboarding_draft"],
            "ready": bool(state["onboarding_ready"]),
        }

    async def timeline(self, session_id: str, before: int, limit: int = 80) -> dict[str, Any]:
        tape_name = self._tape_name(session_id)
        assert self.async_store is not None
        entries = list(
            await self.async_store.fetch_all(TapeQuery(tape=tape_name, store=self.async_store).kinds("event"))
        )
        items: list[dict[str, Any]] = []
        positions: dict[str, int] = {}
        for entry in entries:
            if entry.payload.get("name") != "ui":
                continue
            data = entry.payload.get("data") or {}
            event = data.get("event")
            payload = data.get("payload")
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
        assert self.async_store is not None
        await self.async_store.reset(self._tape_name(session_id))

    def _tape_name(self, session_id: str) -> str:
        assert self.agent is not None
        return self.agent.tape.session_tape(session_id, Path.cwd()).name

    async def _append_ui(self, tape_name: str, event: str, payload: dict[str, Any]) -> None:
        assert self.async_store is not None
        await self.async_store.append(tape_name, TapeEntry.event("ui", {"event": event, "payload": payload}))


def _id(prefix: str) -> str:
    return f"{prefix}-{secrets.token_hex(12)}"


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


def _normalize_tool_calls(event: StreamEvent) -> list[dict[str, Any]]:
    calls: list[dict[str, Any]] = []
    for raw in event.data.get("tool_calls") or []:
        function = raw.get("function") or {}
        arguments = function.get("arguments") or {}
        if isinstance(arguments, str):
            try:
                arguments = json.loads(arguments)
            except json.JSONDecodeError:
                arguments = {}
        calls.append(
            {
                "id": str(raw.get("id") or _id("tool")),
                "name": str(function.get("name") or "tool"),
                "arguments": arguments if isinstance(arguments, dict) else {},
            }
        )
    return calls


def _tool_result_payload(
    call: dict[str, Any],
    spec: ToolSpec | None,
    result: Any,
) -> tuple[dict[str, Any], list[dict[str, Any]], bool]:
    title = spec.title if spec else call["name"]
    if isinstance(result, dict) and "kind" in result and "message" in result:
        return (
            {"id": call["id"], "name": call["name"], "title": title, "status": "error", "error": str(result["message"])},
            [],
            False,
        )
    if isinstance(result, dict) and "modelOutput" in result:
        return (
            {"id": call["id"], "name": call["name"], "title": title, "status": "completed", "output": result.get("clientOutput")},
            list(result.get("artifacts") or []),
            bool(result.get("refreshLedger")),
        )
    return (
        {"id": call["id"], "name": call["name"], "title": title, "status": "completed", "output": result},
        [],
        False,
    )
