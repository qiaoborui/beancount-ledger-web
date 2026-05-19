import { NextResponse } from "next/server";
import { z } from "zod";
import { createSessionToken, setSensitiveUnlockCookie, setSessionCookie } from "@/lib/auth";
import { createLocalUser } from "@/lib/users";

const RegisterSchema = z.object({
  username: z.string().min(2),
  password: z.string().min(8),
  inviteCode: z.string().optional(),
});

export async function POST(request: Request) {
  const input = RegisterSchema.parse(await request.json());
  const expectedInviteCode = process.env.REGISTRATION_INVITE_CODE;
  if (expectedInviteCode && input.inviteCode !== expectedInviteCode) {
    return NextResponse.json({ error: "邀请码不正确" }, { status: 403 });
  }
  try {
    const user = createLocalUser(input.username, input.password);
    await setSessionCookie(await createSessionToken(user.id));
    await setSensitiveUnlockCookie();
    return NextResponse.json({ ok: true, userId: user.id });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
