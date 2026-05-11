import { NextResponse } from "next/server";
import { z } from "zod";
import { requireAuth } from "@/lib/auth";
import { listPushSubscriptions, publicVapidKey, removePushSubscription, savePushSubscription, sendWebPushToAll } from "@/lib/webPush";

const PushKeysSchema = z.object({
  p256dh: z.string().min(1),
  auth: z.string().min(1),
});

const PushSubscriptionSchema = z.object({
  endpoint: z.string().url(),
  expirationTime: z.number().nullable().optional(),
  keys: PushKeysSchema,
});

const PostSchema = z.object({
  subscription: PushSubscriptionSchema,
});

const DeleteSchema = z.object({
  endpoint: z.string().url(),
});

export async function GET() {
  await requireAuth();
  const subscriptions = await listPushSubscriptions();
  return NextResponse.json({
    publicKey: publicVapidKey(),
    configured: Boolean(publicVapidKey() && process.env.WEB_PUSH_VAPID_PRIVATE_KEY),
    count: subscriptions.length,
  });
}

export async function POST(request: Request) {
  await requireAuth();
  const input = PostSchema.parse(await request.json());
  const result = await savePushSubscription(input.subscription, request.headers.get("user-agent") ?? undefined);
  return NextResponse.json({ ok: true, ...result });
}

export async function DELETE(request: Request) {
  await requireAuth();
  const input = DeleteSchema.parse(await request.json());
  const result = await removePushSubscription(input.endpoint);
  return NextResponse.json({ ok: true, ...result });
}

export async function PUT() {
  await requireAuth();
  try {
    const result = await sendWebPushToAll({
      title: "我的账本",
      body: "Web Push 测试通知已发送。",
      url: "/",
      tag: "web-push-test",
    });
    return NextResponse.json({ ok: true, ...result });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
