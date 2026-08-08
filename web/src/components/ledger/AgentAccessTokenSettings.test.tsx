import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { AgentAccessTokenSettings, AgentTokenOperationGate, agentTokenPresentation, agentTokenScopeLabel, agentTokenUsageLabel } from "./AgentAccessTokenSettings";

describe("AgentAccessTokenSettings", () => {
  it("keeps management controls locked with sensitive data", () => {
    const html = renderToStaticMarkup(<AgentAccessTokenSettings sensitiveUnlocked={false} showToast={() => {}} />);
    expect(html).toContain("解锁敏感数据后才能创建、查看或吊销");
    expect(html).toContain("disabled");
  });

  it("distinguishes active, expired and revoked tokens", () => {
    const base = { id: "token-1", name: "Laptop", createdAt: "2026-01-01T00:00:00Z", expiresAt: "2026-12-01T00:00:00Z", scopes: ["read"] };
    expect(agentTokenPresentation(base, new Date("2026-08-05T00:00:00Z").getTime())).toEqual({ label: "可用", active: true });
    expect(agentTokenPresentation({ ...base, expiresAt: "2026-01-02T00:00:00Z" }, new Date("2026-08-05T00:00:00Z").getTime())).toEqual({ label: "已过期", active: false });
    expect(agentTokenPresentation({ ...base, revokedAt: "2026-02-01T00:00:00Z" })).toEqual({ label: "已吊销", active: false });
    expect(agentTokenUsageLabel(base)).toBe("尚未使用");
    expect(agentTokenScopeLabel(base)).toBe("只读");
    expect(agentTokenScopeLabel({ ...base, scopes: ["read", "write"] })).toBe("读写");
    expect(agentTokenScopeLabel({ ...base, legacy: true })).toBe("旧版读写");
  });

  it.each(["sensitive lock", "API endpoint change"])("discards a create response after %s", async () => {
    const gate = new AgentTokenOperationGate();
    const requestGeneration = gate.capture();
    let resolve!: (token: string) => void;
    const delayed = new Promise<string>((done) => { resolve = done; });

    gate.invalidate();
    resolve("blw_agent_old_plaintext");
    const token = await delayed;

    expect(gate.isCurrent(requestGeneration)).toBe(false);
    expect(gate.isCurrent(requestGeneration) ? token : "").toBe("");
  });
});
