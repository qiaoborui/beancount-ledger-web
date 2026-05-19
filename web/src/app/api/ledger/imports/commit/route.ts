import { NextResponse } from "next/server";
import { z } from "zod";
import { requireAuthJson } from "@/lib/apiAuth";
import { commitBillImportAsync } from "@/lib/billImport";

const CommitSchema = z.object({
  importId: z.string().min(1),
  provider: z.enum(["alipay", "wechat"]),
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
