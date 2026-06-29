import { lazy, Suspense, useEffect, useMemo, useState } from "react";
import { createPortal } from "react-dom";
import { ClientNavLink } from "./ClientNavLink";
import { Bot, ChevronDown, Eye, EyeOff, GripVertical, ListChecks, Pencil, X } from "lucide-react";
import { readJson } from "@/lib/clientFetch";
import { formatCompactValuation, formatMoney, formatValuation } from "@/lib/money";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { formatAccountOptionLabel } from "./accountDisplay";
import type { AccountGroup, AccountStatus, AccountView, CreditCardAnalytics, Txn } from "./types";

const loadAccountAgentChat = () => import("./AccountAgentChat");
const LazyAccountAgentChat = lazy(() => loadAccountAgentChat().then((mod) => ({ default: mod.AccountAgentChat })));

type BalanceRow = { account: string; label: string; value: number; currency?: string; active?: boolean; group?: AccountGroup; valuation?: boolean };
type BalanceStatusFilter = "all" | "issue" | "yellow" | "grey";
type BalancePrefixGroup = {
  key: string;
  label: string;
  path: string;
  rows: BalanceRow[];
  total: number;
  currencies: string[];
  statusCounts: Record<AccountStatus["status"], number>;
  issueCount: number;
};
const statusFilters: { key: BalanceStatusFilter; label: string }[] = [
  { key: "all", label: "全部" },
  { key: "issue", label: "异常" },
  { key: "yellow", label: "未断言" },
  { key: "grey", label: "长期未更新" },
];
const accountGroupOrderStorageKey = "ledger-account-prefix-group-order";

