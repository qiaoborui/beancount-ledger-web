import { useState } from "react";
import { readJson } from "@/lib/clientFetch";
import { apiFetch } from "@/lib/apiEndpoints";
import type { BalanceAssertion, ParsedTransaction } from "@/lib/schemas";
import { haptic } from "../haptics";
import type { Txn } from "../types";
import i18n from "@/i18n";

function offlineOrNetworkError(error?: unknown) {
  return (typeof navigator !== "undefined" && !navigator.onLine) || error instanceof TypeError;
}

export function useLedgerMutations({ appendEntry, load, showToast, enqueuePendingWrites, enqueueTransactionUpdate, enqueueTransactionDelete, enqueueAddTransactionTags }: { appendEntry: (entry: ParsedTransaction | BalanceAssertion) => Promise<{ ok: boolean }>; load: (forceFresh?: boolean) => void | Promise<void>; showToast: (kind: "info" | "success" | "error", text: string) => void; enqueuePendingWrites: (entries: (ParsedTransaction | BalanceAssertion)[]) => void; enqueueTransactionUpdate: (source: Txn["source"], entry: ParsedTransaction) => void; enqueueTransactionDelete: (source: Txn["source"], reason: string) => void; enqueueAddTransactionTags: (sources: Txn["source"][], tags: string[]) => void }) {
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
      showToast("info", i18n.t("ledgerMutations.offlineAssertionSaved"));
      return;
    }
    showToast("info", i18n.t("ledgerMutations.writingAssertion"));
    try {
      const res = await appendEntry(assertion);
      if (!res.ok) return;
      haptic([6, 24, 10]);
      showToast("success", i18n.t("ledgerMutations.assertionWritten"));
      load(true);
    } catch (error) {
      if (offlineOrNetworkError(error)) {
        enqueuePendingWrites([assertion]);
        showToast("info", i18n.t("ledgerMutations.networkUnstableAssertionSaved"));
        return;
      }
      showToast("error", error instanceof Error ? error.message : i18n.t("ledgerMutations.assertionWriteFailed"));
    }
  }

  async function updateTransaction(source: Txn["source"], entry: ParsedTransaction) {
    enqueueTransactionUpdate(source, entry);
    haptic(8);
    showToast("success", i18n.t("ledgerMutations.transactionSavedLocal"));
  }

  async function deleteTransaction(source: Txn["source"], reason: string) {
    enqueueTransactionDelete(source, reason);
    haptic(8);
    showToast("success", i18n.t("ledgerMutations.transactionHiddenLocal"));
  }

  async function addTransactionTags(sources: Txn["source"][], tags: string[]) {
    enqueueAddTransactionTags(sources, tags);
    haptic(8);
    showToast("success", i18n.t("ledgerMutations.transactionTagsSavedLocal", { count: sources.length }));
  }

  async function reverseTransaction(source: Txn["source"], date: string) {
    const res = await apiFetch("/api/ledger/transactions", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ source, date }) }, { kind: "write" });
    const data = await readJson<{ error?: string }>(res);
    if (!res.ok) return showToast("error", data.error || i18n.t("ledgerMutations.reversalFailed"));
    haptic(8);
    showToast("success", i18n.t("ledgerMutations.reversalWritten"));
    load(true);
  }

  async function reconcileAccount(input: { account: string; actualAmount: string; balanceDate: string; adjustmentDate: string }) {
    const res = await apiFetch("/api/ledger/reconciliation", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(input) }, { kind: "write" });
    const data = await readJson<{ error?: string; diff?: number }>(res);
    if (!res.ok) return showToast("error", data.error || i18n.t("ledgerMutations.reconcileWriteFailed"));
    haptic([6, 24, 10]);
    showToast("success", data.diff === 0 ? i18n.t("ledgerMutations.assertionWrittenNoDiff") : i18n.t("ledgerMutations.assertionAndAdjustmentWritten"));
    load(true);
  }

  return { assertion, setAssertion, appendAssertion, updateTransaction, deleteTransaction, addTransactionTags, reverseTransaction, reconcileAccount };
}
