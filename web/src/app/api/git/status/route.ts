import { NextResponse } from "next/server";
import { requireCurrentUserJson } from "@/lib/apiAuth";
import { gitStatusForUser } from "@/lib/gitOps";

export async function GET() {
  const { userId, error: authError } = await requireCurrentUserJson();
  if (authError) return authError;
  return NextResponse.json(gitStatusForUser(userId));
}
