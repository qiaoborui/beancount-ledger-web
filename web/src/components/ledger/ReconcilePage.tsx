"use client";

import { useState } from "react";
import { AlertTriangle, CheckCircle, Info } from "lucide-react";
import { formatCny } from "@/lib/money";
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

function classifyAccount(account: string): "wealth" | "credit" | "cash" {
  if (account.startsWith("Liabilities:")) return "credit";
  if (account.includes(":Wealth") || account.includes(":Fund") || account.includes(":Stock") || account.includes(":Bond") || account.includes(":Insurance") || account.includes(":HousingFund")) return "wealth";
  return "cash";
}

const typeMeta: Record<"wealth" | "credit" | "cash", { label: string; cls: string; hint: string }> = {
  wealth: { label: "利息自动调整", cls: "bg-tag text-brand border-line", hint: "差额将自动走收益/亏损科目" },
  credit: { label: "差额需核实", cls: "bg-panel text-[var(--danger)] border-line", hint: "信用卡差额通常说明有漏记账，请核实后再提交" },
  cash: { label: "差额待调整", cls: "bg-panel text-warm border-line", hint: "差额将记入权益调整科目，后续需补记账" },
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
  return <section className="space-y-4">
    <div className="card p-4">
      <h2 className="font-serif text-2xl">待对账</h2>
      <p className="mt-2 text-sm leading-relaxed text-olive">
        建议节奏：<span className="font-medium text-warm">5 号</span>（工资 + 信用卡还款后）·
        <span className="font-medium text-warm">17 号</span>（账单日后）·
        <span className="font-medium text-warm">月末</span>（理财、现金）
      </p>
    </div>
    {rows.map((row) => (
      <ReconcileCard key={row.account} timeRange={timeRange} row={row} onSubmit={onSubmit} status={statuses?.find((s) => s.account === row.account)} />
    ))}
  </section>;
}

function ReconcileCard({ timeRange, row, onSubmit, status }: { timeRange: TimeRange; row: ReconcileRow; onSubmit: (input: { account: string; actualAmount: string; balanceDate: string; adjustmentDate: string }) => void; status?: AccountStatus }) {
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
              {meta.label}
            </span>
          </div>
          <div className="mt-0.5 text-xs text-stone">{row.account}</div>
        </div>
        <div className="flex items-center gap-2">
          {status && <span className={`inline-block h-2.5 w-2.5 shrink-0 rounded-full ${statusColor(status.status)}`} title={statusTitle(status)} />}
          <span className={row.status === "asserted" ? "text-xs text-brand" : "text-xs text-stone"}>
            {row.status === "asserted" ? "已断言" : "未断言"}
          </span>
        </div>
      </div>

      {/* book balance info */}
      <div className="grid grid-cols-2 gap-3 border-t border-line px-4 py-3 text-sm">
        <div>
          账本余额：<strong>{formatCny(row.ledgerBalance / 100)}</strong>
        </div>
        <div>
          最近断言：{row.lastAssertion ? <>{row.lastAssertion.date} {formatCny(row.lastAssertion.amount / 100)}</> : <span className="text-stone">无</span>}
        </div>
      </div>

      {/* input area */}
      <div className="border-t border-line px-4 py-3">
        <label className="mb-1 block text-xs text-stone">实际余额（来自 App / 银行 / 对账单）</label>
        <div className="grid gap-3 sm:grid-cols-[1fr_auto_auto]">
          <input
            className="w-full rounded-xl border border-line bg-panel px-3 py-2.5 text-sm"
            inputMode="decimal"
            placeholder={row.account.startsWith("Liabilities") ? "欠款填负数，如 -5000.00" : "如 12345.67"}
            value={actual}
            onChange={(e) => setActual(e.target.value)}
          />
          <input
            className="rounded-xl border border-line bg-panel px-3 py-2.5 text-sm"
            type="date"
            value={balanceDate}
            onChange={(e) => setBalanceDate(e.target.value)}
            title="对账日：余额断言将写在这一天"
          />
          <button
            className="rounded-xl bg-brand px-5 py-2.5 text-sm font-medium text-paper transition-opacity disabled:opacity-40"
            disabled={diff == null}
            onClick={handleSubmit}
          >
            {diff === 0 ? "写入断言" : "调整并断言"}
          </button>
        </div>
        <p className="mt-1.5 text-xs text-stone">对账日填写余额断言日期；调整分录将自动写入对账日前一天（{adjDate}）。</p>
      </div>

      {/* feedback area */}
      {diff != null && (
        <div className="border-t border-line px-4 py-3">
          {diff === 0 ? (
            <div className="flex items-center gap-2 rounded-xl border border-line bg-panel px-4 py-3">
              <CheckCircle className="h-4 w-4 text-[var(--success)]" />
              <span className="text-sm font-medium text-warm">账实相符</span>
              <span className="text-xs text-stone">点击「写入断言」记录本次对账结果。</span>
            </div>
          ) : (
            <>
              <div className="flex items-start gap-2 rounded-xl border border-line bg-panel px-4 py-3">
                <AlertTriangle className="mt-0.5 h-4 w-4 text-[var(--warning)]" />
                <div>
                  <p className="text-sm font-medium text-warm">
                    差额 <span className="tabular-nums text-brand">{formatCny(diff / 100)}</span>
                  </p>
                  <p className="mt-0.5 text-xs text-stone">{meta.hint}</p>
                </div>
              </div>

              {preview && (
                <div className="mt-3 rounded-xl border border-line bg-panel p-3">
                  <div className="mb-2 flex items-center gap-1.5 text-xs text-stone">
                    <Info className="h-3 w-3" />
                    调整分录预览
                  </div>
                  <div className="space-y-1 rounded-lg bg-tag px-3 py-2 font-mono text-xs">
                    <div className="text-stone">{preview.date} * "余额差额调整"</div>
                    <div className="flex gap-2 pl-3">
                      <span className="text-warm">{preview.debitLabel}</span>
                      <span className="amount-gold ml-auto">
                        {preview.debitAmount > 0 ? "+" : ""}{formatCny(preview.debitAmount / 100)}
                      </span>
                    </div>
                    <div className="flex gap-2 pl-3">
                      <span className="text-warm">{preview.creditLabel}</span>
                      <span className="amount-income ml-auto">
                        {preview.creditAmount > 0 ? "+" : ""}{formatCny(preview.creditAmount / 100)}
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
