import type { HomePagePreference, LedgerPage } from "./types";

export function pageFromPathname(pathname: string, homePage: HomePagePreference = "agent"): LedgerPage {
  if (pathname === "/") return homePage === "overview" ? "home" : "agent";
  if (pathname.startsWith("/agent")) return "agent";
  if (pathname.startsWith("/home")) return "home";
  if (pathname.startsWith("/dashboard")) return "dashboard";
  if (pathname.startsWith("/query")) return "query";
  if (pathname.startsWith("/advice")) return "advice";
  if (pathname.startsWith("/net-worth")) return "net-worth";
  if (pathname.startsWith("/investments")) return "investments";
  if (pathname.startsWith("/transactions")) return "transactions";
  if (pathname.startsWith("/imports")) return "imports";
  if (pathname.startsWith("/editor")) return "editor";
  if (pathname.startsWith("/reconcile")) return "reconcile";
  if (pathname.startsWith("/settings")) return "settings";
  if (pathname.startsWith("/income-statement")) return "income-statement";
  if (pathname.startsWith("/currencies")) return "currencies";
  if (pathname.startsWith("/accounts")) return "accounts";
  return "agent";
}
