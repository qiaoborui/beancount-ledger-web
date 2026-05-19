import fs from "node:fs";
import webpush, { type PushSubscription } from "web-push";
import { webPushSubscriptionsPathForUser } from "./ledgerPaths";

export type StoredPushSubscription = {
  id: string;
  subscription: PushSubscription;
  userAgent?: string;
  createdAt: string;
  updatedAt: string;
};

type PushStore = { version: 1; subscriptions: StoredPushSubscription[] };

const writeQueues = new Map<string, Promise<unknown>>();
function withWriteLock<T>(userId: string, fn: () => Promise<T>): Promise<T> {
  const queue = writeQueues.get(userId) ?? Promise.resolve();
  const next = queue.then(fn, fn);
  writeQueues.set(userId, next.catch(() => undefined));
  return next;
}

function emptyStore(): PushStore {
  return { version: 1, subscriptions: [] };
}

function subscriptionId(subscription: PushSubscription) {
  return Buffer.from(subscription.endpoint).toString("base64url").slice(0, 48);
}

function readPushStoreForUser(userId: string): PushStore {
  const file = webPushSubscriptionsPathForUser(userId);
  if (!fs.existsSync(file)) return emptyStore();
  try {
    const parsed = JSON.parse(fs.readFileSync(file, "utf8")) as PushStore;
    return { version: 1, subscriptions: Array.isArray(parsed.subscriptions) ? parsed.subscriptions : [] };
  } catch {
    return emptyStore();
  }
}

function writePushStoreForUser(userId: string, store: PushStore) {
  fs.writeFileSync(webPushSubscriptionsPathForUser(userId), `${JSON.stringify(store, null, 2)}\n`, "utf8");
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

export async function listPushSubscriptionsForUser(userId: string) {
  return readPushStoreForUser(userId).subscriptions;
}

export async function listPushSubscriptions() {
  return listPushSubscriptionsForUser("owner");
}

export async function savePushSubscriptionForUser(userId: string, subscription: PushSubscription, userAgent?: string) {
  return withWriteLock(userId, async () => {
    const store = readPushStoreForUser(userId);
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
    writePushStoreForUser(userId, store);
    return { id, count: store.subscriptions.length };
  });
}

export async function savePushSubscription(subscription: PushSubscription, userAgent?: string) {
  return savePushSubscriptionForUser("owner", subscription, userAgent);
}

export async function removePushSubscriptionForUser(userId: string, endpoint: string) {
  return withWriteLock(userId, async () => {
    const store = readPushStoreForUser(userId);
    const before = store.subscriptions.length;
    store.subscriptions = store.subscriptions.filter((item) => item.subscription.endpoint !== endpoint);
    if (store.subscriptions.length !== before) writePushStoreForUser(userId, store);
    return { removed: before - store.subscriptions.length, count: store.subscriptions.length };
  });
}

export async function removePushSubscription(endpoint: string) {
  return removePushSubscriptionForUser("owner", endpoint);
}

export async function sendWebPushToAllForUser(userId: string, payload: { title: string; body: string; url?: string; tag?: string }) {
  configureWebPush();
  const store = readPushStoreForUser(userId);
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
    await withWriteLock(userId, async () => {
      const latest = readPushStoreForUser(userId);
      latest.subscriptions = latest.subscriptions.filter((item) => !deadEndpoints.has(item.subscription.endpoint));
      writePushStoreForUser(userId, latest);
    });
  }

  return {
    attempted: store.subscriptions.length,
    sent: results.filter((result) => result.status === "fulfilled").length,
    failed: results.filter((result) => result.status === "rejected").length,
    removed: deadEndpoints.size,
  };
}

export async function sendWebPushToAll(payload: { title: string; body: string; url?: string; tag?: string }) {
  return sendWebPushToAllForUser("owner", payload);
}
