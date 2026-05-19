import { generateAuthenticationOptions } from "@simplewebauthn/server";
import { NextResponse } from "next/server";
import { listPasskeysForUser, rpIDFromRequest, setCurrentChallengeForUser } from "@/lib/passkeys";
import { normalizeUserId } from "@/lib/users";

export async function POST(request: Request) {
  const body = await request.json().catch(() => ({}));
  let userId = "owner";
  try {
    if (typeof body.username === "string" && body.username.trim()) userId = normalizeUserId(body.username);
  } catch {
    return NextResponse.json({ error: "Invalid username" }, { status: 400 });
  }

  const credentials = listPasskeysForUser(userId);
  if (!credentials.length) return NextResponse.json({ error: "No passkey registered" }, { status: 400 });
  const options = await generateAuthenticationOptions({
    rpID: rpIDFromRequest(request),
    allowCredentials: credentials.map((cred) => ({ id: cred.id, transports: cred.transports })),
    userVerification: "required",
  });
  setCurrentChallengeForUser(userId, options.challenge);
  return NextResponse.json({ ...options, userId });
}
