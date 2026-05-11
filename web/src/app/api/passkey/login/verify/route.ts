import { verifyAuthenticationResponse } from "@simplewebauthn/server";
import { NextResponse } from "next/server";
import { createSessionToken, setSessionCookie } from "@/lib/auth";
import { consumeCurrentChallenge, listPasskeys, originFromRequest, rpIDFromRequest, updatePasskeyCounter } from "@/lib/passkeys";

function base64urlToBuffer(value: string) {
  return Buffer.from(value, "base64url");
}

export async function POST(request: Request) {
  const body = await request.json();
  const stored = listPasskeys().find((cred) => cred.id === body.id);
  if (!stored) return NextResponse.json({ error: "Unknown passkey" }, { status: 400 });

  try {
    const verification = await verifyAuthenticationResponse({
      response: body,
      expectedChallenge: consumeCurrentChallenge(),
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
    updatePasskeyCounter(stored.id, verification.authenticationInfo.newCounter);
    await setSessionCookie(await createSessionToken());
    return NextResponse.json({ ok: true });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
