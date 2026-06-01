"use client";

import { useEffect, useMemo, useState } from "react";
import { ClientNavLink } from "./ClientNavLink";
import { ArrowLeft, ChevronDown, ChevronUp } from "lucide-react";
import { readJson } from "@/lib/clientFetch";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Area,
  AreaChart,
  CartesianGrid,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { formatCny } from "@/lib/money";
import { formatTimeRangeLabel, makeTimeRange, navigateTimeRange, type TimePreset, type TimeRange } from "@/lib/timeRange";
import type { AccountDetailRow } from "./types";

type AccountDetail = {
  account: string;
  label: string;
  alias: string | null;
  group: string;
  active: boolean;
  currency: string;
  currentBalance: number;
  rows: AccountDetailRow[];
};

function chartMoney(value: number) {
  return new Intl.NumberFormat("en-US", {
    notation: "compact",
    compactDisplay: "short",
    maximumFractionDigits: 1,
  }).format(value);
}

function AmountCell({ amount }: { amount: number }) {
  const sign = amount >= 0 ? "+" : "";
  const cls =
    amount > 0
      ? "amount-income"
      : amount < 0
        ? "amount-expense"
        : "text-stone";
  return (
    <span className={`whitespace-nowrap tabular-nums font-medium ${cls}`}>
      {sign}
      {formatCny(amount / 100)}
    </span>
  );
}

function accountRowKey(row: AccountDetailRow): string {
  return `${row.txn.source.file}:${row.txn.source.line}:${row.txn.source.hash ?? ""}`;
}

const ACCOUNT_TIME_PRESETS: { key: TimePreset; label: string }[] = [
  { key: "month", label: "本月" },
  { key: "quarter", label: "本季" },
  { key: "year", label: "今年" },
  { key: "all", label: "全部" },
  { key: "custom", label: "自定义" },
];

function filterRowsByRange(rows: AccountDetailRow[], range: TimeRange) {
  if (range.preset === "all") return rows;
  return rows.filter((row) => row.date >= range.start && row.date < range.end);
}

type AccountPeriodSummary = {
  inflow: number;
  outflow: number;
  netChange: number;
  maxInflow: AccountDetailRow | null;
  maxOutflow: AccountDetailRow | null;
  counterparties: { account: string; amount: number; count: number }[];
};

function buildPeriodSummary(account: string, rows: AccountDetailRow[]): AccountPeriodSummary {
  const counterparties = new Map<string, { amount: number; count: number }>();
  let inflow = 0;
  let outflow = 0;
  let maxInflow: AccountDetailRow | null = null;
  let maxOutflow: AccountDetailRow | null = null;

  for (const row of rows) {
    if (row.change > 0) {
      inflow += row.change;
      if (!maxInflow || row.change > maxInflow.change) maxInflow = row;
    } else if (row.change < 0) {
      outflow += Math.abs(row.change);
      if (!maxOutflow || row.change < maxOutflow.change) maxOutflow = row;
    }

    const otherAccounts = Array.from(new Set(row.txn.postings.filter((posting) => posting.account !== account).map((posting) => posting.account)));
    const weight = otherAccounts.length ? Math.abs(row.change) / otherAccounts.length : 0;
    for (const other of otherAccounts) {
      const current = counterparties.get(other) ?? { amount: 0, count: 0 };
      current.amount += weight;
      current.count += 1;
      counterparties.set(other, current);
    }
  }

  return {
    inflow,
    outflow,
    netChange: inflow - outflow,
    maxInflow,
    maxOutflow,
    counterparties: [...counterparties.entries()]
      .map(([account, value]) => ({ account, ...value }))
      .sort((a, b) => b.amount - a.amount)
      .slice(0, 5),
  };
}

export function AccountDetailSkeleton() {
  return (
    <div className="animate-pulse space-y-6">
      <div className="card p-4">
        <div className="mb-2 h-6 w-32 rounded bg-line" />
        <div className="h-8 w-48 rounded bg-line" />
        <div className="mt-2 h-4 w-64 rounded bg-line" />
      </div>
      <div className="card p-4">
        <div className="h-64 rounded-xl bg-line" />
      </div>
      <div className="card p-4">
        <div className="space-y-3">
          {Array.from({ length: 5 }).map((_, i) => (
            <div key={i} className="h-12 rounded bg-line" />
          ))}
        </div>
      </div>
    </div>
  );
}

