import { generateRegistrationOptions } from "@simplewebauthn/server";
import { NextResponse } from "next/server";
import { requireAuth } from "@/lib/auth";
import { listPasskeys, rpIDFromRequest, setCurrentChallenge } from "@/lib/passkeys";

export async function POST(request: Request) {
  await requireAuth();
  const rpID = rpIDFromRequest(request);
  const options = await generateRegistrationOptions({
    rpName: "我的账本",
    rpID,
    userName: "owner",
    userDisplayName: "账本主人",
    attestationType: "none",
    excludeCredentials: listPasskeys().map((cred) => ({ id: cred.id, transports: cred.transports })),
    authenticatorSelection: {
      residentKey: "preferred",
      userVerification: "required",
    },
  });
  setCurrentChallenge(options.challenge);
  return NextResponse.json(options);
}
