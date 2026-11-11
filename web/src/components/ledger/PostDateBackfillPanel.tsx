import { useState } from "react";
import { CalendarClock, Copy, Loader2, RefreshCw, Search } from "lucide-react";
import { fetchJson } from "@/lib/clientFetch";
import i18n from "@/i18n";
import { formatMoney } from "@/lib/money";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { duplicateHintLabel, type ImportDuplicateHint, type ImportPostDateFill } from "./ImportPostDateMatchPanel";

// Fills post dates on existing HSBC card entries from the archived HSBC
// statements: scan (read-only), pick, write. Possible duplicates are listed
// for the user to resolve in the ledger; nothing is removed here.

type EntryRef = { date: string; payee: string; narration: string; amount: string; currency: string; postDate?: string; source?: string; file: string; line: number };

export type PostDateBackfillResult = {
  documents: number;
  bankRows: number;
  missingPostDate: number;
  fills: ImportPostDateFill[];
  reviews: { bankDate: string; postDate: string; bankPayee: string; amount: string; currency: string; hint: ImportDuplicateHint }[];
  possibleDuplicates: { bank: EntryRef; existing: EntryRef; amountDiff: string }[];
  warnings: string[];
};

function money(amount: string, currency: string) {
  return formatMoney(Math.abs(Number(amount)), currency);
}

