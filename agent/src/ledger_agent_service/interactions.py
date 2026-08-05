from __future__ import annotations

import asyncio
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta


@dataclass(frozen=True)
class Interaction:
    id: str
    session_id: str
    subject: str
    created_at: datetime
    expires_at: datetime


class InteractionBroker:
    def __init__(self, timeout_seconds: int) -> None:
        self.timeout_seconds = timeout_seconds
        self._pending: dict[str, asyncio.Future[bool]] = {}
        self._metadata: dict[str, Interaction] = {}
        self._lock = asyncio.Lock()

    async def create(self, session_id: str, subject: str = "") -> tuple[Interaction, asyncio.Future[bool]]:
        now = datetime.now(UTC)
        interaction = Interaction(
            id="interaction-" + secrets.token_hex(12),
            session_id=session_id,
            subject=subject,
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

    async def resolve_session(self, session_id: str, approved: bool, subject: str = "") -> Interaction | None:
        async with self._lock:
            for interaction_id, interaction in self._metadata.items():
                future = self._pending.get(interaction_id)
                if (
                    interaction.session_id != session_id
                    or interaction.subject != subject
                    or future is None
                    or future.done()
                ):
                    continue
                future.set_result(approved)
                return interaction
        return None

    async def has_pending_session(self, session_id: str, subject: str | None = None) -> bool:
        async with self._lock:
            return any(
                interaction.session_id == session_id
                and (subject is None or interaction.subject == subject)
                and (future := self._pending.get(interaction_id)) is not None
                and not future.done()
                for interaction_id, interaction in self._metadata.items()
            )

    async def discard(self, interaction_id: str) -> None:
        async with self._lock:
            future = self._pending.pop(interaction_id, None)
            self._metadata.pop(interaction_id, None)
            if future is not None and not future.done():
                future.cancel()

    async def wait(self, interaction: Interaction, future: asyncio.Future[bool]) -> bool:
        try:
            return await asyncio.wait_for(future, timeout=self.timeout_seconds)
        finally:
            async with self._lock:
                self._pending.pop(interaction.id, None)
                self._metadata.pop(interaction.id, None)
