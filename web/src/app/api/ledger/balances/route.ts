import { NextResponse } from "next/server";
import { requireSensitiveUnlock } from "@/lib/auth";
import { getLedgerSnapshot } from "@/lib/ledgerCache";

export async function GET() {
  await requireSensitiveUnlock();
  const snapshot = getLedgerSnapshot();
  return NextResponse.json({ balances: snapshot.balances, assertions: snapshot.balanceAssertions });
}
