import { NextResponse } from "next/server";
import { requireAuthJson } from "@/lib/apiAuth";
import { appendBeanText, balanceToBean, transactionToBean } from "@/lib/ledgerWriter";
import { LedgerEntrySchema } from "@/lib/schemas";

export async function POST(request: Request) {
  const authError = await requireAuthJson();
  if (authError) return authError;
  const entry = LedgerEntrySchema.parse(await request.json());
  const beanText = entry.kind === "transaction" ? transactionToBean(entry) : balanceToBean(entry);
  try {
    await appendBeanText(entry.date, beanText);
    return NextResponse.json({ ok: true, beanText });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
