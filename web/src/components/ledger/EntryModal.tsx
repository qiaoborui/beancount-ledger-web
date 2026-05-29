import { useState, type ReactNode } from "react";
import type { ParsedTransaction } from "@/lib/schemas";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
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
  const [manualOpen, setManualOpen] = useState(false);
  const toAccountOptions = paymentAccounts.filter((a) => a.startsWith("Assets:") || manual.kind === "transfer");
  const updateKind = (kind: ManualKind) => setManual({
    ...manual,
    kind,
    category: kind === "income" ? (incomeAccounts[0] ?? "Income:Other") : (expenseAccounts.find((a) => a === "Expenses:Unknown") ?? expenseAccounts[0] ?? "Expenses:Unknown"),
  });
  const renderAccountSelect = (value: string, options: string[], onValueChange: (value: string) => void, placeholder: string, className = "") => (
    <Select value={value} onValueChange={onValueChange}>
      <SelectTrigger className={`h-11 min-w-0 bg-panel ${className}`}>
        <SelectValue placeholder={placeholder} />
      </SelectTrigger>
      <SelectContent className="max-h-80">
        {options.map((account) => <SelectItem key={account} value={account}>{optionLabel(account)}</SelectItem>)}
      </SelectContent>
    </Select>
  );

  return <section>
    <div className="rounded-xl border border-line bg-panel p-3">
      <div className="text-sm font-medium">AI 自然语言</div>
      <Textarea id="nl-input" className="mt-3 h-36 min-h-36 bg-panel" placeholder={"例如：\n昨天 星巴克 38 招行信用卡\n今天 午餐 56 支付宝\n5/8 打车 24 微信"} value={nl} onChange={(e) => setNl(e.target.value)} />
      <div className="mt-3 flex flex-wrap items-center gap-3">
        <Button onClick={onParse} disabled={busy}>{parseStatus === "parsing" ? "解析中…" : "AI 解析"}</Button>
        {parseMessage && (
          <Alert variant={parseStatus === "error" ? "destructive" : "default"} className={`w-auto min-w-0 flex-1 ${parseStatus === "success" ? "text-[var(--success)]" : ""}`}>
            <AlertDescription>{parseMessage}</AlertDescription>
          </Alert>
        )}
      </div>
    </div>

    <div className="mt-4 rounded-xl border border-line bg-panel p-3">
      <Button type="button" variant="ghost" className="h-auto w-full justify-between px-0 py-0 text-left text-sm font-medium hover:bg-transparent" onClick={() => setManualOpen((value) => !value)}><span>手动记账</span><span className="text-xs text-stone">{manualOpen ? "收起" : "展开"}</span></Button>
      {manualOpen && <>
        <div className="mt-3 grid min-w-0 grid-cols-1 gap-3 sm:grid-cols-2">
          <Select value={manual.kind} onValueChange={(value) => updateKind(value as ManualKind)}>
            <SelectTrigger className="h-11 min-w-0 bg-panel">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="expense">支出</SelectItem>
              <SelectItem value="income">收入</SelectItem>
              <SelectItem value="transfer">转账/还款</SelectItem>
            </SelectContent>
          </Select>
          <Input className="h-11 min-w-0 bg-panel" type="date" value={manual.date} onChange={(e) => setManual({ ...manual, date: e.target.value })} />
          <Input className="h-11 min-w-0 bg-panel" placeholder="商户/对方" value={manual.payee} onChange={(e) => setManual({ ...manual, payee: e.target.value })} />
          <Input className="h-11 min-w-0 bg-panel" inputMode="decimal" placeholder="金额" value={manual.amount} onChange={(e) => setManual({ ...manual, amount: e.target.value })} />
          <Input className="h-11 min-w-0 bg-panel sm:col-span-2" placeholder="说明，可选" value={manual.narration} onChange={(e) => setManual({ ...manual, narration: e.target.value })} />
          {manual.kind !== "income" && renderAccountSelect(manual.fromAccount, paymentAccounts, (value) => setManual({ ...manual, fromAccount: value }), "付款账户")}
          {manual.kind !== "expense" && renderAccountSelect(manual.toAccount, toAccountOptions, (value) => setManual({ ...manual, toAccount: value }), "收款账户")}
          {manual.kind !== "transfer" && renderAccountSelect(manual.category, categoryOptions, (value) => setManual({ ...manual, category: value }), "分类", "sm:col-span-2")}
        </div>
        <Button className="mt-3" onClick={onPreviewManual} disabled={busy}>生成预览</Button>
      </>}
    </div>

    {previews.length > 0 && <div className="mt-4 rounded-xl border border-line bg-panel p-3">
      <div className="flex items-center justify-between gap-3"><div className="font-medium">解析结果（{previews.length} 条）</div><Button onClick={onAppendPreviews} disabled={busy}>{appendStatus === "writing" ? "写入中…" : `确认写入 ${previews.length} 条`}</Button></div>
      <div className="mt-3 space-y-3">{previews.map((preview, index) => <div key={`${preview.date}-${preview.payee}-${index}`} className="rounded-xl border border-line bg-paper p-3">
        <div className="flex items-start justify-between gap-3"><div><div className="font-medium">{index + 1}. {preview.date} {preview.payee}</div><div className="text-sm text-stone">{preview.narration || "无说明"} · 置信度 {Math.round(preview.confidence * 100)}%</div></div><Button variant="outline" size="xs" className="shrink-0 rounded-lg text-stone" onClick={() => onRemovePreview(index)} disabled={busy}>移除</Button></div>
        {preview.needsReview && <div className="mt-2 rounded-lg border border-line bg-tag px-2 py-1 text-xs text-warm">需要确认{preview.questions.length ? `：${preview.questions.join("；")}` : ""}</div>}
        {(Object.keys(preview.metadata ?? {}).length > 0 || (preview.tags ?? []).length > 0) && <div className="mt-2 flex flex-wrap gap-1">{Object.entries(preview.metadata ?? {}).map(([key, value]) => <span key={key} className="rounded-full bg-tag px-2 py-0.5 text-[11px] text-stone">{key}: {String(value)}</span>)}{(preview.tags ?? []).map((tag) => <span key={tag} className="rounded-full bg-tag px-2 py-0.5 text-[11px] text-stone">#{tag}</span>)}</div>}
        <div className="mt-2 space-y-1">{preview.postings.map((p, i) => <div key={i} className="flex justify-between gap-3 text-sm"><span className="min-w-0 truncate">{p.account}</span><span className="shrink-0">{p.amount} {p.currency}</span></div>)}</div>
      </div>)}</div>
    </div>}
  </section>;
}
