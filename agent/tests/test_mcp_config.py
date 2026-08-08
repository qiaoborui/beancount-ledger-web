from __future__ import annotations

import json
import os

from ledger_agent_service.mcp_config import MCP_CONFIG_ENV, RuntimeMCPConfig


def test_runtime_mcp_config_is_private_ephemeral_and_restores_environment(tmp_path, monkeypatch) -> None:
    original = tmp_path / "existing.json"
    monkeypatch.setenv(MCP_CONFIG_ENV, str(original))
    config = RuntimeMCPConfig("https://ledger.example/", "secret-token")

    path = config.activate()
    payload = json.loads(path.read_text())

    assert os.environ[MCP_CONFIG_ENV] == str(path)
    assert path.stat().st_mode & 0o777 == 0o600
    assert payload == {
        "mcpServers": {
            "ledger": {
                "url": "https://ledger.example/mcp",
                "transport": "http",
                "headers": {"Authorization": "Bearer secret-token"},
            }
        }
    }

    config.close()

    assert os.environ[MCP_CONFIG_ENV] == str(original)
    assert not path.exists()
