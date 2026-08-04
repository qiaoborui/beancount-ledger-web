import asyncio

import pytest

from ledger_agent_service.interactions import InteractionBroker


@pytest.mark.asyncio
async def test_interaction_resolves_once() -> None:
    broker = InteractionBroker(30)
    interaction, future = await broker.create("session-1")

    await broker.resolve(interaction.id, True)

    assert await broker.wait(interaction, future) is True
    with pytest.raises(KeyError):
        await broker.resolve(interaction.id, False)


@pytest.mark.asyncio
async def test_interaction_timeout_removes_pending_state() -> None:
    broker = InteractionBroker(0)
    interaction, future = await broker.create("session-1")

    with pytest.raises(TimeoutError):
        await broker.wait(interaction, future)
    with pytest.raises(KeyError):
        await broker.resolve(interaction.id, True)
