import { NextResponse } from "next/server";
import { requireAuthJson } from "@/lib/apiAuth";
import { getLedgerVersion } from "@/lib/ledgerCache";

export async function GET() {
  const authError = await requireAuthJson();
  if (authError) return authError;
  return NextResponse.json(getLedgerVersion());
}
