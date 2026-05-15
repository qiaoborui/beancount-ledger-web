import { NextResponse } from "next/server";
import { z } from "zod";
import { isSensitiveUnlocked, requireAuth } from "@/lib/auth";
import { parseTransactions } from "@/lib/beancountParser";
import { parseApiTimeParams } from "@/lib/timeRange";
import { appendBeanText, commentTransactionBlock, replaceTransactionBlock, transactionToBean } from "@/lib/ledgerWriter";
import { ParsedTransactionSchema } from "@/lib/schemas";

const SourceSchema = z.object({ file: z.string().min(1), line: z.number().int().positive() });
const UpdateSchema = z.object({ source: SourceSchema, entry: ParsedTransactionSchema });
const DeleteSchema = z.object({ source: SourceSchema, reason: z.string().optional() });
const ReverseSchema = z.object({ source: SourceSchema, date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional() });

function findBySource(source: z.infer<typeof SourceSchema>) {
  const txn = parseTransactions().find((item) => item.source.file === source.file && item.source.line === source.line);
  if (!txn) throw new Error("找不到原交易，账本可能已被修改，请刷新后重试");
  return txn;
}

export async function GET(request: Request) {
  await requireAuth();
  const { start, end } = parseApiTimeParams(new URL(request.url).searchParams);
  const sensitiveUnlocked = await isSensitiveUnlocked();
  let transactions = parseTransactions().sort((a, b) => b.date.localeCompare(a.date));
  transactions = transactions.filter((txn) => txn.date >= start && txn.date < end);
  if (!sensitiveUnlocked) {
    transactions = transactions.filter((txn) => !txn.postings.some((posting) => posting.account.startsWith("Income:")));
  }
  return NextResponse.json({ start, end, transactions, sensitiveUnlocked });
}

export async function PUT(request: Request) {
  await requireAuth();
  const { source, entry } = UpdateSchema.parse(await request.json());
  try {
    await replaceTransactionBlock(source, entry);
    return NextResponse.json({ ok: true });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}

export async function DELETE(request: Request) {
  await requireAuth();
  const { source, reason } = DeleteSchema.parse(await request.json());
  try {
    await commentTransactionBlock(source, reason);
    return NextResponse.json({ ok: true });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}

export async function POST(request: Request) {
  await requireAuth();
  const { source, date } = ReverseSchema.parse(await request.json());
  try {
    const original = findBySource(source);
    const reverseDate = date ?? new Date().toISOString().slice(0, 10);
    const entry = {
      kind: "transaction" as const,
      date: reverseDate,
      payee: original.payee,
      narration: `冲销：${original.narration}`,
      metadata: { ...(original.metadata ?? {}), reversal: true },
      tags: original.tags ?? [],
      confidence: 1,
      needsReview: false,
      questions: [],
      postings: original.postings.map((posting) => ({
        account: posting.account,
        amount: (-(posting.amount / 100)).toFixed(2),
        currency: posting.currency,
      })),
    };
    await appendBeanText(reverseDate, transactionToBean(entry));
    return NextResponse.json({ ok: true, entry });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
