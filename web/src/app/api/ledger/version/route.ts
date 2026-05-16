import { NextResponse } from "next/server";
import { requireAuth } from "@/lib/auth";
import { getLedgerVersion } from "@/lib/ledgerCache";

export async function GET() {
  await requireAuth();
  return NextResponse.json(getLedgerVersion());
}
