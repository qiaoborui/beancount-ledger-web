import { NextResponse } from "next/server";
import { z } from "zod";
import { requireAuthJson } from "@/lib/apiAuth";
import { sendWebPushToAll } from "@/lib/webPush";

const NotifySchema = z.object({
  title: z.string().min(1).max(80),
  body: z.string().min(1).max(200),
  url: z.string().default("/"),
  tag: z.string().min(1).max(80).default("ledger-notification"),
});

export async function POST(request: Request) {
  const authError = await requireAuthJson();
  if (authError) return authError;
  const parsed = NotifySchema.safeParse(await request.json());
  if (!parsed.success) {
    return NextResponse.json({ error: "invalid push notification request" }, { status: 400 });
  }

  try {
    const result = await sendWebPushToAll(parsed.data);
    return NextResponse.json({ ok: true, ...result });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
