import { useEffect, useState } from "react";

export function useClientPathname(initialPathname: string) {
  const [pathname, setPathname] = useState(initialPathname);

  useEffect(() => {
    function updatePathname() {
      setPathname(window.location.pathname);
    }

    const originalPushState = window.history.pushState;
    const originalReplaceState = window.history.replaceState;

    window.history.pushState = function pushState(...args) {
      const result = originalPushState.apply(this, args);
      window.dispatchEvent(new Event("ledger:navigation"));
      return result;
    };

    window.history.replaceState = function replaceState(...args) {
      const result = originalReplaceState.apply(this, args);
      window.dispatchEvent(new Event("ledger:navigation"));
      return result;
    };

    window.addEventListener("popstate", updatePathname);
    window.addEventListener("ledger:navigation", updatePathname);
    return () => {
      window.history.pushState = originalPushState;
      window.history.replaceState = originalReplaceState;
      window.removeEventListener("popstate", updatePathname);
      window.removeEventListener("ledger:navigation", updatePathname);
    };
  }, []);

  return pathname;
}
