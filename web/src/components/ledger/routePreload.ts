import type { LedgerPage } from "./types";

export const loadDashboardPage = () => import("./DashboardPage");
export const loadBQLQueryPage = () => import("./BQLQueryPage");
export const loadNetWorthPage = () => import("./NetWorthPage");
export const loadInvestmentsPage = () => import("./InvestmentsPage");
export const loadIncomeStatementPage = () => import("./IncomeStatementPage");
export const loadLedgerAgentWorkspace = () => import("./LedgerAgentWorkspace");
export const loadCommandPalette = () => import("./CommandPalette");
export const loadEntryModal = () => import("./EntryModal");
export const loadQuickActionsSheet = () => import("./QuickActionsSheet");
export const loadImportPage = () => import("./ImportPage");
export const loadLedgerEditorPage = () => import("./LedgerEditorPage");
export const loadAccountPanels = () => import("./AccountPanels");
export const loadAccountDetailPage = () => import("./AccountDetailPage");
export const loadCurrencyPage = () => import("./CurrencyPage");
export const loadReconcilePage = () => import("./ReconcilePage");
export const loadSettingsPage = () => import("./SettingsPage");
export const loadTransactionList = () => import("./TransactionList");

const routeLoaders: Partial<Record<LedgerPage, () => Promise<unknown>>> = {
  dashboard: loadDashboardPage,
  query: loadBQLQueryPage,
  "net-worth": loadNetWorthPage,
  investments: loadInvestmentsPage,
  transactions: loadTransactionList,
  accounts: loadAccountPanels,
  imports: loadImportPage,
  editor: loadLedgerEditorPage,
  reconcile: loadReconcilePage,
  settings: loadSettingsPage,
  "income-statement": loadIncomeStatementPage,
  currencies: loadCurrencyPage,
};

const routePreloads = new Map<LedgerPage, Promise<unknown>>();
const accountDetailPreloads = new Map<string, Promise<unknown>>();

function cachedPreload<K extends string>(cache: Map<K, Promise<unknown>>, key: K, load: () => Promise<unknown>, label: string) {
  const existing = cache.get(key);
  if (existing) return existing;
  const preload: Promise<unknown> = load().catch((error) => {
    cache.delete(key);
    console.warn(`${label} preload failed`, error);
  });
  cache.set(key, preload);
  return preload;
}

function runWhenIdle(callback: () => void, timeout = 3000) {
  if (typeof window === "undefined") return;
  if (window.requestIdleCallback) {
    window.requestIdleCallback(callback, { timeout });
    return;
  }
  window.setTimeout(callback, 0);
}

function pageFromHref(href: string): LedgerPage {
  const pathname = (() => {
    try {
      return new URL(href, window.location.origin).pathname;
    } catch {
      return href.split("?")[0] || "/";
    }
  })();
  if (pathname.startsWith("/dashboard")) return "dashboard";
  if (pathname.startsWith("/query")) return "query";
  if (pathname.startsWith("/net-worth")) return "net-worth";
  if (pathname.startsWith("/investments")) return "investments";
  if (pathname.startsWith("/transactions")) return "transactions";
  if (pathname.startsWith("/imports")) return "imports";
  if (pathname.startsWith("/editor")) return "editor";
  if (pathname.startsWith("/reconcile")) return "reconcile";
  if (pathname.startsWith("/settings")) return "settings";
  if (pathname.startsWith("/income-statement")) return "income-statement";
  if (pathname.startsWith("/currencies")) return "currencies";
  if (pathname.startsWith("/accounts/")) return "accounts";
  if (pathname.startsWith("/accounts")) return "accounts";
  return "home";
}

export function preloadLedgerRoute(href: string) {
  if (typeof window === "undefined") return undefined;
  const page = pageFromHref(href);
  const preloads: Promise<unknown>[] = [];
  if (page === "accounts" && href.includes("/accounts/")) {
    preloads.push(cachedPreload(accountDetailPreloads, href, loadAccountDetailPage, "Ledger account detail"));
  }
  const load = routeLoaders[page];
  if (load) preloads.push(cachedPreload(routePreloads, page, load, "Ledger route"));
  if (preloads.length === 0) return undefined;
  if (preloads.length === 1) return preloads[0];
  return Promise.all(preloads);
}

function preloadRoutesIncrementally(hrefs: string[], index = 0) {
  if (index >= hrefs.length) return;
  runWhenIdle(() => {
    preloadLedgerRoute(hrefs[index]);
    window.setTimeout(() => preloadRoutesIncrementally(hrefs, index + 1), 180);
  });
}

export function preloadOfflineCoreRoutes() {
  if (typeof window === "undefined") return;
  const coreRoutes = ["/transactions", "/accounts", "/dashboard", "/query", "/net-worth", "/income-statement", "/settings"];
  const secondaryRoutes = ["/imports", "/reconcile", "/currencies", "/investments", "/editor"];
  preloadRoutesIncrementally(coreRoutes);
  window.setTimeout(() => preloadRoutesIncrementally(secondaryRoutes), 1500);
  void loadEntryModal().catch((error) => {
    console.warn("Ledger entry preload failed", error);
  });
  void loadQuickActionsSheet().catch((error) => {
    console.warn("Ledger quick actions preload failed", error);
  });
}
