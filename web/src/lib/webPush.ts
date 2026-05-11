import fs from "node:fs";
import webpush, { type PushSubscription } from "web-push";
import { webPushSubscriptionsPath } from "./ledgerPaths";

export type StoredPushSubscription = {
  id: string;
  subscription: PushSubscription;
  userAgent?: string;
  createdAt: string;
  updatedAt: string;
};

type PushStore = { version: 1; subscriptions: StoredPushSubscription[] };

let writeQueue: Promise<unknown> = Promise.resolve();
function withWriteLock<T>(fn: () => Promise<T>): Promise<T> {
  const next = writeQueue.then(fn, fn);
  writeQueue = next.catch(() => undefined);
  return next;
}

function emptyStore(): PushStore {
  return { version: 1, subscriptions: [] };
}

function subscriptionId(subscription: PushSubscription) {
  return Buffer.from(subscription.endpoint).toString("base64url").slice(0, 48);
}

function readPushStore(): PushStore {
  const file = webPushSubscriptionsPath();
  if (!fs.existsSync(file)) return emptyStore();
  try {
    const parsed = JSON.parse(fs.readFileSync(file, "utf8")) as PushStore;
    return { version: 1, subscriptions: Array.isArray(parsed.subscriptions) ? parsed.subscriptions : [] };
  } catch {
    return emptyStore();
  }
}

function writePushStore(store: PushStore) {
  fs.writeFileSync(webPushSubscriptionsPath(), `${JSON.stringify(store, null, 2)}\n`, "utf8");
}

export function publicVapidKey() {
  return process.env.NEXT_PUBLIC_WEB_PUSH_VAPID_PUBLIC_KEY || process.env.WEB_PUSH_VAPID_PUBLIC_KEY || "";
}

function configureWebPush() {
  const publicKey = publicVapidKey();
  const privateKey = process.env.WEB_PUSH_VAPID_PRIVATE_KEY || "";
  if (!publicKey || !privateKey) throw new Error("WEB_PUSH_VAPID_PUBLIC_KEY and WEB_PUSH_VAPID_PRIVATE_KEY are required");
  webpush.setVapidDetails(process.env.WEB_PUSH_SUBJECT || "mailto:ledger@example.local", publicKey, privateKey);
}

export async function listPushSubscriptions() {
  return readPushStore().subscriptions;
}

export async function savePushSubscription(subscription: PushSubscription, userAgent?: string) {
  return withWriteLock(async () => {
    const store = readPushStore();
    const id = subscriptionId(subscription);
    const now = new Date().toISOString();
    const existing = store.subscriptions.find((item) => item.id === id);
    if (existing) {
      existing.subscription = subscription;
      existing.userAgent = userAgent;
      existing.updatedAt = now;
    } else {
      store.subscriptions.push({ id, subscription, userAgent, createdAt: now, updatedAt: now });
    }
    writePushStore(store);
    return { id, count: store.subscriptions.length };
  });
}

export async function removePushSubscription(endpoint: string) {
  return withWriteLock(async () => {
    const store = readPushStore();
    const before = store.subscriptions.length;
    store.subscriptions = store.subscriptions.filter((item) => item.subscription.endpoint !== endpoint);
    if (store.subscriptions.length !== before) writePushStore(store);
    return { removed: before - store.subscriptions.length, count: store.subscriptions.length };
  });
}

export async function sendWebPushToAll(payload: { title: string; body: string; url?: string; tag?: string }) {
  configureWebPush();
  const store = readPushStore();
  const deadEndpoints = new Set<string>();
  const results = await Promise.allSettled(store.subscriptions.map(async (item) => {
    try {
      await webpush.sendNotification(item.subscription, JSON.stringify(payload));
      return { id: item.id, ok: true };
    } catch (error) {
      const statusCode = typeof error === "object" && error && "statusCode" in error ? Number((error as { statusCode?: unknown }).statusCode) : 0;
      if (statusCode === 404 || statusCode === 410) deadEndpoints.add(item.subscription.endpoint);
      throw error;
    }
  }));

  if (deadEndpoints.size) {
    await withWriteLock(async () => {
      const latest = readPushStore();
      latest.subscriptions = latest.subscriptions.filter((item) => !deadEndpoints.has(item.subscription.endpoint));
      writePushStore(latest);
    });
  }

  return {
    attempted: store.subscriptions.length,
    sent: results.filter((result) => result.status === "fulfilled").length,
    failed: results.filter((result) => result.status === "rejected").length,
    removed: deadEndpoints.size,
  };
}
