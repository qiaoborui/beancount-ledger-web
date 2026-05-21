import { NextResponse } from "next/server";
import { apiHandler } from "@/lib/apiRoute";
import { requireAuthJson } from "@/lib/apiAuth";
import { appendLedgerEntries } from "@/lib/ledgerWriter";
import { LedgerEntrySchema } from "@/lib/schemas";

export const POST = apiHandler(async (request: Request) => {
  const authError = await requireAuthJson();
  if (authError) return authError;
  const body = await request.json();
  const rawEntries = Array.isArray(body?.entries) ? body.entries : null;
  if (!rawEntries?.length) {
    return NextResponse.json({ error: "entries is required" }, { status: 400 });
  }

  const entries = rawEntries.map((entry: unknown) => LedgerEntrySchema.parse(entry));
  const beanTexts = await appendLedgerEntries(entries);
  return NextResponse.json({ ok: true, count: entries.length, beanTexts });
}, { defaultStatus: 400 });
