import { NextResponse } from "next/server";
import { requireSensitiveUnlock } from "@/lib/auth";
import { currentBalances, parseBalances, parseTransactions } from "@/lib/beancountParser";

export async function GET() {
  await requireSensitiveUnlock();
  return NextResponse.json({ balances: currentBalances(parseTransactions()), assertions: parseBalances() });
}
