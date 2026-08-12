import { readFileSync } from "node:fs";
import { renderToString } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { pageFromPathname } from "./routes";
import {
  FinancialAdviceEmptyPanel,
  FinancialAdviceErrorPanel,
  FinancialAdviceEvidenceRow,
  FinancialAdviceLetter,
  FinancialAdvicePage,
  adviceEvidenceLabel,
  classifyFinancialAdvicePayload,
} from "./FinancialAdvicePage";
import type { FinancialAdviceDisplayEvidence, FinancialAdviceResponse } from "./types";

const evidence: FinancialAdviceDisplayEvidence[] = [
  { id: "e0", kind: "income", label: "", direction: "up", current: 150000, baseline: 90000, delta: 60000, ratio: 0.6667, currency: "CNY" },
  { id: "e1", kind: "expense", label: "", direction: "up", current: 79000, baseline: 19200, delta: 59800, ratio: 3.1146, currency: "CNY" },
  { id: "e3", kind: "savings", label: "", direction: "down", ratio: 0.4733, baselineRatio: 0.7867, currency: "CNY" },
  { id: "e4", kind: "category", label: "Food", direction: "up", current: 79000, baseline: 19200, delta: 59800, ratio: 3.1146, share: 1, count: 10, currency: "CNY", link: "/transactions?category=Expenses%3AFood&q=2026-08-11&mode=prefix" },
  { id: "e6", kind: "coverage", label: "", direction: "flat", current: 9, count: 12, currency: "CNY" },
  { id: "e7", kind: "anomaly", label: "Electronics", direction: "up", amount: 60000, median: 2000, date: "2026-07-05", currency: "CNY", link: "/transactions?category=Expenses%3AFood&q=2026-07-05&mode=prefix" },
];

const response: FinancialAdviceResponse = {
  metadata: { mode: "recent", asOf: "2026-08-11", generatedAt: "2026-08-12T04:00:00Z", valuationCurrency: "CNY", locale: "zh-CN", ledgerRevision: "abc123def456", provider: "openai", model: "gpt-4.1-mini", modelGenerated: true },
  coverage: { level: "full", currentTxCount: 12, baselineTxCount: 10, activeExpenseDays: 9, unknownCategories: 0, missingValuation: false },
  ranges: { current: { start: "2026-05-14", end: "2026-08-12" }, baseline: { start: "2026-02-13", end: "2026-05-14" } },
  opening: { title: "本期整体呈上升态势", body: "本期各项往来保持常态，详情可核对下方证据。", evidenceIds: ["e0", "e1"] },
  observations: [
    { topic: "income_change", title: "收入变化", body: "本期收入事项与基准期相当。", evidenceIds: ["e0"] },
    { topic: "category_change", title: "分类变化", body: "本期餐饮类支出情况可结合证据核对。", evidenceIds: ["e4"] },
  ],
  recommendations: [{ topic: "savings_behavior", title: "储蓄行为", body: "建议延续现有节奏，并定期核对账本证据。", evidenceIds: ["e3"] }],
  evidence,
};

const pageSource = readFileSync(new URL("./FinancialAdvicePage.tsx", import.meta.url), "utf8");

describe("FinancialAdvicePage initial state", () => {
  it("renders the utility masthead with mode switch and generate action, but no amounts and no API call on render", () => {
    const html = renderToString(<FinancialAdvicePage valuationCurrency="CNY" onSensitiveLocked={() => {}} />);
    expect(html).toContain("AI 财务建议");
    expect(html).toContain("近 90 天");
    expect(html).toContain("年初至今");
    expect(html).toContain("生成回顾");
    expect(html).toContain("仅供参考");
    expect(html).not.toContain("¥");
    expect(html).not.toContain("evidenceIds");
    expect(html).not.toContain("e0");
  });

  it("keeps the page out of the generic month-range controls", () => {
    const appSource = readFileSync(new URL("../LedgerApp.tsx", import.meta.url), "utf8");
    expect(appSource).toContain('page !== "advice"');
    expect(appSource).toContain('advice: { eyebrow: "ai financial advice", title: t("ledgerApp.pageAdvice") }');
  });
});

