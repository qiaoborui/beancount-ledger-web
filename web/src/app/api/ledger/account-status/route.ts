import { NextResponse } from "next/server";
import { requireAuth } from "@/lib/auth";
import { accountStatusIndicators } from "@/lib/beancountParser";
import { getLedgerSnapshot } from "@/lib/ledgerCache";

export async function GET() {
  await requireAuth();
  const snapshot = getLedgerSnapshot();
  const statuses = accountStatusIndicators(snapshot.transactions, snapshot.balanceAssertions, snapshot.accounts);
  return NextResponse.json({ statuses });
}
