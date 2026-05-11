import fs from "node:fs";
import crypto from "node:crypto";
import { notificationsPath } from "./ledgerPaths";
import { sendWebPushToAll } from "./webPush";

export type Insight = {
  id: string;
  severity: "info" | "warning" | "critical";
  title: string;
  detail: string;
  amount?: number;
  account?: string;
  date?: string;
};

export type NotificationStatus = "unread" | "read" | "dismissed" | "resolved";

export type StoredNotification = {
  id: string;
  insightId: string;
  month: string;
  severity: Insight["severity"];
  title: string;
  detail: string;
  detailHash: string;
  amount?: number;
  account?: string;
  date?: string;
  status: NotificationStatus;
  createdAt: string;
  readAt: string | null;
  dismissedAt: string | null;
  resolvedAt: string | null;
  updatedAt: string;
};

type NotificationStore = { version: 1; notifications: StoredNotification[] };

let writeQueue: Promise<unknown> = Promise.resolve();
function withWriteLock<T>(fn: () => Promise<T>): Promise<T> {
  const next = writeQueue.then(fn, fn);
  writeQueue = next.catch(() => undefined);
  return next;
}

function emptyStore(): NotificationStore {
  return { version: 1, notifications: [] };
}

function hash(value: string) {
  return crypto.createHash("sha256").update(value).digest("hex").slice(0, 16);
}

export function notificationId(month: string, insight: Insight) {
  return `${month}:${insight.id}`;
}

export function readNotificationStore(): NotificationStore {
  const file = notificationsPath();
  if (!fs.existsSync(file)) return emptyStore();
  try {
    const parsed = JSON.parse(fs.readFileSync(file, "utf8")) as NotificationStore;
    return { version: 1, notifications: Array.isArray(parsed.notifications) ? parsed.notifications : [] };
  } catch {
    return emptyStore();
  }
}

function writeNotificationStore(store: NotificationStore) {
  fs.writeFileSync(notificationsPath(), `${JSON.stringify(store, null, 2)}\n`, "utf8");
}

export async function mergeInsightsIntoNotifications(month: string, insights: Insight[]) {
  return withWriteLock(async () => {
    const store = readNotificationStore();
    const now = new Date().toISOString();
    const currentIds = new Set(insights.map((insight) => notificationId(month, insight)));
    const byId = new Map(store.notifications.map((notification) => [notification.id, notification]));
    const createdNotifications: StoredNotification[] = [];
    let changed = false;

    for (const insight of insights) {
      const id = notificationId(month, insight);
      const detailHash = hash(`${insight.title}\n${insight.detail}\n${insight.amount ?? ""}\n${insight.account ?? ""}\n${insight.date ?? ""}`);
      const existing = byId.get(id);
      if (!existing) {
        const notification: StoredNotification = {
          id,
          insightId: insight.id,
          month,
          severity: insight.severity,
          title: insight.title,
          detail: insight.detail,
          detailHash,
          amount: insight.amount,
          account: insight.account,
          date: insight.date,
          status: "unread",
          createdAt: now,
          readAt: null,
          dismissedAt: null,
          resolvedAt: null,
          updatedAt: now,
        };
        store.notifications.push(notification);
        byId.set(id, notification);
        createdNotifications.push(notification);
        changed = true;
        continue;
      }

      if (existing.detailHash !== detailHash || existing.severity !== insight.severity || existing.title !== insight.title) {
        existing.severity = insight.severity;
        existing.title = insight.title;
        existing.detail = insight.detail;
        existing.detailHash = detailHash;
        existing.amount = insight.amount;
        existing.account = insight.account;
        existing.date = insight.date;
        existing.updatedAt = now;
        if (existing.status === "resolved") {
          existing.status = "unread";
          existing.resolvedAt = null;
          existing.readAt = null;
        }
        changed = true;
      }
    }

    for (const notification of store.notifications) {
      if (notification.month === month && !currentIds.has(notification.id) && notification.status !== "resolved") {
        notification.status = "resolved";
        notification.resolvedAt = now;
        notification.updatedAt = now;
        changed = true;
      }
    }

    if (changed) writeNotificationStore(store);
    if (createdNotifications.length) {
      const mostImportant = [...createdNotifications].sort((a, b) => severityRank(a.severity) - severityRank(b.severity))[0];
      await sendWebPushToAll({
        title: createdNotifications.length === 1 ? mostImportant.title : `我的账本：${createdNotifications.length} 条新提醒`,
        body: createdNotifications.length === 1 ? mostImportant.detail : mostImportant.detail,
        url: "/",
        tag: `ledger-notifications-${month}`,
      }).catch(() => undefined);
    }
    return store.notifications.filter((notification) => notification.month === month).sort((a, b) => statusRank(a.status) - statusRank(b.status) || severityRank(a.severity) - severityRank(b.severity) || b.updatedAt.localeCompare(a.updatedAt));
  });
}

function severityRank(severity: Insight["severity"]) {
  return severity === "critical" ? 0 : severity === "warning" ? 1 : 2;
}

function statusRank(status: NotificationStatus) {
  return status === "unread" ? 0 : status === "read" ? 1 : status === "dismissed" ? 2 : 3;
}

export async function updateNotificationStatus(ids: string[], status: NotificationStatus) {
  return withWriteLock(async () => {
    const store = readNotificationStore();
    const now = new Date().toISOString();
    const idSet = new Set(ids);
    for (const notification of store.notifications) {
      if (!idSet.has(notification.id)) continue;
      notification.status = status;
      notification.updatedAt = now;
      if (status === "read") notification.readAt = now;
      if (status === "unread") {
        notification.readAt = null;
        notification.dismissedAt = null;
        notification.resolvedAt = null;
      }
      if (status === "dismissed") notification.dismissedAt = now;
      if (status === "resolved") notification.resolvedAt = now;
    }
    writeNotificationStore(store);
    return store.notifications.filter((notification) => idSet.has(notification.id));
  });
}
