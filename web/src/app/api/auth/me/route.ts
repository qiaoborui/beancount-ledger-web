import { NextResponse } from "next/server";
import { isAuthDisabled, isAuthenticated, isSensitiveUnlocked } from "@/lib/auth";

export async function GET() {
  return NextResponse.json({
    authenticated: await isAuthenticated(),
    sensitiveUnlocked: await isSensitiveUnlocked(),
    authDisabled: isAuthDisabled(),
  });
}
