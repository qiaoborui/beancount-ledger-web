"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { ArrowLeft, ChevronDown, ChevronUp } from "lucide-react";
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
import type { AccountDetailRow } from "@/lib/beancountParser";

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
    <span className={`tabular-nums font-medium ${cls}`}>
      {sign}
      {formatCny(amount / 100)}
    </span>
  );
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

export function AccountDetailPage({ account }: { account: string }) {
  const [data, setData] = useState<AccountDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [expanded, setExpanded] = useState<Set<number>>(new Set());

  useEffect(() => {
    const encoded = encodeURIComponent(account);
    fetch(`/api/ledger/accounts/detail?account=${encoded}`)
      .then((res) => {
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        return res.json();
      })
      .then((json) => {
        if (json.error) throw new Error(json.error);
        setData(json);
      })
      .catch((err) => setError(err.message));
  }, [account]);

  if (error) {
    return (
      <div className="card p-6 text-center">
        <p className="text-[var(--danger)]">加载失败: {error}</p>
        <Link
          href="/accounts"
          className="mt-4 inline-block text-sm text-brand underline"
        >
          ← 返回账户列表
        </Link>
      </div>
    );
  }

  if (!data) return <AccountDetailSkeleton />;

  // 准备图表数据
  const chartData = data.rows.map((row) => ({
    date: row.date,
    balance: row.balance / 100,
  }));

  // 反转 rows 以便最新在前展示
  const displayRows = [...data.rows].reverse();

  function toggleExpand(idx: number) {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(idx)) next.delete(idx);
      else next.add(idx);
      return next;
    });
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <section className="card p-4">
        <Link
          href="/accounts"
          className="mb-3 inline-flex items-center gap-1 text-sm text-stone hover:text-warm"
        >
          <ArrowLeft className="h-4 w-4" /> 账户列表
        </Link>
        <h1 className="font-serif text-2xl font-medium">{data.label}</h1>
        {data.alias && data.alias !== data.label && (
          <p className="mt-1 text-sm text-olive">{data.alias}</p>
        )}
        <div className="mt-2 flex flex-wrap items-baseline gap-3">
          <span className="text-xs text-stone">{data.account}</span>
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

      {/* Balance Chart */}
      {chartData.length > 0 && (
        <section className="card p-4">
          <h2 className="font-serif text-2xl">余额变化</h2>
          <p className="mt-1 text-sm text-olive">
            {chartData.length} 笔变动 ·{" "}
            {chartData[0].date} ~ {chartData.at(-1)!.date}
          </p>
          <div className="mt-4 h-72 min-w-0">
            <ResponsiveContainer width="100%" height="100%">
              <AreaChart
                data={chartData}
                margin={{ left: 8, right: 16, top: 8, bottom: 0 }}
              >
                <CartesianGrid strokeDasharray="3 3" stroke="#e5e3d8" />
                <XAxis dataKey="date" minTickGap={24} fontSize={11} />
                <YAxis
                  width={56}
                  tickFormatter={chartMoney}
                  fontSize={11}
                />
                <Tooltip
                  formatter={(value: number) => [formatCny(value), "余额"]}
                />
                <Area
                  type="monotone"
                  dataKey="balance"
                  name="余额"
                  stroke="#1B365D"
                  fill="#d8d1c1"
                  strokeWidth={2}
                />
              </AreaChart>
            </ResponsiveContainer>
          </div>
        </section>
      )}

      {/* Transaction History */}
      <section className="card p-4">
        <h2 className="font-serif text-2xl">变动明细</h2>
        <p className="mt-1 text-sm text-olive">
          共 {displayRows.length} 笔，最新在前
        </p>

        {displayRows.length === 0 ? (
          <p className="mt-4 text-sm text-stone">该账户暂无交易记录。</p>
        ) : (
          <div className="mt-4 space-y-1.5">
            {displayRows.map((row, idx) => {
              const isExpanded = expanded.has(idx);
              const counterParties = row.txn.postings
                .filter((p) => p.account !== account)
                .map((p) => p.account);

              return (
                <div
                  key={`${row.txn.source.file}:${row.txn.source.line}`}
                  className="rounded-xl border border-line bg-panel"
                >
                  <button
                    className="w-full p-3 text-left"
                    onClick={() => toggleExpand(idx)}
                  >
                    <div className="flex items-start justify-between gap-3">
                      <div className="min-w-0 flex-1">
                        <div className="flex items-center gap-2">
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
                    {/* 摘要行：变动后余额 + 对方账户 */}
                    <div className="mt-1.5 flex flex-wrap items-baseline justify-between gap-x-3 gap-y-0.5">
                      <span className="text-xs text-stone">
                        余额{" "}
                        <span className="font-medium tabular-nums text-warm">
                          {formatCny(row.balance / 100)}
                        </span>
                      </span>
                      <span className="truncate text-xs text-stone/60">
                        {counterParties.join(" · ") || "—"}
                      </span>
                    </div>
                  </button>

                  {/* 展开：完整 posting 列表 */}
                  {isExpanded && (
                    <div className="border-t border-line px-3 pb-3 pt-2">
                      <div className="space-y-1.5">
                        {row.txn.postings.map((p, j) => {
                          const isSelf = p.account === account;
                          return (
                            <div
                              key={j}
                              className={`flex justify-between gap-3 rounded-lg px-2 py-1 text-xs ${
                                isSelf
                                  ? "bg-brand/5 font-medium"
                                  : "bg-paper"
                              }`}
                            >
                              <span className="truncate">
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
                                  className="rounded-full bg-tag px-2 py-0.5 text-[11px] text-stone"
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
                              className="rounded-full bg-tag px-2 py-0.5 text-[11px] text-stone"
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
    </div>
  );
}
