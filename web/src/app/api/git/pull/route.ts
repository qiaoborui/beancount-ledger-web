import { NextResponse } from "next/server";
import { requireAuthJson } from "@/lib/apiAuth";
import { gitPullRebase } from "@/lib/gitOps";

export async function POST() {
  const authError = await requireAuthJson();
  if (authError) return authError;
  try {
    const output = gitPullRebase();
    return NextResponse.json({ ok: true, output });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
