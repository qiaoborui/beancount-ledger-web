import { NextResponse } from "next/server";
import { isSensitiveUnlocked, requireAuth } from "@/lib/auth";
import { currentBalances, monthSummary, netWorthHistory, parseTransactions } from "@/lib/beancountParser";
import { parseApiTimeParams } from "@/lib/timeRange";

export async function GET(request: Request) {
  await requireAuth();
  const { start, end } = parseApiTimeParams(new URL(request.url).searchParams);
  const txns = parseTransactions();
  const sensitiveUnlocked = await isSensitiveUnlocked();
  const summary = monthSummary(start, end, txns);
  const publicDays = Object.fromEntries(
    Object.entries(summary.days).map(([day, value]) => [day, { income: sensitiveUnlocked ? value.income : 0, expense: value.expense }]),
  );
  return NextResponse.json({
    start,
    end,
    summary: sensitiveUnlocked ? summary : { ...summary, income: 0, net: 0, days: publicDays },
    balances: sensitiveUnlocked ? currentBalances(txns) : {},
    netWorthHistory: sensitiveUnlocked ? netWorthHistory(txns) : [],
    sensitiveUnlocked,
  });
}