export function AccountDetailPage({ account, onSensitiveLocked }: { account: string; onSensitiveLocked?: () => void }) {
  const [data, setData] = useState<AccountDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [timeRange, setTimeRange] = useState<TimeRange>(() => makeTimeRange("all"));
  const [customStart, setCustomStart] = useState(timeRange.start);
  const [customEnd, setCustomEnd] = useState(timeRange.end);

  useEffect(() => {
    const encoded = encodeURIComponent(account);
    fetch(`/api/ledger/accounts/detail?account=${encoded}`)
      .then(async (res) => {
        if (res.status === 423) onSensitiveLocked?.();
        return readJson<AccountDetail & { error?: string }>(res);
      })
      .then((json) => {
        if (json.error) throw new Error(json.error);
        setData(json);
      })
      .catch((err) => setError(err.message));
  }, [account, onSensitiveLocked]);

  if (error) {
    return (
      <div className="card p-6 text-center">
        <p className="text-[var(--danger)]">加载失败: {error}</p>
        <ClientNavLink
          href="/accounts"
          className="mt-4 inline-block text-sm text-brand underline"
        >
          ← 返回账户列表
        </ClientNavLink>
      </div>
    );
  }

  if (!data) return <AccountDetailSkeleton />;

  const filteredRows = filterRowsByRange(data.rows, timeRange);
  const periodSummary = buildPeriodSummary(account, filteredRows);

  // 准备图表数据
  const chartData = filteredRows.map((row) => ({
    date: row.date,
    balance: row.balance / 100,
  }));

  function setPreset(preset: TimePreset) {
    if (preset === "custom") {
      setCustomStart(timeRange.start);
      setCustomEnd(timeRange.end);
      setTimeRange({ start: timeRange.start, end: timeRange.end, preset: "custom" });
      return;
    }
    setTimeRange(makeTimeRange(preset));
  }

  function applyCustomRange() {
    if (!customStart || !customEnd || customStart >= customEnd) return;
    setTimeRange({ start: customStart, end: customEnd, preset: "custom" });
  }

  function moveRange(delta: -1 | 1) {
    setTimeRange((current) => navigateTimeRange(current, delta));
  }

  const canMoveRange = timeRange.preset !== "all" && timeRange.preset !== "custom";
  const rangeLabel = formatTimeRangeLabel(timeRange);

  return (
    <div className="account-detail-stack w-full min-w-0 max-w-full [overflow-x:clip] space-y-6">
      {/* Header */}
      <section className="card min-w-0 max-w-full overflow-hidden p-4">
        <ClientNavLink
          href="/accounts"
          className="mb-3 inline-flex items-center gap-1 text-sm text-stone hover:text-warm"
        >
          <ArrowLeft className="h-4 w-4" /> 账户列表
        </ClientNavLink>
        <h1 className="break-words font-serif text-2xl font-medium">{data.label}</h1>
        {data.alias && data.alias !== data.label && (
          <p className="mt-1 break-words text-sm text-olive">{data.alias}</p>
        )}
        <div className="mt-2 flex flex-wrap items-baseline gap-3">
          <span className="min-w-0 break-all text-xs text-stone">{data.account}</span>
          {!data.active && (
            <span className="rounded bg-line px-2 py-0.5 text-xs">已关闭</span>
          )}
        </div>
        <div className="mt-4">
          <span className="text-xs uppercase tracking-[0.22em] text-stone">
            当前余额
          </span>
          <div
            className={`mt-1 text-2xl font-semibold ${
              data.account.startsWith("Liabilities")
                ? "amount-expense"
                : "amount-gold"
            }`}
          >
            {formatCny(data.currentBalance / 100)}
          </div>
        </div>
      </section>

      <section className="card min-w-0 max-w-full overflow-hidden p-4">
        <div className="flex min-w-0 flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
          <div className="min-w-0">
            <h2 className="font-serif text-xl">时间范围</h2>
            <p className="mt-1 text-sm text-olive">{rangeLabel} · {filteredRows.length} / {data.rows.length} 笔变动</p>
          </div>
          <div className="flex min-w-0 flex-wrap items-center gap-2">
            {canMoveRange && <Button type="button" variant="outline" className="rounded-xl bg-panel px-3 text-brand" onClick={() => moveRange(-1)}>‹</Button>}
            <div className="flex min-w-0 overflow-x-auto rounded-xl border border-line bg-panel p-1 text-sm">
              {ACCOUNT_TIME_PRESETS.map((preset) => (
                <button
                  key={preset.key}
                  type="button"
                  className={`shrink-0 rounded px-3 py-1.5 ${timeRange.preset === preset.key ? "bg-brand text-paper" : "text-olive hover:bg-tag"}`}
                  onClick={() => setPreset(preset.key)}
                >
                  {preset.label}
                </button>
              ))}
            </div>
            {canMoveRange && <Button type="button" variant="outline" className="rounded-xl bg-panel px-3 text-brand" onClick={() => moveRange(1)}>›</Button>}
          </div>
        </div>
        {timeRange.preset === "custom" && (
          <div className="mt-3 grid min-w-0 gap-2 sm:grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)_auto] sm:items-center">
            <Input type="date" className="min-w-0 rounded-xl bg-panel text-sm" value={customStart} onChange={(event) => setCustomStart(event.target.value)} />
            <span className="hidden text-sm text-stone sm:block">~</span>
            <Input type="date" className="min-w-0 rounded-xl bg-panel text-sm" value={customEnd} onChange={(event) => setCustomEnd(event.target.value)} />
            <Button type="button" variant="outline" className="rounded-xl bg-panel text-brand" disabled={!customStart || !customEnd || customStart >= customEnd} onClick={applyCustomRange}>确定</Button>
          </div>
        )}
      </section>

      {chartData.length > 0 ? (
        <section className="card min-w-0 max-w-full overflow-hidden p-4">
          <div className="flex min-w-0 flex-col gap-1 sm:flex-row sm:items-end sm:justify-between">
            <div className="min-w-0">
              <h2 className="font-serif text-2xl">余额变化</h2>
              <p className="mt-1 text-sm text-olive">
                {filteredRows.length} 笔变动 ·{" "}
                {chartData[0].date} ~ {chartData.at(-1)!.date}
              </p>
            </div>
            <div className={`shrink-0 text-sm font-medium tabular-nums ${periodSummary.netChange >= 0 ? "amount-income" : "amount-expense"}`}>
              {periodSummary.netChange >= 0 ? "+" : ""}{formatCny(periodSummary.netChange / 100)}
            </div>
          </div>
          <div className="account-balance-chart ledger-chart mt-4 h-72 min-w-0 max-w-full overflow-hidden md:h-80 xl:h-[360px]">
            <ResponsiveContainer width="100%" height="100%" debounce={80}>
              <AreaChart
                data={chartData}
                margin={{ left: 0, right: 10, top: 8, bottom: 0 }}
              >
                <CartesianGrid strokeDasharray="3 3" stroke="var(--chart-grid)" />
                <XAxis dataKey="date" minTickGap={32} fontSize={10} tickMargin={6} />
                <YAxis
                  width={54}
                  tickFormatter={chartMoney}
                  fontSize={10}
                />
                <Tooltip
                  formatter={(value: number) => [formatCny(value), "余额"]}
                />
                <Area
                  type="monotone"
                  dataKey="balance"
                  name="余额"
                  stroke="var(--chart-primary)"
                  fill="var(--chart-fill)"
                  strokeWidth={2}
                />
              </AreaChart>
            </ResponsiveContainer>
          </div>
        </section>
      ) : (
        <section className="card min-w-0 max-w-full overflow-hidden p-4 text-sm text-stone">暂无可绘制的余额变化。</section>
      )}

      <div className="grid min-w-0 max-w-full grid-cols-[minmax(0,1fr)] gap-6 xl:grid-cols-[minmax(0,380px)_minmax(0,1fr)] xl:items-start">
        <div className="min-w-0 max-w-full xl:sticky xl:top-24">
          <AccountPeriodSummaryCard summary={periodSummary} rows={filteredRows} />
        </div>

        <AccountTransactionHistory account={account} rows={filteredRows} totalRows={data.rows.length} />
      </div>
    </div>
  );
}

