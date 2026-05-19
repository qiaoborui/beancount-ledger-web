"use client";

import { BarChart3, BookOpen, ChevronLeft, ChevronRight, GitBranch, Home, Landmark, List, LockKeyhole, Menu, PiggyBank, Plus, Scale, Settings, TrendingUp, UnlockKeyhole, X } from "lucide-react";
import { useEffect, useState, type ReactNode } from "react";
import { ClientNavLink } from "./ledger/ClientNavLink";
import { defaultMobileTabHrefs, readMobileTabHrefs } from "./ledger/storage";
import type { LedgerNavHref } from "./ledger/types";

export const ledgerNavItems: { href: LedgerNavHref; label: string; icon: typeof Home; mobilePrimary: boolean }[] = [
  { href: "/", label: "总览", icon: Home, mobilePrimary: true },
  { href: "/transactions", label: "流水", icon: List, mobilePrimary: true },
  { href: "/accounts", label: "账户", icon: BookOpen, mobilePrimary: true },
  { href: "/budgets", label: "预算", icon: BarChart3, mobilePrimary: false },
  { href: "/net-worth", label: "净资产", icon: Landmark, mobilePrimary: false },
  { href: "/income-statement", label: "损益表", icon: TrendingUp, mobilePrimary: false },
  { href: "/reconcile", label: "对账", icon: Scale, mobilePrimary: false },
  { href: "/settings", label: "设置", icon: Settings, mobilePrimary: false },
];

const sidebarCollapsedKey = "ledger_sidebar_collapsed";

function readSidebarCollapsed() {
  if (typeof window === "undefined") return false;
  return localStorage.getItem(sidebarCollapsedKey) === "1";
}

function writeSidebarCollapsed(collapsed: boolean) {
  if (typeof window === "undefined") return;
  localStorage.setItem(sidebarCollapsedKey, collapsed ? "1" : "0");
}

