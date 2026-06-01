"use client";

import { BarChart3, BookOpen, ChevronLeft, ChevronRight, FileUp, GitBranch, Home, Landmark, LayoutDashboard, List, LockKeyhole, Menu, Monitor, Moon, PiggyBank, Plus, Scale, Settings, Sun, TrendingUp, UnlockKeyhole, X } from "lucide-react";
import { useEffect, useRef, useState, type MouseEvent, type ReactNode } from "react";
import { ClientNavLink } from "./ledger/ClientNavLink";
import { haptic } from "./ledger/haptics";
import { defaultMobileTabHrefs, readMobileTabHrefs } from "./ledger/storage";
import type { LedgerNavHref, ResolvedTheme, ThemeMode } from "./ledger/types";

export const ledgerNavItems: { href: LedgerNavHref; label: string; icon: typeof Home; mobilePrimary: boolean }[] = [
  { href: "/", label: "总览", icon: Home, mobilePrimary: true },
  { href: "/dashboard", label: "看板", icon: LayoutDashboard, mobilePrimary: false },
  { href: "/transactions", label: "流水", icon: List, mobilePrimary: true },
  { href: "/accounts", label: "账户", icon: BookOpen, mobilePrimary: true },
  { href: "/budgets", label: "预算", icon: BarChart3, mobilePrimary: false },
  { href: "/imports", label: "导入", icon: FileUp, mobilePrimary: false },
  { href: "/net-worth", label: "净资产", icon: Landmark, mobilePrimary: false },
  { href: "/income-statement", label: "损益表", icon: TrendingUp, mobilePrimary: false },
  { href: "/reconcile", label: "对账", icon: Scale, mobilePrimary: false },
  { href: "/settings", label: "设置", icon: Settings, mobilePrimary: false },
];

const sidebarCollapsedKey = "ledger_sidebar_collapsed";

const themeOptions: { value: ThemeMode; label: string; icon: typeof Sun }[] = [
  { value: "system", label: "跟随系统", icon: Monitor },
  { value: "light", label: "浅色", icon: Sun },
  { value: "dark", label: "深色", icon: Moon },
];

function readSidebarCollapsed() {
  if (typeof window === "undefined") return false;
  return localStorage.getItem(sidebarCollapsedKey) === "1";
}

function writeSidebarCollapsed(collapsed: boolean) {
  if (typeof window === "undefined") return;
  localStorage.setItem(sidebarCollapsedKey, collapsed ? "1" : "0");
}

