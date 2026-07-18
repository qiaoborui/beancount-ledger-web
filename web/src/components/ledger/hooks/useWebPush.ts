import { useCallback, useEffect, useState } from "react";
import { readJson } from "@/lib/clientFetch";
import { apiFetch } from "@/lib/apiEndpoints";

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
    return { status: "正在检查", description: "正在读取当前浏览器的通知权限和设备订阅。", tone: "muted", toggleDisabled: true, testAvailable: false };
  }
  if (!state.supported) {
    return { status: "当前浏览器不支持", description: "请使用支持 Service Worker 和 Web Push 的浏览器；iPhone 与 iPad 建议先将应用添加到主屏幕。", tone: "warning", toggleDisabled: true, testAvailable: false };
  }
  if (!state.configured) {
    return { status: "服务端待配置", description: "管理员需要配置 VAPID keys，配置完成后即可为当前设备开启通知。", tone: "warning", toggleDisabled: true, testAvailable: false };
  }
  if (state.permission === "denied") {
    return { status: "浏览器已阻止", description: "请从地址栏左侧的站点设置中把“通知”改为“允许”，然后重新检查。", tone: "warning", toggleDisabled: !state.subscribed, testAvailable: false };
  }
  if (state.subscribed) {
    return { status: "已开启", description: "自动账单处理完成后会向当前设备发送通知。", tone: "success", toggleDisabled: false, testAvailable: true };
  }
  if (state.permission === "granted") {
    return { status: "当前设备未订阅", description: "浏览器权限已经允许，打开开关即可接收自动账单处理通知。", tone: "muted", toggleDisabled: false, testAvailable: false };
  }
  return { status: "等待授权", description: "打开开关后，浏览器会请求一次通知权限。授权只作用于当前浏览器。", tone: "muted", toggleDisabled: false, testAvailable: false };
}

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
        apiFetch("/api/push/subscription", undefined, { kind: "auth" }),
        navigator.serviceWorker.ready,
      ]);
      const config = await readJson<{ error?: string; configured?: boolean; publicKey?: string }>(configRes);
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
      if (permission === "denied") throw new Error("浏览器已阻止通知，请在站点设置中允许后重试");
      if (permission !== "granted") throw new Error("通知权限尚未授权");

      const configRes = await apiFetch("/api/push/subscription", undefined, { kind: "auth" });
      const config = await readJson<{ error?: string; configured?: boolean; publicKey?: string }>(configRes);
      if (!configRes.ok) throw new Error(config.error || "读取 Web Push 配置失败");
      if (!config.publicKey || !config.configured) throw new Error("Web Push 尚未配置 VAPID keys");

      const registration = await navigator.serviceWorker.ready;
      const existing = await registration.pushManager.getSubscription();
      const subscription = existing ?? await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(config.publicKey),
      });

      const res = await apiFetch("/api/push/subscription", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ subscription: subscription.toJSON() }) }, { kind: "write" });
      const data = await readJson<{ error?: string }>(res);
      if (!res.ok) throw new Error(data.error || "保存订阅失败");
      showToast("success", "Web Push 已开启");
      await refresh();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setState((current) => ({ ...current, permission: Notification.permission, loading: false, error: message }));
      showToast("error", message || "开启 Web Push 失败");
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
        if (!res.ok) throw new Error(data.error || "删除 Web Push 订阅失败");
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
      const res = await apiFetch("/api/push/subscription", { method: "PUT" }, { kind: "write" });
      const data = await readJson<{ error?: string; sent?: number; attempted?: number }>(res);
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
