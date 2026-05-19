import { NextResponse } from "next/server";
import { requireCurrentUserJson } from "@/lib/apiAuth";
import { getLedgerVersionForUser } from "@/lib/ledgerCache";

export async function GET() {
  const { userId, error: authError } = await requireCurrentUserJson();
  if (authError) return authError;
  return NextResponse.json(getLedgerVersionForUser(userId));
}
