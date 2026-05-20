import { NextResponse } from "next/server";
import { requireAuthJson } from "@/lib/apiAuth";
import { isSensitiveUnlocked } from "@/lib/auth";
import { creditCardAnalytics, monthEndNetWorth, netWorthChangeWindows } from "@/lib/assetAnalytics";
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
  const allNetWorthRows = sensitiveUnlocked ? netWorthHistory(snapshot.transactions) : [];
  const netWorthRows = allNetWorthRows.filter((row) => row.date >= start && row.date < end);
  const monthEndRows = sensitiveUnlocked ? monthEndNetWorth(netWorthRows) : [];
  const publicDays = Object.fromEntries(
    Object.entries(summary.days).map(([day, value]) => [day, { income: sensitiveUnlocked ? value.income : 0, expense: value.expense }]),
  );
  return NextResponse.json({
    start,
    end,
    summary: sensitiveUnlocked ? summary : { ...summary, income: 0, net: 0, days: publicDays },
    balances: sensitiveUnlocked ? snapshot.balances : {},
    netWorthHistory: netWorthRows,
    monthEndNetWorth: monthEndRows,
    netWorthWindows: sensitiveUnlocked ? netWorthChangeWindows(allNetWorthRows) : null,
    creditCards: sensitiveUnlocked ? creditCardAnalytics(snapshot.transactions, snapshot.balances, snapshot.accounts, start, end) : [],
    sensitiveUnlocked,
  });
}
