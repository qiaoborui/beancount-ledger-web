import { NextResponse } from "next/server";
import { z } from "zod";
import { requireCurrentUserJson } from "@/lib/apiAuth";
import { initializeLedgerTemplateForUser } from "@/lib/ledgerWorkspaceAdmin";
import { gitStatusForUser } from "@/lib/gitOps";

const InitSchema = z.object({
  commit: z.boolean().default(false),
  message: z.string().trim().min(1).optional(),
});

export async function POST(request: Request) {
  const { userId, error: authError } = await requireCurrentUserJson();
  if (authError) return authError;
  const input = InitSchema.parse(await request.json().catch(() => ({})));
  try {
    const result = initializeLedgerTemplateForUser(userId, input);
    let status = null;
    try {
      status = gitStatusForUser(userId);
    } catch {
      status = null;
    }
    return NextResponse.json({ ok: true, ...result, status });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
