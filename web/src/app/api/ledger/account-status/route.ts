import { NextResponse } from "next/server";
import { requireSensitiveUnlockJson } from "@/lib/apiAuth";
import { accountStatusIndicators } from "@/lib/beancountParser";
import { getLedgerSnapshot } from "@/lib/ledgerCache";

export async function GET() {
  const authError = await requireSensitiveUnlockJson();
  if (authError) return authError;
  const snapshot = getLedgerSnapshot();
  const statuses = accountStatusIndicators(snapshot.transactions, snapshot.balanceAssertions, snapshot.accounts);
  return NextResponse.json({ statuses });
}
