import { lazy, Suspense, useEffect, useMemo, useState } from "react";
import { createPortal } from "react-dom";
import { ClientNavLink } from "./ClientNavLink";
import { Archive, ArrowLeftRight, Bot, ChevronDown, CreditCard, Eye, EyeOff, ListChecks, PanelRightClose, PanelRightOpen, Pencil, TrendingUp, WalletCards, X } from "lucide-react";
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
type BalanceGroup = {
  key: AccountGroup;
  label: string;
  rows: BalanceRow[];
  total: number;
  currencies: string[];
  statusCounts: Record<AccountStatus["status"], number>;
  issueCount: number;
};
type BalanceCluster = {
  key: string;
  label: string;
  rows: BalanceRow[];
  total: number;
  currencies: string[];
  issueCount: number;
};

const balanceGroupDefs: { key: AccountGroup; label: string }[] = [
  { key: "cash", label: "日常资金" },
  { key: "credit", label: "信用卡" },
  { key: "wealth", label: "投资理财" },
  { key: "receivable", label: "应收应付" },
  { key: "liability", label: "其他负债" },
  { key: "other", label: "低频 / 归档" },
];

const balanceGroupKeys = new Set<AccountGroup>(balanceGroupDefs.map((group) => group.key));

const statusFilters: { key: BalanceStatusFilter; label: string }[] = [
  { key: "all", label: "全部" },
  { key: "issue", label: "异常" },
  { key: "yellow", label: "未断言" },
  { key: "grey", label: "长期未更新" },
];

