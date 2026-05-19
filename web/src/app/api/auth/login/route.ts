import { NextResponse } from "next/server";
import { createSessionToken, setSensitiveUnlockCookie, setSessionCookie, verifyPassword } from "@/lib/auth";
import { hasLocalUsers, normalizeUserId, verifyLocalUserPassword } from "@/lib/users";

export async function POST(request: Request) {
  const { username, password } = await request.json();
  if (typeof password !== "string") return NextResponse.json({ error: "Invalid password" }, { status: 401 });

  let userId = "owner";
  let ok = false;
  if (hasLocalUsers() || typeof username === "string" && username.trim()) {
    try {
      userId = normalizeUserId(typeof username === "string" ? username : "");
      ok = await verifyLocalUserPassword(userId, password);
    } catch {
      ok = false;
    }
  } else {
    ok = await verifyPassword(password);
  }

  if (!ok) return NextResponse.json({ error: "Invalid username or password" }, { status: 401 });
  await setSessionCookie(await createSessionToken(userId));
  await setSensitiveUnlockCookie();
  return NextResponse.json({ ok: true, userId });
}
