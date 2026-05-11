import { NextResponse } from "next/server";
import { requireAuth } from "@/lib/auth";
import { parseNaturalLanguage } from "@/lib/deepseek";

export async function POST(request: Request) {
  await requireAuth();
  const { input } = await request.json();
  if (typeof input !== "string" || !input.trim()) {
    return NextResponse.json({ error: "input is required" }, { status: 400 });
  }
  const today = new Date().toISOString().slice(0, 10);
  try {
    const entries = await parseNaturalLanguage(input, today);
    return NextResponse.json({ entries, entry: entries[0] });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
