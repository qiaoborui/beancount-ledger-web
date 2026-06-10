import { startTransition, useCallback, useEffect, useMemo, useState } from "react";
import { scrollLedgerTo } from "./scrollTarget";

type NavigateOptions = { scroll?: boolean };

export const ledgerBeforeNavigateEvent = "ledger-before-navigate";

function emitLocationChange() {
  startTransition(() => {
    window.dispatchEvent(new PopStateEvent("popstate"));
  });
}

export function navigate(href: string, replace = false, options?: NavigateOptions) {
  window.dispatchEvent(new Event(ledgerBeforeNavigateEvent));
  if (replace) window.history.replaceState(null, "", href);
  else window.history.pushState(null, "", href);
  if (options?.scroll !== false) scrollLedgerTo(0);
  emitLocationChange();
}

export function useBrowserLocation() {
  const read = useCallback(() => ({ pathname: window.location.pathname, search: window.location.search }), []);
  const [location, setLocation] = useState(read);

  useEffect(() => {
    const onPopState = () => setLocation(read());
    window.addEventListener("popstate", onPopState);
    return () => window.removeEventListener("popstate", onPopState);
  }, [read]);

  return location;
}

export function useBrowserRouter() {
  return useMemo(() => ({
    push: (href: string, options?: NavigateOptions) => navigate(href, false, options),
    replace: (href: string, options?: NavigateOptions) => navigate(href, true, options),
  }), []);
}
