import { NextResponse } from "next/server";
import { z } from "zod";
import { requireCurrentUserJson } from "@/lib/apiAuth";
import { clearLedgerRepoToken, updateLedgerRepoToken } from "@/lib/ledgerWorkspaceAdmin";
import { publicLedgerRepoConfig } from "@/lib/ledgerRepoConfig";
import { userLedgerRepoStatus } from "@/lib/gitWorkspace";

const PutSchema = z.object({
  token: z.string().trim().min(1),
  tokenUsername: z.string().trim().min(1).optional(),
});

export async function PUT(request: Request) {
  const { userId, error: authError } = await requireCurrentUserJson();
  if (authError) return authError;
  const input = PutSchema.parse(await request.json());
  try {
    const config = updateLedgerRepoToken(userId, input.token, input.tokenUsername);
    return NextResponse.json({ ok: true, config: publicLedgerRepoConfig(config), status: userLedgerRepoStatus(userId) });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}

export async function DELETE() {
  const { userId, error: authError } = await requireCurrentUserJson();
  if (authError) return authError;
  try {
    const config = clearLedgerRepoToken(userId);
    return NextResponse.json({ ok: true, config: publicLedgerRepoConfig(config), status: userLedgerRepoStatus(userId) });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
