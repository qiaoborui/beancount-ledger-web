import { useState } from "react";
import type { BalanceAssertion, ParsedTransaction } from "@/lib/schemas";
import type { Txn } from "../types";

export function useLedgerMutations({ appendEntry, load, refreshGitStatus, showToast }: { appendEntry: (entry: ParsedTransaction | BalanceAssertion) => Promise<{ ok: boolean }>; load: (forceFresh?: boolean) => void | Promise<void>; refreshGitStatus: () => void | Promise<void>; showToast: (kind: "info" | "success" | "error", text: string) => void }) {
  const [assertion, setAssertion] = useState<BalanceAssertion>({
    kind: "balance",
    date: new Date().toISOString().slice(0, 10),
    account: "Assets:Bank:Checking",
    amount: "0.00",
    currency: "CNY",
  });

  async function appendAssertion() {
    const res = await appendEntry(assertion);
    if (!res.ok) return;
    showToast("success", "余额断言已写入");
    load(true);
    refreshGitStatus();
  }

  async function updateTransaction(source: Txn["source"], entry: ParsedTransaction) {
    const res = await fetch("/api/ledger/transactions", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ source, entry }) });
    const data = await res.json();
    if (!res.ok) return showToast("error", data.error || "修改失败");
    showToast("success", "交易已修改");
    load(true);
    refreshGitStatus();
  }

  async function deleteTransaction(source: Txn["source"], reason: string) {
    const res = await fetch("/api/ledger/transactions", { method: "DELETE", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ source, reason }) });
    const data = await res.json();
    if (!res.ok) return showToast("error", data.error || "删除失败");
    showToast("success", "交易已注释删除");
    load(true);
    refreshGitStatus();
  }

  async function reverseTransaction(source: Txn["source"], date: string) {
    const res = await fetch("/api/ledger/transactions", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ source, date }) });
    const data = await res.json();
    if (!res.ok) return showToast("error", data.error || "冲销失败");
    showToast("success", "冲销交易已写入");
    load(true);
    refreshGitStatus();
  }

  async function reconcileAccount(input: { account: string; actualAmount: string; balanceDate: string; adjustmentDate: string }) {
    const res = await fetch("/api/ledger/reconciliation", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(input) });
    const data = await res.json();
    if (!res.ok) return showToast("error", data.error || "对账写入失败");
    showToast("success", data.diff === 0 ? "余额断言已写入" : "调整分录和余额断言已写入");
    load(true);
    refreshGitStatus();
  }

  return { assertion, setAssertion, appendAssertion, updateTransaction, deleteTransaction, reverseTransaction, reconcileAccount };
}
