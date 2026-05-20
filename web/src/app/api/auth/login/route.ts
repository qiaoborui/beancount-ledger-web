import { NextResponse } from "next/server";
import { createSessionToken, isAuthDisabled, setSensitiveUnlockCookie, setSessionCookie, verifyPassword } from "@/lib/auth";

export async function POST(request: Request) {
  if (isAuthDisabled()) return NextResponse.json({ ok: true });
  const { password } = await request.json();
  if (typeof password !== "string" || !(await verifyPassword(password))) {
    return NextResponse.json({ error: "Invalid password" }, { status: 401 });
  }
  await setSessionCookie(await createSessionToken());
  await setSensitiveUnlockCookie();
  return NextResponse.json({ ok: true });
}
