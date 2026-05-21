import { NextResponse } from "next/server";
import { apiHandler } from "@/lib/apiRoute";
import { requireAuthJson } from "@/lib/apiAuth";
import { appendBeanText, balanceToBean, transactionToBean } from "@/lib/ledgerWriter";
import { LedgerEntrySchema } from "@/lib/schemas";

export const POST = apiHandler(async (request: Request) => {
  const authError = await requireAuthJson();
  if (authError) return authError;
  const entry = LedgerEntrySchema.parse(await request.json());
  const beanText = entry.kind === "transaction" ? transactionToBean(entry) : balanceToBean(entry);
  await appendBeanText(entry.date, beanText);
  return NextResponse.json({ ok: true, beanText });
}, { defaultStatus: 400 });
