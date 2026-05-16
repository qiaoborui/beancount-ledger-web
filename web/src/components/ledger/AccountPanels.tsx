import { useState } from "react";
import Link from "next/link";
import { Eye, EyeOff } from "lucide-react";
import { readJson } from "@/lib/clientFetch";
import { formatCny } from "@/lib/money";
import type { BalanceAssertion } from "@/lib/schemas";
import type { AccountGroup, AccountStatus, AccountView, BudgetRow } from "./types";

export function BalanceGrid({ rows, full, allVisible = false, visibleAccountMap = {}, onToggleAll, onToggleAccount, statuses }: { rows: { account: string; label: string; value: number; active?: boolean; group?: AccountGroup }[]; full?: boolean; allVisible?: boolean; visibleAccountMap?: Record<string, boolean>; onToggleAll?: () => void; onToggleAccount?: (account: string) => void; statuses?: AccountStatus[] }) {
  return <section className="card mt-6 p-4"><div className="flex items-center justify-between gap-3"><h2 className="font-serif text-2xl">账户余额</h2><div className="flex items-center gap-2">{statusDotLegend()}{onToggleAll && <button className="rounded-xl border border-line bg-panel px-3 py-2 text-sm text-olive hover:bg-panel" onClick={onToggleAll} title={allVisible ? "隐藏所有账户余额" : "显示所有账户余额"}>{allVisible ? <EyeOff className="inline h-4 w-4" /> : <Eye className="inline h-4 w-4" />} <span className="ml-1 hidden sm:inline">{allVisible ? "全部隐藏" : "全部显示"}</span></button>}</div></div><div className="mt-4 grid gap-3 sm:grid-cols-2">{rows.map((r) => { const visible = visibleAccountMap[r.account] ?? allVisible; const st = statuses?.find(s => s.account === r.account); return <div key={r.account} className="rounded-xl border border-line bg-panel p-3"><div className="flex items-start justify-between gap-3"><div className="min-w-0 text-sm text-stone"><Link href={`/accounts/${encodeURIComponent(r.account)}`} className="hover:text-warm hover:underline"><span className="flex items-center gap-1.5">{st && <span className={`inline-block h-2.5 w-2.5 shrink-0 rounded-full ${statusColor(st.status)}`} title={statusTitle(st)} />}{r.label}</span></Link>{r.active === false && <span className="ml-2 rounded-xl bg-line px-2 py-0.5 text-xs">已关闭</span>}</div>{onToggleAccount && <button className="shrink-0 rounded-xl border border-line px-2 py-1 text-olive hover:bg-panel" onClick={() => onToggleAccount(r.account)} title={visible ? "隐藏该账户余额" : "显示该账户余额"}>{visible ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}</button>}</div><div className={r.account.startsWith("Liabilities") ? "amount-expense text-xl font-medium" : "amount-gold text-xl font-medium"}>{visible ? formatCny(r.value / 100) : "••••••"}</div><div className="mt-1 text-xs text-stone">{r.account}</div></div>; })}</div>{!full && <p className="mt-3 text-xs text-stone">完整账户和新增断言在“账户”页。</p>}</section>;
}

export function BudgetPanel({ rows, full }: { rows: BudgetRow[]; full?: boolean }) {
  return <section className="card mt-6 p-4"><h2 className="font-serif text-2xl">预算</h2>{rows.map((r) => { const pct = r.ratio == null ? 0 : Math.round(r.ratio * 100); return <div key={r.account} className="border-b border-line py-3"><div className="flex justify-between gap-3 text-sm"><span>{r.account}</span><strong>{formatCny(r.spent / 100)} / {formatCny(r.budget / 100)}</strong></div><div className="mt-2 h-2 overflow-hidden rounded-xl bg-line"><div className={pct > 100 ? "h-full bg-[var(--danger)]" : "h-full bg-brand"} style={{ width: `${Math.min(pct, 140)}%` }} /></div><div className="mt-1 text-xs text-stone">剩余 {formatCny(r.remaining / 100)}，使用率 {r.ratio == null ? "n/a" : `${pct}%`}</div></div>; })}{!full && <p className="mt-3 text-xs text-stone">完整预算在“预算”页。</p>}</section>;
}

