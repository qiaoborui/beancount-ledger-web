import { NextResponse } from "next/server";
import { requireSensitiveUnlockJson } from "@/lib/apiAuth";
import { getLedgerSnapshot } from "@/lib/ledgerCache";

export async function GET() {
  const authError = await requireSensitiveUnlockJson();
  if (authError) return authError;
  const snapshot = getLedgerSnapshot();
  return NextResponse.json({ balances: snapshot.balances, assertions: snapshot.balanceAssertions });
}
