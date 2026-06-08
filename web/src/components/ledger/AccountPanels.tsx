import { useMemo, useState } from "react";
import { ClientNavLink } from "./ClientNavLink";
import { Bot, Eye, EyeOff, Pencil } from "lucide-react";
import { readJson } from "@/lib/clientFetch";
import { formatCompactValuation, formatMoney, formatValuation } from "@/lib/money";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { AccountAgentChat } from "./AccountAgentChat";
import { formatAccountOptionLabel } from "./accountDisplay";
import type { AccountGroup, AccountStatus, AccountView, BudgetRow, CreditCardAnalytics, Txn } from "./types";

type BalanceRow = { account: string; label: string; value: number; currency?: string; active?: boolean; group?: AccountGroup; valuation?: boolean };

export function BalanceGrid({ rows, full, allVisible = false, visibleAccountMap = {}, onToggleAll, onToggleAccount, statuses, txns = [] }: { rows: BalanceRow[]; full?: boolean; allVisible?: boolean; visibleAccountMap?: Record<string, boolean>; onToggleAll?: () => void; onToggleAccount?: (account: string) => void; statuses?: AccountStatus[]; txns?: Txn[] }) {
  const trendMap = useMemo(() => Object.fromEntries(rows.map((row) => [row.account, accountTrendPoints(row, txns)])), [rows, txns]);
  return <section className="card mt-6 p-4"><div className="flex items-center justify-between gap-3"><h2 className="font-serif text-2xl">账户余额</h2><div className="flex items-center gap-2">{statusDotLegend()}{onToggleAll && <button className="rounded-xl border border-line bg-panel px-3 py-2 text-sm text-olive hover:bg-panel" onClick={onToggleAll} title={allVisible ? "隐藏所有账户余额" : "显示所有账户余额"}>{allVisible ? <EyeOff className="inline h-4 w-4" /> : <Eye className="inline h-4 w-4" />} <span className="ml-1 hidden sm:inline">{allVisible ? "全部隐藏" : "全部显示"}</span></button>}</div></div><div className="mt-4 grid gap-3 sm:grid-cols-2 xl:grid-cols-3">{rows.map((r) => { const visible = visibleAccountMap[r.account] ?? allVisible; const st = statuses?.find(s => s.account === r.account); return <div key={r.account} className="relative min-h-32 overflow-hidden rounded-xl border border-line bg-panel p-3"><AccountSparkline points={trendMap[r.account] ?? []} liability={r.account.startsWith("Liabilities")} /><div className="relative z-10 flex items-start justify-between gap-3"><div className="min-w-0 text-sm text-stone"><ClientNavLink href={`/accounts/${encodeURIComponent(r.account)}`} className="hover:text-warm hover:underline"><span className="flex items-center gap-1.5">{st && <span className={`inline-block h-2.5 w-2.5 shrink-0 rounded-full ${statusColor(st.status)}`} title={statusTitle(st)} />}{r.label}</span></ClientNavLink>{r.active === false && <span className="ml-2 rounded-xl bg-line px-2 py-0.5 text-xs">已关闭</span>}</div>{onToggleAccount && <button className="relative z-10 shrink-0 rounded-xl border border-line bg-panel/75 px-2 py-1 text-olive backdrop-blur hover:bg-panel" onClick={() => onToggleAccount(r.account)} title={visible ? "隐藏该账户余额" : "显示该账户余额"}>{visible ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}</button>}</div><div className={`relative z-10 mt-5 text-2xl font-medium ${r.account.startsWith("Liabilities") ? "amount-expense" : "amount-gold"}`}>{visible ? r.valuation ? formatValuation(r.value / 100, r.currency ?? "CNY") : formatMoney(r.value / 100, r.currency ?? "CNY") : "••••••"}</div><div className="relative z-10 mt-2 truncate text-xs text-stone">{r.valuation ? `${r.account} · 估值` : r.account}</div></div>; })}</div>{!full && <p className="mt-3 text-xs text-stone">完整账户在“账户”页；余额核对和断言集中在“对账”页。</p>}</section>;
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

export function BudgetPanel({ rows, valuationCurrency, full }: { rows: BudgetRow[]; valuationCurrency: string; full?: boolean }) {
  return <section className="card mt-6 p-4"><h2 className="font-serif text-2xl">预算</h2>{rows.map((r) => { const pct = r.ratio == null ? 0 : Math.round(r.ratio * 100); return <div key={r.account} className="border-b border-line py-3"><div className="flex justify-between gap-3 text-sm"><span>{formatAccountOptionLabel(r.account, r.label, r.alias)}</span><strong>{formatValuation(r.spent / 100, valuationCurrency)} / {formatValuation(r.budget / 100, valuationCurrency)}</strong></div><div className="mt-2 h-2 overflow-hidden rounded-xl bg-line"><div className={pct > 100 ? "h-full bg-[var(--danger)]" : "h-full bg-brand"} style={{ width: `${Math.min(pct, 140)}%` }} /></div><div className="mt-1 text-xs text-stone">剩余 {formatValuation(r.remaining / 100, valuationCurrency)}，使用率 {r.ratio == null ? "n/a" : `${pct}%`}</div></div>; })}{!full && <p className="mt-3 text-xs text-stone">完整预算在“预算”页。</p>}</section>;
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
  const groups: { key: AccountGroup; label: string }[] = [{ key: "cash", label: "现金账户" }, { key: "credit", label: "信用卡/负债" }, { key: "wealth", label: "理财账户" }, { key: "receivable", label: "应收应付" }, { key: "expense", label: "支出分类" }, { key: "income", label: "收入分类" }, { key: "equity", label: "权益" }, { key: "other", label: "其他" }];
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
  return <section className="card p-4"><div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"><div><h2 className="font-serif text-2xl">账户管理</h2><p className="mt-2 text-sm text-olive">这里管理账户定义和分组；余额集中在下方“账户余额”里并默认隐藏。</p></div><Button type="button" variant="outline" className="shrink-0 rounded-xl bg-panel text-olive" onClick={() => setAgentOpen(true)}><Bot className="h-4 w-4 text-brand" /><span>编辑账户</span><Pencil className="h-3.5 w-3.5 text-stone" /></Button></div><div className="mt-4 grid gap-3 sm:grid-cols-[150px_1fr_1fr_110px_auto]"><Input className="h-12 bg-panel" type="date" value={date} onChange={(e) => setDate(e.target.value)} /><Input className="h-12 bg-panel" placeholder="Assets:HK:HSBC:HKD" value={account} onChange={(e) => setAccount(e.target.value)} /><Input className="h-12 bg-panel" placeholder="显示名 / alias" value={alias} onChange={(e) => setAlias(e.target.value)} /><Input className="h-12 bg-panel uppercase" placeholder="HKD / 空" value={currency} onChange={(e) => setCurrency(e.target.value.toUpperCase())} /><Button className="h-12 px-4" onClick={submit}>新增账户</Button></div>{message && <p className="mt-2 text-sm text-olive">{message}</p>}<div className="mt-5 grid gap-3 sm:grid-cols-2">{groups.map((group) => { const rows = accounts.filter((a) => a.group === group.key); if (!rows.length) return null; return <div key={group.key} className="rounded-xl border border-line bg-panel p-3"><h3 className="text-sm font-medium text-stone">{group.label} · {rows.length}</h3><div className="mt-2 space-y-2">{rows.map((a) => <div key={a.account} className="text-sm"><div className="flex items-center gap-2"><strong>{a.label}</strong><span className="rounded bg-tag px-1.5 py-0.5 text-[10px] text-stone">{a.currency || "多币种"}</span>{!a.active && <span className="rounded bg-line px-2 py-0.5 text-xs">已关闭</span>}</div><div className="mt-0.5 truncate text-xs text-stone">{a.account}</div></div>)}</div></div>; })}</div><AccountAgentChat open={agentOpen} onClose={() => setAgentOpen(false)} onChanged={onAdded} refreshGitStatus={refreshGitStatus} showToast={showToast} /></section>;
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

function statusDotLegend() {
  const items: { status: AccountStatus["status"]; label: string }[] = [
    { status: "green", label: "断言通过" },
    { status: "red", label: "断言失败" },
    { status: "yellow", label: "未断言" },
    { status: "grey", label: "长期未更新" },
  ];
  return (
    <div className="hidden items-center gap-2 sm:flex">
      {items.map((item) => (
        <span key={item.status} className="flex items-center gap-1 text-xs text-stone">
          <span className={`inline-block h-2 w-2 rounded-full ${statusColor(item.status)}`} />
          {item.label}
        </span>
      ))}
    </div>
  );
}
