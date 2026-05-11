import { NextResponse } from "next/server";
import { requireAuth } from "@/lib/auth";
import { detectInsights } from "@/lib/insights";

export async function GET(request: Request) {
  await requireAuth();
  const month = new URL(request.url).searchParams.get("month") ?? new Date().toISOString().slice(0, 7);
  return NextResponse.json({ month, insights: detectInsights(month) });
}
