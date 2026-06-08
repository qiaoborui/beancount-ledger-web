const ledgerMainScrollSelector = "[data-ledger-main-scroll]";

function usesMainScrollContainer() {
  return typeof window !== "undefined" && window.matchMedia("(min-width: 768px)").matches;
}

export function getLedgerMainScrollElement() {
  if (typeof document === "undefined" || !usesMainScrollContainer()) return null;
  return document.querySelector<HTMLElement>(ledgerMainScrollSelector);
}

export function getLedgerScrollTop() {
  if (typeof document === "undefined" || typeof window === "undefined") return 0;
  const element = getLedgerMainScrollElement();
  return element ? element.scrollTop : (document.scrollingElement?.scrollTop ?? window.scrollY);
}

export function scrollLedgerTo(top: number, behavior: ScrollBehavior = "auto") {
  if (typeof window === "undefined") return;
  const element = getLedgerMainScrollElement();
  if (element) {
    element.scrollTo({ top, left: 0, behavior });
    return;
  }
  window.scrollTo({ top, left: 0, behavior });
}
