import { NextResponse } from "next/server";
import { getCurrentUserId } from "@/lib/auth";
import { listPasskeysForUser } from "@/lib/passkeys";
import { normalizeUserId } from "@/lib/users";

export async function GET(request: Request) {
  const url = new URL(request.url);
  let userId = await getCurrentUserId();
  const username = url.searchParams.get("username");
  if (!userId && username) {
    try {
      userId = normalizeUserId(username);
    } catch {
      return NextResponse.json({ registered: false });
    }
  }
  userId ??= "owner";
  return NextResponse.json({ registered: listPasskeysForUser(userId).length > 0, userId });
}
