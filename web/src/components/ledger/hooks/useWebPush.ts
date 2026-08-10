import { useCallback, useEffect, useState } from "react";
import { readJson } from "@/lib/clientFetch";
import { apiFetch } from "@/lib/apiEndpoints";
import i18n from "@/i18n";

function urlBase64ToUint8Array(base64String: string) {
  const padding = "=".repeat((4 - base64String.length % 4) % 4);
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/");
  const rawData = window.atob(base64);
  return Uint8Array.from([...rawData].map((char) => char.charCodeAt(0)));
}

export type WebPushState = {
  supported: boolean;
  permission: NotificationPermission | "unsupported";
  subscribed: boolean;
  configured: boolean;
  loading: boolean;
  error: string;
};

export type WebPushPresentation = {
  status: string;
  description: string;
  tone: "success" | "warning" | "muted";
  toggleDisabled: boolean;
  testAvailable: boolean;
};

export function getWebPushPresentation(state: WebPushState): WebPushPresentation {
  if (state.loading) {
    return { status: i18n.t("webPush.checking"), description: i18n.t("webPush.checkingDesc"), tone: "muted", toggleDisabled: true, testAvailable: false };
  }
  if (!state.supported) {
    return { status: i18n.t("webPush.unsupported"), description: i18n.t("webPush.unsupportedDesc"), tone: "warning", toggleDisabled: true, testAvailable: false };
  }
  if (!state.configured) {
    return { status: i18n.t("webPush.serverPending"), description: i18n.t("webPush.serverPendingDesc"), tone: "warning", toggleDisabled: true, testAvailable: false };
  }
  if (state.permission === "denied") {
    return { status: i18n.t("webPush.blocked"), description: i18n.t("webPush.blockedDesc"), tone: "warning", toggleDisabled: !state.subscribed, testAvailable: false };
  }
  if (state.subscribed) {
    return { status: i18n.t("webPush.enabled"), description: i18n.t("webPush.enabledDesc"), tone: "success", toggleDisabled: false, testAvailable: true };
  }
  if (state.permission === "granted") {
    return { status: i18n.t("webPush.notSubscribed"), description: i18n.t("webPush.notSubscribedDesc"), tone: "muted", toggleDisabled: false, testAvailable: false };
  }
  return { status: i18n.t("webPush.awaitingPermission"), description: i18n.t("webPush.awaitingPermissionDesc"), tone: "muted", toggleDisabled: false, testAvailable: false };
}

export function useWebPush(showToast: (kind: "info" | "success" | "error", text: string) => void) {
  const [state, setState] = useState<WebPushState>({ supported: false, permission: "unsupported", subscribed: false, configured: false, loading: true, error: "" });

  const refresh = useCallback(async () => {
    const supported = typeof window !== "undefined" && "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
    if (!supported) {
      setState({ supported: false, permission: "unsupported", subscribed: false, configured: false, loading: false, error: i18n.t("webPush.unsupportedError") });
      return;
    }

    try {
      const [configRes, registration] = await Promise.all([
        apiFetch("/api/push/subscription", undefined, { kind: "auth" }),
        navigator.serviceWorker.ready,
      ]);
      const config = await readJson<{ error?: string; configured?: boolean; publicKey?: string }>(configRes);
      const subscription = await registration.pushManager.getSubscription();
      setState({ supported: true, permission: Notification.permission, subscribed: Boolean(subscription), configured: Boolean(config.configured && config.publicKey), loading: false, error: config.configured ? "" : i18n.t("webPush.notConfigured") });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setState((current) => ({ ...current, supported: true, permission: Notification.permission, loading: false, error: message }));
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  useEffect(() => {
    const refreshOnFocus = () => void refresh();
    const refreshWhenVisible = () => {
      if (document.visibilityState === "visible") void refresh();
    };
    window.addEventListener("focus", refreshOnFocus);
    document.addEventListener("visibilitychange", refreshWhenVisible);
    return () => {
      window.removeEventListener("focus", refreshOnFocus);
      document.removeEventListener("visibilitychange", refreshWhenVisible);
    };
  }, [refresh]);

  const subscribe = useCallback(async () => {
    setState((current) => ({ ...current, loading: true, error: "" }));
    try {
      const permission = await Notification.requestPermission();
      if (permission === "denied") throw new Error(i18n.t("webPush.permissionDenied"));
      if (permission !== "granted") throw new Error(i18n.t("webPush.permissionNotGranted"));

      const configRes = await apiFetch("/api/push/subscription", undefined, { kind: "auth" });
      const config = await readJson<{ error?: string; configured?: boolean; publicKey?: string }>(configRes);
      if (!configRes.ok) throw new Error(config.error || i18n.t("webPush.readConfigFailed"));
      if (!config.publicKey || !config.configured) throw new Error(i18n.t("webPush.notConfigured"));

      const registration = await navigator.serviceWorker.ready;
      const existing = await registration.pushManager.getSubscription();
      const subscription = existing ?? await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(config.publicKey),
      });

      const res = await apiFetch("/api/push/subscription", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ subscription: subscription.toJSON() }) }, { kind: "write" });
      const data = await readJson<{ error?: string }>(res);
      if (!res.ok) throw new Error(data.error || i18n.t("webPush.saveSubscriptionFailed"));
      showToast("success", i18n.t("webPush.enabledToast"));
      await refresh();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setState((current) => ({ ...current, permission: Notification.permission, loading: false, error: message }));
      showToast("error", message || i18n.t("webPush.enableFailed"));
    }
  }, [refresh, showToast]);

  const unsubscribe = useCallback(async () => {
    setState((current) => ({ ...current, loading: true, error: "" }));
    try {
      const registration = await navigator.serviceWorker.ready;
      const subscription = await registration.pushManager.getSubscription();
      if (subscription) {
        const res = await apiFetch("/api/push/subscription", { method: "DELETE", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ endpoint: subscription.endpoint }) }, { kind: "write" });
        const data = await readJson<{ error?: string }>(res);
        if (!res.ok) throw new Error(data.error || i18n.t("webPush.deleteSubscriptionFailed"));
        await subscription.unsubscribe();
      }
      showToast("success", i18n.t("webPush.disabledToast"));
      await refresh();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setState((current) => ({ ...current, loading: false, error: message }));
      showToast("error", message || i18n.t("webPush.disableFailed"));
    }
  }, [refresh, showToast]);

  const sendTest = useCallback(async () => {
    setState((current) => ({ ...current, loading: true, error: "" }));
    try {
      const res = await apiFetch("/api/push/subscription", { method: "PUT" }, { kind: "write" });
      const data = await readJson<{ error?: string; sent?: number; attempted?: number }>(res);
      if (!res.ok) throw new Error(data.error || i18n.t("webPush.testSendFailed"));
      showToast("success", i18n.t("webPush.testSent", { sent: data.sent, attempted: data.attempted }));
      await refresh();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setState((current) => ({ ...current, loading: false, error: message }));
      showToast("error", message || i18n.t("webPush.testSendFailed"));
    }
  }, [refresh, showToast]);

  return { state, refresh, subscribe, unsubscribe, sendTest };
}