export function AppShell({ children, pathname, routePending = false, onAdd, onGit, gitDirty, changedFileCount = 0, sensitiveUnlocked = false, passkeyEnabled = false, onUnlockSensitive, onLockSensitive, onActiveRouteTap, themeMode, resolvedTheme, onThemeModeChange }: { children: ReactNode; pathname: string; routePending?: boolean; onAdd?: () => void; onGit?: () => void; gitDirty?: boolean; changedFileCount?: number; sensitiveUnlocked?: boolean; passkeyEnabled?: boolean; onUnlockSensitive?: () => void; onLockSensitive?: () => void; onActiveRouteTap?: () => void; themeMode: ThemeMode; resolvedTheme: ResolvedTheme; onThemeModeChange: (mode: ThemeMode) => void }) {
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false);
  const [mobileMenuClosing, setMobileMenuClosing] = useState(false);
  const mobileMenuCloseTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [sidebarCollapsed, setSidebarCollapsed] = useState(false);
  const [mobileTabHrefs, setMobileTabHrefs] = useState<LedgerNavHref[]>(defaultMobileTabHrefs);
  const [navPendingHref, setNavPendingHref] = useState<string | null>(null);
  const navPendingTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [themeMenuOpen, setThemeMenuOpen] = useState(false);

  useEffect(() => {
    setSidebarCollapsed(readSidebarCollapsed());
    setMobileTabHrefs(readMobileTabHrefs());
    const handleMobileTabsChange = () => setMobileTabHrefs(readMobileTabHrefs());
    window.addEventListener("storage", handleMobileTabsChange);
    window.addEventListener("ledger-mobile-tabs-change", handleMobileTabsChange);
    return () => {
      window.removeEventListener("storage", handleMobileTabsChange);
      window.removeEventListener("ledger-mobile-tabs-change", handleMobileTabsChange);
      if (mobileMenuCloseTimer.current) clearTimeout(mobileMenuCloseTimer.current);
      if (navPendingTimer.current) clearTimeout(navPendingTimer.current);
    };
  }, []);

  useEffect(() => {
    setNavPendingHref(null);
    if (navPendingTimer.current) {
      clearTimeout(navPendingTimer.current);
      navPendingTimer.current = null;
    }
  }, [pathname]);

  function markNavigationPending(href: string) {
    if (href === pathname) return;
    haptic(5);
    setNavPendingHref(href);
    if (navPendingTimer.current) clearTimeout(navPendingTimer.current);
    navPendingTimer.current = setTimeout(() => {
      setNavPendingHref(null);
      navPendingTimer.current = null;
    }, 2800);
  }

  function handleNavClick(event: MouseEvent<HTMLAnchorElement>, href: string, onClick?: (event: MouseEvent<HTMLAnchorElement>) => void) {
    onClick?.(event);
    if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) return;
    markNavigationPending(href);
  }

  function openMobileMenu() {
    haptic(6);
    if (mobileMenuCloseTimer.current) clearTimeout(mobileMenuCloseTimer.current);
    setMobileMenuClosing(false);
    setMobileMenuOpen(true);
  }

  function closeMobileMenu() {
    if (!mobileMenuOpen || mobileMenuClosing) return;
    setMobileMenuClosing(true);
    if (mobileMenuCloseTimer.current) clearTimeout(mobileMenuCloseTimer.current);
    mobileMenuCloseTimer.current = setTimeout(() => {
      setMobileMenuOpen(false);
      setMobileMenuClosing(false);
      mobileMenuCloseTimer.current = null;
    }, 190);
  }

  function toggleSidebarCollapsed() {
    haptic(5);
    setSidebarCollapsed((current) => {
      const next = !current;
      writeSidebarCollapsed(next);
      return next;
    });
  }

  const mobilePrimaryNav = ledgerNavItems.filter((item) => mobileTabHrefs.includes(item.href));
  const showingRouteProgress = routePending || Boolean(navPendingHref);

  return (
    <div className="min-h-dvh max-w-full [overflow-x:clip] bg-paper pt-[calc(4rem+env(safe-area-inset-top))] text-ink [overscroll-behavior-y:none]">
      {showingRouteProgress && <div className="fixed left-0 right-0 top-[env(safe-area-inset-top)] z-50 h-0.5 overflow-hidden bg-line"><div className="app-route-progress h-full w-1/3 bg-brand" /></div>}
      <header className="fixed inset-x-0 top-0 z-30 border-b border-line bg-panel/95 pt-[env(safe-area-inset-top)] text-ink backdrop-blur supports-[backdrop-filter]:bg-panel/85">
        <div className="flex h-16 items-center justify-between px-[max(1rem,env(safe-area-inset-left))] pr-[max(1rem,env(safe-area-inset-right))] md:px-6">
          <div className="flex min-w-0 items-center gap-3 md:w-64">
            <button className="rounded-xl border border-line bg-paper p-2 text-brand hover:bg-tag md:hidden" onClick={openMobileMenu} aria-label="打开侧边栏">
              <Menu className="h-5 w-5" />
            </button>
            <ClientNavLink href="/" onClick={(event) => handleNavClick(event, "/")} className="flex min-w-0 items-center gap-3 font-serif text-xl font-medium">
              <span className="grid h-10 w-10 shrink-0 place-items-center rounded-2xl bg-brand text-paper"><PiggyBank className="h-5 w-5" /></span>
              <span className="min-w-0">
                <span className="block truncate leading-tight">我的账本</span>
                <span className="block truncate text-[11px] font-normal uppercase tracking-[0.22em] text-stone">private ledger</span>
              </span>
            </ClientNavLink>
          </div>
          <div className="hidden rounded-full border border-line bg-paper px-4 py-2 text-xs tracking-wide text-olive lg:block">资产 + 费用 = 负债 + 所有者权益 + 收入</div>
          <div className="flex items-center gap-2">
            <ThemeMenu themeMode={themeMode} resolvedTheme={resolvedTheme} open={themeMenuOpen} onOpenChange={setThemeMenuOpen} onThemeModeChange={onThemeModeChange} />
            {passkeyEnabled && (
              <button
                type="button"
                onClick={sensitiveUnlocked ? onLockSensitive : onUnlockSensitive}
                disabled={sensitiveUnlocked ? !onLockSensitive : !onUnlockSensitive}
                className={`rounded-xl border border-line bg-paper px-3 py-2 text-sm ${sensitiveUnlocked ? "text-olive hover:bg-tag" : "text-warm hover:bg-tag"}`}
                aria-label={sensitiveUnlocked ? "锁定敏感数据" : "解锁敏感数据"}
                aria-pressed={sensitiveUnlocked}
                title={sensitiveUnlocked ? "重新隐藏敏感数据" : "使用 Face ID / Passkey 解锁敏感数据"}
              >
                {sensitiveUnlocked ? <UnlockKeyhole className="inline h-4 w-4 text-brand" /> : <LockKeyhole className="inline h-4 w-4 text-brand" />} <span className="hidden sm:inline">{sensitiveUnlocked ? "重新隐藏" : "解锁"}</span>
              </button>
            )}
            <button onClick={onGit} className="relative rounded-xl border border-line bg-paper px-3 py-2 text-sm text-warm hover:bg-tag">
              {gitDirty && changedFileCount > 0 && <span className="absolute -right-2 -top-2 grid h-5 min-w-5 place-items-center rounded-full bg-brand px-1 text-xs text-paper ring-2 ring-panel">{changedFileCount}</span>}
              <GitBranch className="inline h-4 w-4 text-brand" /> <span className="hidden sm:inline">保存到 Git</span>
            </button>
          </div>
        </div>
      </header>

      {(mobileMenuOpen || mobileMenuClosing) && <div className={`mobile-sidebar-backdrop fixed inset-0 z-40 bg-ink/35 md:hidden ${mobileMenuClosing ? "mobile-sidebar-backdrop-close" : ""}`} onClick={closeMobileMenu}>
        <aside className={`mobile-sidebar-panel kami-float h-full w-72 max-w-[85vw] overflow-y-auto border-r border-line bg-panel px-[max(1rem,env(safe-area-inset-left))] pb-4 pr-4 pt-[calc(env(safe-area-inset-top)+1rem)] ${mobileMenuClosing ? "mobile-sidebar-panel-close" : ""}`} onClick={(event) => event.stopPropagation()}>
          <div className="mb-6 flex items-center justify-between">
            <div className="flex items-center gap-2 font-serif text-xl font-medium"><span className="grid h-8 w-8 place-items-center rounded-xl bg-brand text-paper"><PiggyBank className="h-4 w-4" /></span> 我的账本</div>
            <button className="rounded-xl border border-line bg-paper p-2 text-stone" onClick={closeMobileMenu} aria-label="关闭侧边栏"><X className="h-4 w-4" /></button>
          </div>
          <div className="mb-3 text-xs font-medium uppercase tracking-[0.22em] text-stone">全部功能</div>
          <nav className="space-y-2">
            {ledgerNavItems.map((item) => {
              const Icon = item.icon;
              const active = pathname === item.href;
              return (
                <ClientNavLink key={item.href} href={item.href} onClick={(event) => handleNavClick(event, item.href, closeMobileMenu)} className={`flex items-center justify-between rounded-2xl px-3 py-3 text-sm ${active ? "bg-brand text-paper" : "text-olive hover:bg-paper hover:text-ink"}`}>
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

      <div className="min-w-0 max-w-full md:flex">
        <aside className={`desktop-sidebar hidden min-h-[calc(100vh-64px)] shrink-0 overflow-hidden border-r border-line bg-panel/75 p-4 md:block ${sidebarCollapsed ? "desktop-sidebar-collapsed" : ""}`}>
          <div className="desktop-sidebar-header mb-3">
            <div className="desktop-sidebar-heading min-w-0 overflow-hidden whitespace-nowrap text-xs font-medium uppercase tracking-[0.24em] text-stone">本月账页</div>
            <button type="button" onClick={toggleSidebarCollapsed} className="desktop-sidebar-toggle rounded-xl border border-line bg-paper p-2 text-stone hover:bg-tag" aria-label={sidebarCollapsed ? "展开侧边栏" : "折叠侧边栏"} title={sidebarCollapsed ? "展开侧边栏" : "折叠侧边栏"}>
              {sidebarCollapsed ? <ChevronRight className="h-4 w-4" /> : <ChevronLeft className="h-4 w-4" />}
            </button>
          </div>
          <nav className="space-y-2">
            {ledgerNavItems.map((item) => {
              const Icon = item.icon;
              const active = pathname === item.href;
              return (
                <ClientNavLink key={item.href} href={item.href} title={sidebarCollapsed ? item.label : undefined} onClick={(event) => handleNavClick(event, item.href)} className={`desktop-sidebar-link flex items-center rounded-2xl text-sm ${active ? "bg-brand text-paper shadow-sm" : "text-olive hover:bg-paper hover:text-ink"}`}>
                  <Icon className="h-4 w-4 shrink-0" />
                  <span className="desktop-sidebar-link-label min-w-0">{item.label}</span>
                </ClientNavLink>
              );
            })}
          </nav>
        </aside>

        <main className="min-w-0 max-w-full flex-1 [overflow-x:clip] px-4 py-5 md:px-8 md:py-10">
          <div className="mx-auto min-w-0 max-w-[1500px]">{children}</div>
        </main>
      </div>

      <button onClick={() => { haptic(10); onAdd?.(); }} className="kami-float app-fab fixed bottom-[calc(6.25rem+env(safe-area-inset-bottom))] right-5 z-30 grid h-14 w-14 place-items-center rounded-2xl bg-brand text-paper shadow-lg active:scale-95 md:bottom-8" aria-label="打开快捷操作">
        <Plus />
      </button>
      <nav className={`mobile-bottom-nav fixed bottom-0 left-0 right-0 z-20 border-t border-line bg-panel/95 px-[env(safe-area-inset-left)] pr-[env(safe-area-inset-right)] pb-[calc(env(safe-area-inset-bottom)+14px)] pt-2 backdrop-blur md:hidden`} style={{ gridTemplateColumns: `repeat(${Math.max(mobilePrimaryNav.length, 1)}, minmax(0, 1fr))` }}>
        {mobilePrimaryNav.map((item) => {
          const Icon = item.icon;
          const active = pathname === item.href;
          return (
            <ClientNavLink key={item.href} href={item.href} onClick={(event) => { if (active) { event.preventDefault(); onActiveRouteTap?.(); return; } handleNavClick(event, item.href); }} className={`mobile-bottom-tab mx-1 flex flex-col items-center gap-1 rounded-2xl py-2 text-xs transition-colors active:scale-95 ${active ? "mobile-bottom-tab-active bg-brand/10 text-brand" : "text-stone"}`}>
              <Icon className={`h-5 w-5 ${active ? "scale-110" : ""}`} /> {item.label}
            </ClientNavLink>
          );
        })}
      </nav>
    </div>
  );
}

function ThemeMenu({ themeMode, resolvedTheme, open, onOpenChange, onThemeModeChange }: { themeMode: ThemeMode; resolvedTheme: ResolvedTheme; open: boolean; onOpenChange: (open: boolean) => void; onThemeModeChange: (mode: ThemeMode) => void }) {
  const activeOption = themeOptions.find((option) => option.value === themeMode) ?? themeOptions[0];
  const ActiveIcon = activeOption.icon;
  const title = `主题：${activeOption.label}，当前${resolvedTheme === "dark" ? "深色" : "浅色"}`;

  function chooseTheme(mode: ThemeMode) {
    haptic(5);
    onThemeModeChange(mode);
    onOpenChange(false);
  }

  return (
    <div className="relative">
      <button
        type="button"
        className="rounded-xl border border-line bg-paper px-3 py-2 text-sm text-warm hover:bg-tag"
        onClick={() => {
          haptic(4);
          onOpenChange(!open);
        }}
        aria-label={title}
        aria-haspopup="menu"
        aria-expanded={open}
        title={title}
      >
        <ActiveIcon className="inline h-4 w-4 text-brand" /> <span className="hidden sm:inline">{activeOption.label}</span>
      </button>
      {open && (
        <div className="absolute right-0 top-[calc(100%+0.5rem)] z-50 w-36 rounded-2xl border border-line bg-panel p-1.5 text-sm shadow-lg" role="menu">
          {themeOptions.map((option) => {
            const Icon = option.icon;
            const active = themeMode === option.value;
            return (
              <button
                key={option.value}
                type="button"
                className={`flex w-full items-center gap-2 rounded-xl px-3 py-2 text-left ${active ? "bg-brand text-paper" : "text-olive hover:bg-paper hover:text-ink"}`}
                onClick={() => chooseTheme(option.value)}
                role="menuitemradio"
                aria-checked={active}
              >
                <Icon className={`h-4 w-4 ${active ? "text-paper" : "text-brand"}`} />
                <span>{option.label}</span>
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}
