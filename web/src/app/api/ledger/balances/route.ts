import { NextResponse } from "next/server";
import { requireAuth } from "@/lib/auth";
import { currentBalances, parseBalances, parseTransactions } from "@/lib/beancountParser";

export async function GET() {
  await requireAuth();
  return NextResponse.json({ balances: currentBalances(parseTransactions()), assertions: parseBalances() });
}
