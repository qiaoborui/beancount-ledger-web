from __future__ import annotations

import json
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Annotated

import uvicorn
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, Response, status
from fastapi.responses import StreamingResponse

from .config import Settings
from .protocol import InteractionResponse, OnboardingRequest, TurnRequest
from .runtime import AgentRuntime


def _sse(event: str, payload: dict) -> bytes:
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    return f"event: {event}\ndata: {raw}\n\n".encode()


def create_app(settings: Settings | None = None) -> FastAPI:
    configured = settings or Settings.load()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        async with AgentRuntime(configured) as runtime:
            app.state.runtime = runtime
            yield

    app = FastAPI(title="Beancount Ledger Agent", lifespan=lifespan)

    async def authorize(x_agent_service_token: Annotated[str | None, Header()] = None) -> None:
        if x_agent_service_token != configured.service_token:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid agent service token")

    def runtime(request: Request) -> AgentRuntime:
        return request.app.state.runtime

    @app.get("/health")
    async def health() -> dict[str, bool]:
        return {"ok": True}

    @app.post("/v1/turn", dependencies=[Depends(authorize)])
    async def turn(input: TurnRequest, agent: AgentRuntime = Depends(runtime)) -> StreamingResponse:
        async def stream() -> AsyncIterator[bytes]:
            async for event, payload in agent.turn(input):
                yield _sse(event, payload)

        return StreamingResponse(stream(), media_type="text/event-stream", headers={"Cache-Control": "no-cache"})

    @app.post("/v1/onboarding/turn", dependencies=[Depends(authorize)])
    async def onboarding(
        input: OnboardingRequest,
        agent: AgentRuntime = Depends(runtime),
    ) -> StreamingResponse:
        async def stream() -> AsyncIterator[bytes]:
            async for event, payload in agent.onboarding_turn(input):
                yield _sse(event, payload)

        return StreamingResponse(stream(), media_type="text/event-stream", headers={"Cache-Control": "no-cache"})

    @app.post("/v1/interactions/{interaction_id}", status_code=status.HTTP_202_ACCEPTED, dependencies=[Depends(authorize)])
    async def resolve_interaction(
        interaction_id: str,
        input: InteractionResponse,
        agent: AgentRuntime = Depends(runtime),
    ) -> dict[str, bool]:
        try:
            await agent.broker.resolve(interaction_id, input.approved)
        except KeyError as exc:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="interaction not found") from exc
        return {"accepted": True}

    @app.get("/v1/sessions/{session_id}/timeline", dependencies=[Depends(authorize)])
    async def timeline(
        session_id: str,
        agent: AgentRuntime = Depends(runtime),
        before: int = Query(0, ge=0),
    ) -> dict:
        return await agent.timeline(session_id, before)

    @app.delete("/v1/sessions/{session_id}", status_code=status.HTTP_204_NO_CONTENT, dependencies=[Depends(authorize)])
    async def delete_session(session_id: str, agent: AgentRuntime = Depends(runtime)) -> Response:
        await agent.delete_session(session_id)
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    return app


app = create_app()


def main() -> None:
    uvicorn.run("ledger_agent_service.app:app", host="0.0.0.0", port=8080)
