import { NextResponse } from "next/server";
import { requireCurrentUserJson } from "@/lib/apiAuth";
import { gitPullRebaseForUser } from "@/lib/gitOps";

export async function POST() {
  const { userId, error: authError } = await requireCurrentUserJson();
  if (authError) return authError;
  try {
    const output = gitPullRebaseForUser(userId);
    return NextResponse.json({ ok: true, output });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
