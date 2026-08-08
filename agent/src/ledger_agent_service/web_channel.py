from __future__ import annotations

import asyncio
import json
import secrets
from collections.abc import AsyncIterable, AsyncIterator, Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any

from bub.channels.base import Interface
from bub.channels.contracts import MessageHandler
from bub.channels.message import ChannelMessage
from bub.streaming import StreamEvent

from .protocol import OnboardingRequest, ToolSpec, TurnRequest

Event = tuple[str, dict[str, Any]]
EventRecorder = Callable[[str, str, dict[str, Any]], Awaitable[None]]


@dataclass
class WebTurn:
    id: str
    session_id: str
    mode: str
    queue: asyncio.Queue[Event | None] = field(default_factory=asyncio.Queue)
    text: str = ""
    refresh_ledger: bool = False
    active_calls: list[dict[str, Any]] = field(default_factory=list)
    state: dict[str, Any] = field(default_factory=dict)
    closed: bool = False


class LedgerWebChannel(Interface):
    """HTTP/SSE bridge implemented as a regular Bub interface channel."""

    name = "web"

    def __init__(
        self,
        on_receive: MessageHandler,
        tool_specs: dict[str, ToolSpec],
        record_event: EventRecorder,
    ) -> None:
        self._on_receive = on_receive
        self._tool_specs = tool_specs
        self._record_event = record_event
        self._turns: dict[str, WebTurn] = {}

    async def start(self, stop_event: asyncio.Event) -> None:
        del stop_event

    async def stop(self) -> None:
        for turn in list(self._turns.values()):
            await self._close(turn)

    async def turn(self, request: TurnRequest) -> AsyncIterator[Event]:
        async for item in self._submit(
            session_id=request.session_id,
            content=request.message,
            mode="ledger",
            context={
                "_ledger_system_prompt": request.mcp_system_prompt or request.system_prompt,
                "page": request.context.model_dump(by_alias=True),
            },
        ):
            yield item

    async def onboarding(self, request: OnboardingRequest) -> AsyncIterator[Event]:
        session_id = "temp/onboarding-" + secrets.token_hex(12)
        async for item in self._submit(
            session_id=session_id,
            content=request.message or "请主动开始这次建账引导。",
            mode="onboarding",
            context={
                "_ledger_onboarding_request": request,
            },
        ):
            yield item

    async def _submit(
        self,
        *,
        session_id: str,
        content: str,
        mode: str,
        context: dict[str, Any],
    ) -> AsyncIterator[Event]:
        turn = WebTurn(id="turn-" + secrets.token_hex(12), session_id=session_id, mode=mode)
        self._turns[turn.id] = turn
        context = {**context, "_ledger_mode": mode, "_ledger_web_turn": turn}
        message = ChannelMessage(
            session_id=session_id,
            channel=self.name,
            chat_id=session_id,
            content=content,
            context=context,
        )
        if mode == "ledger":
            await self.emit(
                turn,
                "message",
                {"id": _id("message"), "kind": "message", "role": "user", "content": content},
            )
        await turn.queue.put(("status", {"text": "正在分析请求" if mode == "ledger" else "正在分析建账信息"}))
        try:
            await self._on_receive(message)
        except Exception as exc:
            await turn.queue.put(("error", {"error": str(exc)}))
            await self._close(turn)

        while True:
            item = await turn.queue.get()
            if item is None:
                return
            yield item

    async def send(self, message: ChannelMessage) -> None:
        turn = message.context.get("_ledger_web_turn")
        if not isinstance(turn, WebTurn) or self._turns.get(turn.id) is not turn or turn.closed:
            return
        if message.kind == "error":
            await turn.queue.put(("error", {"error": message.content}))
            await self._close(turn)
            return

        final_message = message.content.strip() or "处理完成。"
        if turn.mode == "ledger":
            await self.emit(
                turn,
                "message",
                {"id": _id("message"), "kind": "message", "role": "assistant", "content": final_message},
            )
            await turn.queue.put((
                "final",
                {
                    "sessionId": turn.session_id,
                    "message": final_message,
                    "status": "completed",
                    "refreshLedger": turn.refresh_ledger,
                },
            ))
        else:
            await turn.queue.put((
                "final",
                {
                    "sessionId": "",
                    "message": final_message,
                    "status": "completed",
                    "draft": turn.state.get("onboarding_draft"),
                    "ready": bool(turn.state.get("onboarding_ready")),
                },
            ))
        await self._close(turn)

    def stream_events(
        self,
        message: ChannelMessage,
        stream: AsyncIterable[StreamEvent],
    ) -> AsyncIterable[StreamEvent]:
        turn = message.context.get("_ledger_web_turn")
        if not isinstance(turn, WebTurn):
            return stream

        async def wrapped() -> AsyncIterator[StreamEvent]:
            async for event in stream:
                if event.kind == "text":
                    turn.text += str(event.data.get("delta", ""))
                    await turn.queue.put(("message_delta", {"text": turn.text}))
                elif event.kind == "tool_call":
                    turn.active_calls = _normalize_tool_calls(event)
                    for call in turn.active_calls:
                        spec = self._tool_specs.get(call["name"])
                        await self.emit(turn, "tool_call", {
                            "id": call["id"],
                            "name": call["name"],
                            "title": spec.title if spec else call["name"],
                            "status": "running",
                            "input": call["arguments"],
                        })
                elif event.kind == "tool_result":
                    for index, result in enumerate(list(event.data.get("tool_results") or [])):
                        call = turn.active_calls[index] if index < len(turn.active_calls) else {
                            "id": _id("tool"), "name": "tool", "arguments": {},
                        }
                        payload, artifacts, changed = _tool_result_payload(
                            call,
                            self._tool_specs.get(call["name"]),
                            result,
                        )
                        turn.refresh_ledger = turn.refresh_ledger or changed
                        await self.emit(turn, "tool_result", payload)
                        for artifact in artifacts:
                            await self.emit(turn, "artifact", artifact)
                    await turn.queue.put(("status", {"text": "正在整理工具结果"}))
                    if turn.mode == "onboarding":
                        await turn.queue.put(("onboarding_draft", {
                            "draft": turn.state.get("onboarding_draft"),
                            "ready": bool(turn.state.get("onboarding_ready")),
                        }))
                yield event

        return wrapped()

    async def emit(self, turn: WebTurn, event: str, payload: dict[str, Any]) -> None:
        if turn.mode == "ledger":
            await self._record_event(turn.session_id, event, payload)
        await turn.queue.put((event, payload))

    async def _close(self, turn: WebTurn) -> None:
        if turn.closed:
            return
        turn.closed = True
        self._turns.pop(turn.id, None)
        await turn.queue.put(None)


