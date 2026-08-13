import { renderToString } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { InstanceSetupPage, InstanceSetupUnavailablePage } from "./InstanceSetupPage";

const recoverInstallCodeCommand = "docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml exec server /app/ledger-selfhost recover-install-code";

describe("InstanceSetupPage", () => {
  it("keeps platform setup separate from the Agent-led ledger onboarding", () => {
    const html = renderToString(<InstanceSetupPage onComplete={vi.fn()} recoverInstallCodeCommand={recoverInstallCodeCommand} />);

    expect(html).toContain("一次性安装码");
    expect(html).toContain("Server 写入 Token");
    expect(html).toContain("Indexer 只读 Token");
    expect(html).toContain("配置账本 Agent");
    expect(html).toContain("验证并完成安装");
    expect(html).toContain("h-dvh");
    expect(html).toContain("overflow-y-auto");
    expect(html).toContain("错过或遗失安装码");
    expect(html).toContain("recover-install-code");
  });

  it("does not show Compose recovery instructions for hosted deployments", () => {
    const html = renderToString(<InstanceSetupPage onComplete={vi.fn()} />);

    expect(html).not.toContain("recover-install-code");
  });

  it("shows a retryable unavailable state without bypassing setup", () => {
    const html = renderToString(<InstanceSetupUnavailablePage error="database connection refused" onRetry={vi.fn()} />);

    expect(html).toContain("无法确认实例状态");
    expect(html).toContain("database connection refused");
    expect(html).toContain("/api/health");
    expect(recoverInstallCodeCommand).toContain("exec server /app/ledger-selfhost recover-install-code");
  });
});