export function BalanceGrid({ rows, full, allVisible = false, visibleAccountMap = {}, onToggleAll, onToggleAccount, statuses, txns = [] }: { rows: BalanceRow[]; full?: boolean; allVisible?: boolean; visibleAccountMap?: Record<string, boolean>; onToggleAll?: () => void; onToggleAccount?: (account: string) => void; statuses?: AccountStatus[]; txns?: Txn[] }) {
  const trendMap = useMemo(() => Object.fromEntries(rows.map((row) => [row.account, accountTrendPoints(row, txns)])), [rows, txns]);
  const statusMap = useMemo(() => new Map((statuses ?? []).map((status) => [status.account, status])), [statuses]);
  const lastActivityMap = useMemo(() => accountLastActivity(rows, txns), [rows, txns]);
  const [statusFilter, setStatusFilter] = useState<BalanceStatusFilter>("all");
  const [expandedAccount, setExpandedAccount] = useState<string | null>(null);
  const [mobileAccount, setMobileAccount] = useState<string | null>(null);
  const [openGroups, setOpenGroups] = useState<Record<string, boolean>>({});
  const [groupOrder, setGroupOrder] = useState<string[]>(() => readAccountGroupOrder());
  const [draggedGroupKey, setDraggedGroupKey] = useState<string | null>(null);

  const filteredRows = useMemo(() => rows.filter((row) => accountMatchesStatusFilter(statusMap.get(row.account), statusFilter)), [rows, statusFilter, statusMap]);
  const groups = useMemo(() => orderBalancePrefixGroups(buildBalancePrefixGroups(filteredRows, statusMap), groupOrder), [filteredRows, groupOrder, statusMap]);
  const mobileDetailRow = mobileAccount ? rows.find((row) => row.account === mobileAccount) ?? null : null;

  function rowVisible(row: BalanceRow) {
    return visibleAccountMap[row.account] ?? allVisible;
  }

  function groupVisible(group: BalancePrefixGroup) {
    return group.rows.length > 0 && group.rows.every(rowVisible);
  }

  function selectAccount(row: BalanceRow) {
    if (typeof window !== "undefined" && window.matchMedia("(min-width: 1280px)").matches) {
      setExpandedAccount((current) => current === row.account ? null : row.account);
    } else {
      setMobileAccount(row.account);
    }
  }

  function moveGroup(targetKey: string) {
    if (!draggedGroupKey || draggedGroupKey === targetKey) return;
    const next = reorderKeys(groups.map((group) => group.key), groupOrder, draggedGroupKey, targetKey);
    setGroupOrder(next);
    writeAccountGroupOrder(next);
  }

  return <section className="card relative mt-6 p-4">
    <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
      <div>
        <h2 className="font-serif text-2xl">账户余额</h2>
        <p className="mt-1 text-sm text-stone">按账户前缀和机构折叠；拖拽分组可调整常用顺序。</p>
      </div>
      <div className="flex flex-wrap items-center gap-2">
        <div className="flex rounded-xl border border-line bg-panel p-1">
          {statusFilters.map((filter) => (
            <button
              key={filter.key}
              className={`h-8 rounded-lg px-2.5 text-xs transition ${statusFilter === filter.key ? "bg-brand text-paper" : "text-olive hover:bg-tag"}`}
              onClick={() => setStatusFilter(filter.key)}
            >
              {filter.label}
            </button>
          ))}
        </div>
        {onToggleAll && <button className="inline-flex h-10 items-center gap-1.5 rounded-xl border border-line bg-panel px-3 text-sm text-olive hover:bg-tag" onClick={onToggleAll} title={allVisible ? "隐藏所有账户余额" : "显示所有账户余额"}>{allVisible ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}<span>{allVisible ? "全部隐藏" : "全部显示"}</span></button>}
      </div>
    </div>

    {rows.length ? groups.length ? <>
      <div className="mt-4 space-y-3">
        {groups.map((group, index) => {
          const open = openGroups[group.key] ?? false;
          const dragging = draggedGroupKey === group.key;
          return <div key={group.key} className={`overflow-hidden rounded-xl border border-line bg-panel transition-colors ${dragging ? "border-brand bg-brand/5" : ""}`}>
            <div
              role="button"
              tabIndex={0}
              className="flex w-full cursor-pointer items-start justify-between gap-3 p-4 text-left outline-none hover:bg-paper focus-visible:ring-2 focus-visible:ring-brand focus-visible:ring-offset-2 focus-visible:ring-offset-panel"
              draggable
              onDragStart={(event) => {
                setDraggedGroupKey(group.key);
                event.dataTransfer.effectAllowed = "move";
                event.dataTransfer.setData("text/plain", group.key);
              }}
              onDragOver={(event) => {
                event.preventDefault();
                event.dataTransfer.dropEffect = "move";
              }}
              onDrop={(event) => {
                event.preventDefault();
                moveGroup(group.key);
              }}
              onDragEnd={() => setDraggedGroupKey(null)}
              onClick={() => setOpenGroups((current) => ({ ...current, [group.key]: !open }))}
              onKeyDown={(event) => {
                if (event.key === "Enter" || event.key === " ") {
                  event.preventDefault();
                  setOpenGroups((current) => ({ ...current, [group.key]: !open }));
                }
              }}
            >
              <span className="flex min-w-0 items-center gap-3">
                <GripVertical className="hidden h-4 w-4 shrink-0 text-stone xl:block" aria-hidden="true" />
                <span className="grid h-10 w-10 shrink-0 place-items-center rounded-xl bg-brand/10 text-brand">{institutionInitial(group.label)}</span>
                <span className="min-w-0">
                  <span className="block truncate text-lg font-semibold text-warm">{group.label}</span>
                  <span className="mt-0.5 block truncate text-xs text-stone">{group.path} · {group.rows.length} 个账户 · {group.currencies.length > 1 ? `${group.currencies.length} 个币种` : group.currencies[0] ?? "无币种"}</span>
                </span>
              </span>
              <span className="flex shrink-0 items-center gap-3">
                <span className="text-right">
                  <span className={`block font-semibold ${group.total < 0 ? "amount-expense" : "amount-gold"}`}>{formatGroupAmount(group, groupVisible(group))}</span>
                  <span className="text-xs text-stone">异常 {group.issueCount}</span>
                </span>
                <ChevronDown className={`h-5 w-5 text-olive transition ${open ? "rotate-180" : ""}`} />
              </span>
            </div>
            {open && <div className="border-t border-line">
              <div className="ledger-table-head hidden grid-cols-[minmax(0,1fr)_84px_minmax(108px,148px)_112px_168px] items-center gap-3 border-b border-line px-4 py-2 xl:grid">
                <span>账户</span>
                <span>币种</span>
                <span className="text-right">余额</span>
                <span>状态</span>
                <span className="text-right">操作</span>
              </div>
              {group.rows.map((row) => {
                const visible = rowVisible(row);
                const status = statusMap.get(row.account);
                const expanded = expandedAccount === row.account;
                return <div key={row.account} className="border-b border-line last:border-b-0">
                  <div
                    role="button"
                    tabIndex={0}
                    className={`grid w-full cursor-pointer grid-cols-[minmax(0,1fr)_auto] items-center gap-3 px-4 py-3 text-left outline-none hover:bg-paper focus-visible:ring-2 focus-visible:ring-brand focus-visible:ring-offset-2 focus-visible:ring-offset-panel xl:grid-cols-[minmax(0,1fr)_84px_minmax(108px,148px)_112px_168px] ${expanded ? "bg-[var(--selected-bg)]" : ""}`}
                    onClick={() => selectAccount(row)}
                    onKeyDown={(event) => {
                      if (event.key === "Enter" || event.key === " ") {
                        event.preventDefault();
                        selectAccount(row);
                      }
                    }}
                  >
                    <span className="min-w-0">
                      <span className="flex items-center gap-2">
                        <span className={`h-2.5 w-2.5 shrink-0 rounded-full ${status ? statusColor(status.status) : "bg-stone"}`} title={status ? statusTitle(status) : "未检查"} />
                        <strong className="truncate text-sm text-warm">{row.label}</strong>
                        {row.active === false && <span className="rounded bg-line px-1.5 py-0.5 text-[10px] text-stone">已关闭</span>}
                      </span>
                      <span className="mt-0.5 block truncate text-xs text-stone">{shortAccountPath(row.account)} · {lastActivityMap.get(row.account) ? `最近活动 ${lastActivityMap.get(row.account)}` : "暂无近期活动"}</span>
                    </span>
                    <span className="rounded-lg border border-line bg-paper px-2 py-1 text-xs text-olive xl:w-fit">{row.currency || "多币种"}</span>
                    <span className={`hidden text-right text-sm font-medium xl:block ${row.value < 0 || row.account.startsWith("Liabilities") ? "amount-expense" : "amount-gold"}`}>{formatRowAmount(row, visible)}</span>
                    <span className="hidden truncate text-xs text-stone xl:block">{status ? statusTitle(status) : "未检查"}</span>
                    <span className="hidden h-9 items-center justify-end gap-2 xl:flex">
                      <ClientNavLink href={`/accounts/${encodeURIComponent(row.account)}`} className="inline-flex h-9 min-w-12 items-center justify-center whitespace-nowrap rounded-lg border border-line bg-paper px-3 text-xs font-medium text-olive hover:bg-tag" onClick={(event) => event.stopPropagation()}>流水</ClientNavLink>
                      <ClientNavLink href="/reconcile" className="inline-flex h-9 min-w-12 items-center justify-center whitespace-nowrap rounded-lg bg-brand px-3 text-xs font-medium text-paper hover:bg-brand-light" onClick={(event) => event.stopPropagation()}>对账</ClientNavLink>
                      {onToggleAccount && <button type="button" className="inline-grid h-9 w-9 shrink-0 place-items-center rounded-lg border border-line bg-panel text-olive hover:bg-tag" onClick={(event) => { event.stopPropagation(); onToggleAccount(row.account); }} title={visible ? "隐藏该账户余额" : "显示该账户余额"}>{visible ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}</button>}
                    </span>
                  </div>
                  {expanded && <div className="hidden border-t border-line bg-paper/80 px-4 py-4 xl:block">
                    <AccountDetailPanel row={row} visible={visible} status={status} lastActivity={lastActivityMap.get(row.account)} points={trendMap[row.account] ?? []} onToggleAccount={onToggleAccount} inline />
                  </div>}
                  <div className="flex items-center justify-between gap-3 px-4 pb-3 xl:hidden">
                    <span className={`text-sm font-medium ${row.value < 0 || row.account.startsWith("Liabilities") ? "amount-expense" : "amount-gold"}`}>{formatRowAmount(row, visible)}</span>
                    <span className="text-xs text-stone">{status ? statusTitle(status) : "未检查"}</span>
                  </div>
                </div>;
              })}
            </div>}
          </div>;
        })}
      </div>

      <MobileAccountDetailSheet
        row={mobileDetailRow}
        visible={mobileDetailRow ? rowVisible(mobileDetailRow) : false}
        status={mobileDetailRow ? statusMap.get(mobileDetailRow.account) : undefined}
        lastActivity={mobileDetailRow ? lastActivityMap.get(mobileDetailRow.account) : undefined}
        points={mobileDetailRow ? trendMap[mobileDetailRow.account] ?? [] : []}
        onToggleAccount={onToggleAccount}
        onClose={() => setMobileAccount(null)}
      />
    </> : <p className="mt-4 rounded-xl border border-line bg-panel p-4 text-sm text-stone">当前筛选下没有账户。</p> : <p className="mt-4 rounded-xl border border-line bg-panel p-4 text-sm text-stone">暂无有流水且余额不为 0 的账户。</p>}
    {!full && <p className="mt-3 text-xs text-stone">完整账户在“账户”页；余额核对和断言集中在“对账”页。</p>}
  </section>;
}