function AccountPeriodSummaryCard({ summary, rows }: { summary: AccountPeriodSummary; rows: AccountDetailRow[] }) {
  const hasRows = rows.length > 0;
  return (
    <section className="card min-w-0 max-w-full overflow-hidden p-4">
      <div className="flex min-w-0 items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 className="font-serif text-2xl">期间摘要</h2>
          <p className="mt-1 text-sm text-olive">{hasRows ? `${rows.length} 笔变动解释当前范围` : "当前范围暂无账户变动"}</p>
        </div>
      </div>
      <div className="mt-4 grid min-w-0 grid-cols-3 divide-x divide-line overflow-hidden rounded-xl border border-line bg-panel text-center">
        <SummaryMetric label="流入" value={formatCny(summary.inflow / 100)} cls="amount-income" />
        <SummaryMetric label="流出" value={formatCny(summary.outflow / 100)} cls="amount-expense" />
        <SummaryMetric label="净变化" value={`${summary.netChange >= 0 ? "+" : ""}${formatCny(summary.netChange / 100)}`} cls={summary.netChange >= 0 ? "amount-income" : "amount-expense"} />
      </div>
      <div className="mt-3 grid min-w-0 gap-2 sm:grid-cols-2">
        <ExtremeRow label="最大流入" row={summary.maxInflow} />
        <ExtremeRow label="最大流出" row={summary.maxOutflow} />
      </div>
      <div className="mt-4">
        <div className="text-xs uppercase tracking-[0.18em] text-stone">主要对方账户</div>
        {summary.counterparties.length ? (
          <div className="mt-2 space-y-2">
            {summary.counterparties.map((item) => (
              <div key={item.account} className="min-w-0 overflow-hidden rounded-xl border border-line bg-panel px-3 py-2">
                <div className="flex min-w-0 items-center justify-between gap-3 text-sm">
                  <span className="min-w-0 truncate text-olive">{item.account}</span>
                  <strong className="shrink-0 whitespace-nowrap tabular-nums text-warm">{formatCny(item.amount / 100)}</strong>
                </div>
                <div className="mt-0.5 text-xs text-stone">{item.count} 笔相关变动</div>
              </div>
            ))}
          </div>
        ) : (
          <div className="mt-2 rounded-xl border border-line bg-panel p-3 text-sm text-stone">暂无对方账户信息。</div>
        )}
      </div>
    </section>
  );
}

