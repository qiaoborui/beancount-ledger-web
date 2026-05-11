import { NextResponse } from "next/server";
import { listPasskeys } from "@/lib/passkeys";

export async function GET() {
  return NextResponse.json({ registered: listPasskeys().length > 0 });
}