function buildBalancePrefixGroups(rows: BalanceRow[], statusMap: Map<string, AccountStatus>): BalancePrefixGroup[] {
  const groupMap = new Map<string, BalanceRow[]>();
  for (const row of rows) {
    const key = accountPrefixKey(row.account);
    groupMap.set(key, [...groupMap.get(key) ?? [], row]);
  }
  return Array.from(groupMap.entries()).map(([key, groupRows]) => {
    const statusCounts: Record<AccountStatus["status"], number> = { green: 0, red: 0, yellow: 0, grey: 0 };
    for (const row of groupRows) {
      const status = statusMap.get(row.account);
      if (status) statusCounts[status.status] += 1;
    }
    return {
      key,
      label: institutionLabel(key, groupRows),
      path: key,
      rows: groupRows,
      total: groupRows.reduce((sum, row) => sum + row.value, 0),
      currencies: Array.from(new Set(groupRows.map((row) => row.currency || "多币种"))),
      statusCounts,
      issueCount: statusCounts.red + statusCounts.yellow + statusCounts.grey,
    };
  });
}

function orderBalancePrefixGroups(groups: BalancePrefixGroup[], order: string[]) {
  const index = new Map(order.map((key, position) => [key, position]));
  return [...groups].sort((a, b) => {
    const aIndex = index.get(a.key);
    const bIndex = index.get(b.key);
    if (aIndex != null && bIndex != null) return aIndex - bIndex;
    if (aIndex != null) return -1;
    if (bIndex != null) return 1;
    return a.label.localeCompare(b.label, "zh-Hans-CN");
  });
}

