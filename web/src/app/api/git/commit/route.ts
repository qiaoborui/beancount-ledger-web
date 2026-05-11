import { NextResponse } from "next/server";
import { requireAuth } from "@/lib/auth";
import { gitCommitPullPush } from "@/lib/gitOps";

export async function POST(request: Request) {
  await requireAuth();
  const { message } = await request.json().catch(() => ({ message: "chore: update ledger" }));
  try {
    const result = gitCommitPullPush(String(message || "chore: update ledger"));
    return NextResponse.json({ ok: true, ...result });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
