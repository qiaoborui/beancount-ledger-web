import { NextResponse } from "next/server";
import { z } from "zod";
import { requireAuthJson } from "@/lib/apiAuth";
import { mergeInsightsIntoNotifications, updateNotificationStatus } from "@/lib/notifications";
import { detectInsights } from "@/lib/insights";
import { getMonthsInRange, parseApiTimeParams } from "@/lib/timeRange";

const PatchSchema = z.object({
  ids: z.array(z.string()).min(1),
  status: z.enum(["unread", "read", "dismissed", "resolved"]),
});

export async function GET(request: Request) {
  const authError = await requireAuthJson();
  if (authError) return authError;
  const { start, end } = parseApiTimeParams(new URL(request.url).searchParams);
  const months = getMonthsInRange(start, end);
  let allNotifications: Awaited<ReturnType<typeof mergeInsightsIntoNotifications>> = [];
  for (const month of months) {
    const insights = detectInsights(month);
    const notifications = await mergeInsightsIntoNotifications(month, insights);
    allNotifications.push(...notifications);
  }
  return NextResponse.json({ start, end, notifications: allNotifications });
}

export async function PATCH(request: Request) {
  const authError = await requireAuthJson();
  if (authError) return authError;
  const input = PatchSchema.parse(await request.json());
  const notifications = await updateNotificationStatus(input.ids, input.status);
  return NextResponse.json({ ok: true, notifications });
}
