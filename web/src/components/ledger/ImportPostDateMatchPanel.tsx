import { CalendarClock, Copy, RotateCcw, Trash2 } from "lucide-react";
import i18n from "@/i18n";
import { formatMoney } from "@/lib/money";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";

// Statement rows from a bank CSV that the server paired with existing Alipay /
// WeChat entries. Fills write the bank post date onto the existing entry
// instead of importing the row again; duplicate hints mark rows that are
// probably an existing purchase but need the user's decision.

export type ImportPostDateFill = {
  id: string;
  date: string;
  payee: string;
  narration: string;
  account: string;
  amount: string;
  currency: string;
  postDate: string;
  bankDate: string;
  bankPayee: string;
};

export type ImportDuplicateHint = {
  reason: "amount-differs" | "ambiguous" | string;
  date: string;
  payee: string;
  narration: string;
  amount: string;
  currency: string;
  source?: string;
};

type HintedEntry = {
  id: string;
  date: string;
  payee: string;
  narration: string;
  amount: number;
  currency: string;
  duplicateHint?: ImportDuplicateHint;
};

/** Entries the review starts with: probable duplicates begin set aside. */
export function initialImportEntries<T extends { duplicateHint?: ImportDuplicateHint }>(entries: T[]): T[] {
  return entries.filter((entry) => !entry.duplicateHint);
}

/** Puts a set-aside preview entry back in its original preview position. */
export function restoreImportEntry<T extends { id: string }>(previewEntries: T[], current: T[], id: string): T[] {
  if (current.some((entry) => entry.id === id)) return current;
  const restored = previewEntries.find((entry) => entry.id === id);
  if (!restored) return current;
  const order = new Map(previewEntries.map((entry, index) => [entry.id, index]));
  return [...current, restored].sort((a, b) => (order.get(a.id) ?? Number.MAX_SAFE_INTEGER) - (order.get(b.id) ?? Number.MAX_SAFE_INTEGER));
}

export function duplicateHintLabel(hint: ImportDuplicateHint) {
  const existing = `${hint.date} ${hint.payee || hint.narration} ${formatMoney(Math.abs(Number(hint.amount)), hint.currency)}`;
  return hint.reason === "ambiguous"
    ? i18n.t("importPage.duplicateHintAmbiguous", { existing })
    : i18n.t("importPage.duplicateHintAmountDiffers", { existing, source: hint.source || i18n.t("importPage.existingEntry") });
}

