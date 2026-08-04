from __future__ import annotations

from typing import Any

import httpx

from .protocol import CapabilityResult, ToolSpec


class LedgerCapabilities:
    def __init__(self, base_url: str, service_token: str) -> None:
        self.base_url = base_url
        self.service_token = service_token
        self.client = httpx.AsyncClient(timeout=httpx.Timeout(120, connect=10))

    async def close(self) -> None:
        await self.client.aclose()

    async def specs(self) -> list[ToolSpec]:
        response = await self.client.get(
            f"{self.base_url}/api/internal/agent/tools",
            headers={"X-Agent-Service-Token": self.service_token},
        )
        response.raise_for_status()
        payload = response.json()
        return [ToolSpec.model_validate(item) for item in payload.get("tools", [])]

    async def preview(self, name: str, arguments: dict[str, Any], capability_token: str) -> CapabilityResult:
        return await self._call(name, "preview", arguments, capability_token)

    async def execute(
        self,
        name: str,
        arguments: dict[str, Any],
        capability_token: str,
        confirmation_token: str = "",
    ) -> CapabilityResult:
        return await self._call(name, "execute", arguments, capability_token, confirmation_token)

    async def _call(
        self,
        name: str,
        action: str,
        arguments: dict[str, Any],
        capability_token: str,
        confirmation_token: str = "",
    ) -> CapabilityResult:
        response = await self.client.post(
            f"{self.base_url}/api/internal/agent/tools/{name}/{action}",
            headers={"Authorization": f"Bearer {capability_token}"},
            json={"arguments": arguments, "confirmationToken": confirmation_token},
        )
        if response.is_error:
            detail = response.json().get("error", response.text)
            raise RuntimeError(str(detail))
        return CapabilityResult.model_validate(response.json())
