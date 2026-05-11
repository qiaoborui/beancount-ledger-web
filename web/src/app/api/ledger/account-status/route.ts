import { NextResponse } from "next/server";
import { requireAuth } from "@/lib/auth";
import { accountStatusIndicators } from "@/lib/beancountParser";

export async function GET() {
  await requireAuth();
  const statuses = accountStatusIndicators();
  return NextResponse.json({ statuses });
}