export function AccountManager({ accounts, onAdded }: { accounts: AccountView[]; balances: Record<string, number>; onAdded: () => void }) {
  const [date, setDate] = useState(new Date().toISOString().slice(0, 10));
  const [account, setAccount] = useState("");
  const [alias, setAlias] = useState("");
  const [message, setMessage] = useState("");
  const groups: { key: AccountGroup; label: string }[] = [{ key: "cash", label: "现金账户" }, { key: "credit", label: "信用卡/负债" }, { key: "wealth", label: "理财账户" }, { key: "receivable", label: "应收应付" }, { key: "expense", label: "支出分类" }, { key: "income", label: "收入分类" }, { key: "equity", label: "权益" }, { key: "other", label: "其他" }];
  async function submit() {
    setMessage("写入中...");
    const res = await fetch("/api/ledger/accounts", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ date, account, alias, currency: "CNY" }) });
    const data = await readJson<{ error?: string }>(res);
    if (!res.ok) { setMessage(data.error || "新增失败"); return; }
    setMessage("账户已新增");
    setAccount("");
    setAlias("");
    onAdded();
  }
  return <section className="card p-4"><h2 className="font-serif text-2xl">账户管理</h2><p className="mt-2 text-sm text-olive">这里管理账户定义和分组；余额集中在下方“账户余额”里并默认隐藏。</p><div className="mt-4 grid gap-3 sm:grid-cols-[150px_1fr_1fr_auto]"><input className="border border-line bg-panel p-3" type="date" value={date} onChange={(e) => setDate(e.target.value)} /><input className="border border-line bg-panel p-3" placeholder="Assets:CN:Bank:Checking" value={account} onChange={(e) => setAccount(e.target.value)} /><input className="border border-line bg-panel p-3" placeholder="显示名 / alias" value={alias} onChange={(e) => setAlias(e.target.value)} /><button className="bg-brand px-4 py-3 text-paper" onClick={submit}>新增账户</button></div>{message && <p className="mt-2 text-sm text-olive">{message}</p>}<div className="mt-5 grid gap-3 sm:grid-cols-2">{groups.map((group) => { const rows = accounts.filter((a) => a.group === group.key); if (!rows.length) return null; return <div key={group.key} className="rounded-xl border border-line bg-panel p-3"><h3 className="text-sm font-medium text-stone">{group.label} · {rows.length}</h3><div className="mt-2 space-y-2">{rows.map((a) => <div key={a.account} className="text-sm"><div className="flex items-center gap-2"><strong>{a.label}</strong>{!a.active && <span className="rounded bg-line px-2 py-0.5 text-xs">已关闭</span>}</div><div className="mt-0.5 truncate text-xs text-stone">{a.account}</div></div>)}</div></div>; })}</div></section>;
}

export function BalanceAssertionForm({ assertion, setAssertion, onSubmit, accounts }: { assertion: BalanceAssertion; setAssertion: (next: BalanceAssertion) => void; onSubmit: () => void; accounts: AccountView[] }) {
  return <section className="card mt-6 max-w-full overflow-hidden p-4"><h2 className="font-serif text-2xl">新增余额断言</h2><div className="mt-4 grid min-w-0 grid-cols-1 gap-3 sm:grid-cols-3"><input className="min-w-0 border border-line bg-panel p-3" type="date" value={assertion.date} onChange={(e) => setAssertion({ ...assertion, date: e.target.value })} /><select className="min-w-0 border border-line bg-panel p-3 sm:col-span-2" value={assertion.account} onChange={(e) => setAssertion({ ...assertion, account: e.target.value })}>{accounts.map((a) => <option key={a.account} value={a.account}>{a.label} · {a.account}</option>)}</select><input className="min-w-0 border border-line bg-panel p-3 sm:col-span-2" placeholder="金额，信用卡欠款填负数" value={assertion.amount} onChange={(e) => setAssertion({ ...assertion, amount: e.target.value })} /><button className="min-w-0 bg-brand px-4 py-3 text-paper" onClick={onSubmit}>写入断言</button></div><p className="mt-3 text-xs text-stone">例如 5 号还款完成后，写 6 号断言。信用卡欠款用负数。</p></section>;
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
