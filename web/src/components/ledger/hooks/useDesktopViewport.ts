import { useEffect, useState } from "react";

const desktopViewportQuery = "(min-width: 768px)";

function matchesDesktopViewport() {
  return typeof window !== "undefined"
    && typeof window.matchMedia === "function"
    && window.matchMedia(desktopViewportQuery).matches;
}

export function useDesktopViewport() {
  const [desktop, setDesktop] = useState(matchesDesktopViewport);

  useEffect(() => {
    if (typeof window.matchMedia !== "function") return;
    const media = window.matchMedia(desktopViewportQuery);
    const update = () => setDesktop(media.matches);
    update();
    media.addEventListener("change", update);
    return () => media.removeEventListener("change", update);
  }, []);

  return desktop;
}
