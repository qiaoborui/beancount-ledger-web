import { renderToString } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { InstanceSetupPage } from "./InstanceSetupPage";

describe("InstanceSetupPage", () => {
  it("keeps platform setup separate from the Agent-led ledger onboarding", () => {
    const html = renderToString(<InstanceSetupPage onComplete={vi.fn()} />);

    expect(html).toContain("一次性安装码");
    expect(html).toContain("Server 写入 Token");
    expect(html).toContain("Indexer 只读 Token");
    expect(html).toContain("配置账本 Agent");
    expect(html).toContain("验证并完成安装");
    expect(html).toContain("h-dvh");
    expect(html).toContain("overflow-y-auto");
  });
});