def _id(prefix: str) -> str:
    return f"{prefix}-{secrets.token_hex(12)}"


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
        calls.append({
            "id": str(raw.get("id") or _id("tool")),
            "name": str(function.get("name") or "tool"),
            "arguments": arguments if isinstance(arguments, dict) else {},
        })
    return calls


def _tool_result_payload(
    call: dict[str, Any],
    spec: ToolSpec | None,
    result: Any,
) -> tuple[dict[str, Any], list[dict[str, Any]], bool]:
    title = spec.title if spec else call["name"]
    if isinstance(result, str):
        try:
            decoded = json.loads(result)
        except json.JSONDecodeError:
            decoded = None
        if isinstance(decoded, dict):
            result = decoded
    if isinstance(result, dict) and "kind" in result and "message" in result:
        return ({
            "id": call["id"], "name": call["name"], "title": title,
            "status": "error", "error": str(result["message"]),
        }, [], False)
    if isinstance(result, dict) and "modelOutput" in result:
        return ({
            "id": call["id"], "name": call["name"], "title": title,
            "status": "completed", "output": result.get("clientOutput"),
        }, list(result.get("artifacts") or []), bool(result.get("refreshLedger")))
    return ({
        "id": call["id"], "name": call["name"], "title": title,
        "status": "completed", "output": result,
    }, [], False)