function reorderKeys(visibleKeys: string[], savedOrder: string[], sourceKey: string, targetKey: string) {
  const visibleSet = new Set(visibleKeys);
  const orderedVisible = [...savedOrder.filter((key) => visibleSet.has(key)), ...visibleKeys.filter((key) => !savedOrder.includes(key))];
  const from = orderedVisible.indexOf(sourceKey);
  const to = orderedVisible.indexOf(targetKey);
  if (from < 0 || to < 0) return savedOrder;
  const nextVisible = [...orderedVisible];
  const [moved] = nextVisible.splice(from, 1);
  nextVisible.splice(to, 0, moved);
  const hiddenSaved = savedOrder.filter((key) => !visibleSet.has(key));
  return [...nextVisible, ...hiddenSaved];
}

function readAccountGroupOrder() {
  if (typeof window === "undefined") return [];
  try {
    const value = window.localStorage.getItem(accountGroupOrderStorageKey);
    const parsed = value ? JSON.parse(value) : [];
    return Array.isArray(parsed) ? parsed.filter((item): item is string => typeof item === "string") : [];
  } catch {
    return [];
  }
}

function writeAccountGroupOrder(order: string[]) {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(accountGroupOrderStorageKey, JSON.stringify(order));
}

function accountMatchesStatusFilter(status: AccountStatus | undefined, filter: BalanceStatusFilter) {
  if (filter === "all") return true;
  if (!status) return false;
  if (filter === "issue") return status.status !== "green";
  return status.status === filter;
}

function accountLastActivity(rows: BalanceRow[], txns: Txn[]) {
  const accounts = new Set(rows.map((row) => row.account));
  const out = new Map<string, string>();
  for (const txn of txns) {
    for (const posting of txn.postings) {
      if (!accounts.has(posting.account)) continue;
      const previous = out.get(posting.account);
      if (!previous || txn.date > previous) out.set(posting.account, txn.date);
    }
  }
  return out;
}

function formatRowAmount(row: BalanceRow, visible: boolean) {
  if (!visible) return "••••••";
  const currency = row.currency ?? "CNY";
  return row.valuation ? formatValuation(row.value / 100, currency) : formatMoney(row.value / 100, currency);
}

