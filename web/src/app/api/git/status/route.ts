import { NextResponse } from "next/server";
import { requireAuth } from "@/lib/auth";
import { gitStatus } from "@/lib/gitOps";

export async function GET() {
  await requireAuth();
  return NextResponse.json(gitStatus());
}
