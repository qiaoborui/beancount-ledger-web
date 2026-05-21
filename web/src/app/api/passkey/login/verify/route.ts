import { verifyAuthenticationResponse } from "@simplewebauthn/server";
import { NextResponse } from "next/server";
import { apiHandler } from "@/lib/apiRoute";
import { createSessionToken, setSensitiveUnlockCookie, setSessionCookie } from "@/lib/auth";
import { consumeCurrentChallenge, listPasskeys, originFromRequest, rpIDFromRequest, updatePasskeyCounter } from "@/lib/passkeys";
import { rateLimit } from "@/lib/rateLimit";

function base64urlToBuffer(value: string) {
  return Buffer.from(value, "base64url");
}

export const POST = apiHandler(async (request: Request) => {
  const rateLimitError = rateLimit(request, { name: "passkey.login.verify", limit: 20, windowMs: 60_000 });
  if (rateLimitError) return rateLimitError;

  const body = await request.json();
  const stored = listPasskeys().find((cred) => cred.id === body.id);
  if (!stored) return NextResponse.json({ error: "Unknown passkey" }, { status: 400 });

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
  await setSensitiveUnlockCookie();
  return NextResponse.json({ ok: true });
}, { defaultStatus: 400 });
