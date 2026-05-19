import { NextResponse } from "next/server";
import { requireCurrentUserJson } from "@/lib/apiAuth";
import { accountStatusIndicators } from "@/lib/beancountParser";
import { getLedgerSnapshotForUser } from "@/lib/ledgerCache";

export async function GET() {
  const { userId, error: authError } = await requireCurrentUserJson();
  if (authError) return authError;
  const snapshot = getLedgerSnapshotForUser(userId);
  const statuses = accountStatusIndicators(snapshot.transactions, snapshot.balanceAssertions, snapshot.accounts);
  return NextResponse.json({ statuses });
}
