import { NextResponse } from "next/server";
import { requireCurrentUserJson } from "@/lib/apiAuth";
import { userLedgerRepoStatus } from "@/lib/gitWorkspace";

export async function GET() {
  const { userId, error: authError } = await requireCurrentUserJson();
  if (authError) return authError;
  return NextResponse.json(userLedgerRepoStatus(userId));
}
