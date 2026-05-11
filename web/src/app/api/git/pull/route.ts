import { NextResponse } from "next/server";
import { requireAuth } from "@/lib/auth";
import { gitPullRebase } from "@/lib/gitOps";

export async function POST() {
  await requireAuth();
  try {
    const output = gitPullRebase();
    return NextResponse.json({ ok: true, output });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
