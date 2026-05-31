import type { AccountView } from "./types";

const LEDGER_ACCOUNT_PREFIXES = ["Assets:", "Liabilities:", "Expenses:", "Income:", "Equity:"];

export function isLedgerAccount(value: string) {
  return LEDGER_ACCOUNT_PREFIXES.some((prefix) => value.startsWith(prefix));
}

export function formatAccountOptionLabel(account: AccountView): string;
export function formatAccountOptionLabel(account: string, label?: string | null, alias?: string | null): string;
export function formatAccountOptionLabel(accountOrView: AccountView | string, label?: string | null, alias?: string | null) {
  const account = typeof accountOrView === "string" ? accountOrView : accountOrView.account;
  const display = typeof accountOrView === "string"
    ? (alias || label || "").trim()
    : (accountOrView.alias || accountOrView.label || "").trim();
  return display && display !== account ? `${display} · ${account}` : account;
}

