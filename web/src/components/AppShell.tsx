"use client";

import { Activity, BookOpen, Bot, ChevronLeft, ChevronRight, Coins, Database, FileCode2, FileUp, Home, Landmark, LayoutDashboard, List, LockKeyhole, Menu, Monitor, Moon, Plus, Scale, Settings, Sun, TrendingUp, UnlockKeyhole, X } from "lucide-react";
import { useEffect, useRef, useState, type MouseEvent, type ReactNode } from "react";
import { ClientNavLink } from "./ledger/ClientNavLink";
import { haptic } from "./ledger/haptics";
import { preloadLedgerRoute } from "./ledger/routePreload";
import { defaultMobileTabHrefs, readMobileTabHrefs } from "./ledger/storage";
import type { LedgerNavHref, ResolvedTheme, ThemeMode } from "./ledger/types";

type LedgerNavGroup = "observe" | "record" | "manage";

type LedgerNavItem = {
  href: LedgerNavHref;
  label: string;
  icon: typeof Home;
  mobilePrimary: boolean;
  group: LedgerNavGroup;
};

export const ledgerNavItems: LedgerNavItem[] = [
  { href: "/agent", label: "账本 Agent", icon: Bot, mobilePrimary: false, group: "observe" },
  { href: "/home", label: "财务概览", icon: Home, mobilePrimary: false, group: "observe" },
  { href: "/dashboard", label: "收支分析", icon: LayoutDashboard, mobilePrimary: false, group: "observe" },
  { href: "/query", label: "BQL 查询", icon: Database, mobilePrimary: false, group: "observe" },
  { href: "/net-worth", label: "资产负债", icon: Landmark, mobilePrimary: false, group: "observe" },
  { href: "/income-statement", label: "损益表", icon: TrendingUp, mobilePrimary: false, group: "observe" },
  { href: "/investments", label: "股票", icon: TrendingUp, mobilePrimary: false, group: "observe" },
  { href: "/transactions", label: "交易账本", icon: List, mobilePrimary: true, group: "record" },
  { href: "/imports", label: "导入", icon: FileUp, mobilePrimary: false, group: "record" },
  { href: "/editor", label: "编辑", icon: FileCode2, mobilePrimary: false, group: "record" },
  { href: "/accounts", label: "账户", icon: BookOpen, mobilePrimary: true, group: "manage" },
  { href: "/currencies", label: "货币", icon: Coins, mobilePrimary: false, group: "manage" },
  { href: "/reconcile", label: "对账", icon: Scale, mobilePrimary: false, group: "manage" },
  { href: "/settings", label: "设置", icon: Settings, mobilePrimary: false, group: "manage" },
];

