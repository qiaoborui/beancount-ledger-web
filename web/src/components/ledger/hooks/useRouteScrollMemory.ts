import { useCallback, useEffect, useRef } from "react";

const scrollPositions = new Map<string, number>();

export function useRouteScrollMemory(routeKey: string) {
  const currentKeyRef = useRef(routeKey);

  useEffect(() => {
    const previousKey = currentKeyRef.current;
    scrollPositions.set(previousKey, window.scrollY);
    currentKeyRef.current = routeKey;

    const y = scrollPositions.get(routeKey) ?? 0;
    const id = window.requestAnimationFrame(() => window.scrollTo({ top: y, behavior: "instant" }));
    return () => window.cancelAnimationFrame(id);
  }, [routeKey]);

  useEffect(() => {
    const save = () => scrollPositions.set(currentKeyRef.current, window.scrollY);
    window.addEventListener("pagehide", save);
    return () => {
      save();
      window.removeEventListener("pagehide", save);
    };
  }, []);

  const scrollToTop = useCallback((key = routeKey) => {
    scrollPositions.set(key, 0);
    window.scrollTo({ top: 0, behavior: "smooth" });
  }, [routeKey]);

  return { scrollToTop };
}