export function PostDateBackfillPanel({ showToast, onWritten }: { showToast: (kind: "info" | "success" | "error", text: string) => void; onWritten?: () => void }) {
  const [result, setResult] = useState<PostDateBackfillResult | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [scanning, setScanning] = useState(false);
  const [writing, setWriting] = useState(false);

  async function scan() {
    setScanning(true);
    try {
      const data = await fetchJson<PostDateBackfillResult>("/api/ledger/imports/post-date-backfill", { method: "POST" }, undefined, { kind: "write" });
      setResult(data);
      setSelected(new Set(data.fills.map((fill) => fill.id)));
    } catch (err) {
      showToast("error", err instanceof Error ? err.message : String(err));
    } finally {
      setScanning(false);
    }
  }

  async function write() {
    if (selected.size === 0) return;
    setWriting(true);
    try {
      const data = await fetchJson<{ ok?: boolean; count?: number }>("/api/ledger/imports/post-date-backfill/apply", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ fillIds: [...selected] }),
      }, undefined, { kind: "write" });
      showToast("success", i18n.t("importPage.backfillWritten", { count: data.count ?? 0 }));
      onWritten?.();
      await scan();
    } catch (err) {
      showToast("error", err instanceof Error ? err.message : String(err));
    } finally {
      setWriting(false);
    }
  }

  function toggle(id: string, checked: boolean) {
    setSelected((current) => {
      const next = new Set(current);
      if (checked) next.add(id);
      else next.delete(id);
      return next;
    });
  }

  const busy = scanning || writing;
  return (
    <section data-postdate-backfill="true" className="min-w-0 overflow-hidden border-x border-b border-line bg-panel md:border-x-0">
      <div className="flex min-w-0 flex-col gap-3 border-b border-line bg-paper px-4 py-4 sm:flex-row sm:items-center sm:justify-between sm:px-5">
        <div className="min-w-0">
          <div className="flex min-w-0 items-center gap-2">
            <CalendarClock className="h-4 w-4 shrink-0 text-brand" />
            <h2 className="truncate text-sm font-medium text-ink">{i18n.t("importPage.backfillTitle")}</h2>
          </div>
          <div className="mt-1 text-xs leading-5 text-stone">
            {result
              ? i18n.t("importPage.backfillSummary", { documents: result.documents, rows: result.bankRows, missing: result.missingPostDate })
              : i18n.t("importPage.backfillDetail")}
          </div>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          <Button type="button" variant="outline" size="sm" onClick={() => void scan()} disabled={busy}>
            {scanning ? <Loader2 className="h-4 w-4 animate-spin" /> : result ? <RefreshCw className="h-4 w-4" /> : <Search className="h-4 w-4" />}
            {result ? i18n.t("importPage.backfillRescan") : i18n.t("importPage.backfillScan")}
          </Button>
          {result && result.fills.length > 0 ? (
            <Button type="button" size="sm" onClick={() => void write()} disabled={busy || selected.size === 0}>
              {writing ? <Loader2 className="h-4 w-4 animate-spin" /> : null}
              {i18n.t("importPage.backfillWrite", { count: selected.size })}
            </Button>
          ) : null}
        </div>
      </div>

      {result ? (
        <div className="divide-y divide-line">
          {result.warnings.map((warning) => (
            <div key={warning} className="px-4 py-2 text-xs leading-5 text-[var(--warning)] sm:px-5">{warning}</div>
          ))}
          {result.fills.length === 0 && result.reviews.length === 0 && result.possibleDuplicates.length === 0 ? (
            <div className="px-4 py-6 text-center text-sm text-stone sm:px-5">{i18n.t("importPage.backfillNothing")}</div>
          ) : null}
          {result.fills.length > 0 ? (
            <ul className="divide-y divide-line">
              {result.fills.map((fill) => (
                <li key={fill.id} className="grid min-w-0 grid-cols-[2.75rem_minmax(0,1fr)_auto] items-center gap-1 py-2 pr-4 sm:pr-5">
                  <div className="grid h-11 place-items-center">
                    <Checkbox
                      checked={selected.has(fill.id)}
                      className="relative after:absolute after:-inset-3"
                      onCheckedChange={(checked) => toggle(fill.id, checked === true)}
                      aria-label={i18n.t("importPage.postDateFillToggle", { payee: fill.payee || fill.narration })}
                      disabled={busy}
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
                    <div className="font-serif text-base font-medium leading-none text-warm tabular-nums">{money(fill.amount, fill.currency)}</div>
                    <div className="mt-1 text-xs text-brand">{i18n.t("importPage.postDateValue", { date: fill.postDate })}</div>
                  </div>
                </li>
              ))}
            </ul>
          ) : null}
          {result.reviews.length > 0 ? (
            <div className="min-w-0">
              <div className="bg-paper px-4 py-2 text-xs font-medium text-ink sm:px-5">{i18n.t("importPage.backfillReviewsTitle", { count: result.reviews.length })}</div>
              <ul className="divide-y divide-line">
                {result.reviews.map((review) => (
                  <li key={`${review.bankDate}-${review.postDate}-${review.bankPayee}-${review.amount}`} className="px-4 py-2 sm:px-5">
                    <div className="flex min-w-0 items-center gap-2 text-sm text-ink">
                      <span className="shrink-0 font-mono text-xs text-stone">{review.bankDate}</span>
                      <span className="min-w-0 truncate">{review.bankPayee}</span>
                      <span className="ml-auto shrink-0 font-serif tabular-nums text-warm">{money(review.amount, review.currency)}</span>
                    </div>
                    <div className="mt-0.5 text-xs leading-5 text-stone">{duplicateHintLabel(review.hint)} · {i18n.t("importPage.postDateValue", { date: review.postDate })}</div>
                  </li>
                ))}
              </ul>
            </div>
          ) : null}
          {result.possibleDuplicates.length > 0 ? (
            <div className="min-w-0">
              <div className="flex items-center gap-2 bg-paper px-4 py-2 text-xs font-medium text-ink sm:px-5">
                <Copy className="h-3.5 w-3.5 text-[var(--warning)]" />
                {i18n.t("importPage.backfillDuplicatesTitle", { count: result.possibleDuplicates.length })}
              </div>
              <div className="px-4 pt-2 text-xs leading-5 text-stone sm:px-5">{i18n.t("importPage.backfillDuplicatesDetail")}</div>
              <ul className="divide-y divide-line">
                {result.possibleDuplicates.map((pair) => (
                  <li key={`${pair.bank.file}:${pair.bank.line}`} className="grid min-w-0 gap-1 px-4 py-2 text-xs sm:grid-cols-2 sm:gap-4 sm:px-5">
                    {[pair.bank, pair.existing].map((entry) => (
                      <div key={`${entry.file}:${entry.line}`} className="min-w-0">
                        <div className="flex min-w-0 items-center gap-2 text-sm text-ink">
                          <span className="shrink-0 font-mono text-xs text-stone">{entry.date}</span>
                          <span className="min-w-0 truncate">{entry.payee || entry.narration}</span>
                          <span className="ml-auto shrink-0 font-serif tabular-nums text-warm">{money(entry.amount, entry.currency)}</span>
                        </div>
                        <div className="truncate text-stone">{entry.source || "-"} · {entry.file}:{entry.line}</div>
                      </div>
                    ))}
                  </li>
                ))}
              </ul>
            </div>
          ) : null}
        </div>
      ) : null}
    </section>
  );
}
