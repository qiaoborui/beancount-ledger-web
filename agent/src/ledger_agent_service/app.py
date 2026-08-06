from __future__ import annotations

import json
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Annotated

import uvicorn
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, Response, status
from fastapi.responses import StreamingResponse

from .config import Settings
from .protocol import OnboardingRequest, TurnRequest
from .runtime import AgentGateway


TELEGRAM_UPDATE_MAX_BYTES = 1 << 20


def _sse(event: str, payload: dict) -> bytes:
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    return f"event: {event}\ndata: {raw}\n\n".encode()


async def _read_bounded_body(request: Request, limit: int) -> bytes:
    chunks: list[bytes] = []
    total = 0
    async for chunk in request.stream():
        total += len(chunk)
        if total > limit:
            raise HTTPException(
                status_code=status.HTTP_413_CONTENT_TOO_LARGE,
                detail="Telegram update payload is too large",
            )
        chunks.append(chunk)
    return b"".join(chunks)


def create_app(settings: Settings | None = None) -> FastAPI:
    configured = settings or Settings.load()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        async with AgentGateway(configured) as runtime:
            app.state.runtime = runtime
            yield

    app = FastAPI(title="Beancount Ledger Agent", lifespan=lifespan)

    async def authorize(x_agent_service_token: Annotated[str | None, Header()] = None) -> None:
        if x_agent_service_token != configured.service_token:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid agent service token")

    def runtime(request: Request) -> AgentGateway:
        return request.app.state.runtime

    @app.get("/health")
    async def health(request: Request) -> dict[str, bool]:
        if not request.app.state.runtime.healthy:
            raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="Bub ChannelManager is not running")
        return {"ok": True}

    @app.post("/v1/channels/web/messages", dependencies=[Depends(authorize)])
    async def turn(input: TurnRequest, agent: AgentGateway = Depends(runtime)) -> StreamingResponse:
        async def stream() -> AsyncIterator[bytes]:
            async for event, payload in agent.turn(input):
                yield _sse(event, payload)

        return StreamingResponse(stream(), media_type="text/event-stream", headers={"Cache-Control": "no-cache"})

    @app.post("/v1/channels/telegram/updates", dependencies=[Depends(authorize)])
    async def telegram_updates(request: Request, agent: AgentGateway = Depends(runtime)) -> Response:
        raw = await _read_bounded_body(request, TELEGRAM_UPDATE_MAX_BYTES)
        await agent.telegram_update(raw)
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @app.post("/v1/onboarding/turn", dependencies=[Depends(authorize)])
    async def onboarding(
        input: OnboardingRequest,
        agent: AgentGateway = Depends(runtime),
    ) -> StreamingResponse:
        async def stream() -> AsyncIterator[bytes]:
            async for event, payload in agent.onboarding_turn(input):
                yield _sse(event, payload)

        return StreamingResponse(stream(), media_type="text/event-stream", headers={"Cache-Control": "no-cache"})

    @app.get("/v1/sessions/{session_id}/timeline", dependencies=[Depends(authorize)])
    async def timeline(
        session_id: str,
        agent: AgentGateway = Depends(runtime),
        before: int = Query(0, ge=0),
    ) -> dict:
        return await agent.timeline(session_id, before)

    @app.delete("/v1/sessions/{session_id}", status_code=status.HTTP_204_NO_CONTENT, dependencies=[Depends(authorize)])
    async def delete_session(session_id: str, agent: AgentGateway = Depends(runtime)) -> Response:
        await agent.delete_session(session_id)
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    return app


app = create_app()


def main() -> None:
    uvicorn.run("ledger_agent_service.app:app", host="0.0.0.0", port=8080)
