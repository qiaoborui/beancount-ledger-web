"use client";

import { useEffect, useState } from "react";

export function PwaRegister() {
  const [updateReady, setUpdateReady] = useState(false);

  useEffect(() => {
    if (!("serviceWorker" in navigator)) return;

    let registrationRef: ServiceWorkerRegistration | null = null;
    let reloaded = false;
    let checkInterval: number | undefined;

    const onControllerChange = () => {
      if (reloaded) return;
      reloaded = true;
      window.location.reload();
    };

    const markUpdateReady = (registration: ServiceWorkerRegistration) => {
      if (registration.waiting && navigator.serviceWorker.controller) setUpdateReady(true);
    };

    const checkForUpdate = () => {
      if (document.visibilityState !== "visible") return;
      registrationRef?.update().catch((error) => {
        console.warn("Service worker update check failed", error);
      });
    };

    const registerServiceWorker = () => {
      navigator.serviceWorker.register("/sw.js", { updateViaCache: "none" }).then((registration) => {
        registrationRef = registration;
        markUpdateReady(registration);
        registration.addEventListener("updatefound", () => {
          const worker = registration.installing;
          if (!worker) return;
          worker.addEventListener("statechange", () => {
            if (worker.state === "installed" && navigator.serviceWorker.controller) setUpdateReady(true);
          });
        });
      }).catch((error) => {
        console.warn("Service worker registration failed", error);
      });
    };

    if (document.readyState === "complete") {
      registerServiceWorker();
    } else {
      window.addEventListener("load", registerServiceWorker);
    }
    document.addEventListener("visibilitychange", checkForUpdate);
    navigator.serviceWorker.addEventListener("controllerchange", onControllerChange);
    checkInterval = window.setInterval(checkForUpdate, 60 * 60 * 1000);

    return () => {
      window.removeEventListener("load", registerServiceWorker);
      document.removeEventListener("visibilitychange", checkForUpdate);
      navigator.serviceWorker.removeEventListener("controllerchange", onControllerChange);
      if (checkInterval) window.clearInterval(checkInterval);
    };
  }, []);

  const activateUpdate = async () => {
    const registration = await navigator.serviceWorker.getRegistration();
    const waiting = registration?.waiting;
    if (!waiting) {
      window.location.reload();
      return;
    }
    waiting.postMessage({ type: "SKIP_WAITING" });
  };

  if (!updateReady) return null;

  return <div className="fixed inset-x-4 bottom-[calc(5.75rem+env(safe-area-inset-bottom))] z-[120] mx-auto flex max-w-md items-center justify-between gap-3 rounded-2xl border border-line bg-panel/95 px-4 py-3 text-sm text-olive shadow-lg backdrop-blur md:bottom-4">
    <span>有新版本可用</span>
    <button className="rounded-xl bg-brand px-3 py-1.5 text-paper" onClick={activateUpdate}>刷新更新</button>
  </div>;
}
