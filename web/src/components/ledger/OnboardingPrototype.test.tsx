import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { OnboardingPrototype, OnboardingStatusUnavailable } from "./OnboardingPrototype";

describe("OnboardingPrototype", () => {
  it("starts with a plain-language personal finance workflow", () => {
    const html = renderToStaticMarkup(<OnboardingPrototype onCreate={vi.fn()} />);

    expect(html).toContain("建账 Agent");
    expect(html).toContain("正在开始");
    expect(html).toContain("dot-matrix-loader");
    expect(html).toContain('role="status"');
    expect(html).toContain("资金账户");
    expect(html).toContain("收入分类");
    expect(html).toContain("支出分类");
    expect(html).toContain("h-dvh");
    expect(html).toContain("overflow-hidden");
    expect(html).toContain("overflow-y-auto");
    expect(html).toContain("实时账本结构");
    expect(html).toContain("不会遮挡 Agent 回复");
    expect(html).not.toContain("Assets:");
    expect(html).not.toContain("Expenses:");
  });

  it("keeps the user in the validation wait state and surfaces an indexer error", () => {
    const html = renderToStaticMarkup(<OnboardingPrototype onCreate={vi.fn()} waiting error="bean-check 失败，请检查账户名" />);

    expect(html).toContain("bean-check 失败，请检查账户名");
    expect(html).toContain("回答建账 Agent 的问题");
  });

  it("keeps a failed onboarding status explicit and retryable", () => {
    const html = renderToStaticMarkup(<OnboardingStatusUnavailable error="read model unavailable" onRetry={vi.fn()} />);

    expect(html).toContain("无法确认建账状态");
    expect(html).toContain("read model unavailable");
    expect(html).toContain("/api/setup/status");
  });
});
