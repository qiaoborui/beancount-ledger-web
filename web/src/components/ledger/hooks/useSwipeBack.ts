import { useEffect } from "react";

type SwipeBackOptions = {
  enabled: boolean;
  onBack: () => void;
  edgeStart?: number;
  edgeWidth?: number;
  threshold?: number;
  intentThreshold?: number;
};

export function useSwipeBack({ enabled, onBack, edgeStart = 32, edgeWidth = 72, threshold = 82, intentThreshold = 14 }: SwipeBackOptions) {
  useEffect(() => {
    if (!enabled) return;
    let startX = 0;
    let startY = 0;
    let tracking = false;
    let triggered = false;

    const onTouchStart = (event: TouchEvent) => {
      const touch = event.touches[0];
      if (!touch || touch.clientX < edgeStart || touch.clientX > edgeStart + edgeWidth) return;
      startX = touch.clientX;
      startY = touch.clientY;
      tracking = true;
      triggered = false;
    };

    const onTouchMove = (event: TouchEvent) => {
      if (!tracking || triggered) return;
      const touch = event.touches[0];
      if (!touch) return;
      const dx = touch.clientX - startX;
      const dy = Math.abs(touch.clientY - startY);
      if (dx < -8) {
        tracking = false;
        return;
      }
      if (dy > 42 && dy > dx) {
        tracking = false;
        return;
      }
      if (dx > intentThreshold && dx > dy * 1.15 && event.cancelable) {
        event.preventDefault();
      }
      if (dx > threshold && dy < 56) {
        triggered = true;
        tracking = false;
        if (event.cancelable) event.preventDefault();
        onBack();
      }
    };

    const onTouchEnd = () => {
      tracking = false;
      triggered = false;
    };

    window.addEventListener("touchstart", onTouchStart, { passive: true });
    window.addEventListener("touchmove", onTouchMove, { passive: false });
    window.addEventListener("touchend", onTouchEnd, { passive: true });
    window.addEventListener("touchcancel", onTouchEnd, { passive: true });
    return () => {
      window.removeEventListener("touchstart", onTouchStart);
      window.removeEventListener("touchmove", onTouchMove);
      window.removeEventListener("touchend", onTouchEnd);
      window.removeEventListener("touchcancel", onTouchEnd);
    };
  }, [edgeStart, edgeWidth, enabled, intentThreshold, onBack, threshold]);
}
