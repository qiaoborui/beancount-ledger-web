import { useState } from "react";
import { readJson } from "@/lib/clientFetch";
import { Button } from "@/components/ui/button";
import { MobileSheet } from "./MobileSheet";
import type { LedgerNotification } from "./types";

export function NotificationCenter({ notifications, open, onClose, onChange }: { notifications: LedgerNotification[]; open: boolean; onClose: () => void; onChange: (updated: LedgerNotification[]) => void }) {
  const [filter, setFilter] = useState<"unread" | "all" | "read" | "dismissed">("unread");
  const unread = notifications.filter((notification) => notification.status === "unread");
  const read = notifications.filter((notification) => notification.status === "read");
  const dismissed = notifications.filter((notification) => notification.status === "dismissed");
  const visibleNotifications = filter === "unread" ? unread : filter === "read" ? read : filter === "dismissed" ? dismissed : notifications.filter((notification) => notification.status !== "resolved");
  const criticalUnread = unread.filter((notification) => notification.severity === "critical").length;
  const warningUnread = unread.filter((notification) => notification.severity === "warning").length;

  async function updateStatus(ids: string[], status: LedgerNotification["status"]) {
    const res = await fetch("/api/ledger/notifications", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ids, status }) });
    const data = await readJson<{ error?: string; notifications?: LedgerNotification[] }>(res);
    if (res.ok) onChange(data.notifications ?? []);
  }

  if (!open) return null;
  return <MobileSheet open={open} title="通知中心" onClose={onClose} size="lg" zIndexClassName="z-[105]">
      <p className="text-sm text-stone">通知状态保存在账本仓库里，换设备也会跟随 Git 同步。</p>
      <div className="mt-4 grid grid-cols-3 divide-x divide-line rounded-xl border border-line bg-panel p-3 text-center text-sm">
        <div><strong>{unread.length}</strong><div className="text-xs text-stone">未读</div></div>
        <div><strong className="text-[var(--danger)]">{criticalUnread}</strong><div className="text-xs text-stone">严重未读</div></div>
        <div><strong className="text-[var(--warning)]">{warningUnread}</strong><div className="text-xs text-stone">提醒未读</div></div>
      </div>
      <div className="mt-4 flex flex-wrap items-center justify-between gap-2">
        <div className="flex rounded-xl border border-line bg-panel p-1 text-sm">
          {(["unread", "all", "read", "dismissed"] as const).map((key) => <Button key={key} variant={filter === key ? "default" : "ghost"} size="xs" className={`rounded ${filter === key ? "" : "text-olive"}`} onClick={() => setFilter(key)}>{key === "unread" ? `未读 ${unread.length}` : key === "read" ? `已读 ${read.length}` : key === "dismissed" ? `已忽略 ${dismissed.length}` : `全部 ${notifications.length}`}</Button>)}
        </div>
        {unread.length > 0 && <Button variant="outline" className="rounded-xl bg-panel text-olive" onClick={() => void updateStatus(unread.map((notification) => notification.id), "read")}>全部标为已读</Button>}
      </div>
      <div className="mt-5 space-y-3">
        {visibleNotifications.length === 0 && <div className="rounded-xl border border-line bg-panel p-6 text-center text-sm text-stone">{filter === "unread" ? "暂无未读提示。" : "暂无提示。"}</div>}
        {visibleNotifications.map((notification) => {
          const isUnread = notification.status === "unread";
          return <div key={notification.id} className={`rounded-xl border p-4 text-sm ${notification.status === "dismissed" ? "border-line bg-panel opacity-60" : isUnread && notification.severity === "critical" ? "border-line bg-panel" : isUnread && notification.severity === "warning" ? "border-line bg-panel" : "border-line bg-panel"}`}>
            <div className="flex items-start justify-between gap-3">
              <div className="min-w-0">
                <div className="flex items-center gap-2">{isUnread && <span className={`h-2 w-2 rounded-full ${notification.severity === "critical" ? "bg-[var(--danger)]" : notification.severity === "warning" ? "bg-[var(--warning)]" : "bg-brand"}`} />}<strong>{notification.title}</strong></div>
                <div className="mt-2 text-olive">{notification.detail}</div>
                {notification.account && <div className="mt-2 text-xs text-stone">{notification.account}</div>}
              </div>
              <div className="flex shrink-0 flex-col items-end gap-2">
                <span className="rounded bg-panel/70 px-2 py-0.5 text-xs text-stone">{notification.severity === "critical" ? "严重" : notification.severity === "warning" ? "提醒" : "信息"}</span>
                {notification.status === "unread" && <Button variant="link" size="xs" className="h-auto px-0 text-stone" onClick={() => void updateStatus([notification.id], "read")}>标为已读</Button>}
                {notification.status === "read" && <Button variant="link" size="xs" className="h-auto px-0 text-stone" onClick={() => void updateStatus([notification.id], "unread")}>标为未读</Button>}
                {notification.status !== "dismissed" && <Button variant="link" size="xs" className="h-auto px-0 text-stone" onClick={() => void updateStatus([notification.id], "dismissed")}>忽略</Button>}
                {notification.status === "dismissed" && <Button variant="link" size="xs" className="h-auto px-0 text-stone" onClick={() => void updateStatus([notification.id], "unread")}>恢复</Button>}
              </div>
            </div>
          </div>;
        })}
      </div>
  </MobileSheet>;
}
