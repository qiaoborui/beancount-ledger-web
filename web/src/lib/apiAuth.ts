import { NextResponse } from "next/server";
import { requireAuth, requireSensitiveUnlock } from "./auth";

function authFailureResponse(error: unknown): NextResponse {
  if (error instanceof Response) {
    const message = error.status === 423 ? "Sensitive data is locked" : "Unauthorized";
    return NextResponse.json({ error: message }, { status: error.status });
  }
  throw error;
}

export async function requireAuthJson(): Promise<NextResponse | null> {
  try {
    await requireAuth();
    return null;
  } catch (error) {
    return authFailureResponse(error);
  }
}

export async function requireSensitiveUnlockJson(): Promise<NextResponse | null> {
  try {
    await requireSensitiveUnlock();
    return null;
  } catch (error) {
    return authFailureResponse(error);
  }
}
