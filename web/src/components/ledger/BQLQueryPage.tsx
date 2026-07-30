"use client";

import { AlertTriangle, Clock, Database, Play, RefreshCw } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { apiEndpointLedgerScope, apiFetch } from "@/lib/apiEndpoints";
import { readJson } from "@/lib/clientFetch";

type BQLColumn = {
  name: string;
  type: string;
};

type BQLResult = {
  columns: BQLColumn[];
  rows: unknown[][];
  query: string;
  warnings?: string[];
  valuationCurrency: string;
  limit: number;
  rowCount: number;
};

const defaultQuery = `SELECT month, account, sum(value) AS total
FROM postings
WHERE date >= '2026-01-01' AND account LIKE 'Expenses:%'
GROUP BY month, account
ORDER BY month DESC, total DESC
LIMIT 100`;

const examples = [
  {
    label: "月度分类支出",
    query: defaultQuery,
  },
  {
    label: "商户排行",
    query: `SELECT payee, count(*) AS tx_count, sum(value) AS total
FROM transactions
WHERE date >= '2026-01-01' AND type = 'expense'
GROUP BY payee
ORDER BY total DESC
LIMIT 50`,
  },
  {
    label: "收入账户",
    query: `SELECT month, account, sum(value) AS total
FROM postings
WHERE account LIKE 'Income:%'
GROUP BY month, account
ORDER BY month DESC
LIMIT 100`,
  },
];

const recentsLimit = 8;
const recentsKey = "ledger.bql.recents.v1";

export function BQLQueryPage({ valuationCurrency, onSensitiveLocked }: { valuationCurrency: string; onSensitiveLocked: () => void }) {
  const [query, setQuery] = useState(defaultQuery);
  const [result, setResult] = useState<BQLResult | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [recents, setRecents] = useState<string[]>(() => readRecents());
  const canRun = Boolean(query.trim()) && !loading;
  const preview = useMemo(() => result ? summarizeResult(result) : "", [result]);

  useEffect(() => {
    setRecents(readRecents());
  }, []);

  async function runQuery(nextQuery = query) {
    const text = nextQuery.trim();
    if (!text || loading) return;
    setLoading(true);
    setError("");
    try {
      const response = await apiFetch("/api/ledger/bql", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ query: text, valuationCurrency }),
      }, { kind: "read" });
      if (response.status === 401 || response.status === 423) {
        onSensitiveLocked();
        return;
      }
      const payload = await readJson<BQLResult & { error?: string }>(response);
      if (!response.ok) throw new Error(payload.error || `请求失败：${response.status}`);
      setResult(payload);
      setRecents((current) => {
        const next = [text, ...current.filter((item) => item !== text)].slice(0, recentsLimit);
        writeRecents(next);
        return next;
      });
    } catch (runError) {
      setError(runError instanceof Error ? runError.message : "BQL 查询失败");
    } finally {
      setLoading(false);
    }
  }

  function useQuery(nextQuery: string, execute = false) {
    setQuery(nextQuery);
    if (execute) void runQuery(nextQuery);
  }

  return (
    <div className="bql-workbench min-w-0">
      <section className="border-b border-line bg-panel px-3 py-3 md:px-4 xl:px-6">
        <div className="grid gap-3 xl:grid-cols-[minmax(0,1fr)_18rem]">
          <div className="min-w-0">
            <div className="mb-2 flex min-w-0 flex-wrap items-center justify-between gap-2">
              <div className="flex min-w-0 items-center gap-2">
                <span className="grid h-8 w-8 shrink-0 place-items-center rounded-md bg-tag text-brand"><Database className="h-4 w-4" /></span>
                <div className="min-w-0">
                  <h2 className="truncate text-sm font-semibold text-ink">BQL 查询</h2>
                  {preview && <p className="mt-0.5 truncate text-[11px] text-stone">{preview}</p>}
                </div>
              </div>
              <Button type="button" size="sm" className="h-8 rounded-md bg-brand text-paper hover:bg-brand/90" onClick={() => void runQuery()} disabled={!canRun}>
                {loading ? <RefreshCw className="h-3.5 w-3.5 animate-spin" /> : <Play className="h-3.5 w-3.5" />}
                运行
              </Button>
            </div>
            <Textarea
              className="min-h-48 resize-y rounded-md border-line bg-paper font-mono text-[13px] leading-5 text-ink shadow-none focus-visible:ring-2"
              spellCheck={false}
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              onKeyDown={(event) => {
                if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
                  event.preventDefault();
                  void runQuery();
                }
              }}
            />
            {error && <div className="mt-2 flex items-start gap-2 rounded-md border border-line bg-tag px-3 py-2 text-sm text-warm">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 amount-danger" />
              <span className="min-w-0 [overflow-wrap:anywhere]">{error}</span>
            </div>}
            {result?.warnings?.length ? <div className="mt-2 flex flex-wrap gap-2">
              {result.warnings.map((warning) => <span key={warning} className="rounded-full bg-tag px-2.5 py-1 text-xs text-stone">{warning}</span>)}
            </div> : null}
          </div>
          <aside className="min-w-0 border-t border-line pt-3 xl:border-l xl:border-t-0 xl:pl-3 xl:pt-0">
            <div className="text-[11px] font-semibold uppercase tracking-[0.12em] text-stone">示例</div>
            <div className="mt-2 grid gap-2">
              {examples.map((example) => <button key={example.label} type="button" className="min-w-0 rounded-md border border-line bg-paper px-3 py-2 text-left text-sm text-olive hover:bg-tag" onClick={() => useQuery(example.query)}>
                <span className="block truncate font-medium text-ink">{example.label}</span>
                <span className="mt-1 block truncate font-mono text-[11px] text-stone">{example.query.split("\n")[0]}</span>
              </button>)}
            </div>
            {recents.length > 0 && <>
              <div className="mt-4 flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-[0.12em] text-stone"><Clock className="h-3 w-3" /> 最近</div>
              <div className="mt-2 grid gap-2">
                {recents.map((recent) => <button key={recent} type="button" className="min-w-0 rounded-md border border-line bg-paper px-3 py-2 text-left hover:bg-tag" onClick={() => useQuery(recent)}>
                  <span className="line-clamp-2 font-mono text-[11px] leading-4 text-olive">{recent.replace(/\s+/g, " ")}</span>
                </button>)}
              </div>
            </>}
          </aside>
        </div>
      </section>
      <BQLResultTable result={result} loading={loading} />
    </div>
  );
}

