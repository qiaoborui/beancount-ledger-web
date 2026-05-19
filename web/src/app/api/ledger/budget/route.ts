import { NextResponse } from "next/server";
import { requireCurrentUserJson } from "@/lib/apiAuth";
import { monthSummary } from "@/lib/beancountParser";
import { getLedgerSnapshotForUser } from "@/lib/ledgerCache";
import { parseApiTimeParams } from "@/lib/timeRange";

export async function GET(request: Request) {
  const { userId, error: authError } = await requireCurrentUserJson();
  if (authError) return authError;
  const { start, end } = parseApiTimeParams(new URL(request.url).searchParams);
  const snapshot = getLedgerSnapshotForUser(userId);
  const budgets = snapshot.budgets.filter((b) => b.date <= end);
  const latest = new Map<string, { amount: number; date: string }>();
  for (const b of budgets) {
    const cur = latest.get(b.account);
    if (!cur || b.date >= cur.date) latest.set(b.account, { amount: b.amount, date: b.date });
  }
  const actual = monthSummary(start, end, snapshot.transactions).categories;
  const rows = Array.from(new Set([...latest.keys(), ...Object.keys(actual)])).sort().map((account) => {
    const budget = latest.get(account)?.amount ?? 0;
    const spent = actual[account] ?? 0;
    return { account, budget, spent, remaining: budget - spent, ratio: budget ? spent / budget : null };
  });
  return NextResponse.json({ start, end, rows });
}
