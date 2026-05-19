"use client";

import { useState } from "react";
import { AlertTriangle, CheckCircle, FileUp, Loader2 } from "lucide-react";
import { readJson } from "@/lib/clientFetch";

type Provider = "alipay" | "wechat";

type ImportPreview = {
  importId: string;
  provider: Provider;
  originalFilename: string;
  generatedBean: string;
  dedupReport: string;
  candidateCount: number;
  dateStart: string | null;
  dateEnd: string | null;
  warnings: string[];
  error?: string;
};

type CommitResult = {
  ok?: boolean;
  outputFile?: string;
  includeFile?: string;
  count?: number;
  beanText?: string;
  error?: string;
};

export function ImportPage({ onImported }: { onImported?: () => void }) {
  const [provider, setProvider] = useState<Provider>("alipay");
  const [file, setFile] = useState<File | null>(null);
  const [alipayFundRounding, setAlipayFundRounding] = useState(false);
  const [preview, setPreview] = useState<ImportPreview | null>(null);
  const [commitResult, setCommitResult] = useState<CommitResult | null>(null);
  const [loading, setLoading] = useState(false);
  const [committing, setCommitting] = useState(false);
  const [error, setError] = useState("");

  async function generatePreview() {
    if (!file) {
      setError("请先选择账单文件");
      return;
    }
    setLoading(true);
    setError("");
    setPreview(null);
    setCommitResult(null);
    try {
      const form = new FormData();
      form.set("provider", provider);
      form.set("file", file);
      form.set("alipayFundRounding", String(alipayFundRounding));
      const res = await fetch("/api/ledger/imports/preview", { method: "POST", body: form });
      const data = await readJson<ImportPreview>(res);
      if (!res.ok || data.error) throw new Error(data.error || "生成预览失败");
      setPreview(data);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  }

  async function commitImport() {
    if (!preview) return;
    setCommitting(true);
    setError("");
    setCommitResult(null);
    try {
      const res = await fetch("/api/ledger/imports/commit", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ importId: preview.importId, provider: preview.provider, alipayFundRounding }),
      });
      const data = await readJson<CommitResult>(res);
      if (!res.ok || data.error) throw new Error(data.error || "写入失败");
      setCommitResult(data);
      onImported?.();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setCommitting(false);
    }
  }

  const providerLabel = provider === "alipay" ? "支付宝" : "微信支付";

  return (
    <div className="space-y-6">
      <section className="card p-5">
        <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <h2 className="font-serif text-2xl">账单导入</h2>
            <p className="mt-2 max-w-2xl text-sm leading-6 text-olive">
              上传支付宝 CSV 或微信支付 XLSX，后端会使用 double-entry-generator 生成 Beancount 分录，并优先按 <strong>source + orderId</strong> 去重。
            </p>
          </div>
          <div className="rounded-2xl border border-line bg-paper px-4 py-3 text-xs leading-5 text-stone">
            当前策略：订单 ID 优先；无订单 ID 时回退到日期 + 金额 + 资金账户。
          </div>
        </div>

        <div className="mt-5 grid gap-4 md:grid-cols-[220px_1fr]">
          <label className="block">
            <span className="mb-1 block text-xs text-stone">账单来源</span>
            <select className="w-full rounded-xl border border-line bg-paper px-3 py-2" value={provider} onChange={(event) => { setProvider(event.target.value as Provider); setPreview(null); setCommitResult(null); }}>
              <option value="alipay">支付宝 CSV</option>
              <option value="wechat">微信支付 XLSX</option>
            </select>
          </label>

          <label className="block">
            <span className="mb-1 block text-xs text-stone">账单文件</span>
            <input className="w-full rounded-xl border border-line bg-paper px-3 py-2 text-sm" type="file" accept={provider === "alipay" ? ".csv" : ".xlsx,.xls"} onChange={(event) => { setFile(event.target.files?.[0] ?? null); setPreview(null); setCommitResult(null); }} />
          </label>
        </div>

        {provider === "alipay" && (
          <label className="mt-4 flex items-start gap-3 rounded-2xl border border-line bg-paper p-4 text-sm">
            <input className="mt-1 h-4 w-4 accent-brand" type="checkbox" checked={alipayFundRounding} onChange={(event) => setAlipayFundRounding(event.target.checked)} />
            <span>
              <span className="font-medium">启用支付宝基金 9.99 → 10.00 补差规则</span>
              <span className="mt-1 block text-xs leading-5 text-stone">仅当你确认该基金定投是支付 9.99、基金入账 10.00，且 0.01 记为收益/优惠时开启。</span>
            </span>
          </label>
        )}

        <div className="mt-5 flex flex-wrap items-center gap-3">
          <button className="rounded-xl bg-brand px-5 py-3 text-paper disabled:opacity-60" onClick={generatePreview} disabled={loading || !file}>
            {loading ? <Loader2 className="mr-2 inline h-4 w-4 animate-spin" /> : <FileUp className="mr-2 inline h-4 w-4" />}生成预览
          </button>
          {file && <span className="text-sm text-stone">已选择：{file.name}</span>}
        </div>
      </section>

      {error && <div className="rounded-2xl border border-line bg-panel p-4 text-sm text-[var(--danger)]"><AlertTriangle className="mr-2 inline h-4 w-4" />{error}</div>}

      {preview && (
        <section className="card p-5">
          <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <h3 className="font-serif text-xl">{providerLabel}导入预览</h3>
              <p className="mt-1 text-sm text-stone">{preview.originalFilename} · {preview.candidateCount} 条生成交易 · {preview.dateStart ?? "?"} ~ {preview.dateEnd ?? "?"}</p>
            </div>
            <button className="rounded-xl bg-brand px-5 py-3 text-paper disabled:opacity-60" onClick={commitImport} disabled={committing || commitResult?.ok === true}>
              {committing ? <Loader2 className="mr-2 inline h-4 w-4 animate-spin" /> : null}确认写入账本
            </button>
          </div>

          {preview.warnings.length > 0 && <div className="mt-4 rounded-2xl border border-line bg-paper p-4 text-sm text-warm">{preview.warnings.map((warning) => <div key={warning}>⚠️ {warning}</div>)}</div>}

          <div className="mt-4 grid gap-4 lg:grid-cols-2">
            <div>
              <div className="mb-2 text-xs uppercase tracking-[0.22em] text-stone">dedup report</div>
              <pre className="max-h-96 overflow-auto rounded-2xl border border-line bg-ink p-4 text-xs leading-5 text-paper">{preview.dedupReport}</pre>
            </div>
            <div>
              <div className="mb-2 text-xs uppercase tracking-[0.22em] text-stone">generated bean</div>
              <pre className="max-h-96 overflow-auto rounded-2xl border border-line bg-ink p-4 text-xs leading-5 text-paper">{preview.generatedBean}</pre>
            </div>
          </div>
        </section>
      )}

      {commitResult?.ok && (
        <section className="card p-5">
          <h3 className="font-serif text-xl text-brand"><CheckCircle className="mr-2 inline h-5 w-5" />导入完成</h3>
          <div className="mt-3 space-y-1 text-sm text-olive">
            <div>写入交易：{commitResult.count} 条</div>
            <div>导入文件：{commitResult.outputFile}</div>
            <div>月份 include：{commitResult.includeFile}</div>
            <div className="text-stone">如需保存到远端，请点击右上角「保存到 Git」。</div>
          </div>
        </section>
      )}
    </div>
  );
}