function SummaryMetric({ label, value, cls }: { label: string; value: string; cls: string }) {
  return <div className="min-w-0 p-3"><div className="text-[11px] uppercase tracking-[0.14em] text-stone">{label}</div><div className={`mt-1 truncate text-sm font-semibold tabular-nums sm:text-base ${cls}`}>{value}</div></div>;
}

function ExtremeRow({ label, row }: { label: string; row: AccountDetailRow | null }) {
  return (
    <div className="min-w-0 overflow-hidden rounded-xl border border-line bg-panel p-3">
      <div className="text-[11px] uppercase tracking-[0.14em] text-stone">{label}</div>
      {row ? (
        <>
          <div className="mt-1 flex min-w-0 items-baseline justify-between gap-2">
            <span className="min-w-0 truncate text-sm font-medium text-olive">{row.payee || "（无对手）"}</span>
            <AmountCell amount={row.change} />
          </div>
          <div className="mt-0.5 min-w-0 truncate text-xs text-stone">{row.date} · {row.narration || "无说明"}</div>
        </>
      ) : (
        <div className="mt-2 text-sm text-stone">暂无</div>
      )}
    </div>
  );
}

function AccountTransactionHistory({ account, rows, totalRows }: { account: string; rows: AccountDetailRow[]; totalRows: number }) {
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [query, setQuery] = useState("");
  const displayRows = useMemo(() => [...rows].reverse(), [rows]);
  const normalizedQuery = query.trim().toLowerCase();
  const filteredRows = useMemo(() => {
    if (!normalizedQuery) return displayRows;
    const words = normalizedQuery.split(/\s+/);
    return displayRows.filter((row) => {
      const haystack = [
        row.date,
        row.payee,
        row.narration,
        row.txn.postings.map((posting) => posting.account).join(" "),
        Object.entries(row.txn.metadata ?? {}).map(([key, value]) => `${key}:${String(value)}`).join(" "),
        (row.txn.tags ?? []).map((tag) => `#${tag}`).join(" "),
      ].join(" ").toLowerCase();
      return words.every((word) => haystack.includes(word));
    });
  }, [displayRows, normalizedQuery]);

  function toggleExpand(key: string) {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  }

  function clearFilter() {
    setQuery("");
  }

  return (
    <section className="card min-w-0 max-w-full overflow-hidden p-4">
      <div className="flex min-w-0 flex-col gap-3 lg:flex-row lg:items-end lg:justify-between">
        <div className="min-w-0">
          <h2 className="font-serif text-2xl">变动明细</h2>
          <p className="mt-1 text-sm text-olive">
            共 {filteredRows.length} / {displayRows.length} 笔，最新在前{displayRows.length !== totalRows ? ` · 全部 ${totalRows} 笔` : ""}
          </p>
        </div>
        <div className="flex min-w-0 gap-2">
          <Input
            className="min-w-0 flex-1 rounded-xl bg-panel text-sm lg:w-72"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="筛选商户、说明、账户、metadata"
          />
          {query.trim() && <Button type="button" variant="outline" className="shrink-0 rounded-xl bg-panel text-stone" onClick={clearFilter}>清空</Button>}
        </div>
      </div>

      {filteredRows.length === 0 ? (
        <p className="mt-4 text-sm text-stone">没有匹配的交易记录。</p>
      ) : (
        <div className="mt-4 max-h-none min-w-0 max-w-full space-y-1.5 overflow-hidden xl:max-h-[calc(100dvh-13rem)] xl:overflow-y-auto xl:pr-1">
          {filteredRows.map((row) => {
            const key = accountRowKey(row);
            const isExpanded = expanded.has(key);
            const counterParties = row.txn.postings
              .filter((p) => p.account !== account)
              .map((p) => p.account);

            return (
              <div
                key={key}
                className="min-w-0 max-w-full overflow-hidden rounded-xl border border-line bg-panel"
              >
                <button
                  type="button"
                  className="account-detail-row-button min-w-0 w-full overflow-hidden p-3 text-left"
                  onClick={() => toggleExpand(key)}
                >
                  <div className="flex min-w-0 items-start justify-between gap-3">
                    <div className="min-w-0 flex-1">
                      <div className="flex min-w-0 items-center gap-2">
                        <strong className="truncate text-sm">
                          {row.payee || "（无对手）"}
                        </strong>
                        {isExpanded ? (
                          <ChevronUp className="h-4 w-4 shrink-0 text-stone" />
                        ) : (
                          <ChevronDown className="h-4 w-4 shrink-0 text-stone" />
                        )}
                      </div>
                      <div className="mt-0.5 truncate text-xs text-olive">
                        {row.narration}
                      </div>
                    </div>
                    <div className="shrink-0 text-right">
                      <div className="text-sm">
                        <AmountCell amount={row.change} />
                      </div>
                      <div className="mt-0.5 text-xs tabular-nums text-stone">
                        {row.date}
                      </div>
                    </div>
                  </div>
                  <div className="mt-1.5 flex min-w-0 items-baseline justify-between gap-x-3 gap-y-0.5">
                    <span className="shrink-0 whitespace-nowrap text-xs text-stone">
                      余额{" "}
                      <span className="font-medium tabular-nums text-warm">
                        {formatCny(row.balance / 100)}
                      </span>
                    </span>
                    <span className="min-w-0 flex-1 truncate text-right text-xs text-stone/60">
                      {counterParties.join(" · ") || "—"}
                    </span>
                  </div>
                </button>

                {isExpanded && (
                  <div className="min-w-0 border-t border-line px-3 pb-3 pt-2">
                    <div className="min-w-0 space-y-1.5">
                      {row.txn.postings.map((p, j) => {
                        const isSelf = p.account === account;
                        return (
                          <div
                            key={`${p.account}:${j}`}
                            className={`flex min-w-0 justify-between gap-3 overflow-hidden rounded-lg px-2 py-1 text-xs ${
                              isSelf
                                ? "bg-brand/5 font-medium"
                                : "bg-paper"
                            }`}
                          >
                            <span className="min-w-0 flex-1 truncate">
                              {p.account}
                              {isSelf && (
                                <span className="ml-1 text-stone">
                                  ← 本账户
                                </span>
                              )}
                            </span>
                            <span
                              className={`shrink-0 tabular-nums ${
                                p.amount > 0
                                  ? "text-[var(--success)]"
                                  : p.amount < 0
                                    ? "text-[var(--danger)]"
                                    : "text-stone"
                              }`}
                            >
                              {formatCny(p.amount / 100)}
                            </span>
                          </div>
                        );
                      })}
                    </div>
                    {row.txn.metadata &&
                      Object.keys(row.txn.metadata).length > 0 && (
                        <div className="mt-2 flex flex-wrap gap-1">
                          {Object.entries(row.txn.metadata).map(
                            ([key, value]) => (
                              <span
                                key={key}
                                className="max-w-full break-all rounded-full bg-tag px-2 py-0.5 text-[11px] text-stone"
                              >
                                {key}: {String(value)}
                              </span>
                            )
                          )}
                        </div>
                      )}
                    {row.txn.tags && row.txn.tags.length > 0 && (
                      <div className="mt-1 flex flex-wrap gap-1">
                        {row.txn.tags.map((tag) => (
                          <span
                            key={tag}
                            className="max-w-full break-all rounded-full bg-tag px-2 py-0.5 text-[11px] text-stone"
                          >
                            #{tag}
                          </span>
                        ))}
                      </div>
                    )}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}
    </section>
  );
}
