import { useState } from "react";

export function usePullToRefresh(refresh: () => void | Promise<void>) {
  const [pullStartY, setPullStartY] = useState<number | null>(null);

  function handleTouchStart(event: React.TouchEvent) {
    if (window.scrollY <= 0) setPullStartY(event.touches[0].clientY);
  }

  function handleTouchEnd(event: React.TouchEvent) {
    if (pullStartY == null) return;
    const distance = event.changedTouches[0].clientY - pullStartY;
    setPullStartY(null);
    if (window.scrollY <= 0 && distance > 80) refresh();
  }

  return { handleTouchStart, handleTouchEnd };
}
