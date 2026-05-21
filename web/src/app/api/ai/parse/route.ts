import { NextResponse } from "next/server";
import { apiHandler } from "@/lib/apiRoute";
import { requireAuthJson } from "@/lib/apiAuth";
import { parseNaturalLanguage } from "@/lib/deepseek";
import { logDuration } from "@/lib/diagnostics";
import { rateLimit } from "@/lib/rateLimit";

export const POST = apiHandler(async (request: Request) => {
  const rateLimitError = rateLimit(request, { name: "ai.parse", limit: 20, windowMs: 5 * 60_000 });
  if (rateLimitError) return rateLimitError;

  const authError = await requireAuthJson();
  if (authError) return authError;
  const { input } = await request.json();
  if (typeof input !== "string" || !input.trim()) {
    return NextResponse.json({ error: "input is required" }, { status: 400 });
  }
  const today = new Date().toISOString().slice(0, 10);
  const startedAt = Date.now();
  const entries = await parseNaturalLanguage(input, today);
  logDuration("ai.parse", startedAt, { entries: entries.length });
  return NextResponse.json({ entries, entry: entries[0] });
}, { defaultStatus: 400 });
