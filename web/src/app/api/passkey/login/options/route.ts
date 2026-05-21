import { generateAuthenticationOptions } from "@simplewebauthn/server";
import { NextResponse } from "next/server";
import { apiHandler } from "@/lib/apiRoute";
import { listPasskeys, rpIDFromRequest, setCurrentChallenge } from "@/lib/passkeys";
import { rateLimit } from "@/lib/rateLimit";

export const POST = apiHandler(async (request: Request) => {
  const rateLimitError = rateLimit(request, { name: "passkey.login.options", limit: 20, windowMs: 60_000 });
  if (rateLimitError) return rateLimitError;

  const credentials = listPasskeys();
  if (!credentials.length) return NextResponse.json({ error: "No passkey registered" }, { status: 400 });
  const options = await generateAuthenticationOptions({
    rpID: rpIDFromRequest(request),
    allowCredentials: credentials.map((cred) => ({ id: cred.id, transports: cred.transports })),
    userVerification: "required",
  });
  setCurrentChallenge(options.challenge);
  return NextResponse.json(options);
}, { defaultStatus: 400 });
