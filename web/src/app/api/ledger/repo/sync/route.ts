import { NextResponse } from "next/server";
import { z } from "zod";
import { requireCurrentUserJson } from "@/lib/apiAuth";
import { gitCommitPullPushForUser, gitPullRebaseForUser, gitStatusForUser } from "@/lib/gitOps";

const SyncSchema = z.object({
  action: z.enum(["pull", "commit-push", "status"]).default("status"),
  message: z.string().trim().min(1).optional(),
});

export async function POST(request: Request) {
  const { userId, error: authError } = await requireCurrentUserJson();
  if (authError) return authError;
  const input = SyncSchema.parse(await request.json().catch(() => ({})));
  try {
    if (input.action === "pull") {
      const output = gitPullRebaseForUser(userId);
      return NextResponse.json({ ok: true, output, status: gitStatusForUser(userId) });
    }
    if (input.action === "commit-push") {
      const result = gitCommitPullPushForUser(userId, input.message ?? "chore: update ledger");
      return NextResponse.json({ ok: true, ...result, status: gitStatusForUser(userId) });
    }
    return NextResponse.json({ ok: true, status: gitStatusForUser(userId) });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
