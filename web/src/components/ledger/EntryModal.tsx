import { useState, type ReactNode } from "react";
import type { ParsedTransaction } from "@/lib/schemas";
import { MobileSheet } from "./MobileSheet";
import type { ManualForm, ManualKind } from "./types";

type ParseStatus = "idle" | "parsing" | "success" | "error";
type AppendStatus = "idle" | "writing";

export function EntryModal({ children, onClose }: { children: ReactNode; onClose: () => void }) {
  return <MobileSheet open title="记一笔" onClose={onClose} size="md" align="center">{children}</MobileSheet>;
}

export function EntryPanel({ nl, setNl, onParse, manual, setManual, onPreviewManual, previews, onRemovePreview, onAppendPreviews, parseStatus, parseMessage, appendStatus, expenseAccounts, incomeAccounts, paymentAccounts, accountLabels }: { nl: string; setNl: (value: string) => void; onParse: () => void; manual: ManualForm; setManual: (value: ManualForm) => void; onPreviewManual: () => void; previews: ParsedTransaction[]; onRemovePreview: (index: number) => void; onAppendPreviews: () => void; parseStatus: ParseStatus; parseMessage: string; appendStatus: AppendStatus; expenseAccounts: string[]; incomeAccounts: string[]; paymentAccounts: string[]; accountLabels: Record<string, string> }) {
  const categoryOptions = manual.kind === "income" ? incomeAccounts : expenseAccounts;
  const optionLabel = (a: string) => `${accountLabels[a] ?? a} · ${a}`;
  const busy = parseStatus === "parsing" || appendStatus === "writing";
  const statusClass = parseStatus === "error" ? "border-line bg-panel text-[var(--danger)]" : parseStatus === "success" ? "border-line bg-panel text-[var(--success)]" : "border-line bg-paper text-stone";
  const [manualOpen, setManualOpen] = useState(false);

  return <section>
    <div className="rounded-xl border border-line bg-panel p-3">
      <div className="text-sm font-medium">AI 自然语言</div>
      <textarea id="nl-input" className="mt-3 h-36 w-full border border-line bg-panel p-3" placeholder={"例如：\n昨天 星巴克 38 招行信用卡\n今天 午餐 56 支付宝\n5/8 打车 24 微信"} value={nl} onChange={(e) => setNl(e.target.value)} />
      <div className="mt-3 flex flex-wrap items-center gap-3">
        <button className="bg-brand px-4 py-2 text-paper disabled:opacity-60" onClick={onParse} disabled={busy}>{parseStatus === "parsing" ? "解析中…" : "AI 解析"}</button>
        {parseMessage && <div className={`rounded-lg border px-3 py-2 text-sm ${statusClass}`}>{parseMessage}</div>}
      </div>
    </div>

    <div className="mt-4 rounded-xl border border-line bg-panel p-3">
      <button type="button" className="flex w-full items-center justify-between text-left text-sm font-medium" onClick={() => setManualOpen((value) => !value)}><span>手动记账</span><span className="text-xs text-stone">{manualOpen ? "收起" : "展开"}</span></button>
      {manualOpen && <><div className="mt-3 grid min-w-0 grid-cols-1 gap-3 sm:grid-cols-2"><select className="min-w-0 border border-line bg-panel p-3" value={manual.kind} onChange={(e) => setManual({ ...manual, kind: e.target.value as ManualKind, category: e.target.value === "income" ? (incomeAccounts[0] ?? "Income:Other") : (expenseAccounts.find((a) => a === "Expenses:Unknown") ?? expenseAccounts[0] ?? "Expenses:Unknown") })}><option value="expense">支出</option><option value="income">收入</option><option value="transfer">转账/还款</option></select><input className="min-w-0 border border-line bg-panel p-3" type="date" value={manual.date} onChange={(e) => setManual({ ...manual, date: e.target.value })} /><input className="min-w-0 border border-line bg-panel p-3" placeholder="商户/对方" value={manual.payee} onChange={(e) => setManual({ ...manual, payee: e.target.value })} /><input className="min-w-0 border border-line bg-panel p-3" inputMode="decimal" placeholder="金额" value={manual.amount} onChange={(e) => setManual({ ...manual, amount: e.target.value })} /><input className="min-w-0 border border-line bg-panel p-3 sm:col-span-2" placeholder="说明，可选" value={manual.narration} onChange={(e) => setManual({ ...manual, narration: e.target.value })} />{manual.kind !== "income" && <select className="min-w-0 border border-line bg-panel p-3" value={manual.fromAccount} onChange={(e) => setManual({ ...manual, fromAccount: e.target.value })}>{paymentAccounts.map((a) => <option key={a} value={a}>{optionLabel(a)}</option>)}</select>}{manual.kind !== "expense" && <select className="min-w-0 border border-line bg-panel p-3" value={manual.toAccount} onChange={(e) => setManual({ ...manual, toAccount: e.target.value })}>{paymentAccounts.filter((a) => a.startsWith("Assets:") || manual.kind === "transfer").map((a) => <option key={a} value={a}>{optionLabel(a)}</option>)}</select>}{manual.kind !== "transfer" && <select className="min-w-0 border border-line bg-panel p-3 sm:col-span-2" value={manual.category} onChange={(e) => setManual({ ...manual, category: e.target.value })}>{categoryOptions.map((a) => <option key={a} value={a}>{optionLabel(a)}</option>)}</select>}</div>
      <button className="mt-3 bg-brand px-4 py-2 text-paper disabled:opacity-60" onClick={onPreviewManual} disabled={busy}>生成预览</button></>}
    </div>

    {previews.length > 0 && <div className="mt-4 rounded-xl border border-line bg-panel p-3">
      <div className="flex items-center justify-between gap-3"><div className="font-medium">解析结果（{previews.length} 条）</div><button className="bg-brand px-4 py-2 text-paper disabled:opacity-60" onClick={onAppendPreviews} disabled={busy}>{appendStatus === "writing" ? "写入中…" : `确认写入 ${previews.length} 条`}</button></div>
      <div className="mt-3 space-y-3">{previews.map((preview, index) => <div key={`${preview.date}-${preview.payee}-${index}`} className="rounded-xl border border-line bg-paper p-3">
        <div className="flex items-start justify-between gap-3"><div><div className="font-medium">{index + 1}. {preview.date} {preview.payee}</div><div className="text-sm text-stone">{preview.narration || "无说明"} · 置信度 {Math.round(preview.confidence * 100)}%</div></div><button className="shrink-0 rounded-lg border border-line px-2 py-1 text-xs text-stone disabled:opacity-60" onClick={() => onRemovePreview(index)} disabled={busy}>移除</button></div>
        {preview.needsReview && <div className="mt-2 rounded-lg border border-line bg-tag px-2 py-1 text-xs text-warm">需要确认{preview.questions.length ? `：${preview.questions.join("；")}` : ""}</div>}
        {(Object.keys(preview.metadata ?? {}).length > 0 || (preview.tags ?? []).length > 0) && <div className="mt-2 flex flex-wrap gap-1">{Object.entries(preview.metadata ?? {}).map(([key, value]) => <span key={key} className="rounded-full bg-tag px-2 py-0.5 text-[11px] text-stone">{key}: {String(value)}</span>)}{(preview.tags ?? []).map((tag) => <span key={tag} className="rounded-full bg-tag px-2 py-0.5 text-[11px] text-stone">#{tag}</span>)}</div>}
        <div className="mt-2 space-y-1">{preview.postings.map((p, i) => <div key={i} className="flex justify-between gap-3 text-sm"><span className="min-w-0 truncate">{p.account}</span><span className="shrink-0">{p.amount} {p.currency}</span></div>)}</div>
      </div>)}</div>
    </div>}
  </section>;
}