function formatGroupAmount(group: BalancePrefixGroup, visible: boolean) {
  if (!visible) return "••••••";
  if (group.currencies.length !== 1 || group.currencies[0] === "多币种") return `${group.currencies.length} 币种`;
  return formatMoney(group.total / 100, group.currencies[0]);
}

function accountPrefixKey(account: string) {
  const parts = account.split(":");
  if ((parts[0] === "Assets" || parts[0] === "Liabilities") && parts.length >= 3) return parts.slice(0, 3).join(":");
  if (parts.length <= 2) return account;
  return parts.slice(0, -1).join(":");
}

function institutionLabel(prefix: string, rows: BalanceRow[]) {
  const common = commonChinesePrefix(rows.map((row) => row.label));
  if (common) return common;
  const parts = prefix.split(":");
  return parts.at(-1) ?? prefix;
}

function commonChinesePrefix(labels: string[]) {
  if (labels.length === 0) return "";
  const chars = Array.from(labels[0]).filter((char) => /[\u4e00-\u9fff]/.test(char));
  let prefix = "";
  for (const char of chars) {
    const next = prefix + char;
    if (!labels.every((label) => label.startsWith(next))) break;
    prefix = next;
  }
  return prefix.length >= 2 ? prefix : "";
}

function institutionInitial(label: string) {
  return Array.from(label.trim())[0] ?? "账";
}

function shortAccountPath(account: string) {
  return account.split(":").slice(0, -1).join(" > ") || account;
}

function BalanceMetric({ label, value }: { label: string; value: string }) {
  return <div className="rounded-xl border border-line bg-paper p-3"><div className="ledger-label">{label}</div><div className="mt-1 font-semibold tabular-nums text-olive">{value}</div></div>;
}

