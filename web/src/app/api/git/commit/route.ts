import { NextResponse } from "next/server";
import { requireCurrentUserJson } from "@/lib/apiAuth";
import { gitCommitPullPushForUser } from "@/lib/gitOps";

export async function POST(request: Request) {
  const { userId, error: authError } = await requireCurrentUserJson();
  if (authError) return authError;
  const { message } = await request.json().catch(() => ({ message: "chore: update ledger" }));
  try {
    const result = gitCommitPullPushForUser(userId, String(message || "chore: update ledger"));
    return NextResponse.json({ ok: true, ...result });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