const navGroups: { id: LedgerNavGroup; label: string }[] = [
  { id: "observe", label: "了解现状" },
  { id: "record", label: "记录与整理" },
  { id: "manage", label: "口径与账户" },
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

function isActivePath(pathname: string, href: LedgerNavHref) {
  return href === "/" ? pathname === href : pathname === href || pathname.startsWith(`${href}/`);
}

export function AppShell({ children, pathname, routePending = false, onAdd, sensitiveUnlocked = false, passkeyEnabled = false, sensitiveUnlockAvailable = passkeyEnabled, sensitiveUnlockLabel = "解锁", sensitiveUnlockTitle = "使用 Face ID / Passkey 解锁敏感数据", onUnlockSensitive, onLockSensitive, onActiveRouteTap, themeMode, resolvedTheme, onThemeModeChange }: { children: ReactNode; pathname: string; routePending?: boolean; onAdd?: () => void; sensitiveUnlocked?: boolean; passkeyEnabled?: boolean; sensitiveUnlockAvailable?: boolean; sensitiveUnlockLabel?: string; sensitiveUnlockTitle?: string; onUnlockSensitive?: () => void; onLockSensitive?: () => void; onActiveRouteTap?: () => void; themeMode: ThemeMode; resolvedTheme: ResolvedTheme; onThemeModeChange: (mode: ThemeMode) => void }) {
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

  useEffect(() => {
    const warmMobileTabs = () => {
      for (const href of mobileTabHrefs) {
        if (href !== pathname) preloadLedgerRoute(href);
      }
    };
    if (window.requestIdleCallback) {
      const id = window.requestIdleCallback(warmMobileTabs, { timeout: 3000 });
      return () => window.cancelIdleCallback?.(id);
    }
    const id = window.setTimeout(warmMobileTabs, 1800);
    return () => window.clearTimeout(id);
  }, [mobileTabHrefs, pathname]);

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
    <div className="app-shell app-overflow-guard min-h-dvh max-w-full [overflow-x:clip] bg-paper pt-[calc(3.5rem+env(safe-area-inset-top))] text-ink [overscroll-behavior-y:none] md:pt-0">
      <a href="#main-content" className="skip-link">跳到主要内容</a>
      {showingRouteProgress && <div className="fixed left-0 right-0 top-[env(safe-area-inset-top)] z-50 h-0.5 overflow-hidden bg-line"><div className="app-route-progress h-full w-1/3 bg-brand" /></div>}
      <header className="app-shell-header fixed inset-x-0 top-0 z-30 border-b border-line bg-panel pt-[env(safe-area-inset-top)] text-ink md:hidden">
        <div className="flex h-14 items-center px-[max(0.75rem,env(safe-area-inset-left))] pr-[max(0.75rem,env(safe-area-inset-right))] md:h-12 md:px-3">
          <div className="flex min-w-0 items-center gap-2.5 md:w-48 md:gap-2">
            <button className="grid h-9 w-9 place-items-center rounded-md border border-line bg-paper text-brand hover:bg-tag md:hidden" onClick={openMobileMenu} aria-label="打开侧边栏">
              <Menu className="h-4.5 w-4.5" />
            </button>
            <ClientNavLink href="/" onClick={(event) => handleNavClick(event, "/")} className="flex min-w-0 items-center gap-2.5">
              <span className="grid h-8 w-8 shrink-0 place-items-center rounded-md bg-brand text-primary-foreground md:h-7 md:w-7"><Activity className="h-4 w-4 md:h-3.5 md:w-3.5" /></span>
              <span className="min-w-0 leading-tight">
                <span className="block truncate text-sm font-semibold tracking-[-0.012em] md:text-[13px]">Ledger</span>
                <span className="block truncate text-[10px] font-medium tracking-[0.08em] text-stone">个人财务工作台</span>
              </span>
            </ClientNavLink>
          </div>
          <div className="ml-auto flex items-center gap-2">
            <ThemeMenu themeMode={themeMode} resolvedTheme={resolvedTheme} open={themeMenuOpen} onOpenChange={setThemeMenuOpen} onThemeModeChange={onThemeModeChange} />
            {(sensitiveUnlocked || sensitiveUnlockAvailable) && (
              <button
                type="button"
                onClick={sensitiveUnlocked ? onLockSensitive : onUnlockSensitive}
                disabled={sensitiveUnlocked ? !onLockSensitive : !onUnlockSensitive}
                className={`inline-flex h-9 items-center gap-2 rounded-md border border-line bg-paper px-2.5 text-sm md:h-8 md:px-2 md:text-xs ${sensitiveUnlocked ? "text-olive hover:bg-tag" : "text-warm hover:bg-tag"}`}
                aria-label={sensitiveUnlocked ? "锁定敏感数据" : "解锁敏感数据"}
                aria-pressed={sensitiveUnlocked}
                title={sensitiveUnlocked ? "重新隐藏敏感数据" : sensitiveUnlockTitle}
              >
                {sensitiveUnlocked ? <UnlockKeyhole className="h-4 w-4 text-brand" /> : <LockKeyhole className="h-4 w-4 text-brand" />} <span className="hidden sm:inline">{sensitiveUnlocked ? "重新隐藏" : sensitiveUnlockLabel}</span>
              </button>
            )}
          </div>
        </div>
      </header>

      {(mobileMenuOpen || mobileMenuClosing) && <div className={`mobile-sidebar-backdrop fixed inset-0 z-40 bg-ink/45 md:hidden ${mobileMenuClosing ? "mobile-sidebar-backdrop-close" : ""}`} onClick={closeMobileMenu}>
        <aside className={`mobile-sidebar-panel kami-float h-full w-72 max-w-[85vw] overflow-y-auto border-r border-line bg-panel pb-[calc(env(safe-area-inset-bottom)+0.75rem)] pl-[max(0.75rem,env(safe-area-inset-left))] pr-3 pt-[calc(env(safe-area-inset-top)+0.75rem)] ${mobileMenuClosing ? "mobile-sidebar-panel-close" : ""}`} onClick={(event) => event.stopPropagation()}>
          <div className="mb-4 flex items-center justify-between border-b border-line pb-3">
            <div className="flex items-center gap-2.5">
              <span className="grid h-8 w-8 place-items-center rounded-md bg-brand text-primary-foreground"><Activity className="h-4 w-4" /></span>
              <div><div className="text-sm font-semibold">Ledger</div><div className="text-[10px] text-stone">个人财务工作台</div></div>
            </div>
            <button className="grid h-9 w-9 place-items-center rounded-md border border-line bg-paper text-stone hover:bg-tag" onClick={closeMobileMenu} aria-label="关闭侧边栏"><X className="h-4 w-4" /></button>
          </div>
          <GroupedNavigation pathname={pathname} mobileTabHrefs={mobileTabHrefs} onNavigate={(event, href) => handleNavClick(event, href, closeMobileMenu)} />
          <div className="mt-5 border-t border-line px-1 pt-4 text-xs leading-5 text-stone">底部导航可在设置中调整，其他功能保留在这里。</div>
        </aside>
      </div>}

      <div className="app-shell-frame min-w-0 max-w-full md:flex">
        <aside className={`app-shell-sidebar desktop-sidebar hidden shrink-0 flex-col overflow-hidden border-r border-line bg-panel md:flex ${sidebarCollapsed ? "desktop-sidebar-collapsed" : ""}`}>
          <div className="desktop-sidebar-brand flex h-14 shrink-0 items-center border-b border-line px-2.5">
            <ClientNavLink href="/" onClick={(event) => handleNavClick(event, "/")} className="desktop-sidebar-brand-link flex min-w-0 flex-1 items-center gap-2.5 overflow-hidden">
              <span className="grid h-7 w-7 shrink-0 place-items-center rounded-md bg-brand text-primary-foreground"><Activity className="h-3.5 w-3.5" /></span>
              <span className="desktop-sidebar-brand-copy min-w-0 leading-tight">
                <span className="block truncate text-sm font-semibold tracking-[-0.012em]">Ledger</span>
                <span className="block truncate text-[11px] font-medium text-stone">私人财务控制台</span>
              </span>
            </ClientNavLink>
            <button type="button" onClick={toggleSidebarCollapsed} className="desktop-sidebar-toggle grid h-7 w-7 shrink-0 place-items-center rounded-md text-stone hover:bg-tag hover:text-ink" aria-label={sidebarCollapsed ? "展开侧边栏" : "折叠侧边栏"} title={sidebarCollapsed ? "展开侧边栏" : "折叠侧边栏"}>
              {sidebarCollapsed ? <ChevronRight className="h-3.5 w-3.5" /> : <ChevronLeft className="h-3.5 w-3.5" />}
            </button>
          </div>
          <div className="min-h-0 flex-1 overflow-y-auto px-2 py-3">
            <GroupedNavigation pathname={pathname} collapsed={sidebarCollapsed} onNavigate={(event, href) => handleNavClick(event, href)} />
          </div>
          <div className="desktop-sidebar-utilities shrink-0 border-t border-line p-2">
            <div className={`flex items-center gap-1.5 ${sidebarCollapsed ? "flex-col" : ""}`}>
              <ThemeMenu themeMode={themeMode} resolvedTheme={resolvedTheme} open={themeMenuOpen} onOpenChange={setThemeMenuOpen} onThemeModeChange={onThemeModeChange} placement="top" compact={sidebarCollapsed} />
              {(sensitiveUnlocked || sensitiveUnlockAvailable) && (
                <button
                  type="button"
                  onClick={sensitiveUnlocked ? onLockSensitive : onUnlockSensitive}
                  disabled={sensitiveUnlocked ? !onLockSensitive : !onUnlockSensitive}
                  className={`inline-flex h-8 min-w-0 items-center justify-center gap-2 rounded-md px-2 text-xs text-olive hover:bg-tag hover:text-ink ${sidebarCollapsed ? "w-8" : "flex-1"}`}
                  aria-label={sensitiveUnlocked ? "锁定敏感数据" : "解锁敏感数据"}
                  aria-pressed={sensitiveUnlocked}
                  title={sensitiveUnlocked ? "重新隐藏敏感数据" : sensitiveUnlockTitle}
                >
                  {sensitiveUnlocked ? <UnlockKeyhole className="h-3.5 w-3.5 shrink-0" /> : <LockKeyhole className="h-3.5 w-3.5 shrink-0" />}
                  {!sidebarCollapsed && <span className="truncate">{sensitiveUnlocked ? "隐藏金额" : sensitiveUnlockLabel}</span>}
                </button>
              )}
            </div>
          </div>
        </aside>

        <main id="main-content" data-ledger-main-scroll className="app-shell-main min-w-0 max-w-full flex-1 [overflow-x:clip] px-3 py-4 md:px-0 md:py-0">
          <div className="min-w-0">{children}</div>
        </main>
      </div>

      <button onClick={() => { haptic(10); onAdd?.(); }} className="kami-float app-fab fixed bottom-[calc(6.15rem+env(safe-area-inset-bottom))] right-4 z-30 inline-flex h-12 w-12 items-center justify-center gap-2 rounded-lg bg-brand text-primary-foreground active:scale-95 md:bottom-4 md:right-4 md:h-9 md:w-auto md:px-3" aria-label="打开快捷操作">
        <Plus className="h-5 w-5 md:h-4 md:w-4" /><span className="hidden text-xs font-semibold md:inline">新建</span>
      </button>
      <nav className="mobile-bottom-nav fixed bottom-0 left-0 right-0 z-20 border-t border-line bg-panel px-[env(safe-area-inset-left)] pr-[env(safe-area-inset-right)] pb-[calc(env(safe-area-inset-bottom)+10px)] pt-1.5 md:hidden" style={{ gridTemplateColumns: `repeat(${Math.max(mobilePrimaryNav.length, 1)}, minmax(0, 1fr))` }}>
        {mobilePrimaryNav.map((item) => {
          const Icon = item.icon;
          const active = isActivePath(pathname, item.href);
          return (
            <ClientNavLink key={item.href} href={item.href} onClick={(event) => { if (active) { event.preventDefault(); onActiveRouteTap?.(); return; } handleNavClick(event, item.href); }} className={`mobile-bottom-tab mx-1 flex min-h-14 flex-col items-center justify-center gap-1 rounded-md py-1.5 text-[11px] font-medium active:scale-95 ${active ? "mobile-bottom-tab-active text-brand" : "text-stone"}`}>
              <Icon className="h-4.5 w-4.5" /> {item.label}
            </ClientNavLink>
          );
        })}
      </nav>
    </div>
  );
}

