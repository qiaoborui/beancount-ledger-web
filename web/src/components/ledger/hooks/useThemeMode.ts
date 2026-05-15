import { useEffect, useState } from "react";
import { readThemeMode, writeThemeMode } from "../storage";
import type { ResolvedTheme, ThemeMode } from "../types";

const darkQuery = "(prefers-color-scheme: dark)";

function getSystemTheme(): ResolvedTheme {
  if (typeof window === "undefined") return "light";
  return window.matchMedia(darkQuery).matches ? "dark" : "light";
}

function resolveTheme(mode: ThemeMode): ResolvedTheme {
  return mode === "system" ? getSystemTheme() : mode;
}

function applyTheme(theme: ResolvedTheme) {
  if (typeof document === "undefined") return;
  const root = document.documentElement;
  root.dataset.theme = theme;
  root.style.colorScheme = theme;
  document.querySelector<HTMLMetaElement>('meta[name="theme-color"]')?.setAttribute("content", theme === "dark" ? "#0f172a" : "#1B365D");
}

export function useThemeMode() {
  const [themeMode, setThemeModeState] = useState<ThemeMode>(() => readThemeMode());
  const [resolvedTheme, setResolvedTheme] = useState<ResolvedTheme>(() => resolveTheme(readThemeMode()));

  useEffect(() => {
    const media = window.matchMedia(darkQuery);

    function sync() {
      const next = resolveTheme(themeMode);
      setResolvedTheme(next);
      applyTheme(next);
    }

    sync();
    media.addEventListener("change", sync);
    return () => media.removeEventListener("change", sync);
  }, [themeMode]);

  function setThemeMode(mode: ThemeMode) {
    writeThemeMode(mode);
    setThemeModeState(mode);
    const next = resolveTheme(mode);
    setResolvedTheme(next);
    applyTheme(next);
  }

  return { themeMode, resolvedTheme, setThemeMode };
}
