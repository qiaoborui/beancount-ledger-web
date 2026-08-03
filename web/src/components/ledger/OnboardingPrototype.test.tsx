import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { OnboardingPrototype } from "./OnboardingPrototype";

describe("OnboardingPrototype", () => {
  it("starts with a plain-language personal finance workflow", () => {
    const html = renderToStaticMarkup(<OnboardingPrototype onCreate={vi.fn()} />);

    expect(html).toContain("从一段引导开始");
    expect(html).toContain("建账 Agent");
    expect(html).toContain("正在开始");
    expect(html).toContain("钱在哪里");
    expect(html).not.toContain("Assets:");
    expect(html).not.toContain("Expenses:");
  });

  it("keeps the user in the validation wait state and surfaces an indexer error", () => {
    const html = renderToStaticMarkup(<OnboardingPrototype onCreate={vi.fn()} waiting error="bean-check 失败，请检查账户名" />);

    expect(html).toContain("bean-check 失败，请检查账户名");
    expect(html).toContain("回答建账 Agent 的问题");
  });
});