function BQLResultTable({ result, loading }: { result: BQLResult | null; loading: boolean }) {
  if (loading && !result) return <section className="border-b border-line bg-panel p-5 text-sm text-stone">正在运行查询…</section>;
  if (!result) return <section className="border-b border-line bg-panel p-5 text-sm text-stone">运行 BQL 后会在这里显示表格。</section>;
  if (result.rows.length === 0) return <section className="border-b border-line bg-panel p-5 text-sm text-stone">查询完成，没有返回行。</section>;

  return <section className="min-w-0 border-b border-line bg-panel">
    <div className="flex flex-wrap items-center justify-between gap-2 border-b border-line px-3 py-2 md:px-4">
      <div className="text-sm font-semibold text-ink">结果表</div>
      <div className="text-xs tabular-nums text-stone">{result.rowCount} 行 · {result.valuationCurrency}</div>
    </div>
    <div className="max-h-[calc(100vh-18rem)] min-w-0 overflow-auto">
      <table className="min-w-full border-collapse text-left text-sm">
        <thead className="sticky top-0 z-10 bg-tag text-[11px] uppercase tracking-[0.08em] text-stone">
          <tr>
            {result.columns.map((column) => <th key={column.name} className="whitespace-nowrap border-b border-line px-3 py-2 font-semibold">{column.name}</th>)}
          </tr>
        </thead>
        <tbody>
          {result.rows.map((row, rowIndex) => <tr key={rowIndex} className="border-b border-line/70 hover:bg-tag/70">
            {result.columns.map((column, columnIndex) => <td key={`${rowIndex}:${column.name}`} className={`max-w-[24rem] whitespace-nowrap px-3 py-2 ${column.type === "money" || column.type === "number" ? "text-right tabular-nums" : "text-left"}`}>
              <span className="block truncate" title={String(row[columnIndex] ?? "")}>{formatCell(row[columnIndex], column)}</span>
            </td>)}
          </tr>)}
        </tbody>
      </table>
    </div>
  </section>;
}

function summarizeResult(result: BQLResult) {
  return `${result.rowCount} 行 · ${result.columns.length} 列 · ${result.valuationCurrency}`;
}

function formatCell(value: unknown, column: BQLColumn) {
  if (value == null) return "";
  if (column.type === "money" && typeof value === "number") return formatMoney(value, "");
  if (column.type === "number" && typeof value === "number") return new Intl.NumberFormat("zh-CN").format(value);
  return String(value);
}

function formatMoney(cents: number, currency: string) {
  const value = cents / 100;
  const formatted = new Intl.NumberFormat("zh-CN", { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(value);
  return currency ? `${formatted} ${currency}` : formatted;
}

function scopedRecentsKey() {
  return `${recentsKey}:${apiEndpointLedgerScope()}`;
}

function readRecents() {
  try {
    const raw = window.localStorage.getItem(scopedRecentsKey());
    if (!raw) return [];
    const values = JSON.parse(raw);
    if (!Array.isArray(values)) return [];
    return values.filter((value): value is string => typeof value === "string" && value.trim() !== "").slice(0, recentsLimit);
  } catch {
    return [];
  }
}

function writeRecents(values: string[]) {
  try {
    window.localStorage.setItem(scopedRecentsKey(), JSON.stringify(values.slice(0, recentsLimit)));
  } catch {
    // Ignore storage failures; recent queries are a convenience.
  }
}
