import { NextResponse } from "next/server";
import { requireAuthJson } from "@/lib/apiAuth";
import { gitStatus } from "@/lib/gitOps";

export async function GET() {
  const authError = await requireAuthJson();
  if (authError) return authError;
  return NextResponse.json(gitStatus());
}