export function ImportPostDateMatchPanel({
  fills,
  excludedFillIds,
  hintedEntries,
  activeEntryIds,
  disabled,
  onToggleFill,
  onRemoveEntry,
  onRestoreEntry,
}: {
  fills: ImportPostDateFill[];
  excludedFillIds: ReadonlySet<string>;
  hintedEntries: HintedEntry[];
  activeEntryIds: ReadonlySet<string>;
  disabled: boolean;
  onToggleFill: (id: string, included: boolean) => void;
  onRemoveEntry: (id: string) => void;
  onRestoreEntry: (id: string) => void;
}) {
  if (fills.length === 0 && hintedEntries.length === 0) return null;
  const includedFillCount = fills.filter((fill) => !excludedFillIds.has(fill.id)).length;
  return (
    <div className="grid min-w-0 gap-px border border-line bg-line xl:max-h-56 xl:shrink-0 xl:overflow-y-auto" data-import-postdate-panel="true">
      {fills.length > 0 ? (
        <section className="min-w-0 bg-panel">
          <div className="flex min-w-0 items-center gap-2 border-b border-line bg-paper px-3 py-2">
            <CalendarClock className="h-4 w-4 shrink-0 text-brand" />
            <div className="min-w-0 text-sm font-medium text-ink">{i18n.t("importPage.postDateFillsTitle", { count: includedFillCount, total: fills.length })}</div>
          </div>
          <div className="px-3 pb-1 pt-2 text-xs leading-5 text-stone">{i18n.t("importPage.postDateFillsDetail")}</div>
          <ul className="divide-y divide-line">
            {fills.map((fill) => {
              const included = !excludedFillIds.has(fill.id);
              return (
                <li key={fill.id} className="grid min-w-0 grid-cols-[2.75rem_minmax(0,1fr)_auto] items-center gap-1 py-2 pr-3">
                  <div className="grid h-11 place-items-center">
                    <Checkbox
                      checked={included}
                      className="relative after:absolute after:-inset-3"
                      onCheckedChange={(checked) => onToggleFill(fill.id, checked === true)}
                      aria-label={i18n.t("importPage.postDateFillToggle", { payee: fill.payee || fill.narration })}
                      disabled={disabled}
                    />
                  </div>
                  <div className="min-w-0">
                    <div className="flex min-w-0 items-center gap-2">
                      <span className="shrink-0 font-mono text-xs text-stone">{fill.date}</span>
                      <span className="min-w-0 truncate text-sm font-medium text-ink">{fill.payee || fill.narration || i18n.t("importPage.unnamedMerchant")}</span>
                    </div>
                    <div className="mt-0.5 truncate text-xs text-stone">{i18n.t("importPage.postDateFillBank", { payee: fill.bankPayee, date: fill.bankDate })}</div>
                  </div>
                  <div className="text-right">
                    <div className="font-serif text-base font-medium leading-none text-warm tabular-nums">{formatMoney(Math.abs(Number(fill.amount)), fill.currency)}</div>
                    <div className="mt-1 text-xs text-brand">{i18n.t("importPage.postDateValue", { date: fill.postDate })}</div>
                  </div>
                </li>
              );
            })}
          </ul>
        </section>
      ) : null}
      {hintedEntries.length > 0 ? (
        <section className="min-w-0 bg-panel">
          <div className="flex min-w-0 items-center gap-2 border-b border-line bg-paper px-3 py-2">
            <Copy className="h-4 w-4 shrink-0 text-[var(--warning)]" />
            <div className="min-w-0 text-sm font-medium text-ink">{i18n.t("importPage.duplicateHintsTitle", { count: hintedEntries.length })}</div>
          </div>
          <div className="px-3 pb-1 pt-2 text-xs leading-5 text-stone">{i18n.t("importPage.duplicateHintsDetail")}</div>
          <ul className="divide-y divide-line">
            {hintedEntries.map((entry) => {
              const active = activeEntryIds.has(entry.id);
              return (
                <li key={entry.id} className="grid min-w-0 grid-cols-[minmax(0,1fr)_auto] items-center gap-3 px-3 py-2">
                  <div className="min-w-0">
                    <div className="flex min-w-0 items-center gap-2">
                      <span className="shrink-0 font-mono text-xs text-stone">{entry.date}</span>
                      <span className="min-w-0 truncate text-sm font-medium text-ink">{entry.payee || entry.narration || i18n.t("importPage.unnamedMerchant")}</span>
                      <span className="shrink-0 font-serif text-sm text-warm tabular-nums">{formatMoney(entry.amount, entry.currency)}</span>
                    </div>
                    {entry.duplicateHint ? <div className="mt-0.5 text-xs leading-5 text-stone">{duplicateHintLabel(entry.duplicateHint)}</div> : null}
                  </div>
                  {active ? (
                    <Button type="button" size="sm" variant="outline" className="h-11 sm:h-9" onClick={() => onRemoveEntry(entry.id)} disabled={disabled}>
                      <Trash2 className="h-4 w-4" />
                      {i18n.t("importPage.duplicateHintSkip")}
                    </Button>
                  ) : (
                    <Button type="button" size="sm" variant="outline" className="h-11 sm:h-9" onClick={() => onRestoreEntry(entry.id)} disabled={disabled}>
                      <RotateCcw className="h-4 w-4" />
                      {i18n.t("importPage.duplicateHintImport")}
                    </Button>
                  )}
                </li>
              );
            })}
          </ul>
        </section>
      ) : null}
    </div>
  );
}
