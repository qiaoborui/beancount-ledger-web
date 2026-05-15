import { NextResponse } from "next/server";
import { requireAuth } from "@/lib/auth";
import { appendLedgerEntries } from "@/lib/ledgerWriter";
import { LedgerEntrySchema } from "@/lib/schemas";

export async function POST(request: Request) {
  await requireAuth();
  const body = await request.json();
  const rawEntries = Array.isArray(body?.entries) ? body.entries : null;
  if (!rawEntries?.length) {
    return NextResponse.json({ error: "entries is required" }, { status: 400 });
  }

  try {
    const entries = rawEntries.map((entry: unknown) => LedgerEntrySchema.parse(entry));
    const beanTexts = await appendLedgerEntries(entries);
    return NextResponse.json({ ok: true, count: entries.length, beanTexts });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