export function AppShell({ children, pathname, onAdd, onGit, gitDirty, changedFileCount = 0, sensitiveUnlocked = false, passkeyEnabled = false, onUnlockSensitive }: { children: ReactNode; pathname: string; onAdd?: () => void; onGit?: () => void; gitDirty?: boolean; changedFileCount?: number; sensitiveUnlocked?: boolean; passkeyEnabled?: boolean; onUnlockSensitive?: () => void }) {
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false);
  const [sidebarCollapsed, setSidebarCollapsed] = useState(false);
  const [mobileTabHrefs, setMobileTabHrefs] = useState<LedgerNavHref[]>(defaultMobileTabHrefs);

  useEffect(() => {
    setSidebarCollapsed(readSidebarCollapsed());
    setMobileTabHrefs(readMobileTabHrefs());
    const handleMobileTabsChange = () => setMobileTabHrefs(readMobileTabHrefs());
    window.addEventListener("storage", handleMobileTabsChange);
    window.addEventListener("ledger-mobile-tabs-change", handleMobileTabsChange);
    return () => {
      window.removeEventListener("storage", handleMobileTabsChange);
      window.removeEventListener("ledger-mobile-tabs-change", handleMobileTabsChange);
    };
  }, []);

  function toggleSidebarCollapsed() {
    setSidebarCollapsed((current) => {
      const next = !current;
      writeSidebarCollapsed(next);
      return next;
    });
  }

  const mobilePrimaryNav = ledgerNavItems.filter((item) => mobileTabHrefs.includes(item.href));

  return (
    <div className="min-h-dvh bg-paper pt-[calc(4rem+env(safe-area-inset-top))] text-ink">
      <header className="fixed inset-x-0 top-0 z-30 border-b border-line bg-panel/95 pt-[env(safe-area-inset-top)] text-ink backdrop-blur supports-[backdrop-filter]:bg-panel/85">
        <div className="flex h-16 items-center justify-between px-[max(1rem,env(safe-area-inset-left))] pr-[max(1rem,env(safe-area-inset-right))] md:px-6">
          <div className="flex min-w-0 items-center gap-3 md:w-64">
            <button className="rounded-xl border border-line bg-paper p-2 text-brand hover:bg-tag md:hidden" onClick={() => setMobileMenuOpen(true)} aria-label="打开侧边栏">
              <Menu className="h-5 w-5" />
            </button>
            <ClientNavLink href="/" className="flex min-w-0 items-center gap-3 font-serif text-xl font-medium">
              <span className="grid h-10 w-10 shrink-0 place-items-center rounded-2xl bg-brand text-paper"><PiggyBank className="h-5 w-5" /></span>
              <span className="min-w-0">
                <span className="block truncate leading-tight">我的账本</span>
                <span className="block truncate text-[11px] font-normal uppercase tracking-[0.22em] text-stone">private ledger</span>
              </span>
            </ClientNavLink>
          </div>
          <div className="hidden rounded-full border border-line bg-paper px-4 py-2 text-xs tracking-wide text-olive lg:block">资产 + 费用 = 负债 + 所有者权益 + 收入</div>
          <div className="flex items-center gap-2">
            {passkeyEnabled && (
              <button
                type="button"
                onClick={sensitiveUnlocked ? undefined : onUnlockSensitive}
                disabled={sensitiveUnlocked || !onUnlockSensitive}
                className={`rounded-xl border border-line bg-paper px-3 py-2 text-sm ${sensitiveUnlocked ? "cursor-default text-olive" : "text-warm hover:bg-tag"}`}
                aria-label={sensitiveUnlocked ? "敏感数据已解锁" : "解锁敏感数据"}
                aria-pressed={sensitiveUnlocked}
                title={sensitiveUnlocked ? "敏感数据已解锁" : "使用 Face ID / Passkey 解锁敏感数据"}
              >
                {sensitiveUnlocked ? <UnlockKeyhole className="inline h-4 w-4 text-brand" /> : <LockKeyhole className="inline h-4 w-4 text-brand" />} <span className="hidden sm:inline">{sensitiveUnlocked ? "已解锁" : "解锁"}</span>
              </button>
            )}
            <button onClick={onGit} className="relative rounded-xl border border-line bg-paper px-3 py-2 text-sm text-warm hover:bg-tag">
              {gitDirty && changedFileCount > 0 && <span className="absolute -right-2 -top-2 grid h-5 min-w-5 place-items-center rounded-full bg-brand px-1 text-xs text-paper ring-2 ring-panel">{changedFileCount}</span>}
              <GitBranch className="inline h-4 w-4 text-brand" /> <span className="hidden sm:inline">保存到 Git</span>
            </button>
          </div>
        </div>
      </header>

      {mobileMenuOpen && <div className="fixed inset-0 z-40 bg-ink/35 md:hidden" onClick={() => setMobileMenuOpen(false)}>
        <aside className="kami-float h-full w-72 max-w-[85vw] overflow-y-auto border-r border-line bg-panel px-[max(1rem,env(safe-area-inset-left))] pb-4 pr-4 pt-[calc(env(safe-area-inset-top)+1rem)]" onClick={(event) => event.stopPropagation()}>
          <div className="mb-6 flex items-center justify-between">
            <div className="flex items-center gap-2 font-serif text-xl font-medium"><span className="grid h-8 w-8 place-items-center rounded-xl bg-brand text-paper"><PiggyBank className="h-4 w-4" /></span> 我的账本</div>
            <button className="rounded-xl border border-line bg-paper p-2 text-stone" onClick={() => setMobileMenuOpen(false)} aria-label="关闭侧边栏"><X className="h-4 w-4" /></button>
          </div>
          <div className="mb-3 text-xs font-medium uppercase tracking-[0.22em] text-stone">全部功能</div>
          <nav className="space-y-2">
            {ledgerNavItems.map((item) => {
              const Icon = item.icon;
              const active = pathname === item.href;
              return (
                <ClientNavLink key={item.href} href={item.href} onClick={() => setMobileMenuOpen(false)} className={`flex items-center justify-between rounded-2xl px-3 py-3 text-sm ${active ? "bg-brand text-paper" : "text-olive hover:bg-paper hover:text-ink"}`}>
                  <span className="flex items-center gap-3"><Icon className="h-4 w-4" /> {item.label}</span>
                  {!mobileTabHrefs.includes(item.href) && <span className={`rounded-full px-2 py-0.5 text-xs ${active ? "bg-paper/10 text-paper/70" : "bg-tag text-stone"}`}>更多</span>}
                </ClientNavLink>
              );
            })}
          </nav>
          <div className="mt-6 rounded-2xl border border-line bg-paper p-4 text-xs leading-5 text-olive">
            底部 Tab 可在设置页自定义；其他页面仍可从这里进入。
          </div>
        </aside>
      </div>}

      <div className="md:flex">
        <aside className={`hidden min-h-[calc(100vh-64px)] shrink-0 border-r border-line bg-panel/75 p-4 transition-[width] md:block ${sidebarCollapsed ? "w-20" : "w-64"}`}>
          <div className={`mb-3 flex items-center ${sidebarCollapsed ? "justify-center" : "justify-between"}`}>
            {!sidebarCollapsed && <div className="text-xs font-medium uppercase tracking-[0.24em] text-stone">本月账页</div>}
            <button type="button" onClick={toggleSidebarCollapsed} className="rounded-xl border border-line bg-paper p-2 text-stone hover:bg-tag" aria-label={sidebarCollapsed ? "展开侧边栏" : "折叠侧边栏"} title={sidebarCollapsed ? "展开侧边栏" : "折叠侧边栏"}>
              {sidebarCollapsed ? <ChevronRight className="h-4 w-4" /> : <ChevronLeft className="h-4 w-4" />}
            </button>
          </div>
          <nav className="space-y-2">
            {ledgerNavItems.map((item) => {
              const Icon = item.icon;
              const active = pathname === item.href;
              return (
                <ClientNavLink key={item.href} href={item.href} title={sidebarCollapsed ? item.label : undefined} className={`flex items-center rounded-2xl px-3 py-3 text-sm ${sidebarCollapsed ? "justify-center" : "gap-3"} ${active ? "bg-brand text-paper shadow-sm" : "text-olive hover:bg-paper hover:text-ink"}`}>
                  <Icon className="h-4 w-4 shrink-0" /> {!sidebarCollapsed && item.label}
                </ClientNavLink>
              );
            })}
          </nav>
        </aside>

        <main className="min-w-0 flex-1 px-4 py-6 md:px-8 md:py-10">
          <div className="mx-auto max-w-5xl">{children}</div>
        </main>
      </div>

      <button onClick={onAdd} className="kami-float fixed bottom-[calc(6.25rem+env(safe-area-inset-bottom))] right-5 z-30 grid h-14 w-14 place-items-center rounded-2xl bg-brand text-paper md:bottom-8" aria-label="记一笔">
        <Plus />
      </button>
      <nav className={`mobile-bottom-nav fixed bottom-0 left-0 right-0 z-20 border-t border-line bg-panel/95 px-[env(safe-area-inset-left)] pr-[env(safe-area-inset-right)] pb-[calc(env(safe-area-inset-bottom)+14px)] pt-2 backdrop-blur md:hidden`} style={{ gridTemplateColumns: `repeat(${Math.max(mobilePrimaryNav.length, 1)}, minmax(0, 1fr))` }}>
        {mobilePrimaryNav.map((item) => {
          const Icon = item.icon;
          const active = pathname === item.href;
          return (
            <ClientNavLink key={item.href} href={item.href} className={`flex flex-col items-center gap-1 py-2 text-xs ${active ? "text-brand" : "text-stone"}`}>
              <Icon className="h-5 w-5" /> {item.label}
            </ClientNavLink>
          );
        })}
      </nav>
    </div>
  );
}
