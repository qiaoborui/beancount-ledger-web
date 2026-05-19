import { useEffect, useState } from "react";

export function useLedgerLock({ passkeyRegistered, authed }: { passkeyRegistered: boolean; authed: boolean | null }) {
  const [unlocked, setUnlocked] = useState(() => typeof window !== "undefined" && sessionStorage.getItem("ledger_unlocked") === "1");

  useEffect(() => {
    const lockAfterMs = 5 * 60 * 1000;
    const lockedAtKey = "ledger_locked_at";
    const hiddenAtKey = "ledger_hidden_at";

    function shouldUseLock() {
      return passkeyRegistered && authed;
    }

    function lock() {
      sessionStorage.setItem(lockedAtKey, String(Date.now()));
      sessionStorage.removeItem("ledger_unlocked");
      setUnlocked(false);
    }

    function handleVisibilityChange() {
      if (!shouldUseLock()) return;
      if (document.visibilityState === "hidden") {
        sessionStorage.setItem(hiddenAtKey, String(Date.now()));
        return;
      }
      const hiddenAt = Number(sessionStorage.getItem(hiddenAtKey) || 0);
      if (hiddenAt && Date.now() - hiddenAt > lockAfterMs) lock();
    }

    function handlePageHide() {
      if (!shouldUseLock()) return;
      // Mobile browser/PWA edge gestures and bfcache transitions can emit pagehide
      // during ordinary in-app navigation. Record hidden time, but let pageshow
      // apply the same 5-minute timeout policy instead of immediately relocking.
      sessionStorage.setItem(hiddenAtKey, String(Date.now()));
    }

    function handlePageShow() {
      if (!shouldUseLock()) return;
      const lockedAt = Number(sessionStorage.getItem(lockedAtKey) || 0);
      const hiddenAt = Number(sessionStorage.getItem(hiddenAtKey) || 0);
      if (lockedAt || (hiddenAt && Date.now() - hiddenAt > lockAfterMs)) {
        sessionStorage.removeItem("ledger_unlocked");
        setUnlocked(false);
      } else if (sessionStorage.getItem("ledger_unlocked") === "1") {
        setUnlocked(true);
      }
    }

    document.addEventListener("visibilitychange", handleVisibilityChange);
    window.addEventListener("pagehide", handlePageHide);
    window.addEventListener("pageshow", handlePageShow);
    return () => {
      document.removeEventListener("visibilitychange", handleVisibilityChange);
      window.removeEventListener("pagehide", handlePageHide);
      window.removeEventListener("pageshow", handlePageShow);
    };
  }, [passkeyRegistered, authed]);

  return { unlocked, setUnlocked };
}