function GroupedNavigation({ pathname, mobileTabHrefs = [], collapsed = false, onNavigate }: { pathname: string; mobileTabHrefs?: LedgerNavHref[]; collapsed?: boolean; onNavigate: (event: MouseEvent<HTMLAnchorElement>, href: LedgerNavHref) => void }) {
  return <nav className="space-y-5">
    {navGroups.map((group) => <div key={group.id} className="desktop-nav-group">
      <div className="desktop-nav-group-label mb-2 px-2 text-[11px] font-semibold text-stone">{group.label}</div>
      <div className="space-y-1">
        {ledgerNavItems.filter((item) => item.group === group.id).map((item) => {
          const Icon = item.icon;
          const active = isActivePath(pathname, item.href);
          return <ClientNavLink key={item.href} href={item.href} title={collapsed ? item.label : undefined} onClick={(event) => onNavigate(event, item.href)} className={`desktop-sidebar-link flex items-center rounded-md text-[14px] font-semibold ${active ? "desktop-sidebar-link-active bg-tag text-ink" : "text-olive hover:bg-paper hover:text-ink"}`}>
            <Icon className={`h-4 w-4 shrink-0 ${active ? "text-brand" : "text-stone"}`} />
            <span className="desktop-sidebar-link-label min-w-0">{item.label}</span>
            {!collapsed && mobileTabHrefs.length > 0 && !mobileTabHrefs.includes(item.href) && <span className="ml-auto text-[10px] text-stone">更多</span>}
          </ClientNavLink>;
        })}
      </div>
    </div>)}
  </nav>;
}

