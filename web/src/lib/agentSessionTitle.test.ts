import { afterEach, describe, expect, it, vi } from "vitest";
import { sanitizeAgentSessionTitle, requestAgentSessionTitle, AGENT_SESSION_TITLE_MAX_LENGTH } from "./agentSessionTitle";

describe("sanitizeAgentSessionTitle", () => {
  it("keeps the first line and drops model formatting", () => {
    expect(sanitizeAgentSessionTitle("**本月餐饮支出**\n解释一下这个数字")).toBe("本月餐饮支出");
    expect(sanitizeAgentSessionTitle("`账单核对`")).toBe("账单核对");
    expect(sanitizeAgentSessionTitle("标题：修复 iOS 流水。")).toBe("修复 iOS 流水");
    expect(sanitizeAgentSessionTitle("Title: Q3 budget review")).toBe("Q3 budget review");
    expect(sanitizeAgentSessionTitle("  **会话标题：Q3 预算复盘**。 ")).toBe("Q3 预算复盘");
  });

  it("clips a long title without splitting characters", () => {
    const title = sanitizeAgentSessionTitle("长".repeat(60));
    expect(Array.from(title)).toHaveLength(AGENT_SESSION_TITLE_MAX_LENGTH);
    expect(sanitizeAgentSessionTitle("🐷".repeat(40))).toBe("🐷".repeat(AGENT_SESSION_TITLE_MAX_LENGTH));
  });

  it("rejects empty and non-string replies", () => {
    expect(sanitizeAgentSessionTitle("")).toBe("");
    expect(sanitizeAgentSessionTitle("  \n ")).toBe("");
    expect(sanitizeAgentSessionTitle("！")).toBe("");
    expect(sanitizeAgentSessionTitle(undefined)).toBe("");
    expect(sanitizeAgentSessionTitle({ title: "x" })).toBe("");
  });
});

describe("requestAgentSessionTitle", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("posts the opening exchange and returns the generated title", async () => {
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ title: "本月餐饮支出" }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);

    await expect(requestAgentSessionTitle("这个月外食花了多少？", "本月餐饮支出合计 1,280.00 元。")).resolves.toBe("本月餐饮支出");
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(String(url)).toContain("/api/ai/agent/session-title");
    expect(init.method).toBe("POST");
    expect(JSON.parse(String(init.body))).toEqual({ question: "这个月外食花了多少？", answer: "本月餐饮支出合计 1,280.00 元。" });
  });

  it("falls back silently when the server or the model fails", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify({ error: "AI provider is not configured" }), { status: 503 })));
    await expect(requestAgentSessionTitle("查一下余额", "余额 100 元。")).resolves.toBe("");

    vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("offline"); }));
    await expect(requestAgentSessionTitle("查一下余额", "余额 100 元。")).resolves.toBe("");

    vi.stubGlobal("fetch", vi.fn(async () => new Response("", { status: 200 })));
    await expect(requestAgentSessionTitle("查一下余额", "余额 100 元。")).resolves.toBe("");
  });

  it("does not call the server without a question", async () => {
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ title: "x" }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    await expect(requestAgentSessionTitle("   ", "回答")).resolves.toBe("");
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
