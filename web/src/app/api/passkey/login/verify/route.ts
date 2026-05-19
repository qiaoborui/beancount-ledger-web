import { verifyAuthenticationResponse } from "@simplewebauthn/server";
import { NextResponse } from "next/server";
import { createSessionToken, setSensitiveUnlockCookie, setSessionCookie } from "@/lib/auth";
import { consumeCurrentChallengeForUser, listPasskeysForUser, originFromRequest, rpIDFromRequest, updatePasskeyCounterForUser } from "@/lib/passkeys";
import { normalizeUserId } from "@/lib/users";

function base64urlToBuffer(value: string) {
  return Buffer.from(value, "base64url");
}

export async function POST(request: Request) {
  const body = await request.json();
  let userId = "owner";
  try {
    if (typeof body.username === "string" && body.username.trim()) userId = normalizeUserId(body.username);
  } catch {
    return NextResponse.json({ error: "Invalid username" }, { status: 400 });
  }

  const stored = listPasskeysForUser(userId).find((cred) => cred.id === body.id);
  if (!stored) return NextResponse.json({ error: "Unknown passkey" }, { status: 400 });

  try {
    const verification = await verifyAuthenticationResponse({
      response: body,
      expectedChallenge: consumeCurrentChallengeForUser(userId),
      expectedOrigin: originFromRequest(request),
      expectedRPID: rpIDFromRequest(request),
      requireUserVerification: true,
      credential: {
        id: stored.id,
        publicKey: base64urlToBuffer(stored.publicKey),
        counter: stored.counter,
        transports: stored.transports,
      },
    });

    if (!verification.verified) return NextResponse.json({ error: "Passkey login failed" }, { status: 401 });
    updatePasskeyCounterForUser(userId, stored.id, verification.authenticationInfo.newCounter);
    await setSessionCookie(await createSessionToken(userId));
    await setSensitiveUnlockCookie();
    return NextResponse.json({ ok: true, userId });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
