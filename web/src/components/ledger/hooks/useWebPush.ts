import { useCallback, useEffect, useState } from "react";

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

export function useWebPush(showToast: (kind: "info" | "success" | "error", text: string) => void) {
  const [state, setState] = useState<WebPushState>({ supported: false, permission: "unsupported", subscribed: false, configured: false, loading: true, error: "" });

  const refresh = useCallback(async () => {
    const supported = typeof window !== "undefined" && "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
    if (!supported) {
      setState({ supported: false, permission: "unsupported", subscribed: false, configured: false, loading: false, error: "当前浏览器不支持 Web Push" });
      return;
    }

    try {
      const [configRes, registration] = await Promise.all([
        fetch("/api/push/subscription"),
        navigator.serviceWorker.ready,
      ]);
      const config = await configRes.json();
      const subscription = await registration.pushManager.getSubscription();
      setState({ supported: true, permission: Notification.permission, subscribed: Boolean(subscription), configured: Boolean(config.configured && config.publicKey), loading: false, error: config.configured ? "" : "Web Push 尚未配置 VAPID keys" });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setState((current) => ({ ...current, supported: true, permission: Notification.permission, loading: false, error: message }));
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const subscribe = useCallback(async () => {
    setState((current) => ({ ...current, loading: true, error: "" }));
    try {
      const configRes = await fetch("/api/push/subscription");
      const config = await configRes.json();
      if (!configRes.ok) throw new Error(config.error || "读取 Web Push 配置失败");
      if (!config.publicKey || !config.configured) throw new Error("Web Push 尚未配置 VAPID keys");

      const permission = await Notification.requestPermission();
      if (permission !== "granted") throw new Error("通知权限未开启");

      const registration = await navigator.serviceWorker.ready;
      const existing = await registration.pushManager.getSubscription();
      const subscription = existing ?? await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(config.publicKey),
      });

      const res = await fetch("/api/push/subscription", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ subscription: subscription.toJSON() }) });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || "保存订阅失败");
      showToast("success", "Web Push 已开启");
      await refresh();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setState((current) => ({ ...current, loading: false, error: message }));
      showToast("error", message || "开启 Web Push 失败");
    }
  }, [refresh, showToast]);

  const unsubscribe = useCallback(async () => {
    setState((current) => ({ ...current, loading: true, error: "" }));
    try {
      const registration = await navigator.serviceWorker.ready;
      const subscription = await registration.pushManager.getSubscription();
      if (subscription) {
        await fetch("/api/push/subscription", { method: "DELETE", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ endpoint: subscription.endpoint }) });
        await subscription.unsubscribe();
      }
      showToast("success", "Web Push 已关闭");
      await refresh();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setState((current) => ({ ...current, loading: false, error: message }));
      showToast("error", message || "关闭 Web Push 失败");
    }
  }, [refresh, showToast]);

  const sendTest = useCallback(async () => {
    setState((current) => ({ ...current, loading: true, error: "" }));
    try {
      const res = await fetch("/api/push/subscription", { method: "PUT" });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || "测试通知发送失败");
      showToast("success", `测试通知已发送：${data.sent}/${data.attempted}`);
      await refresh();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setState((current) => ({ ...current, loading: false, error: message }));
      showToast("error", message || "测试通知发送失败");
    }
  }, [refresh, showToast]);

  return { state, refresh, subscribe, unsubscribe, sendTest };
}
