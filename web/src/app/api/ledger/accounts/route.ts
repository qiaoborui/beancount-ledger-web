import { NextResponse } from "next/server";
import { z } from "zod";
import { requireAuthJson } from "@/lib/apiAuth";
import { getLedgerSnapshot } from "@/lib/ledgerCache";
import { appendAccount } from "@/lib/ledgerWriter";

const AccountSchema = z.object({
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  account: z.string().regex(/^(Assets|Liabilities|Equity|Income|Expenses)(:[A-Z][A-Za-z0-9-]*)+$/),
  alias: z.string().max(80).optional().default(""),
  currency: z.literal("CNY").default("CNY"),
});

export async function GET() {
  const authError = await requireAuthJson();
  if (authError) return authError;
  return NextResponse.json({ accounts: getLedgerSnapshot().accounts });
}

export async function POST(request: Request) {
  const authError = await requireAuthJson();
  if (authError) return authError;
  const input = AccountSchema.parse(await request.json());
  const exists = getLedgerSnapshot().accounts.some((account) => account.account === input.account);
  if (exists) return NextResponse.json({ error: "账户已存在" }, { status: 400 });

  try {
    await appendAccount(input);
    return NextResponse.json({ ok: true, account: input });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
