import { generateAuthenticationOptions } from "@simplewebauthn/server";
import { NextResponse } from "next/server";
import { listPasskeys, rpIDFromRequest, setCurrentChallenge } from "@/lib/passkeys";

export async function POST(request: Request) {
  const credentials = listPasskeys();
  if (!credentials.length) return NextResponse.json({ error: "No passkey registered" }, { status: 400 });
  const options = await generateAuthenticationOptions({
    rpID: rpIDFromRequest(request),
    allowCredentials: credentials.map((cred) => ({ id: cred.id, transports: cred.transports })),
    userVerification: "required",
  });
  setCurrentChallenge(options.challenge);
  return NextResponse.json(options);
}
