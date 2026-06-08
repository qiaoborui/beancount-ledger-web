import { useCallback, useEffect, useRef } from "react";
import { ledgerBeforeNavigateEvent } from "@/lib/browserRouter";
import { getLedgerScrollTop, scrollLedgerTo } from "@/lib/scrollTarget";

const scrollPositions = new Map<string, number>();

export function useRouteScrollMemory(routeKey: string) {
  const currentKeyRef = useRef(routeKey);
  const navigationSavedKeyRef = useRef<string | null>(null);

  const saveCurrentPosition = useCallback(() => {
    scrollPositions.set(currentKeyRef.current, getLedgerScrollTop());
  }, []);

  useEffect(() => {
    const previousKey = currentKeyRef.current;
    if (navigationSavedKeyRef.current !== previousKey) {
      scrollPositions.set(previousKey, getLedgerScrollTop());
    }
    navigationSavedKeyRef.current = null;
    currentKeyRef.current = routeKey;

    const y = scrollPositions.get(routeKey) ?? 0;
    const id = window.requestAnimationFrame(() => scrollLedgerTo(y, "instant"));
    return () => window.cancelAnimationFrame(id);
  }, [routeKey]);

  useEffect(() => {
    const saveBeforeNavigate = () => {
      saveCurrentPosition();
      navigationSavedKeyRef.current = currentKeyRef.current;
    };
    window.addEventListener("pagehide", saveCurrentPosition);
    window.addEventListener(ledgerBeforeNavigateEvent, saveBeforeNavigate);
    return () => {
      saveCurrentPosition();
      window.removeEventListener("pagehide", saveCurrentPosition);
      window.removeEventListener(ledgerBeforeNavigateEvent, saveBeforeNavigate);
    };
  }, [saveCurrentPosition]);

  const scrollToTop = useCallback((key = routeKey) => {
    scrollPositions.set(key, 0);
    scrollLedgerTo(0, "smooth");
  }, [routeKey]);

  return { getScrollTop: getLedgerScrollTop, scrollToTop };
}
