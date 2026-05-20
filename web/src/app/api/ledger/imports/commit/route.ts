import { NextResponse } from "next/server";
import { z } from "zod";
import { requireAuthJson } from "@/lib/apiAuth";
import { commitBillImportAsync } from "@/lib/billImport";

const PostingSchema = z.object({ account: z.string().min(1), amount: z.string().min(1), currency: z.string().min(1) });

const EntrySchema = z.object({
  id: z.string().min(1),
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  flag: z.enum(["*", "!"]).default("*"),
  payee: z.string(),
  narration: z.string(),
  source: z.string().optional(),
  orderId: z.string().optional(),
  merchantId: z.string().optional(),
  payTime: z.string().optional(),
  method: z.string().optional(),
  txType: z.string().optional(),
  status: z.string().optional(),
  type: z.string().optional(),
  categoryAccount: z.string().min(1),
  fundingAccount: z.string().min(1),
  amount: z.number(),
  currency: z.string().min(1),
  metadata: z.record(z.string(), z.string()),
  postings: z.array(PostingSchema).min(1),
});

const CommitSchema = z.object({
  importId: z.string().min(1),
  provider: z.enum(["alipay", "wechat", "cmb"]),
  entries: z.array(EntrySchema).min(1),
  alipayFundRounding: z.boolean().optional(),
});

export async function POST(request: Request) {
  const authError = await requireAuthJson();
  if (authError) return authError;

  try {
    const input = CommitSchema.parse(await request.json());
    const result = await commitBillImportAsync(input);
    return NextResponse.json(result);
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
