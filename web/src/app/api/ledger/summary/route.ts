import { NextResponse } from "next/server";
import { requireAuthJson } from "@/lib/apiAuth";
import { isSensitiveUnlocked } from "@/lib/auth";
import { monthSummary, netWorthHistory } from "@/lib/beancountParser";
import { getLedgerSnapshot } from "@/lib/ledgerCache";
import { parseApiTimeParams } from "@/lib/timeRange";

export async function GET(request: Request) {
  const authError = await requireAuthJson();
  if (authError) return authError;
  const { start, end } = parseApiTimeParams(new URL(request.url).searchParams);
  const snapshot = getLedgerSnapshot();
  const sensitiveUnlocked = await isSensitiveUnlocked();
  const summary = monthSummary(start, end, snapshot.transactions);
  const publicDays = Object.fromEntries(
    Object.entries(summary.days).map(([day, value]) => [day, { income: sensitiveUnlocked ? value.income : 0, expense: value.expense }]),
  );
  return NextResponse.json({
    start,
    end,
    summary: sensitiveUnlocked ? summary : { ...summary, income: 0, net: 0, days: publicDays },
    balances: sensitiveUnlocked ? snapshot.balances : {},
    netWorthHistory: sensitiveUnlocked ? netWorthHistory(snapshot.transactions) : [],
    sensitiveUnlocked,
  });
}
