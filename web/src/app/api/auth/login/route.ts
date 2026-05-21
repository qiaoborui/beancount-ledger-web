import { NextResponse } from "next/server";
import { apiHandler } from "@/lib/apiRoute";
import { createSessionToken, isAuthDisabled, setSensitiveUnlockCookie, setSessionCookie, verifyPassword } from "@/lib/auth";
import { rateLimit } from "@/lib/rateLimit";

export const POST = apiHandler(async (request: Request) => {
  const rateLimitError = rateLimit(request, { name: "auth.login", limit: 10, windowMs: 60_000 });
  if (rateLimitError) return rateLimitError;

  if (isAuthDisabled()) return NextResponse.json({ ok: true });
  const { password } = await request.json();
  if (typeof password !== "string" || !(await verifyPassword(password))) {
    return NextResponse.json({ error: "Invalid password" }, { status: 401 });
  }
  await setSessionCookie(await createSessionToken());
  await setSensitiveUnlockCookie();
  return NextResponse.json({ ok: true });
}, { defaultStatus: 400 });
