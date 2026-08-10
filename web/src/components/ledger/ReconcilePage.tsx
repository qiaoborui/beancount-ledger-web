"use client";

import { useState } from "react";
import { useTranslation } from "react-i18next";
import { AlertTriangle, CheckCircle, Info } from "lucide-react";
import { formatMoney } from "@/lib/money";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import type { TimeRange } from "@/lib/timeRange";
import type { AccountStatus, ReconcileRow } from "./types";
import { statusColor, statusTitle } from "./AccountPanels";

function todayStr() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

function prevDay(dateStr: string) {
  const d = new Date(dateStr);
  d.setDate(d.getDate() - 1);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

function classifyAccount(account: string): "wealth" | "liability" | "cash" {
  if (account.startsWith("Liabilities:")) return "liability";
  if (account.includes(":Wealth") || account.includes(":Fund") || account.includes(":Stock") || account.includes(":Bond") || account.includes(":Insurance") || account.includes(":HousingFund")) return "wealth";
  return "cash";
}

const typeMeta: Record<"wealth" | "liability" | "cash", { labelKey: string; cls: string; hintKey: string }> = {
  wealth: { labelKey: "reconcile.wealthLabel", cls: "bg-tag text-brand border-line", hintKey: "reconcile.wealthHint" },
  liability: { labelKey: "reconcile.liabilityLabel", cls: "bg-panel text-[var(--danger)] border-line", hintKey: "reconcile.liabilityHint" },
  cash: { labelKey: "reconcile.cashLabel", cls: "bg-panel text-warm border-line", hintKey: "reconcile.cashHint" },
};

function wealthInterestAccount(_account: string): string {
  return "Income:Other";
}

function adjustmentPreview(account: string, diff: number, date: string): { debitLabel: string; debitAmount: number; creditLabel: string; creditAmount: number; date: string } | null {
  if (diff === 0) return null;
  const type = classifyAccount(account);
  if (type === "wealth") {
    const other = diff > 0 ? wealthInterestAccount(account) : "Expenses:Unknown";
    return {
      date,
      debitLabel: account,
      debitAmount: diff,
      creditLabel: other,
      creditAmount: -diff,
    };
  }
  return {
    date,
    debitLabel: account,
    debitAmount: diff,
    creditLabel: "Equity:Balance-Adjustments",
    creditAmount: -diff,
  };
}

export function ReconcilePage({ timeRange, rows, onSubmit, statuses }: { timeRange: TimeRange; rows: ReconcileRow[]; onSubmit: (input: { account: string; actualAmount: string; balanceDate: string; adjustmentDate: string }) => void; statuses?: AccountStatus[] }) {
  const { t } = useTranslation();
  return <section className="space-y-4">
    <div className="card p-4">
      <h2 className="font-serif text-2xl">{t("reconcile.title")}</h2>
      <p className="mt-2 text-sm leading-relaxed text-olive">
        {t("reconcile.rhythm", { a: t("reconcile.day5"), b: t("reconcile.day17"), c: t("reconcile.monthEnd") })}
      </p>
    </div>
    {rows.map((row) => (
      <ReconcileCard key={row.account} timeRange={timeRange} row={row} onSubmit={onSubmit} status={statuses?.find((s) => s.account === row.account)} />
    ))}
  </section>;
}

function ReconcileCard({ timeRange, row, onSubmit, status }: { timeRange: TimeRange; row: ReconcileRow; onSubmit: (input: { account: string; actualAmount: string; balanceDate: string; adjustmentDate: string }) => void; status?: AccountStatus }) {
  const { t } = useTranslation();
  const [actual, setActual] = useState("");
  const [balanceDate, setBalanceDate] = useState(todayStr());
  const actualCents = actual ? Math.round(Number(actual) * 100) : null;
  const diff = actualCents == null || !Number.isFinite(actualCents) ? null : actualCents - row.ledgerBalance;

  const acctType = classifyAccount(row.account);
  const meta = typeMeta[acctType];
  const adjDate = prevDay(balanceDate);
  const preview = diff != null && diff !== 0 ? adjustmentPreview(row.account, diff, adjDate) : null;

  const handleSubmit = () => {
    if (diff == null) return;
    onSubmit({ account: row.account, actualAmount: actual, balanceDate, adjustmentDate: adjDate });
  };

  return (
    <div className="card overflow-hidden p-0">
      {/* header */}
      <div className="flex items-start justify-between gap-3 p-4 pb-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <h3 className="font-medium leading-tight">{row.label}</h3>
            <span className={`shrink-0 rounded-full border px-2 py-0.5 text-[11px] font-medium ${meta.cls}`}>
              {t(meta.labelKey)}
            </span>
          </div>
          <div className="mt-0.5 text-xs text-stone">{row.account}</div>
        </div>
        <div className="flex items-center gap-2">
          {status && <span className={`inline-block h-2.5 w-2.5 shrink-0 rounded-full ${statusColor(status.status)}`} title={statusTitle(status)} />}
          <span className={row.status === "asserted" ? "text-xs text-brand" : "text-xs text-stone"}>
            {row.status === "asserted" ? t("reconcile.asserted") : t("reconcile.notAsserted")}
          </span>
        </div>
      </div>

      {/* book balance info */}
      <div className="grid grid-cols-2 gap-3 border-t border-line px-4 py-3 text-sm">
        <div>
          {t("reconcile.bookBalance")}<strong>{formatMoney(row.ledgerBalance / 100, row.currency)}</strong>
        </div>
        <div>
          {t("reconcile.lastAssertion")}{row.lastAssertion ? <>{row.lastAssertion.date} {formatMoney(row.lastAssertion.amount / 100, row.lastAssertion.currency)}</> : <span className="text-stone">{t("reconcile.none")}</span>}
        </div>
      </div>

      {/* input area */}
      <div className="border-t border-line px-4 py-3">
        <label className="mb-1 block text-xs text-stone">{t("reconcile.actualBalanceLabel")}</label>
        <div className="grid gap-3 sm:grid-cols-[1fr_auto_auto]">
          <Input
            className="h-11 rounded-xl bg-panel text-sm"
            inputMode="decimal"
            placeholder={row.account.startsWith("Liabilities") ? t("reconcile.liabilityPlaceholder") : t("reconcile.amountPlaceholder")}
            value={actual}
            onChange={(e) => setActual(e.target.value)}
          />
          <Input
            className="h-11 rounded-xl bg-panel text-sm"
            type="date"
            value={balanceDate}
            onChange={(e) => setBalanceDate(e.target.value)}
            title={t("reconcile.balanceDateTitle")}
          />
          <Button
            className="h-11 rounded-xl px-5 text-sm"
            disabled={diff == null}
            onClick={handleSubmit}
          >
            {diff === 0 ? t("reconcile.writeAssertion") : t("reconcile.adjustAndAssert")}
          </Button>
        </div>
        <p className="mt-1.5 text-xs text-stone">{t("reconcile.balanceDateHint", { date: adjDate })}</p>
      </div>

      {/* feedback area */}
      {diff != null && (
        <div className="border-t border-line px-4 py-3">
          {diff === 0 ? (
            <div className="flex items-center gap-2 rounded-xl border border-line bg-panel px-4 py-3">
              <CheckCircle className="h-4 w-4 text-[var(--success)]" />
              <span className="text-sm font-medium text-warm">{t("reconcile.matches")}</span>
              <span className="text-xs text-stone">{t("reconcile.matchesHint")}</span>
            </div>
          ) : (
            <>
              <div className="flex items-start gap-2 rounded-xl border border-line bg-panel px-4 py-3">
                <AlertTriangle className="mt-0.5 h-4 w-4 text-[var(--warning)]" />
                <div>
                  <p className="text-sm font-medium text-warm">
                    {t("reconcile.difference")} <span className="tabular-nums text-brand">{formatMoney(diff / 100, row.currency)}</span>
                  </p>
                  <p className="mt-0.5 text-xs text-stone">{t(meta.hintKey)}</p>
                </div>
              </div>

              {preview && (
                <div className="mt-3 rounded-xl border border-line bg-panel p-3">
                  <div className="mb-2 flex items-center gap-1.5 text-xs text-stone">
                    <Info className="h-3 w-3" />
                    {t("reconcile.adjustmentPreview")}
                  </div>
                  <div className="space-y-1 rounded-lg bg-tag px-3 py-2 font-mono text-xs">
                    <div className="text-stone">{preview.date} * "{t("reconcile.balanceAdjustmentNarration")}"</div>
                    <div className="flex gap-2 pl-3">
                      <span className="text-warm">{preview.debitLabel}</span>
                      <span className="amount-gold ml-auto">
                        {preview.debitAmount > 0 ? "+" : ""}{formatMoney(preview.debitAmount / 100, row.currency)}
                      </span>
                    </div>
                    <div className="flex gap-2 pl-3">
                      <span className="text-warm">{preview.creditLabel}</span>
                      <span className="amount-income ml-auto">
                        {preview.creditAmount > 0 ? "+" : ""}{formatMoney(preview.creditAmount / 100, row.currency)}
                      </span>
                    </div>
                  </div>
                </div>
              )}
            </>
          )}
        </div>
      )}
    </div>
  );
}
