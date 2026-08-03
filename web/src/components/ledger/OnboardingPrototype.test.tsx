import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { OnboardingPrototype } from "./OnboardingPrototype";

describe("OnboardingPrototype", () => {
  it("starts with a personal ledger and funding-account workflow", () => {
    const html = renderToStaticMarkup(<OnboardingPrototype onCreate={vi.fn()} />);

    expect(html).toContain("建立你的财务地图");
    expect(html).toContain("日常记账货币");
    expect(html).toContain("建立资金账户");
  });

  it("keeps the user in the validation wait state and surfaces an indexer error", () => {
    const html = renderToStaticMarkup(<OnboardingPrototype onCreate={vi.fn()} waiting error="bean-check 失败，请检查账户名" />);

    expect(html).toContain("bean-check 失败，请检查账户名");
    expect(html).toContain("disabled");
  });
});
