import { NextResponse } from "next/server";
import { requireAuthJson } from "@/lib/apiAuth";
import { gitCommitPullPush } from "@/lib/gitOps";

export async function POST(request: Request) {
  const authError = await requireAuthJson();
  if (authError) return authError;
  const { message } = await request.json().catch(() => ({ message: "chore: update ledger" }));
  try {
    const result = gitCommitPullPush(String(message || "chore: update ledger"));
    return NextResponse.json({ ok: true, ...result });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