describe("FinancialAdvicePage routing and preload wiring", () => {
  it("maps /advice to the advice page", () => {
    expect(pageFromPathname("/advice")).toBe("advice");
  });

  it("lazy loads the page and renders it only behind the sensitive unlock boundary", () => {
    const appSource = readFileSync(new URL("../LedgerApp.tsx", import.meta.url), "utf8");
    expect(appSource).toContain("loadFinancialAdvicePage");
    expect(appSource).toContain("MemoFinancialAdvicePage");
    expect(appSource).toContain('page === "advice" && (unlocked ? <MemoFinancialAdvicePage');
    expect(appSource).toContain("requireSensitiveUnlock(t(\"ledgerApp.adviceHidden\")");
  });

  it("keeps /advice out of the default mobile tabs while allowing customization", () => {
    const storageSource = readFileSync(new URL("./storage.ts", import.meta.url), "utf8");
    expect(storageSource).toContain('"/advice"');
    expect(storageSource).toContain('const defaultMobileTabHrefs: LedgerNavHref[] = ["/home", "/transactions", "/accounts"];');
  });

  it("adds the observe-group nav item without making it a mobile primary", () => {
    const shellSource = readFileSync(new URL("../AppShell.tsx", import.meta.url), "utf8");
    expect(shellSource).toContain('{ href: "/advice", labelKey: "nav.advice", icon: Sparkles, mobilePrimary: false, group: "observe" }');
  });
});

describe("FinancialAdviceLetter", () => {
  it("renders exact facts only from display evidence, never from model prose", () => {
    const html = renderToString(<FinancialAdviceLetter response={response} />);
    expect(html).toContain("本期整体呈上升态势");
    expect(html).toContain("本期各项往来保持常态，详情可核对下方证据。");
    expect(html).toContain("¥1,500.00");
    expect(html).toContain("¥790.00");
    expect(html).toContain("¥600.00");
    const savings = renderToString(<FinancialAdviceEvidenceRow evidence={evidence[2]} />);
    expect(savings).toContain("47.3%");
    expect(savings).toContain("78.7%");
    expect(html).toContain("观察");
    expect(html).toContain("建议");
    const prose = "本期收入事项与基准期相当。本期餐饮类支出情况可结合证据核对。建议延续现有节奏，并定期核对账本证据。";
    for (const part of prose.split("。").filter(Boolean)) {
      expect(html).toContain(part + "。");
    }
    expect(html).not.toContain("150000");
    expect(html.indexOf("47.3%")).toBeGreaterThan(html.indexOf("建议延续现有节奏"));
  });

  it("labels evidence rows from the server evidence map", () => {
    const t = (key: string) => key;
    expect(adviceEvidenceLabel(evidence[0], t)).toBe("advice.evidenceIncome");
    expect(adviceEvidenceLabel(evidence[3], t)).toBe("Food");
    expect(adviceEvidenceLabel(evidence[4], t)).toBe("advice.evidenceActivity");
    expect(adviceEvidenceLabel(evidence[5], t)).toBe("Electronics");
  });

  it("shows the sparse caveat when coverage is limited", () => {
    const sparse = { ...response, coverage: { ...response.coverage, level: "sparse" as const } };
    const html = renderToString(<FinancialAdviceLetter response={sparse} />);
    expect(html).toContain("数据有限");
    expect(html).toContain("当前区间数据较少");
  });

  it("renders evidence links as transaction drilldowns", () => {
    const html = renderToString(<FinancialAdviceEvidenceRow evidence={evidence[3]} />);
    expect(html).toContain('href="/transactions?category=Expenses%3AFood&amp;q=2026-08-11&amp;mode=prefix"');
    expect(html).toContain("查看");
  });
});

describe("FinancialAdvice state panels", () => {
  it("renders the empty state with transaction and import links", () => {
    const html = renderToString(<FinancialAdviceEmptyPanel />);
    expect(html).toContain("当前区间还没有交易");
    expect(html).toContain('href="/transactions"');
    expect(html).toContain('href="/imports"');
  });

  it("renders the provider-error evidence-only fallback with exact amounts", () => {
    const html = renderToString(<FinancialAdviceErrorPanel title="生成超时" body="服务商响应超时。下方仍可查看账本证据。" evidence={[evidence[0], evidence[5]]} onRetry={() => {}} />);
    expect(html).toContain("生成超时");
    expect(html).toContain("本次仅展示账本证据");
    expect(html).toContain("¥1,500.00");
    expect(html).toContain("¥600.00");
    expect(html).toContain("重新生成");
  });

  it("marks anomaly candidates for review without fraud language", () => {
    const html = renderToString(<FinancialAdviceEvidenceRow evidence={evidence[5]} />);
    expect(html).toContain("Electronics");
    expect(html).toContain("2026-07-05");
    expect(html).toContain("中位数");
    expect(html).not.toContain("欺诈");
    expect(html).not.toContain("fraud");
  });
});

