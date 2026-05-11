import { NextResponse } from "next/server";
import { z } from "zod";
import { requireAuth } from "@/lib/auth";
import { accountGroup, currentBalances, parseAccounts, parseBalances, parseTransactions } from "@/lib/beancountParser";
import { appendBeanText, balanceToBean, transactionToBean } from "@/lib/ledgerWriter";
import { cents, fromCents } from "@/lib/money";
import { parseApiTimeParams } from "@/lib/timeRange";
import type { ParsedTransaction } from "@/lib/schemas";

function reconciliableAccounts() {
  return parseAccounts().filter(
    (a) => a.active && (a.account.startsWith("Assets:") || a.account.startsWith("Liabilities:"))
  );
}

const ReconcileSchema = z.object({
  account: z.string().min(1),
  actualAmount: z.preprocess((value) => typeof value === "string" ? value.trim().replace(/,/g, "").replace(/^¥/, "") : value, z.string().regex(/^-?\d+(\.\d{1,2})?$/)),
  balanceDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  adjustmentDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
});

function normalizeAccountToken(value: string): string {
  return value.replace(/[^A-Za-z0-9]/g, "").toLowerCase();
}

function wealthInterestAccount(account: string, openAccounts: string[]): string {
  const incomeInterestAccounts = openAccounts.filter((name) => name.startsWith("Income:Interest:"));
  const accountTokens = account.split(":").map(normalizeAccountToken).filter(Boolean);
  const matched = incomeInterestAccounts.find((name) => {
    const incomeToken = normalizeAccountToken(name.split(":").at(-1) ?? "");
    return accountTokens.some((token) => token === incomeToken || token.includes(incomeToken) || incomeToken.includes(token));
  });
  return matched ?? incomeInterestAccounts[0] ?? (openAccounts.includes("Income:Other") ? "Income:Other" : "Equity:Balance-Adjustments");
}

function todayStr() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

function balancesBefore(date: string): Record<string, number> {
  return currentBalances(parseTransactions().filter((txn) => txn.date < date));
}

function adjustmentEntry(account: string, label: string, diff: number, date: string, openAccounts: string[]): ParsedTransaction | null {
  if (diff === 0) return null;
  const group = accountGroup(account);
  const isWealth = group === "wealth";

  if (isWealth) {
    const other = diff > 0 ? wealthInterestAccount(account, openAccounts) : (openAccounts.includes("Expenses:Investment:Loss") ? "Expenses:Investment:Loss" : "Expenses:Unknown");
    return {
      kind: "transaction",
      date,
      payee: label,
      narration: diff > 0 ? "月末理财收益调整" : "月末理财亏损调整",
      metadata: { purpose: "reconciliation" },
      tags: [],
      confidence: 1,
      needsReview: false,
      questions: [],
      postings: [
        { account, amount: fromCents(diff), currency: "CNY" },
        { account: other, amount: fromCents(-diff), currency: "CNY" },
      ],
    };
  }

  return {
    kind: "transaction",
    date,
    payee: label,
    narration: "余额差额调整",
    metadata: { purpose: "reconciliation" },
    tags: [],
    confidence: 1,
    needsReview: false,
    questions: [],
    postings: [
      { account, amount: fromCents(diff), currency: "CNY" },
      { account: "Equity:Balance-Adjustments", amount: fromCents(-diff), currency: "CNY" },
    ],
  };
}

export async function GET(request: Request) {
  await requireAuth();
  const { start, end } = parseApiTimeParams(new URL(request.url).searchParams);
  const monthPrefix = start.slice(0, 7);
  const balances = balancesBefore(todayStr());
  const assertions = parseBalances();
  const rows = reconciliableAccounts().map((a) => {
    const accountAssertions = assertions.filter((assertion) => assertion.account === a.account).sort((a, b) => b.date.localeCompare(a.date));
    const monthAssertions = accountAssertions.filter((assertion) => assertion.date >= start && assertion.date < end);
    return {
      account: a.account,
      label: a.label,
      ledgerBalance: balances[a.account] ?? 0,
      status: monthAssertions.length ? "asserted" : "pending",
      lastAssertion: accountAssertions[0] ?? null,
    } as const;
  });
  return NextResponse.json({ start, end, monthPrefix, rows });
}

export async function POST(request: Request) {
  await requireAuth();
  const input = ReconcileSchema.parse(await request.json());
  const accounts = parseAccounts();
  const accountInfo = accounts.find((a) => a.active && (a.account.startsWith("Assets:") || a.account.startsWith("Liabilities:")) && a.account === input.account);
  if (!accountInfo) return NextResponse.json({ error: "不支持的对账账户" }, { status: 400 });

  const balances = balancesBefore(input.balanceDate);
  const ledgerBalance = balances[input.account] ?? 0;
  const actual = cents(input.actualAmount);
  const diff = actual - ledgerBalance;
  const adjustmentDate = input.adjustmentDate ?? input.balanceDate;
  const balance = { kind: "balance" as const, date: input.balanceDate, account: input.account, amount: fromCents(actual), currency: "CNY" as const };
  const adjustment = adjustmentEntry(input.account, accountInfo.label, diff, adjustmentDate, accounts.map((account) => account.account));
  const beanText = `${adjustment ? `${transactionToBean(adjustment)}\n` : ""}${balanceToBean(balance)}`;

  try {
    await appendBeanText(Number(input.balanceDate.slice(0, 4)), beanText);
    return NextResponse.json({ ok: true, ledgerBalance, actual, diff, adjustment, balance, beanText });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
