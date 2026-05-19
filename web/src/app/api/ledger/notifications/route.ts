import { NextResponse } from "next/server";
import { z } from "zod";
import { requireCurrentUserJson } from "@/lib/apiAuth";
import { mergeInsightsIntoNotificationsForUser, updateNotificationStatusForUser } from "@/lib/notifications";
import { detectInsightsForUser } from "@/lib/insights";

const StatusSchema = z.object({
  ids: z.array(z.string().min(1)).min(1),
  status: z.enum(["unread", "read", "dismissed", "resolved"]),
});

export async function GET(request: Request) {
  const { userId, error: authError } = await requireCurrentUserJson();
  if (authError) return authError;
  const month = new URL(request.url).searchParams.get("month") ?? new Date().toISOString().slice(0, 7);
  try {
    const insights = detectInsightsForUser(userId, month);
    const notifications = await mergeInsightsIntoNotificationsForUser(userId, month, insights);
    return NextResponse.json({ month, notifications });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}

export async function PATCH(request: Request) {
  const { userId, error: authError } = await requireCurrentUserJson();
  if (authError) return authError;
  const input = StatusSchema.parse(await request.json());
  const notifications = await updateNotificationStatusForUser(userId, input.ids, input.status);
  return NextResponse.json({ ok: true, notifications });
}
