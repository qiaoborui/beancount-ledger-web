import { NextResponse } from "next/server";
import { requireAuth } from "@/lib/auth";
import { incomeStatementTree, parseTransactions } from "@/lib/beancountParser";
import { parseApiTimeParams } from "@/lib/timeRange";

export async function GET(request: Request) {
  await requireAuth();
  const { start, end } = parseApiTimeParams(new URL(request.url).searchParams);
  const txns = parseTransactions();
  const { income, expense, totalIncome, totalExpense, netIncome } = incomeStatementTree(start, end, txns);
  return NextResponse.json({ start, end, income, expense, totalIncome, totalExpense, netIncome });
}
