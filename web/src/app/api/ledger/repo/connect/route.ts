import { NextResponse } from "next/server";
import { z } from "zod";
import { requireCurrentUserJson } from "@/lib/apiAuth";
import { connectUserLedgerRepo, userLedgerRepoStatus } from "@/lib/gitWorkspace";

const ConnectSchema = z.object({
  remoteUrl: z.string().min(1),
  branch: z.string().trim().min(1).optional(),
  provider: z.enum(["github", "git"]).optional(),
  owner: z.string().trim().min(1).optional(),
  repo: z.string().trim().min(1).optional(),
  token: z.string().trim().min(1).optional(),
  tokenUsername: z.string().trim().min(1).optional(),
});

export async function POST(request: Request) {
  const { userId, error: authError } = await requireCurrentUserJson();
  if (authError) return authError;
  const input = ConnectSchema.parse(await request.json());
  try {
    const config = connectUserLedgerRepo(userId, input);
    return NextResponse.json({ ok: true, config, status: userLedgerRepoStatus(userId) });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
