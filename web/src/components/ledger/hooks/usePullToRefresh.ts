import { useMemo, useState } from "react";
import { getLedgerScrollTop } from "@/lib/scrollTarget";
import { haptic } from "../haptics";

const PULL_THRESHOLD = 92;
const MAX_PULL = 128;
const INTERACTIVE_SELECTOR = "button,a,input,textarea,select,[role='button'],[contenteditable='true']";

function isAtPageTop() {
  return getLedgerScrollTop() <= 0;
}

function startedFromInteractiveTarget(target: EventTarget | null) {
  return target instanceof Element && Boolean(target.closest(INTERACTIVE_SELECTOR));
}

export function usePullToRefresh(refresh: () => void | Promise<void>, disabled = false) {
  const [pullStartY, setPullStartY] = useState<number | null>(null);
  const [pullDistance, setPullDistance] = useState(0);
  const [refreshingByGesture, setRefreshingByGesture] = useState(false);

  function handleTouchStart(event: React.TouchEvent) {
    if (disabled || refreshingByGesture) return;
    if (startedFromInteractiveTarget(event.target)) return;
    if (isAtPageTop()) setPullStartY(event.touches[0].clientY);
  }

  function handleTouchMove(event: React.TouchEvent) {
    if (pullStartY == null || disabled) return;
    const rawDistance = event.touches[0].clientY - pullStartY;
    if (rawDistance <= 0 || !isAtPageTop()) {
      setPullDistance(0);
      return;
    }
    setPullDistance(Math.min(MAX_PULL, rawDistance * 0.55));
  }

  async function handleTouchEnd() {
    if (pullStartY == null) return;
    const shouldRefresh = !disabled && isAtPageTop() && pullDistance >= PULL_THRESHOLD;
    setPullStartY(null);
    setPullDistance(0);
    if (!shouldRefresh) return;
    haptic(8);
    setRefreshingByGesture(true);
    try {
      await refresh();
    } finally {
      setRefreshingByGesture(false);
    }
  }

  const pullState = useMemo(() => {
    if (refreshingByGesture) return "refreshing" as const;
    if (pullDistance >= PULL_THRESHOLD) return "release" as const;
    if (pullDistance > 8) return "pull" as const;
    return "idle" as const;
  }, [pullDistance, refreshingByGesture]);

  return { handleTouchStart, handleTouchMove, handleTouchEnd, pullDistance, pullState };
}
