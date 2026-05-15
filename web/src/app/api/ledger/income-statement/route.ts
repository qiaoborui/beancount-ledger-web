import { NextResponse } from "next/server";
import { isSensitiveUnlocked, requireAuth } from "@/lib/auth";
import { incomeStatementTree, parseTransactions } from "@/lib/beancountParser";
import { parseApiTimeParams } from "@/lib/timeRange";

export async function GET(request: Request) {
  await requireAuth();
  const { start, end } = parseApiTimeParams(new URL(request.url).searchParams);
  const txns = parseTransactions();
  const { income, expense, totalIncome, totalExpense, netIncome } = incomeStatementTree(start, end, txns);
  const sensitiveUnlocked = await isSensitiveUnlocked();
  return NextResponse.json({
    start,
    end,
    income: sensitiveUnlocked ? income : [],
    expense,
    totalIncome: sensitiveUnlocked ? totalIncome : 0,
    totalExpense,
    netIncome: sensitiveUnlocked ? netIncome : 0,
    sensitiveUnlocked,
  });
}
