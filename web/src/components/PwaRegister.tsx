"use client";

import { useEffect, useRef, useState } from "react";
import { haptic } from "./ledger/haptics";
import { shouldShowServiceWorkerUpdate } from "./pwaUpdate";

type WindowControlsOverlay = {
  visible: boolean;
  addEventListener: (type: "geometrychange", listener: () => void) => void;
  removeEventListener: (type: "geometrychange", listener: () => void) => void;
};

type NavigatorWithPwaChrome = Navigator & {
  standalone?: boolean;
  userAgentData?: { platform?: string };
  windowControlsOverlay?: WindowControlsOverlay;
};

function isMacDesktopPwaPlatform(navigatorLike: NavigatorWithPwaChrome) {
  const platform = navigatorLike.userAgentData?.platform || navigatorLike.platform || "";
  const userAgent = navigatorLike.userAgent || "";
  const touchPoints = navigatorLike.maxTouchPoints || 0;
  return /mac/i.test(platform) && !/iphone|ipad|ipod/i.test(userAgent) && touchPoints < 2;
}

export function PwaRegister() {
  const [updateReady, setUpdateReady] = useState(false);
  const dismissedWaitingRef = useRef<ServiceWorker | null>(null);

  useEffect(() => {
    const media = window.matchMedia("(display-mode: standalone)");
    const navigatorWithChrome = navigator as NavigatorWithPwaChrome;
    const overlay = navigatorWithChrome.windowControlsOverlay;
    const updateDisplayMode = () => {
      const standalone = media.matches || Boolean(navigatorWithChrome.standalone);
      document.documentElement.dataset.displayMode = standalone ? "standalone" : "browser";
      document.documentElement.dataset.desktopPlatform = isMacDesktopPwaPlatform(navigatorWithChrome) ? "macos" : "other";
      document.documentElement.dataset.windowControlsOverlay = overlay ? (overlay.visible ? "visible" : "hidden") : "unsupported";
    };
    updateDisplayMode();
    media.addEventListener("change", updateDisplayMode);
    overlay?.addEventListener("geometrychange", updateDisplayMode);
    return () => {
      media.removeEventListener("change", updateDisplayMode);
      overlay?.removeEventListener("geometrychange", updateDisplayMode);
    };
  }, []);

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
      setUpdateReady(shouldShowServiceWorkerUpdate(registration.waiting, navigator.serviceWorker.controller, dismissedWaitingRef.current));
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
            if (worker.state === "installed") markUpdateReady(registration);
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
    haptic(8);
    const registration = await navigator.serviceWorker.getRegistration();
    const waiting = registration?.waiting;
    if (!waiting) {
      setUpdateReady(false);
      await registration?.update().catch((error) => {
        console.warn("Service worker update check failed", error);
      });
      return;
    }
    dismissedWaitingRef.current = waiting;
    setUpdateReady(false);
    waiting.postMessage({ type: "SKIP_WAITING" });
  };

  if (!updateReady) return null;

  return <div className="fixed inset-x-4 bottom-[calc(5.75rem+env(safe-area-inset-bottom))] z-[120] mx-auto flex max-w-md items-center justify-between gap-3 rounded-2xl border border-line bg-panel/95 px-4 py-3 text-sm text-olive shadow-lg backdrop-blur md:bottom-4">
    <span>有新版本可用</span>
    <button className="rounded-xl bg-brand px-3 py-1.5 text-paper" onClick={activateUpdate}>刷新更新</button>
  </div>;
}
