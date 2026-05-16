import { NextResponse } from "next/server";
import { isSensitiveUnlocked, requireAuth } from "@/lib/auth";
import { incomeStatementTree } from "@/lib/beancountParser";
import { expenseAnalyticsSummary } from "@/lib/categoryAnalytics";
import { getLedgerSnapshot } from "@/lib/ledgerCache";
import { parseApiTimeParams } from "@/lib/timeRange";

export async function GET(request: Request) {
  await requireAuth();
  const { start, end } = parseApiTimeParams(new URL(request.url).searchParams);
  const snapshot = getLedgerSnapshot();
  const { income, expense, totalIncome, totalExpense, netIncome } = incomeStatementTree(start, end, snapshot.transactions);
  const expenseAnalytics = expenseAnalyticsSummary(snapshot.transactions, start, end);
  const sensitiveUnlocked = await isSensitiveUnlocked();
  return NextResponse.json({
    start,
    end,
    income: sensitiveUnlocked ? income : [],
    expense,
    totalIncome: sensitiveUnlocked ? totalIncome : 0,
    totalExpense,
    expenseAnalytics: expenseAnalytics.categories,
    topPayees: expenseAnalytics.topPayees,
    topPaymentAccounts: expenseAnalytics.topPaymentAccounts,
    netIncome: sensitiveUnlocked ? netIncome : 0,
    sensitiveUnlocked,
  });
}
