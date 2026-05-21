import type { NextResponse } from "next/server";
import { apiErrorResponse } from "./apiRoute";
import { requireAuth, requireSensitiveUnlock } from "./auth";

export async function requireAuthJson(): Promise<NextResponse | null> {
  try {
    await requireAuth();
    return null;
  } catch (error) {
    return apiErrorResponse(error);
  }
}

export async function requireSensitiveUnlockJson(): Promise<NextResponse | null> {
  try {
    await requireSensitiveUnlock();
    return null;
  } catch (error) {
    return apiErrorResponse(error);
  }
}
