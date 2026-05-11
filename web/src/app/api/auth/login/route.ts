import { NextResponse } from "next/server";
import { createSessionToken, setSessionCookie, verifyPassword } from "@/lib/auth";

export async function POST(request: Request) {
  const { password } = await request.json();
  if (typeof password !== "string" || !(await verifyPassword(password))) {
    return NextResponse.json({ error: "Invalid password" }, { status: 401 });
  }
  await setSessionCookie(await createSessionToken());
  return NextResponse.json({ ok: true });
}
