import { NextResponse } from "next/server";
import { requireCurrentUserJson } from "@/lib/apiAuth";
import { isSensitiveUnlocked } from "@/lib/auth";
import { incomeStatementTree } from "@/lib/beancountParser";
import { expenseAnalyticsSummary } from "@/lib/categoryAnalytics";
import { getLedgerSnapshotForUser } from "@/lib/ledgerCache";
import { parseApiTimeParams } from "@/lib/timeRange";

export async function GET(request: Request) {
  const { userId, error: authError } = await requireCurrentUserJson();
  if (authError) return authError;
  const { start, end } = parseApiTimeParams(new URL(request.url).searchParams);
  const snapshot = getLedgerSnapshotForUser(userId);
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
