import { verifyRegistrationResponse } from "@simplewebauthn/server";
import { NextResponse } from "next/server";
import { requireCurrentUserJson } from "@/lib/apiAuth";
import { consumeCurrentChallengeForUser, originFromRequest, rpIDFromRequest, savePasskeyForUser } from "@/lib/passkeys";

function bufferToBase64url(buffer: Uint8Array) {
  return Buffer.from(buffer).toString("base64url");
}

export async function POST(request: Request) {
  const { userId, error: authError } = await requireCurrentUserJson();
  if (authError) return authError;
  const body = await request.json();
  try {
    const verification = await verifyRegistrationResponse({
      response: body,
      expectedChallenge: consumeCurrentChallengeForUser(userId),
      expectedOrigin: originFromRequest(request),
      expectedRPID: rpIDFromRequest(request),
      requireUserVerification: true,
    });

    if (!verification.verified || !verification.registrationInfo) {
      return NextResponse.json({ error: "Passkey registration failed" }, { status: 400 });
    }

    savePasskeyForUser(userId, {
      id: verification.registrationInfo.credential.id,
      publicKey: bufferToBase64url(verification.registrationInfo.credential.publicKey),
      counter: verification.registrationInfo.credential.counter,
      transports: body.response?.transports,
    });

    return NextResponse.json({ ok: true });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