function ThemeMenu({ themeMode, resolvedTheme, open, onOpenChange, onThemeModeChange, placement = "bottom", compact = false }: { themeMode: ThemeMode; resolvedTheme: ResolvedTheme; open: boolean; onOpenChange: (open: boolean) => void; onThemeModeChange: (mode: ThemeMode) => void; placement?: "top" | "bottom"; compact?: boolean }) {
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
        className={`inline-flex h-9 items-center justify-center gap-2 rounded-md border border-line bg-paper px-2.5 text-sm text-warm hover:bg-tag md:h-8 md:px-2 md:text-xs ${compact ? "w-8" : ""}`}
        onClick={() => {
          haptic(4);
          onOpenChange(!open);
        }}
        aria-label={title}
        aria-haspopup="menu"
        aria-expanded={open}
        title={title}
      >
        <ActiveIcon className="h-4 w-4 text-brand" /> {!compact && <span className="hidden lg:inline">{activeOption.label}</span>}
      </button>
      {open && (
        <div className={`absolute z-50 w-36 rounded-md border border-line bg-panel p-1.5 text-sm shadow-lg ${placement === "top" ? "bottom-[calc(100%+0.5rem)] left-0" : "right-0 top-[calc(100%+0.5rem)]"}`} role="menu">
          {themeOptions.map((option) => {
            const Icon = option.icon;
            const active = themeMode === option.value;
            return (
              <button
                key={option.value}
                type="button"
                className={`flex w-full items-center gap-2 rounded-sm px-3 py-2 text-left ${active ? "bg-tag text-ink" : "text-olive hover:bg-paper hover:text-ink"}`}
                onClick={() => chooseTheme(option.value)}
                role="menuitemradio"
                aria-checked={active}
              >
                <Icon className={`h-4 w-4 ${active ? "text-brand" : "text-stone"}`} />
                <span>{option.label}</span>
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}
