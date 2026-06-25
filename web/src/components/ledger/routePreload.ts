import type { LedgerPage } from "./types";

export const loadDashboardPage = () => import("./DashboardPage");
export const loadNetWorthPage = () => import("./NetWorthPage");
export const loadInvestmentsPage = () => import("./InvestmentsPage");
export const loadIncomeStatementPage = () => import("./IncomeStatementPage");
export const loadAiBookkeepingChat = () => import("./AiBookkeepingChat");
export const loadCommandPalette = () => import("./CommandPalette");
export const loadEntryModal = () => import("./EntryModal");
export const loadGitSaveModal = () => import("./GitSaveModal");
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

function pageFromHref(href: string): LedgerPage {
  const pathname = (() => {
    try {
      return new URL(href, window.location.origin).pathname;
    } catch {
      return href.split("?")[0] || "/";
    }
  })();
  if (pathname.startsWith("/dashboard")) return "dashboard";
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
  if (typeof window === "undefined") return;
  const page = pageFromHref(href);
  if (routePreloads.has(page)) return;
  const load = routeLoaders[page];
  if (!load) return;
  routePreloads.set(page, load().catch((error) => {
    routePreloads.delete(page);
    console.warn("Ledger route preload failed", error);
  }));
  if (page === "accounts" && href.includes("/accounts/")) {
    void loadAccountDetailPage().catch((error) => {
      console.warn("Ledger account detail preload failed", error);
    });
  }
}
