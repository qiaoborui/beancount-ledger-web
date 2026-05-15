import { NextResponse } from "next/server";
import { isSensitiveUnlocked, requireAuth } from "@/lib/auth";
import { currentBalances, monthSummary, netWorthHistory, parseTransactions } from "@/lib/beancountParser";
import { parseApiTimeParams } from "@/lib/timeRange";

export async function GET(request: Request) {
  await requireAuth();
  const { start, end } = parseApiTimeParams(new URL(request.url).searchParams);
  const txns = parseTransactions();
  const sensitiveUnlocked = await isSensitiveUnlocked();
  return NextResponse.json({
    start,
    end,
    summary: monthSummary(start, end, txns),
    balances: sensitiveUnlocked ? currentBalances(txns) : {},
    netWorthHistory: sensitiveUnlocked ? netWorthHistory(txns) : [],
    sensitiveUnlocked,
  });
}
