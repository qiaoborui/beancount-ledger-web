import { generateRegistrationOptions } from "@simplewebauthn/server";
import { NextResponse } from "next/server";
import { requireCurrentUserJson } from "@/lib/apiAuth";
import { listPasskeysForUser, rpIDFromRequest, setCurrentChallengeForUser } from "@/lib/passkeys";

export async function POST(request: Request) {
  const { userId, error: authError } = await requireCurrentUserJson();
  if (authError) return authError;
  const rpID = rpIDFromRequest(request);
  const options = await generateRegistrationOptions({
    rpName: "我的账本",
    rpID,
    userName: userId,
    userDisplayName: "账本主人",
    attestationType: "none",
    excludeCredentials: listPasskeysForUser(userId).map((cred) => ({ id: cred.id, transports: cred.transports })),
    authenticatorSelection: {
      residentKey: "preferred",
      userVerification: "required",
    },
  });
  setCurrentChallengeForUser(userId, options.challenge);
  return NextResponse.json(options);
}
