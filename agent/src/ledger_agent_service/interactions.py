from __future__ import annotations

import asyncio
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta


@dataclass(frozen=True)
class Interaction:
    id: str
    session_id: str
    created_at: datetime
    expires_at: datetime


class InteractionBroker:
    def __init__(self, timeout_seconds: int) -> None:
        self.timeout_seconds = timeout_seconds
        self._pending: dict[str, asyncio.Future[bool]] = {}
        self._metadata: dict[str, Interaction] = {}
        self._lock = asyncio.Lock()

    async def create(self, session_id: str) -> tuple[Interaction, asyncio.Future[bool]]:
        now = datetime.now(UTC)
        interaction = Interaction(
            id="interaction-" + secrets.token_hex(12),
            session_id=session_id,
            created_at=now,
            expires_at=now + timedelta(seconds=self.timeout_seconds),
        )
        future = asyncio.get_running_loop().create_future()
        async with self._lock:
            self._pending[interaction.id] = future
            self._metadata[interaction.id] = interaction
        return interaction, future

    async def resolve(self, interaction_id: str, approved: bool) -> Interaction:
        async with self._lock:
            future = self._pending.get(interaction_id)
            interaction = self._metadata.get(interaction_id)
            if future is None or interaction is None or future.done():
                raise KeyError(interaction_id)
            future.set_result(approved)
            return interaction

    async def wait(self, interaction: Interaction, future: asyncio.Future[bool]) -> bool:
        try:
            return await asyncio.wait_for(future, timeout=self.timeout_seconds)
        finally:
            async with self._lock:
                self._pending.pop(interaction.id, None)
                self._metadata.pop(interaction.id, None)
