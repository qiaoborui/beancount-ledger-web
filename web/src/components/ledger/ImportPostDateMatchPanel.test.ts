import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { duplicateHintLabel, ImportPostDateMatchPanel, initialImportEntries, restoreImportEntry } from "./ImportPostDateMatchPanel";

const hint = { reason: "amount-differs", date: "2026-10-13", payee: "河南早点", narration: "外卖", amount: "-33.48", currency: "CNY", source: "支付宝" };
const entries = [
  { id: "a", date: "2026-10-12", payee: "A", narration: "", amount: 7.5, currency: "CNY" },
  { id: "b", date: "2026-10-13", payee: "ELEME", narration: "", amount: 33.33, currency: "CNY", duplicateHint: hint },
  { id: "c", date: "2026-10-20", payee: "C", narration: "", amount: 88, currency: "CNY" },
];

describe("post date matches in import review", () => {
  it("starts with probable duplicates set aside and restores them in preview order", () => {
    const initial = initialImportEntries(entries);
    expect(initial.map((entry) => entry.id)).toEqual(["a", "c"]);
    expect(restoreImportEntry(entries, initial, "b").map((entry) => entry.id)).toEqual(["a", "b", "c"]);
    expect(restoreImportEntry(entries, initial, "missing")).toBe(initial);
  });

  it("names the existing entry a duplicate hint points at", () => {
    expect(duplicateHintLabel(hint)).toContain("河南早点");
    expect(duplicateHintLabel({ ...hint, reason: "ambiguous" })).toContain("2026-10-13");
  });

  it("renders fills with their post date and nothing when there are no matches", () => {
    const props = {
      excludedFillIds: new Set<string>(),
      activeEntryIds: new Set(["a", "c"]),
      disabled: false,
      onToggleFill: vi.fn(),
      onRemoveEntry: vi.fn(),
      onRestoreEntry: vi.fn(),
    };
    const fill = { id: "f1", date: "2026-10-12", payee: "茶庄", narration: "", account: "Liabilities:HK:HSBC:CreditCard", amount: "-7.50", currency: "CNY", postDate: "13/10/2026", bankDate: "2026-10-12", bankPayee: "APPLEPAY TEA" };
    const html = renderToStaticMarkup(createElement(ImportPostDateMatchPanel, { ...props, fills: [fill], hintedEntries: [entries[1]] }));
    expect(html).toContain('data-import-postdate-panel="true"');
    expect(html).toContain("13/10/2026");
    expect(html).toContain("APPLEPAY TEA");
    expect(html).toContain("ELEME");
    expect(renderToStaticMarkup(createElement(ImportPostDateMatchPanel, { ...props, fills: [], hintedEntries: [] }))).toBe("");
  });
});
