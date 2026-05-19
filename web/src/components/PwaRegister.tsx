"use client";

import { useEffect, useState } from "react";
import { haptic } from "./ledger/haptics";

export function PwaRegister() {
  const [updateReady, setUpdateReady] = useState(false);

  useEffect(() => {
    const media = window.matchMedia("(display-mode: standalone)");
    const updateDisplayMode = () => {
      const standalone = media.matches || Boolean((navigator as Navigator & { standalone?: boolean }).standalone);
      document.documentElement.dataset.displayMode = standalone ? "standalone" : "browser";
    };
    updateDisplayMode();
    media.addEventListener("change", updateDisplayMode);
    return () => media.removeEventListener("change", updateDisplayMode);
  }, []);

  useEffect(() => {
    if (!("serviceWorker" in navigator)) return;

    let registrationRef: ServiceWorkerRegistration | null = null;
    const onControllerChange = () => window.location.reload();

    const markUpdateReady = (registration: ServiceWorkerRegistration) => {
      if (registration.waiting && navigator.serviceWorker.controller) setUpdateReady(true);
    };

    window.addEventListener("load", () => {
      navigator.serviceWorker.register("/sw.js").then((registration) => {
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
    });

    navigator.serviceWorker.addEventListener("controllerchange", onControllerChange);
    return () => navigator.serviceWorker.removeEventListener("controllerchange", onControllerChange);
  }, []);

  const activateUpdate = async () => {
    haptic(8);
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
