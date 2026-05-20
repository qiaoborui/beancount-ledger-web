import { useState } from "react";
import { readJson } from "@/lib/clientFetch";
import type { BalanceAssertion, ParsedTransaction } from "@/lib/schemas";
import { haptic } from "../haptics";
import type { Txn } from "../types";

function offlineOrNetworkError(error?: unknown) {
  return (typeof navigator !== "undefined" && !navigator.onLine) || error instanceof TypeError;
}

export function useLedgerMutations({ appendEntry, load, refreshGitStatus, showToast, enqueuePendingWrites, enqueueTransactionUpdate, enqueueTransactionDelete }: { appendEntry: (entry: ParsedTransaction | BalanceAssertion) => Promise<{ ok: boolean }>; load: (forceFresh?: boolean) => void | Promise<void>; refreshGitStatus: () => void | Promise<void>; showToast: (kind: "info" | "success" | "error", text: string) => void; enqueuePendingWrites: (entries: (ParsedTransaction | BalanceAssertion)[]) => void; enqueueTransactionUpdate: (source: Txn["source"], entry: ParsedTransaction) => void; enqueueTransactionDelete: (source: Txn["source"], reason: string) => void }) {
  const [assertion, setAssertion] = useState<BalanceAssertion>({
    kind: "balance",
    date: new Date().toISOString().slice(0, 10),
    account: "Assets:Bank:Checking",
    amount: "0.00",
    currency: "CNY",
  });

  async function appendAssertion() {
    if (offlineOrNetworkError()) {
      enqueuePendingWrites([assertion]);
      showToast("info", "离线状态，余额断言已保存为待同步");
      return;
    }
    showToast("info", "正在写入余额断言");
    try {
      const res = await appendEntry(assertion);
      if (!res.ok) return;
      haptic([6, 24, 10]);
      showToast("success", "余额断言已写入");
      load(true);
      refreshGitStatus();
    } catch (error) {
      if (offlineOrNetworkError(error)) {
        enqueuePendingWrites([assertion]);
        showToast("info", "网络不稳定，余额断言已保存为待同步");
        return;
      }
      showToast("error", error instanceof Error ? error.message : "余额断言写入失败");
    }
  }

  async function updateTransaction(source: Txn["source"], entry: ParsedTransaction) {
    enqueueTransactionUpdate(source, entry);
    haptic(8);
    showToast("success", "交易已先保存到本地，稍后同步");
  }

  async function deleteTransaction(source: Txn["source"], reason: string) {
    enqueueTransactionDelete(source, reason);
    haptic(8);
    showToast("success", "交易已先在本地隐藏，稍后同步删除");
  }

  async function reverseTransaction(source: Txn["source"], date: string) {
    const res = await fetch("/api/ledger/transactions", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ source, date }) });
    const data = await readJson<{ error?: string }>(res);
    if (!res.ok) return showToast("error", data.error || "冲销失败");
    haptic(8);
    showToast("success", "冲销交易已写入");
    load(true);
    refreshGitStatus();
  }

  async function reconcileAccount(input: { account: string; actualAmount: string; balanceDate: string; adjustmentDate: string }) {
    const res = await fetch("/api/ledger/reconciliation", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(input) });
    const data = await readJson<{ error?: string; diff?: number }>(res);
    if (!res.ok) return showToast("error", data.error || "对账写入失败");
    haptic([6, 24, 10]);
    showToast("success", data.diff === 0 ? "余额断言已写入" : "调整分录和余额断言已写入");
    load(true);
    refreshGitStatus();
  }

  return { assertion, setAssertion, appendAssertion, updateTransaction, deleteTransaction, reverseTransaction, reconcileAccount };
}
