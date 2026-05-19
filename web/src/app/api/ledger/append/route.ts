import { NextResponse } from "next/server";
import { requireCurrentUserJson } from "@/lib/apiAuth";
import { appendBeanTextForUser, balanceToBean, transactionToBean } from "@/lib/ledgerWriter";
import { LedgerEntrySchema } from "@/lib/schemas";

export async function POST(request: Request) {
  const { userId, error: authError } = await requireCurrentUserJson();
  if (authError) return authError;
  const entry = LedgerEntrySchema.parse(await request.json());
  const beanText = entry.kind === "transaction" ? transactionToBean(entry) : balanceToBean(entry);
  try {
    await appendBeanTextForUser(userId, entry.date, beanText);
    return NextResponse.json({ ok: true, beanText });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