describe("FinancialAdvice response boundary", () => {
  it("classifies the real generic 429 envelope without retaining it as renderable advice", () => {
    const result = classifyFinancialAdvicePayload(429, { error: "Too many requests" });
    expect(result).toEqual({ ok: false, code: "rate_limited" });
    expect("response" in result).toBe(false);
  });

  it.each([
    [400, { error: "invalid request body" }],
    [500, { error: "internal error" }],
    [502, "upstream gateway failed"],
    [200, { metadata: {} }],
  ])("classifies status %i non-envelope payloads as safe request errors", (status, payload) => {
    const result = classifyFinancialAdvicePayload(status, payload);
    expect(result).toEqual({ ok: false, code: "request_failed" });
    expect("response" in result).toBe(false);
  });

  it("retains validated evidence-only provider errors", () => {
    const providerError: FinancialAdviceResponse = { ...response, opening: undefined, observations: undefined, recommendations: undefined, error: { code: "provider_timeout", message: "safe" } };
    const result = classifyFinancialAdvicePayload(504, providerError);
    expect(result).toEqual({ ok: false, code: "provider_timeout", response: providerError });
  });

  it("accepts the real empty-state shape with omitted narrative fields", () => {
    const empty: FinancialAdviceResponse = {
      ...response,
      metadata: { ...response.metadata, modelGenerated: false },
      coverage: { ...response.coverage, level: "empty" },
      opening: undefined,
      observations: undefined,
      recommendations: undefined,
      evidence: [],
    };
    expect(classifyFinancialAdvicePayload(200, empty)).toEqual({ ok: true, response: empty });
  });
});

describe("FinancialAdvicePage privacy and accessibility contract", () => {
  it("requests with no-store and never writes advice to browser storage", () => {
    expect(pageSource).toContain('"/api/ai/financial-advice"');
    expect(pageSource).toContain("cache: \"no-store\"");
    expect(pageSource).toContain("readJson<unknown>");
    expect(pageSource).not.toContain("localStorage");
    expect(pageSource).not.toContain("indexedDB");
    expect(pageSource).not.toContain("LedgerCache");
    expect(pageSource).not.toContain("sessionStorage");
    expect(pageSource).not.toContain("caches.");
  });

  it("aborts stale and cleared requests on mode change, endpoint change, and unmount", () => {
    expect(pageSource).toContain("AbortController");
    expect(pageSource).toContain("apiEndpointSettingsChangeEvent");
    expect(pageSource).toContain("sequenceRef.current !== sequence");
    expect(pageSource).toContain("controller.signal.aborted");
    expect(pageSource).toContain("abortRef.current?.abort()");
  });

  it("surfaces sensitive lock responses through the existing unlock boundary", () => {
    expect(pageSource).toContain("response.status === 401 || response.status === 423");
    expect(pageSource).toContain("onSensitiveLocked()");
  });

  it("keeps controls accessible and states announced", () => {
    expect(pageSource).toContain('aria-pressed={mode === item}');
    expect(pageSource).toContain('aria-live="polite"');
    expect(pageSource).toContain('aria-busy={busy}');
    expect(pageSource).toContain('role="status"');
    expect(pageSource).toContain("focus-visible:outline-brand");
    expect(pageSource).toContain("motion-safe:animate-spin");
    expect(pageSource).toContain("motion-safe:animate-pulse");
  });

  it("keeps all required state copy in both locales", () => {
    const zh = readFileSync(new URL("../../i18n/locales/zh-CN.ts", import.meta.url), "utf8");
    const en = readFileSync(new URL("../../i18n/locales/en-US.ts", import.meta.url), "utf8");
    for (const key of ["generate", "regenerate", "generating", "updating", "recent90Days", "yearToDate", "sparseNote", "emptyTitle", "errorOfflineTitle", "errorProviderTimeoutTitle", "errorModelOutputInvalidTitle", "errorRateLimitedTitle", "errorRateLimitedBody", "evidenceOnlyNote", "liveStatusIdle", "liveStatusGenerating", "liveStatusReady", "liveStatusError", "liveStatusOffline"]) {
      expect(zh).toContain(`${key}:`);
      expect(en).toContain(`${key}:`);
    }
  });
});
