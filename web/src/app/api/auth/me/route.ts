import { NextResponse } from "next/server";
import { getCurrentUserId } from "@/lib/auth";

export async function GET() {
  const userId = await getCurrentUserId();
  return NextResponse.json({ authenticated: Boolean(userId), userId });
}
