import { NextResponse } from "next/server";
import { requireAuthJson } from "@/lib/apiAuth";
import { detectInsights } from "@/lib/insights";

export async function GET(request: Request) {
  const authError = await requireAuthJson();
  if (authError) return authError;
  const month = new URL(request.url).searchParams.get("month") ?? new Date().toISOString().slice(0, 7);
  return NextResponse.json({ month, insights: detectInsights(month) });
}
