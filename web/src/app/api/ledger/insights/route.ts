import { NextResponse } from "next/server";
import { requireCurrentUserJson } from "@/lib/apiAuth";
import { detectInsightsForUser } from "@/lib/insights";

export async function GET(request: Request) {
  const { userId, error: authError } = await requireCurrentUserJson();
  if (authError) return authError;
  const month = new URL(request.url).searchParams.get("month") ?? new Date().toISOString().slice(0, 7);
  return NextResponse.json({ month, insights: detectInsightsForUser(userId, month) });
}