export function BalanceGrid({ rows, full, allVisible = false, visibleAccountMap = {}, onToggleAll, onToggleAccount, statuses, txns = [] }: { rows: BalanceRow[]; full?: boolean; allVisible?: boolean; visibleAccountMap?: Record<string, boolean>; onToggleAll?: () => void; onToggleAccount?: (account: string) => void; statuses?: AccountStatus[]; txns?: Txn[] }) {
  const trendMap = useMemo(() => Object.fromEntries(rows.map((row) => [row.account, accountTrendPoints(row, txns)])), [rows, txns]);
  const statusMap = useMemo(() => new Map((statuses ?? []).map((status) => [status.account, status])), [statuses]);
  const lastActivityMap = useMemo(() => accountLastActivity(rows, txns), [rows, txns]);
  const [statusFilter, setStatusFilter] = useState<BalanceStatusFilter>("all");
  const [selectedGroupKey, setSelectedGroupKey] = useState<AccountGroup>("cash");
  const [selectedAccount, setSelectedAccount] = useState<string | null>(null);
  const [desktopDetailOpen, setDesktopDetailOpen] = useState(true);
  const [openGroups, setOpenGroups] = useState<Record<string, boolean>>({});

  const filteredRows = useMemo(() => rows.filter((row) => accountMatchesStatusFilter(statusMap.get(row.account), statusFilter)), [rows, statusFilter, statusMap]);
  const groups = useMemo(() => buildBalanceGroups(filteredRows, statusMap), [filteredRows, statusMap]);
  const selectedGroup = groups.find((group) => group.key === selectedGroupKey) ?? groups[0] ?? null;
  const selectedClusters = useMemo(() => selectedGroup ? buildBalanceClusters(selectedGroup.rows, statusMap) : [], [selectedGroup, statusMap]);
  const desktopDetailRow = selectedGroup?.rows.find((row) => row.account === selectedAccount) ?? selectedGroup?.rows[0] ?? null;
  const mobileDetailRow = selectedAccount ? rows.find((row) => row.account === selectedAccount) ?? null : null;

  function rowVisible(row: BalanceRow) {
    return visibleAccountMap[row.account] ?? allVisible;
  }

  function groupVisible(group: BalanceGroup) {
    return group.rows.length > 0 && group.rows.every(rowVisible);
  }

  function clusterVisible(cluster: BalanceCluster) {
    return cluster.rows.length > 0 && cluster.rows.every(rowVisible);
  }

  function selectGroup(group: BalanceGroup) {
    setSelectedGroupKey(group.key);
    setSelectedAccount(group.rows[0]?.account ?? null);
  }

  return <section className="card relative mt-6 p-4">
    <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
      <div>
        <h2 className="font-serif text-2xl">账户余额</h2>
        <p className="mt-1 text-sm text-stone">按账户用途收纳余额；桌面端用分组目录，移动端用抽屉展开。</p>
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
      <div className="mt-4 hidden gap-4 xl:grid xl:grid-cols-[236px_minmax(0,1fr)]">
        <div className="rounded-xl border border-line bg-panel p-2">
          <div className="flex h-10 items-center justify-between px-2 text-sm font-medium text-olive">
            <span>分组</span>
            <span className="ledger-label">{filteredRows.length} 个账户</span>
          </div>
          <div className="space-y-2">
            {groups.map((group) => {
              const selected = selectedGroup?.key === group.key;
              return <button key={group.key} className={`w-full rounded-xl border p-3 text-left transition ${selected ? "border-brand bg-brand text-paper shadow-[var(--paper-shadow)]" : "border-line bg-paper text-olive hover:bg-tag"}`} onClick={() => selectGroup(group)}>
                <div className="flex items-start gap-3">
                  <span className={`mt-0.5 ${selected ? "text-paper" : "text-warm"}`}>{groupIcon(group.key, "h-5 w-5")}</span>
                  <span className="min-w-0 flex-1">
                    <span className="flex items-center justify-between gap-2">
                      <strong className="truncate text-sm">{group.label}</strong>
                      <span className={`shrink-0 text-xs ${selected ? "text-paper/75" : "text-stone"}`}>{group.rows.length}</span>
                    </span>
                    <span className={`mt-2 block text-lg font-semibold ${selected ? "text-paper" : group.total < 0 ? "amount-expense" : "amount-gold"}`}>{formatGroupAmount(group, groupVisible(group))}</span>
                    <span className={`mt-1 flex items-center gap-1 text-xs ${selected ? "text-paper/75" : "text-stone"}`}>
                      <span className={`inline-block h-2 w-2 rounded-full ${group.issueCount ? "bg-[var(--warning)]" : "bg-[var(--success)]"}`} />
                      异常 {group.issueCount}
                    </span>
                  </span>
                </div>
              </button>;
            })}
          </div>
        </div>

        <div className="min-w-0 rounded-xl border border-line bg-panel">
          {selectedGroup && <>
            <div className="border-b border-line p-4">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div className="flex items-center gap-3">
                  <span className="text-warm">{groupIcon(selectedGroup.key, "h-6 w-6")}</span>
                  <div>
                    <h3 className="text-xl font-semibold text-warm">当前分组：{selectedGroup.label}</h3>
                    <p className="mt-1 text-xs text-stone">{selectedGroup.rows.length} 个账户 · {selectedGroup.currencies.length > 1 ? `${selectedGroup.currencies.length} 个币种` : selectedGroup.currencies[0] ?? "无币种"}</p>
                  </div>
                </div>
                <div className="flex shrink-0 items-center gap-3">
                  <div className={`text-right text-2xl font-semibold ${selectedGroup.total < 0 ? "amount-expense" : "amount-gold"}`}>{formatGroupAmount(selectedGroup, groupVisible(selectedGroup))}</div>
                  <button
                    type="button"
                    className="hidden h-10 w-10 place-items-center rounded-xl border border-line bg-paper text-olive hover:bg-tag xl:grid"
                    onClick={() => setDesktopDetailOpen((open) => !open)}
                    aria-label={desktopDetailOpen ? "收起账户详情" : "展开账户详情"}
                    title={desktopDetailOpen ? "收起账户详情" : "展开账户详情"}
                  >
                    {desktopDetailOpen ? <PanelRightClose className="h-4 w-4" /> : <PanelRightOpen className="h-4 w-4" />}
                  </button>
                </div>
              </div>
              <div className="mt-4 grid gap-3 sm:grid-cols-4">
                <BalanceMetric label="账户数量" value={`${selectedGroup.rows.length}`} />
                <BalanceMetric label="断言通过" value={`${selectedGroup.statusCounts.green}`} />
                <BalanceMetric label="未断言" value={`${selectedGroup.statusCounts.yellow}`} />
                <BalanceMetric label="长期未更新" value={`${selectedGroup.statusCounts.grey}`} />
              </div>
            </div>
            <div className="overflow-hidden">
              <div className="min-w-0">
                <div className="ledger-table-head grid grid-cols-[minmax(0,1fr)_64px_minmax(92px,124px)_96px_36px] items-center gap-3 border-b border-line px-4 py-3">
                  <span>账户</span>
                  <span>币种</span>
                  <span className="text-right">余额</span>
                  <span>状态</span>
                  <span></span>
                </div>
                {selectedClusters.map((cluster) => (
                  <div key={cluster.key}>
                    <BalanceClusterHeader cluster={cluster} visible={clusterVisible(cluster)} />
                    {cluster.rows.map((row) => {
                      const visible = rowVisible(row);
                      const status = statusMap.get(row.account);
                      const selected = desktopDetailRow?.account === row.account;
                      return <div
                        key={row.account}
                        role="button"
                        tabIndex={0}
                        className={`grid w-full cursor-pointer grid-cols-[minmax(0,1fr)_64px_minmax(92px,124px)_96px_36px] items-center gap-3 border-b border-line px-4 py-3 text-left text-sm outline-none last:border-b-0 focus-visible:ring-2 focus-visible:ring-brand focus-visible:ring-offset-2 focus-visible:ring-offset-panel ${selected ? "bg-[var(--selected-bg)]" : "hover:bg-paper"}`}
                        onClick={() => setSelectedAccount(row.account)}
                        onKeyDown={(event) => {
                          if (event.key === "Enter" || event.key === " ") {
                            event.preventDefault();
                            setSelectedAccount(row.account);
                          }
                        }}
                      >
                        <span className="min-w-0">
                          <span className="flex items-center gap-2">
                            {status && <span className={`inline-block h-2.5 w-2.5 shrink-0 rounded-full ${statusColor(status.status)}`} title={statusTitle(status)} />}
                            <strong className="truncate text-warm">{row.label}</strong>
                            {row.active === false && <span className="rounded bg-line px-1.5 py-0.5 text-[10px] text-stone">已关闭</span>}
                          </span>
                          <span className="mt-1 block truncate text-xs text-stone">{shortAccountPath(row.account)} · {lastActivityMap.get(row.account) ? `最近活动 ${lastActivityMap.get(row.account)}` : "暂无近期活动"}</span>
                        </span>
                        <span className="w-fit rounded-lg border border-line bg-paper px-2 py-1 text-xs text-olive">{row.currency || "多币种"}</span>
                        <span className={`text-right font-medium ${row.value < 0 || row.account.startsWith("Liabilities") ? "amount-expense" : "amount-gold"}`}>{formatRowAmount(row, visible)}</span>
                        <span className="truncate text-xs text-stone">{status ? statusTitle(status) : "未检查"}</span>
                        <span className="flex justify-end">
                          {onToggleAccount && <button type="button" className="rounded-lg border border-line bg-panel p-1.5 text-olive hover:bg-tag" onClick={(event) => { event.stopPropagation(); onToggleAccount(row.account); }} title={visible ? "隐藏该账户余额" : "显示该账户余额"}>{visible ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}</button>}
                        </span>
                      </div>;
                    })}
                  </div>
                ))}
              </div>
            </div>
          </>}
        </div>

        {desktopDetailOpen && desktopDetailRow && (
          <div className="pointer-events-none fixed right-6 top-28 z-[80] hidden w-[340px] max-w-[calc(100vw-3rem)] xl:block">
            <div className="pointer-events-auto rounded-2xl shadow-[var(--float-shadow)]">
              <AccountDetailPanel row={desktopDetailRow} visible={rowVisible(desktopDetailRow)} status={statusMap.get(desktopDetailRow.account)} lastActivity={lastActivityMap.get(desktopDetailRow.account)} points={trendMap[desktopDetailRow.account] ?? []} onToggleAccount={onToggleAccount} onClose={() => setDesktopDetailOpen(false)} floating />
            </div>
          </div>
        )}
      </div>

      <div className="mt-4 space-y-3 xl:hidden">
        {groups.map((group, index) => {
          const open = openGroups[group.key] ?? (index === 0 || group.issueCount > 0);
          return <div key={group.key} className="overflow-hidden rounded-xl border border-line bg-panel">
            <button className="flex w-full items-center justify-between gap-3 p-4 text-left" onClick={() => setOpenGroups((current) => ({ ...current, [group.key]: !open }))}>
              <span className="flex min-w-0 items-center gap-3">
                <span className="text-warm">{groupIcon(group.key, "h-6 w-6")}</span>
                <span className="min-w-0">
                  <span className="block truncate text-lg font-semibold text-warm">{group.label}</span>
                  <span className="mt-0.5 block text-xs text-stone">{group.rows.length} 个账户</span>
                </span>
              </span>
              <span className="flex shrink-0 items-center gap-3">
                <span className="text-right">
                  <span className={`block font-semibold ${group.total < 0 ? "amount-expense" : "amount-gold"}`}>{formatGroupAmount(group, groupVisible(group))}</span>
                  <span className="text-xs text-stone">异常 {group.issueCount}</span>
                </span>
                <ChevronDown className={`h-5 w-5 text-olive transition ${open ? "rotate-180" : ""}`} />
              </span>
            </button>
            {open && <div className="border-t border-line">
              {buildBalanceClusters(group.rows, statusMap).map((cluster) => (
                <div key={cluster.key}>
                  <div className="flex items-center justify-between gap-3 border-b border-line bg-paper/70 px-4 py-2 text-xs text-stone">
                    <span className="truncate font-medium text-olive">{cluster.label}</span>
                    <span className="ledger-label shrink-0">{cluster.rows.length} 个</span>
                  </div>
                  {cluster.rows.map((row) => {
                    const visible = rowVisible(row);
                    const status = statusMap.get(row.account);
                    return <button key={row.account} className="flex w-full items-center gap-3 border-b border-line px-4 py-3 text-left last:border-b-0 hover:bg-paper" onClick={() => setSelectedAccount(row.account)}>
                      <span className={`h-2.5 w-2.5 shrink-0 rounded-full ${status ? statusColor(status.status) : "bg-stone"}`} />
                      <span className="min-w-0 flex-1">
                        <span className="block truncate text-sm font-semibold text-warm">{row.label}</span>
                        <span className="mt-0.5 block truncate text-xs text-stone">{shortAccountPath(row.account)}</span>
                      </span>
                      <span className="shrink-0 rounded-lg border border-line bg-paper px-2 py-1 text-xs text-olive">{row.currency || "多币种"}</span>
                      <span className={`shrink-0 text-right text-sm font-medium ${row.value < 0 || row.account.startsWith("Liabilities") ? "amount-expense" : "amount-gold"}`}>{formatRowAmount(row, visible)}</span>
                    </button>;
                  })}
                </div>
              ))}
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
        onClose={() => setSelectedAccount(null)}
      />
    </> : <p className="mt-4 rounded-xl border border-line bg-panel p-4 text-sm text-stone">当前筛选下没有账户。</p> : <p className="mt-4 rounded-xl border border-line bg-panel p-4 text-sm text-stone">暂无有流水且余额不为 0 的账户。</p>}
    {!full && <p className="mt-3 text-xs text-stone">完整账户在“账户”页；余额核对和断言集中在“对账”页。</p>}
  </section>;
}

function buildBalanceGroups(rows: BalanceRow[], statusMap: Map<string, AccountStatus>): BalanceGroup[] {
  return balanceGroupDefs.map((def) => {
    const groupRows = rows.filter((row) => balanceGroupKey(row) === def.key);
    const statusCounts: Record<AccountStatus["status"], number> = { green: 0, red: 0, yellow: 0, grey: 0 };
    for (const row of groupRows) {
      const status = statusMap.get(row.account);
      if (status) statusCounts[status.status] += 1;
    }
    return {
      ...def,
      rows: groupRows,
      total: groupRows.reduce((sum, row) => sum + row.value, 0),
      currencies: Array.from(new Set(groupRows.map((row) => row.currency || "多币种"))),
      statusCounts,
      issueCount: statusCounts.red + statusCounts.yellow + statusCounts.grey,
    };
  }).filter((group) => group.rows.length > 0);
}

function buildBalanceClusters(rows: BalanceRow[], statusMap: Map<string, AccountStatus>): BalanceCluster[] {
  const clusterMap = new Map<string, BalanceRow[]>();
  for (const row of rows) {
    const key = accountClusterKey(row.account);
    clusterMap.set(key, [...clusterMap.get(key) ?? [], row]);
  }
  return Array.from(clusterMap.entries()).map(([key, clusterRows]) => ({
    key,
    label: accountClusterLabel(key),
    rows: clusterRows,
    total: clusterRows.reduce((sum, row) => sum + row.value, 0),
    currencies: Array.from(new Set(clusterRows.map((row) => row.currency || "多币种"))),
    issueCount: clusterRows.filter((row) => {
      const status = statusMap.get(row.account);
      return status && status.status !== "green";
    }).length,
  }));
}

function balanceGroupKey(row: BalanceRow): AccountGroup {
  const key = row.group ?? "other";
  return balanceGroupKeys.has(key) ? key : "other";
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

function formatGroupAmount(group: BalanceGroup, visible: boolean) {
  if (!visible) return "••••••";
  if (group.currencies.length !== 1 || group.currencies[0] === "多币种") return `${group.currencies.length} 币种`;
  return formatMoney(group.total / 100, group.currencies[0]);
}

function formatClusterAmount(cluster: BalanceCluster, visible: boolean) {
  if (!visible) return "••••••";
  if (cluster.currencies.length !== 1 || cluster.currencies[0] === "多币种") return `${cluster.currencies.length} 币种`;
  return formatMoney(cluster.total / 100, cluster.currencies[0]);
}

function accountClusterKey(account: string) {
  const parts = account.split(":");
  if (parts.length <= 3) return account;
  return parts.slice(0, -1).join(":");
}

function accountClusterLabel(clusterKey: string) {
  const parts = clusterKey.split(":");
  if ((parts[0] === "Assets" || parts[0] === "Liabilities") && parts.length > 1) return parts.slice(1).join(" / ");
  return parts.join(" / ");
}

function shortAccountPath(account: string) {
  return account.split(":").slice(0, -1).join(" > ") || account;
}

function groupIcon(group: AccountGroup, className: string) {
  if (group === "credit") return <CreditCard className={className} />;
  if (group === "wealth") return <TrendingUp className={className} />;
  if (group === "receivable" || group === "liability") return <ArrowLeftRight className={className} />;
  if (group === "other") return <Archive className={className} />;
  return <WalletCards className={className} />;
}

function BalanceMetric({ label, value }: { label: string; value: string }) {
  return <div className="rounded-xl border border-line bg-paper p-3"><div className="ledger-label">{label}</div><div className="mt-1 font-semibold tabular-nums text-olive">{value}</div></div>;
}

function BalanceClusterHeader({ cluster, visible }: { cluster: BalanceCluster; visible: boolean }) {
  return <div className="ledger-table-head grid grid-cols-[minmax(0,1fr)_64px_minmax(92px,124px)_96px_36px] items-center gap-3 border-b border-line px-4 py-2">
    <span className="min-w-0 truncate font-medium text-olive">{cluster.label}</span>
    <span className="rounded-lg border border-line bg-panel px-2 py-1 text-center text-olive">{cluster.rows.length} 个</span>
    <span className={`text-right font-medium ${cluster.total < 0 ? "amount-expense" : "amount-gold"}`}>{formatClusterAmount(cluster, visible)}</span>
    <span>异常 {cluster.issueCount}</span>
    <span></span>
  </div>;
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

function AccountDetailPanel({ row, visible, status, lastActivity, points, onToggleAccount, compact, floating, onClose }: { row: BalanceRow | null; visible: boolean; status?: AccountStatus; lastActivity?: string; points: number[]; onToggleAccount?: (account: string) => void; compact?: boolean; floating?: boolean; onClose?: () => void }) {
  if (!row) {
    return <aside className="rounded-xl border border-line bg-panel p-4 text-sm text-stone">选择一个账户查看详情。</aside>;
  }
  return <aside className={`${compact ? "" : "rounded-xl border border-line bg-panel p-4"} ${floating ? "bg-panel/95 backdrop-blur" : ""}`}>
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
    <div className={`mt-5 grid gap-3 ${compact ? "grid-cols-3" : "grid-cols-1 2xl:grid-cols-3"}`}>
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