function MobileAccountDetailSheet({ row, visible, status, lastActivity, points, onToggleAccount, onClose }: { row: BalanceRow | null; visible: boolean; status?: AccountStatus; lastActivity?: string; points: number[]; onToggleAccount?: (account: string) => void; onClose: () => void }) {
  const [mounted, setMounted] = useState(false);

  useEffect(() => setMounted(true), []);

  useEffect(() => {
    if (!row) return;
    const originalOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => {
      document.body.style.overflow = originalOverflow;
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [row, onClose]);

  if (!mounted || !row) return null;

  return createPortal(
    <div className="fixed inset-0 z-[120] xl:hidden">
      <button className="absolute inset-0 bg-[var(--overlay)]" aria-label="关闭账户详情" onClick={onClose} />
      <div className="absolute inset-x-0 bottom-0 max-h-[82dvh] overflow-y-auto rounded-t-2xl border border-line bg-panel p-5 pb-[calc(env(safe-area-inset-bottom)+1.25rem)] shadow-[var(--float-shadow)]" role="dialog" aria-modal="true" aria-label="账户详情">
        <div className="mx-auto mb-4 h-1 w-12 rounded-full bg-line" />
        <AccountDetailPanel row={row} visible={visible} status={status} lastActivity={lastActivity} points={points} onToggleAccount={onToggleAccount} compact onClose={onClose} />
      </div>
    </div>,
    document.body,
  );
}

function AccountDetailPanel({ row, visible, status, lastActivity, points, onToggleAccount, compact, inline, onClose }: { row: BalanceRow | null; visible: boolean; status?: AccountStatus; lastActivity?: string; points: number[]; onToggleAccount?: (account: string) => void; compact?: boolean; inline?: boolean; onClose?: () => void }) {
  if (!row) {
    return <aside className="rounded-xl border border-line bg-panel p-4 text-sm text-stone">选择一个账户查看详情。</aside>;
  }
  return <aside className={compact || inline ? "" : "rounded-xl border border-line bg-panel p-4"}>
    <div className="flex items-start justify-between gap-3">
      <div className="min-w-0">
        <h3 className="truncate text-xl font-semibold text-warm">{row.label}</h3>
        <p className="mt-1 break-all text-xs text-stone">{row.account}</p>
      </div>
      <div className="flex shrink-0 items-center gap-2">
        {onToggleAccount && <button className="rounded-xl border border-line p-2 text-olive hover:bg-tag" onClick={() => onToggleAccount(row.account)} title={visible ? "隐藏该账户余额" : "显示该账户余额"}>{visible ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}</button>}
        {onClose && <button className="rounded-xl border border-line p-2 text-olive hover:bg-tag" onClick={onClose} title="关闭账户详情"><X className="h-4 w-4" /></button>}
      </div>
    </div>
    <div className={`mt-5 grid gap-3 ${compact || inline ? "grid-cols-3" : "grid-cols-1 2xl:grid-cols-3"}`}>
      <BalanceMetric label="余额" value={formatRowAmount(row, visible)} />
      <BalanceMetric label="状态" value={status ? statusTitle(status) : "未检查"} />
      <BalanceMetric label="币种" value={row.currency || "多币种"} />
    </div>
    <div className="relative mt-4 min-h-24 overflow-hidden rounded-xl border border-line bg-paper p-3">
      <AccountSparkline points={points} liability={row.account.startsWith("Liabilities")} />
      <div className="relative z-10 text-xs text-stone">最近活动</div>
      <div className="relative z-10 mt-2 text-sm font-medium text-olive">{lastActivity ?? "暂无近期活动"}</div>
      <div className="relative z-10 mt-1 text-xs text-stone">{row.active === false ? "账户已关闭" : "账户启用中"}</div>
    </div>
    <div className="mt-4 grid grid-cols-2 gap-3">
      <ClientNavLink href={`/accounts/${encodeURIComponent(row.account)}`} className="inline-flex h-11 items-center justify-center gap-2 rounded-xl border border-line bg-paper text-sm font-medium text-olive hover:bg-tag"><ListChecks className="h-4 w-4" />流水</ClientNavLink>
      <ClientNavLink href="/reconcile" className="inline-flex h-11 items-center justify-center gap-2 rounded-xl bg-brand text-sm font-medium text-paper hover:bg-brand-light"><ListChecks className="h-4 w-4" />对账</ClientNavLink>
    </div>
  </aside>;
}

function accountTrendPoints(row: BalanceRow, txns: Txn[]) {
  if (row.valuation) return [];
  const deltas = new Map<string, number>();
  for (const txn of txns) {
    const delta = txn.postings.filter((posting) => posting.account === row.account).reduce((sum, posting) => sum + posting.amount, 0);
    if (delta !== 0) deltas.set(txn.date, (deltas.get(txn.date) ?? 0) + delta);
  }
  const dates = Array.from(deltas.keys()).sort();
  if (!dates.length) return [row.value, row.value];
  let balance = row.value - Array.from(deltas.values()).reduce((sum, value) => sum + value, 0);
  const points = [balance];
  for (const date of dates) {
    balance += deltas.get(date) ?? 0;
    points.push(balance);
  }
  return points;
}

function AccountSparkline({ points, liability }: { points: number[]; liability: boolean }) {
  if (points.length < 2) return null;
  const min = Math.min(...points);
  const max = Math.max(...points);
  const span = Math.max(1, max - min);
  const width = 180;
  const height = 70;
  const path = points.map((point, index) => {
    const x = points.length === 1 ? 0 : (index / (points.length - 1)) * width;
    const y = max === min ? height / 2 : height - ((point - min) / span) * (height - 12) - 6;
    return `${index === 0 ? "M" : "L"}${x.toFixed(2)},${y.toFixed(2)}`;
  }).join(" ");
  const stroke = liability ? "rgb(var(--color-expense))" : "rgb(var(--color-brand))";
  return <div className="pointer-events-none absolute bottom-5 right-4 top-6 z-0 w-[38%] opacity-[0.08] sm:w-[52%] sm:opacity-[0.12]" aria-hidden="true">
    <svg className="h-full w-full" viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="none">
      <path d={path} fill="none" stroke={stroke} strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.5" vectorEffect="non-scaling-stroke" />
    </svg>
  </div>;
}

export function CreditCardPanel({ cards, statuses, valuationCurrency, visibleAccountMap = {}, visible, summaryVisible, onToggleSummaryVisible, onToggleAccount }: { cards: CreditCardAnalytics[]; statuses: AccountStatus[]; valuationCurrency: string; visibleAccountMap?: Record<string, boolean>; visible: boolean; summaryVisible: boolean; onToggleSummaryVisible: () => void; onToggleAccount?: (account: string) => void }) {
  if (!cards.length) return null;
  const totalOutstanding = cards.reduce((sum, card) => sum + card.outstanding, 0);
  const totalSpend = cards.reduce((sum, card) => sum + card.periodSpend, 0);
  const totalBillCycleSpend = cards.reduce((sum, card) => sum + card.billCycleSpend, 0);
  const totalRepayments = cards.reduce((sum, card) => sum + card.periodRepayments, 0);
  const billing = cards[0];
  const summaryMask = (value: string) => summaryVisible ? value : "••••••";
  return <section className="card mt-6 p-4"><div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"><div><div className="flex items-center gap-3"><h2 className="font-serif text-2xl">信用卡视图</h2><button className="shrink-0 rounded-xl border border-line px-2 py-1 text-olive hover:bg-tag" onClick={onToggleSummaryVisible} title={summaryVisible ? "隐藏信用卡汇总" : "显示信用卡汇总"}>{summaryVisible ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}</button></div><p className="mt-1 text-sm text-olive">账单周期 {billing.billCycleStart.slice(5)} ~ {billing.billCycleEnd.slice(5)}；{billing.statementDate.slice(5)} 出账，最晚 {billing.dueDate.slice(5)} 还款。</p></div><div className="rounded-2xl border border-line bg-panel px-4 py-3 text-right"><div className="text-xs text-stone">总未还</div><div className="amount-expense text-xl font-semibold">{summaryMask(formatValuation(totalOutstanding / 100, valuationCurrency))}</div></div></div><div className="mt-4 grid gap-3 sm:grid-cols-4"><CreditSummary label="账单周期消费" value={summaryMask(formatValuation(totalBillCycleSpend / 100, valuationCurrency))} /><CreditSummary label="当前范围刷卡" value={summaryMask(formatValuation(totalSpend / 100, valuationCurrency))} /><CreditSummary label="当前范围还款" value={summaryMask(formatValuation(totalRepayments / 100, valuationCurrency))} /><CreditSummary label="卡片数量" value={`${cards.length}`} /></div><div className="mt-4 grid gap-3 md:grid-cols-2 xl:grid-cols-3">{cards.map((card) => { const cardVisible = visibleAccountMap[card.account] ?? visible; const cardMask = (value: string) => cardVisible ? value : "••••••"; const st = statuses.find((item) => item.account === card.account); return <div key={card.account} className="rounded-2xl border border-line bg-panel p-4"><div className="flex items-start justify-between gap-3"><div className="min-w-0"><div className="flex items-center gap-2 text-sm font-medium text-olive">{st && <span className={`inline-block h-2.5 w-2.5 shrink-0 rounded-full ${statusColor(st.status)}`} title={statusTitle(st)} />}{card.label}</div><div className="mt-1 truncate text-xs text-stone">{card.account}</div></div>{onToggleAccount && <button className="shrink-0 rounded-xl border border-line px-2 py-1 text-olive hover:bg-tag" onClick={() => onToggleAccount(card.account)} title={cardVisible ? "隐藏该信用卡金额" : "显示该信用卡金额"}>{cardVisible ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}</button>}</div><div className="amount-expense mt-3 text-2xl font-semibold">{cardMask(formatCompactValuation(card.outstanding / 100, valuationCurrency))}</div><div className="mt-4 grid grid-cols-2 gap-3 text-sm"><CreditSummary label="账单周期消费" value={cardMask(formatValuation(card.billCycleSpend / 100, valuationCurrency))} /><CreditSummary label="当前范围刷卡" value={cardMask(formatValuation(card.periodSpend / 100, valuationCurrency))} /><CreditSummary label="最晚还款" value={card.dueDate.slice(5)} /><CreditSummary label="最近活动" value={card.lastActivityDate?.slice(5) ?? "—"} /></div></div>; })}</div></section>;
}

function CreditSummary({ label, value }: { label: string; value: string }) {
  return <div className="rounded-xl border border-line bg-panel p-3"><div className="text-xs text-stone">{label}</div><div className="mt-1 font-medium text-olive">{value}</div></div>;
}

export function AccountManager({ accounts, onAdded, refreshGitStatus, showToast }: { accounts: AccountView[]; balances: Record<string, number>; onAdded: () => void | Promise<void>; refreshGitStatus: () => void | Promise<void>; showToast: (kind: "info" | "success" | "error", text: string) => void }) {
  const [date, setDate] = useState(new Date().toISOString().slice(0, 10));
  const [account, setAccount] = useState("");
  const [alias, setAlias] = useState("");
  const [currency, setCurrency] = useState("");
  const [message, setMessage] = useState("");
  const [agentOpen, setAgentOpen] = useState(false);
  const groups: { key: AccountGroup; label: string }[] = [{ key: "cash", label: "现金账户" }, { key: "credit", label: "信用卡" }, { key: "liability", label: "其他负债" }, { key: "wealth", label: "理财账户" }, { key: "receivable", label: "应收应付" }, { key: "expense", label: "支出分类" }, { key: "income", label: "收入分类" }, { key: "equity", label: "权益" }, { key: "other", label: "其他" }];
  const visibleGroups = groups.map((group) => ({ ...group, rows: accounts.filter((account) => account.group === group.key) })).filter((group) => group.rows.length > 0);
  async function submit() {
    setMessage("写入中...");
    const res = await fetch("/api/ledger/accounts", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ date, account, alias, currency: currency.trim().toUpperCase() }) });
    const data = await readJson<{ error?: string }>(res);
    if (!res.ok) { setMessage(data.error || "新增失败"); return; }
    setMessage("账户已新增");
    setAccount("");
    setAlias("");
    onAdded();
  }
  return <section className="card p-4"><div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"><div><h2 className="font-serif text-2xl">账户管理</h2><p className="mt-2 text-sm text-olive">这里管理账户定义和分组；余额集中在下方“账户余额”里并默认隐藏。</p></div><Button type="button" variant="outline" className="shrink-0 rounded-xl bg-panel text-olive" onPointerEnter={() => void loadAccountAgentChat()} onFocus={() => void loadAccountAgentChat()} onClick={() => setAgentOpen(true)}><Bot className="h-4 w-4 text-brand" /><span>编辑账户</span><Pencil className="h-3.5 w-3.5 text-stone" /></Button></div><div className="mt-4 grid gap-3 sm:grid-cols-[150px_1fr_1fr_110px_auto]"><Input className="h-12 bg-panel" type="date" value={date} onChange={(e) => setDate(e.target.value)} /><Input className="h-12 bg-panel" placeholder="Assets:HK:HSBC:HKD" value={account} onChange={(e) => setAccount(e.target.value)} /><Input className="h-12 bg-panel" placeholder="显示名 / alias" value={alias} onChange={(e) => setAlias(e.target.value)} /><Input className="h-12 bg-panel uppercase" placeholder="HKD / 空" value={currency} onChange={(e) => setCurrency(e.target.value.toUpperCase())} /><Button className="h-12 px-4" onClick={submit}>新增账户</Button></div>{message && <p className="mt-2 text-sm text-olive">{message}</p>}{visibleGroups.length ? <div className="mt-5 grid gap-3 sm:grid-cols-2">{visibleGroups.map((group) => <div key={group.key} className="rounded-xl border border-line bg-panel p-3"><h3 className="text-sm font-medium text-stone">{group.label} · {group.rows.length}</h3><div className="mt-2 space-y-2">{group.rows.map((a) => <div key={a.account} className="text-sm"><div className="flex items-center gap-2"><strong>{a.label}</strong><span className="rounded bg-tag px-1.5 py-0.5 text-[10px] text-stone">{a.currency || "多币种"}</span>{!a.active && <span className="rounded bg-line px-2 py-0.5 text-xs">已关闭</span>}</div><div className="mt-0.5 truncate text-xs text-stone">{a.account}</div></div>)}</div></div>)}</div> : <p className="mt-5 rounded-xl border border-line bg-panel p-4 text-sm text-stone">暂无有流水且余额不为 0 的账户。</p>}{agentOpen && <Suspense fallback={null}><LazyAccountAgentChat open={agentOpen} onClose={() => setAgentOpen(false)} onChanged={onAdded} refreshGitStatus={refreshGitStatus} showToast={showToast} /></Suspense>}</section>;
}

// ── 账户状态指示器 ──

export function statusColor(status: AccountStatus["status"]): string {
  const map: Record<AccountStatus["status"], string> = {
    green: "bg-[var(--success)]",
    red: "bg-[var(--danger)]",
    yellow: "bg-[var(--warning)]",
    grey: "bg-stone",
  };
  return map[status];
}

export function statusTitle(st: AccountStatus): string {
  switch (st.status) {
    case "green": return "断言通过";
    case "red": return "断言失败";
    case "yellow": return "未断言";
    case "grey": return st.lastEntryDate ? `超过60天未更新（最近：${st.lastEntryDate}）` : "无记录";
  }
}
