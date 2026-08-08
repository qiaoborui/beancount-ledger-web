from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

MCP_CONFIG_ENV = "BUB_MCP_CONFIG_PATH"


class RuntimeMCPConfig:
    """Provide bub-mcp with an ephemeral ledger server config backed by env credentials."""

    def __init__(self, base_url: str, token: str) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = token
        self._directory: tempfile.TemporaryDirectory[str] | None = None
        self._previous: str | None = None

    def activate(self) -> Path:
        if self._directory is not None:
            raise RuntimeError("runtime MCP config is already active")
        if not self.base_url or not self.token:
            raise RuntimeError("LEDGER_API_URL and an Agent credential are required for MCP")
        directory = tempfile.TemporaryDirectory(prefix="ledger-agent-mcp-")
        path = Path(directory.name) / "mcp.json"
        payload = {
            "mcpServers": {
                "ledger": {
                    "url": f"{self.base_url}/mcp",
                    "transport": "http",
                    "headers": {"Authorization": f"Bearer {self.token}"},
                }
            }
        }
        try:
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as output:
                json.dump(payload, output, ensure_ascii=False)
        except BaseException:
            directory.cleanup()
            raise
        self._previous = os.environ.get(MCP_CONFIG_ENV)
        os.environ[MCP_CONFIG_ENV] = str(path)
        self._directory = directory
        return path

    def close(self) -> None:
        if self._directory is None:
            return
        current = os.environ.get(MCP_CONFIG_ENV)
        if current == str(Path(self._directory.name) / "mcp.json"):
            if self._previous is None:
                os.environ.pop(MCP_CONFIG_ENV, None)
            else:
                os.environ[MCP_CONFIG_ENV] = self._previous
        self._directory.cleanup()
        self._directory = None
        self._previous = None
