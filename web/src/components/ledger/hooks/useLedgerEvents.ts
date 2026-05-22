import { useEffect, useRef } from "react";
import type { GitChange } from "../GitSaveModal";
import type { LedgerVersion } from "../types";

type RealtimeEvent = {
  type: string;
  at: string;
  data?: unknown;
};

type LedgerUpdatedPayload = {
  source?: string;
  version?: LedgerVersion;
};

type GitStatusPayload = {
  source?: string;
  status?: string;
  dirty?: boolean;
  changedFileCount?: number;
  changes?: GitChange[];
  error?: string;
};

type JobStatusPayload = {
  name?: string;
  status?: "running" | "ok" | "error";
  message?: string;
};

type NotificationsUpdatedPayload = {
  source?: string;
  unreadCount?: number;
  createdCount?: number;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function eventWebSocketURL() {
  const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
  return `${protocol}//${window.location.host}/api/events/ws`;
}

function readPayload<T>(value: unknown): T {
  return isRecord(value) ? value as T : {} as T;
}

export function useLedgerEvents({
  enabled,
  onLedgerUpdated,
  onGitStatus,
  onJobStatus,
  onNotificationsUpdated,
  showToast,
}: {
  enabled: boolean;
  onLedgerUpdated: (payload: LedgerUpdatedPayload) => void | Promise<void>;
  onGitStatus: (payload: GitStatusPayload) => void;
  onJobStatus?: (payload: JobStatusPayload) => void;
  onNotificationsUpdated?: (payload: NotificationsUpdatedPayload) => void;
  showToast: (kind: "info" | "success" | "error", text: string) => void;
}) {
  const handlersRef = useRef({ onLedgerUpdated, onGitStatus, onJobStatus, onNotificationsUpdated, showToast });
  handlersRef.current = { onLedgerUpdated, onGitStatus, onJobStatus, onNotificationsUpdated, showToast };

  useEffect(() => {
    if (!enabled || typeof window === "undefined") return;
    let socket: WebSocket | null = null;
    let closed = false;
    let reconnectTimer: number | null = null;
    let reconnectAttempt = 0;

    const scheduleReconnect = () => {
      if (closed) return;
      const delay = Math.min(30_000, 800 * 2 ** reconnectAttempt);
      reconnectAttempt += 1;
      reconnectTimer = window.setTimeout(connect, delay);
    };

    const connect = () => {
      if (closed) return;
      socket = new WebSocket(eventWebSocketURL());
      socket.addEventListener("open", () => {
        reconnectAttempt = 0;
      });
      socket.addEventListener("message", (event) => {
        let parsed: RealtimeEvent | null = null;
        try {
          parsed = JSON.parse(String(event.data)) as RealtimeEvent;
        } catch {
          return;
        }
        if (!parsed || typeof parsed.type !== "string") return;
        const handlers = handlersRef.current;
        if (parsed.type === "ledger.updated") {
          void handlers.onLedgerUpdated(readPayload<LedgerUpdatedPayload>(parsed.data));
          return;
        }
        if (parsed.type === "git.status") {
          const payload = readPayload<GitStatusPayload>(parsed.data);
          if (payload.error) {
            handlers.showToast("error", `读取 Git 状态失败：${payload.error}`);
            return;
          }
          handlers.onGitStatus(payload);
          return;
        }
        if (parsed.type === "job.status") {
          handlers.onJobStatus?.(readPayload<JobStatusPayload>(parsed.data));
          return;
        }
        if (parsed.type === "notifications.updated") {
          handlers.onNotificationsUpdated?.(readPayload<NotificationsUpdatedPayload>(parsed.data));
        }
      });
      socket.addEventListener("close", scheduleReconnect);
      socket.addEventListener("error", () => {
        socket?.close();
      });
    };

    connect();
    return () => {
      closed = true;
      if (reconnectTimer) window.clearTimeout(reconnectTimer);
      socket?.close();
    };
  }, [enabled]);
}
