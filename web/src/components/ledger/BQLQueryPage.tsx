"use client";

import { sql } from "@codemirror/lang-sql";
import { EditorView, type ViewUpdate } from "@codemirror/view";
import CodeMirror from "@uiw/react-codemirror";
import { AlertTriangle, BarChart3, Clock, Database, LineChart as LineChartIcon, Pencil, PieChart as PieChartIcon, Play, RefreshCw, Sparkles, Table2, Trash2 } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { Bar, BarChart, CartesianGrid, Cell, Line, LineChart, Pie, PieChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { Button } from "@/components/ui/button";
import { apiFetch } from "@/lib/apiEndpoints";
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

type BQLRun = {
  id: string;
  query: string;
  result?: BQLResult;
  error?: string;
};

type BQLHistoryRecord = {
  id: string;
  query: string;
  title: string;
  titleSource: "ai" | "fallback" | "manual";
  createdAt: string;
  lastRunAt: string;
  runCount: number;
};

type BQLStatement = {
  text: string;
  start: number;
  end: number;
};

type EditorSelection = {
  from: number;
  to: number;
};

type ChartKind = "table" | "bar" | "pie" | "line";

type ChartDatum = {
  label: string;
  value: number;
};

type ChartModel = {
  labelColumn: BQLColumn;
  valueColumn: BQLColumn;
  data: ChartDatum[];
  canLine: boolean;
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

const chartColors = [
  "var(--chart-palette-1, var(--chart-primary))",
  "var(--chart-palette-2, var(--stone))",
  "var(--chart-palette-3, var(--chart-primary))",
  "var(--chart-palette-4, var(--stone))",
  "var(--chart-palette-5, var(--chart-primary))",
  "var(--chart-palette-6, var(--stone))",
];

const bqlEditorTheme = EditorView.theme({
  "&": {
    minHeight: "12rem",
    background: "var(--ledger-code-bg)",
    color: "var(--ledger-code-fg)",
    fontSize: "13px",
  },
  ".cm-scroller": {
    minHeight: "12rem",
    background: "transparent",
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
    lineHeight: "1.55",
  },
  ".cm-content": {
    padding: "12px 0",
  },
  ".cm-line": {
    padding: "0 12px",
  },
  ".cm-gutters": {
    background: "var(--ledger-code-gutter-bg)",
    borderRight: "1px solid var(--ledger-code-border)",
    color: "var(--ledger-code-muted)",
  },
  ".cm-cursor, .cm-dropCursor": {
    borderLeftColor: "var(--ledger-code-fg)",
  },
  ".cm-activeLine, .cm-activeLineGutter": {
    background: "color-mix(in srgb, var(--ledger-code-selection) 46%, transparent)",
  },
  ".cm-focused": {
    outline: "none",
  },
  ".cm-selectionBackground, &.cm-focused .cm-selectionBackground": {
    background: "var(--ledger-code-selection)",
  },
  ".cm-selectionMatch": {
    background: "color-mix(in srgb, var(--ledger-code-selection) 68%, transparent)",
  },
  ".cm-matchingBracket, .cm-nonmatchingBracket": {
    background: "color-mix(in srgb, var(--brand) 22%, transparent)",
    outline: "1px solid var(--brand)",
  },
  ".cm-panels, .cm-tooltip": {
    background: "var(--ledger-code-bg)",
    borderColor: "var(--ledger-code-border)",
    color: "var(--ledger-code-fg)",
  },
  ".cm-button, .cm-textfield": {
    background: "var(--paper)",
    border: "1px solid var(--ledger-code-border)",
    color: "var(--ink)",
  },
});

export function BQLQueryPage({ valuationCurrency, onSensitiveLocked, onOpenAgent, agentQuery }: { valuationCurrency: string; onSensitiveLocked: () => void; onOpenAgent?: (prompt: string) => void; agentQuery?: { id: number; query: string } | null }) {
  const [query, setQuery] = useState(defaultQuery);
  const [runs, setRuns] = useState<BQLRun[]>([]);
  const [activeViews, setActiveViews] = useState<Record<string, ChartKind>>({});
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [history, setHistory] = useState<BQLHistoryRecord[]>([]);
  const [historyLoading, setHistoryLoading] = useState(true);
  const [historyError, setHistoryError] = useState("");
  const [editingHistoryID, setEditingHistoryID] = useState<string | null>(null);
  const [editingTitle, setEditingTitle] = useState("");
  const [historyMutationID, setHistoryMutationID] = useState<string | null>(null);
  const selectionRef = useRef<EditorSelection>({ from: 0, to: 0 });
  const editorExtensions = useMemo(() => [sql()], []);
  const statements = useMemo(() => splitBQLStatements(query), [query]);
  const canRun = statements.length > 0 && !loading;
  const preview = useMemo(() => summarizeRuns(runs), [runs]);
  const appliedAgentQueryRef = useRef(0);

  useEffect(() => {
    if (!agentQuery || agentQuery.id === appliedAgentQueryRef.current) return;
    appliedAgentQueryRef.current = agentQuery.id;
    useQuery(agentQuery.query);
  }, [agentQuery]);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const response = await apiFetch("/api/ledger/bql-history", undefined, { kind: "read" });
        if (response.status === 401 || response.status === 423) {
          onSensitiveLocked();
          return;
        }
        const payload = await readJson<{ records: BQLHistoryRecord[]; error?: string }>(response);
        if (!response.ok) throw new Error(payload.error || `请求失败：${response.status}`);
        if (!cancelled) setHistory(sortHistory(payload.records));
      } catch {
        if (!cancelled) setHistoryError("查询历史暂时无法加载");
      } finally {
        if (!cancelled) setHistoryLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [onSensitiveLocked]);

  async function runAllQueries() {
    await executeStatements(statements, query.trim());
  }

  async function runCurrentQuery() {
    const current = currentStatement(query, selectionRef.current);
    await executeStatements(current ? [current] : statements, current?.text ?? query.trim());
  }

  async function executeStatements(nextStatements: BQLStatement[], historyText: string) {
    const selected = nextStatements.map((statement) => statement.text.trim()).filter(Boolean);
    if (selected.length === 0 || loading) return;
    setLoading(true);
    setError("");
    const nextRuns = selected.map((text, index) => ({ id: `${Date.now()}:${index}:${text.length}`, query: text }));
    setRuns(nextRuns);
    try {
      let completed = true;
      for (const run of nextRuns) {
        try {
          const response = await apiFetch("/api/ledger/bql", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ query: run.query, valuationCurrency }),
          }, { kind: "read" });
          if (response.status === 401 || response.status === 423) {
            completed = false;
            onSensitiveLocked();
            return;
          }
          const payload = await readJson<BQLResult & { error?: string }>(response);
          if (!response.ok) throw new Error(payload.error || `请求失败：${response.status}`);
          updateRun(run.id, { result: payload });
        } catch (runError) {
          completed = false;
          updateRun(run.id, { error: runError instanceof Error ? runError.message : "BQL 查询失败" });
        }
      }
      if (completed) void rememberSuccessfulQuery(historyText);
    } finally {
      setLoading(false);
    }
  }

  function updateRun(id: string, patch: Partial<BQLRun>) {
    setRuns((current) => current.map((run) => run.id === id ? { ...run, ...patch } : run));
  }

  async function rememberSuccessfulQuery(text: string) {
    const trimmed = text.trim();
    if (!trimmed) return;
    try {
      const response = await apiFetch("/api/ledger/bql-history", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ query: trimmed }),
      }, { kind: "write" });
      if (response.status === 401 || response.status === 423) {
        onSensitiveLocked();
        return;
      }
      const record = await readJson<BQLHistoryRecord & { error?: string }>(response);
      if (!response.ok) throw new Error(record.error || `请求失败：${response.status}`);
      setHistory((current) => sortHistory([record, ...current.filter((item) => item.id !== record.id)]));
      setHistoryError("");
      void generateHistoryTitle(record.id);
    } catch {
      setHistoryError("查询已完成，历史未同步");
    }
  }

  async function generateHistoryTitle(id: string) {
    try {
      const response = await apiFetch(`/api/ledger/bql-history/${id}/title`, { method: "POST" }, { kind: "write" });
      if (response.status === 401 || response.status === 423) {
        onSensitiveLocked();
        return;
      }
      const next = await readJson<BQLHistoryRecord & { error?: string }>(response);
      if (!response.ok) throw new Error(next.error || `请求失败：${response.status}`);
      setHistory((current) => current.map((item) => item.id === next.id ? next : item));
    } catch {
      // The fallback title remains usable; the next successful run retries AI naming.
    }
  }

  function runHistory(record: BQLHistoryRecord) {
    useQuery(record.query);
    void executeStatements(splitBQLStatements(record.query), record.query);
  }

  function beginRename(record: BQLHistoryRecord) {
    setEditingHistoryID(record.id);
    setEditingTitle(record.title);
  }

  async function saveHistoryTitle(record: BQLHistoryRecord) {
    const title = editingTitle.trim();
    if (!title) return;
    setHistoryMutationID(record.id);
    try {
      const response = await apiFetch(`/api/ledger/bql-history/${record.id}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ title }),
      }, { kind: "write" });
      if (response.status === 401 || response.status === 423) {
        onSensitiveLocked();
        return;
      }
      const next = await readJson<BQLHistoryRecord & { error?: string }>(response);
      if (!response.ok) throw new Error(next.error || `请求失败：${response.status}`);
      setHistory((current) => current.map((item) => item.id === next.id ? next : item));
      setEditingHistoryID(null);
      setHistoryError("");
    } catch {
      setHistoryError("标题保存失败");
    } finally {
      setHistoryMutationID(null);
    }
  }

  async function removeHistory(record: BQLHistoryRecord) {
    setHistoryMutationID(record.id);
    try {
      const response = await apiFetch(`/api/ledger/bql-history/${record.id}`, { method: "DELETE" }, { kind: "write" });
      if (response.status === 401 || response.status === 423) {
        onSensitiveLocked();
        return;
      }
      if (!response.ok) throw new Error(`请求失败：${response.status}`);
      setHistory((current) => current.filter((item) => item.id !== record.id));
      setEditingHistoryID((current) => current === record.id ? null : current);
      setHistoryError("");
    } catch {
      setHistoryError("历史记录删除失败");
    } finally {
      setHistoryMutationID(null);
    }
  }

  function useQuery(nextQuery: string) {
    setQuery(nextQuery);
    selectionRef.current = { from: 0, to: 0 };
  }

  function handleEditorUpdate(update: ViewUpdate) {
    const selection = update.state.selection.main;
    selectionRef.current = { from: selection.from, to: selection.to };
    if (update.docChanged) setQuery(update.state.doc.toString());
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
              <div className="flex flex-wrap items-center gap-2">
                {onOpenAgent && <Button type="button" variant="outline" size="sm" className="h-8 rounded-md border-line bg-paper text-ink hover:bg-tag" onClick={() => onOpenAgent(`请根据当前 BQL 编辑器内容生成或优化查询，并先校验语法。当前内容：\n\n${query}`)}>
                  <Sparkles className="h-3.5 w-3.5" />
                  AI 生成
                </Button>}
                <Button type="button" variant="outline" size="sm" className="h-8 rounded-md border-line bg-paper text-ink hover:bg-tag" onClick={() => void runCurrentQuery()} disabled={!canRun}>
                  {loading ? <RefreshCw className="h-3.5 w-3.5 animate-spin" /> : <Play className="h-3.5 w-3.5" />}
                  当前语句
                </Button>
                <Button type="button" size="sm" className="h-8 rounded-md bg-brand text-paper hover:bg-brand/90" onClick={() => void runAllQueries()} disabled={!canRun}>
                  {loading ? <RefreshCw className="h-3.5 w-3.5 animate-spin" /> : <Play className="h-3.5 w-3.5" />}
                  全部运行
                </Button>
              </div>
            </div>
            <div
              className="overflow-hidden rounded-md border border-[var(--ledger-code-border)] bg-[var(--ledger-code-bg)] text-[var(--ledger-code-fg)] focus-within:ring-2 focus-within:ring-brand/30"
              onKeyDown={(event) => {
                if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
                  event.preventDefault();
                  void runCurrentQuery();
                }
              }}
            >
              <CodeMirror
                basicSetup={{ foldGutter: false, highlightActiveLine: true, highlightActiveLineGutter: true }}
                extensions={editorExtensions}
                height="12rem"
                theme={bqlEditorTheme}
                value={query}
                onUpdate={handleEditorUpdate}
              />
            </div>
            <div className="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-stone">
              <span>{statements.length || 0} 条语句</span>
              <span>Cmd/Ctrl + Enter 运行选中或当前语句</span>
            </div>
            {error && <div className="mt-2 flex items-start gap-2 rounded-md border border-line bg-tag px-3 py-2 text-sm text-warm">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 amount-danger" />
              <span className="min-w-0 [overflow-wrap:anywhere]">{error}</span>
            </div>}
          </div>
          <aside className="min-w-0 border-t border-line pt-3 xl:border-l xl:border-t-0 xl:pl-3 xl:pt-0">
            <div className="flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-[0.12em] text-stone">
              <Clock className="h-3 w-3" />
              {history.length > 0 ? "查询历史" : "示例查询"}
            </div>
            {historyError && <div className="mt-2 text-xs text-warm">{historyError}</div>}
            <div className="mt-2 grid gap-2">
              {historyLoading && <div className="flex items-center gap-2 px-1 py-2 text-xs text-stone"><RefreshCw className="h-3.5 w-3.5 animate-spin" />加载查询历史</div>}
              {!historyLoading && history.length === 0 && examples.map((example, index) => <button key={`${example.label}:${example.query}:${index}`} type="button" className="min-w-0 rounded-md border border-line bg-paper px-3 py-2 text-left text-sm text-olive hover:bg-tag" onClick={() => useQuery(example.query)}>
                <span className="block truncate font-medium text-ink">{example.label}</span>
                <span className="mt-1 block truncate font-mono text-[11px] text-stone">{example.query.replace(/\s+/g, " ")}</span>
              </button>)}
              {!historyLoading && history.map((record) => <div key={record.id} className="min-w-0 rounded-md border border-line bg-paper px-3 py-2">
                <div className="flex min-w-0 items-start gap-1">
                  {editingHistoryID === record.id ? <input autoFocus value={editingTitle} maxLength={40} className="h-7 min-w-0 flex-1 border-b border-brand bg-transparent px-0 text-sm font-medium text-ink outline-none" onChange={(event) => setEditingTitle(event.target.value)} onBlur={() => void saveHistoryTitle(record)} onKeyDown={(event) => {
                    if (event.key === "Enter") void saveHistoryTitle(record);
                    if (event.key === "Escape") setEditingHistoryID(null);
                  }} /> : <button type="button" className="min-w-0 flex-1 truncate text-left text-sm font-medium text-ink hover:text-brand" onClick={() => useQuery(record.query)} title={record.title}>{record.title}</button>}
                  <button type="button" className="grid h-7 w-7 shrink-0 place-items-center text-stone hover:bg-tag hover:text-ink disabled:opacity-40" title="重命名" aria-label="重命名" disabled={historyMutationID === record.id} onClick={() => beginRename(record)}><Pencil className="h-3.5 w-3.5" /></button>
                  <button type="button" className="grid h-7 w-7 shrink-0 place-items-center text-stone hover:bg-tag hover:text-ink disabled:opacity-40" title="运行查询" aria-label="运行查询" disabled={loading || historyMutationID === record.id} onClick={() => runHistory(record)}><Play className="h-3.5 w-3.5" /></button>
                  <button type="button" className="grid h-7 w-7 shrink-0 place-items-center text-stone hover:bg-tag hover:text-warm disabled:opacity-40" title="删除" aria-label="删除" disabled={historyMutationID === record.id} onClick={() => void removeHistory(record)}><Trash2 className="h-3.5 w-3.5" /></button>
                </div>
                <span className="mt-1 block truncate font-mono text-[11px] text-stone">{record.query.replace(/\s+/g, " ")}</span>
                <span className="mt-1 block text-[11px] text-stone">{formatHistoryTime(record.lastRunAt)} · {record.runCount} 次</span>
              </div>)}
            </div>
          </aside>
        </div>
      </section>
      <BQLResults runs={runs} loading={loading} activeViews={activeViews} onViewChange={(id, view) => setActiveViews((current) => ({ ...current, [id]: view }))} />
    </div>
  );
}

function BQLResults({ runs, loading, activeViews, onViewChange }: { runs: BQLRun[]; loading: boolean; activeViews: Record<string, ChartKind>; onViewChange: (id: string, view: ChartKind) => void }) {
  if (loading && runs.length === 0) return <section className="border-b border-line bg-panel p-5 text-sm text-stone">正在运行查询…</section>;
  if (runs.length === 0) return <section className="border-b border-line bg-panel p-5 text-sm text-stone">运行 BQL 后会在这里显示表格或图表。</section>;
  return <div className="min-w-0">
    {runs.map((run, index) => <BQLResultBlock key={run.id} run={run} index={index} loading={loading && !run.result && !run.error} activeView={activeViews[run.id] ?? "table"} onViewChange={(view) => onViewChange(run.id, view)} />)}
  </div>;
}

function BQLResultBlock({ run, index, loading, activeView, onViewChange }: { run: BQLRun; index: number; loading: boolean; activeView: ChartKind; onViewChange: (view: ChartKind) => void }) {
  const chart = useMemo(() => run.result ? buildChartModel(run.result) : null, [run.result]);
  const visibleView = activeView !== "table" && !supportsChart(chart, activeView) ? "table" : activeView;
  return <section className="min-w-0 border-b border-line bg-panel">
    <div className="flex min-w-0 flex-wrap items-center justify-between gap-2 border-b border-line px-3 py-2 md:px-4">
      <div className="min-w-0">
        <div className="text-sm font-semibold text-ink">结果 {index + 1}</div>
        <div className="mt-0.5 truncate font-mono text-[11px] text-stone" title={run.query}>{run.query.replace(/\s+/g, " ")}</div>
      </div>
      <div className="flex flex-wrap items-center gap-2">
        {run.result && <div className="text-xs tabular-nums text-stone">{run.result.rowCount} 行 · {run.result.valuationCurrency}</div>}
        {run.result && <ChartModeButtons chart={chart} activeView={visibleView} onViewChange={onViewChange} />}
      </div>
    </div>
    {loading && <div className="p-5 text-sm text-stone">正在运行这条查询…</div>}
    {run.error && <div className="flex items-start gap-2 px-3 py-3 text-sm text-warm md:px-4">
      <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 amount-danger" />
      <span className="min-w-0 [overflow-wrap:anywhere]">{run.error}</span>
    </div>}
    {run.result?.warnings?.length ? <div className="flex flex-wrap gap-2 px-3 py-2 md:px-4">
      {run.result.warnings.map((warning) => <span key={warning} className="rounded-full bg-tag px-2.5 py-1 text-xs text-stone">{warning}</span>)}
    </div> : null}
    {run.result && <BQLResultContent result={run.result} chart={chart} activeView={visibleView} />}
  </section>;
}

function ChartModeButtons({ chart, activeView, onViewChange }: { chart: ChartModel | null; activeView: ChartKind; onViewChange: (view: ChartKind) => void }) {
  const modes: Array<{ view: ChartKind; label: string; icon: typeof Table2; disabled?: boolean }> = [
    { view: "table", label: "表格", icon: Table2 },
    { view: "bar", label: "柱状", icon: BarChart3, disabled: !supportsChart(chart, "bar") },
    { view: "pie", label: "饼图", icon: PieChartIcon, disabled: !supportsChart(chart, "pie") },
    { view: "line", label: "折线", icon: LineChartIcon, disabled: !supportsChart(chart, "line") },
  ];
  return <div className="flex overflow-hidden rounded-md border border-line bg-paper">
    {modes.map((mode) => {
      const Icon = mode.icon;
      return <button
        key={mode.view}
        type="button"
        className={`grid h-7 w-8 place-items-center border-l border-line first:border-l-0 ${activeView === mode.view ? "bg-brand text-paper" : "text-stone hover:bg-tag"} disabled:cursor-not-allowed disabled:opacity-40`}
        disabled={mode.disabled}
        title={mode.label}
        aria-label={mode.label}
        aria-pressed={activeView === mode.view}
        onClick={() => onViewChange(mode.view)}
      >
        <Icon className="h-3.5 w-3.5" />
      </button>;
    })}
  </div>;
}

function BQLResultContent({ result, chart, activeView }: { result: BQLResult; chart: ChartModel | null; activeView: ChartKind }) {
  if (result.rows.length === 0) return <div className="p-5 text-sm text-stone">查询完成，没有返回行。</div>;
  if (activeView === "table") return <BQLResultTable result={result} />;
  if (!chart) return <div className="p-5 text-sm text-stone">当前结果没有可绘制的维度和值列。</div>;
  return <BQLResultChart chart={chart} kind={activeView} />;
}

function BQLResultTable({ result }: { result: BQLResult }) {
  return <div className="max-h-[calc(100vh-19rem)] min-w-0 overflow-auto">
    <table className="min-w-full border-collapse text-left text-sm">
      <thead className="sticky top-0 z-10 bg-tag text-[11px] uppercase tracking-[0.08em] text-stone">
        <tr>
          {result.columns.map((column) => <th key={column.name} className="whitespace-nowrap border-b border-line px-3 py-2 font-semibold">{column.name}</th>)}
        </tr>
      </thead>
      <tbody>
        {result.rows.map((row, rowIndex) => <tr key={rowIndex} className="border-b border-line/70 hover:bg-tag/70">
          {result.columns.map((column, columnIndex) => <td key={`${rowIndex}:${column.name}`} className={`max-w-[24rem] whitespace-nowrap px-3 py-2 ${isNumericColumn(column) ? "text-right tabular-nums" : "text-left"}`}>
            <span className="block truncate" title={String(row[columnIndex] ?? "")}>{formatCell(row[columnIndex], column)}</span>
          </td>)}
        </tr>)}
      </tbody>
    </table>
  </div>;
}

function BQLResultChart({ chart, kind }: { chart: ChartModel; kind: ChartKind }) {
  const data = kind === "pie" ? chart.data.filter((item) => item.value > 0).slice(0, 12) : chart.data.slice(0, 80);
  if (data.length === 0) return <div className="p-5 text-sm text-stone">没有可绘制的数据。</div>;
  return <div className="h-[22rem] min-w-0 px-3 py-3 md:px-4">
    <ResponsiveContainer width="100%" height="100%">
      {kind === "pie" ? (
        <PieChart>
          <Tooltip formatter={(value) => formatChartValue(Number(value), chart.valueColumn)} />
          <Pie data={data} dataKey="value" nameKey="label" innerRadius="48%" outerRadius="78%" paddingAngle={1}>
            {data.map((entry, index) => <Cell key={entry.label} fill={chartColors[index % chartColors.length]} />)}
          </Pie>
        </PieChart>
      ) : kind === "line" ? (
        <LineChart data={data} margin={{ top: 10, right: 16, bottom: 12, left: 10 }}>
          <CartesianGrid stroke="var(--chart-grid)" strokeDasharray="3 3" vertical={false} />
          <XAxis dataKey="label" tick={{ fontSize: 11 }} tickLine={false} axisLine={false} minTickGap={18} />
          <YAxis tick={{ fontSize: 11 }} tickLine={false} axisLine={false} width={64} tickFormatter={(value) => shortChartValue(Number(value), chart.valueColumn)} />
          <Tooltip formatter={(value) => formatChartValue(Number(value), chart.valueColumn)} />
          <Line type="monotone" dataKey="value" stroke="var(--chart-primary)" strokeWidth={2} dot={false} activeDot={{ r: 4 }} />
        </LineChart>
      ) : (
        <BarChart data={data} margin={{ top: 10, right: 16, bottom: 12, left: 10 }}>
          <CartesianGrid stroke="var(--chart-grid)" strokeDasharray="3 3" vertical={false} />
          <XAxis dataKey="label" tick={{ fontSize: 11 }} tickLine={false} axisLine={false} minTickGap={18} />
          <YAxis tick={{ fontSize: 11 }} tickLine={false} axisLine={false} width={64} tickFormatter={(value) => shortChartValue(Number(value), chart.valueColumn)} />
          <Tooltip formatter={(value) => formatChartValue(Number(value), chart.valueColumn)} />
          <Bar dataKey="value" fill="var(--chart-primary)" radius={[4, 4, 0, 0]} />
        </BarChart>
      )}
    </ResponsiveContainer>
  </div>;
}

function summarizeRuns(runs: BQLRun[]) {
  if (runs.length === 0) return "";
  const completed = runs.filter((run) => run.result).length;
  const failed = runs.filter((run) => run.error).length;
  const rows = runs.reduce((total, run) => total + (run.result?.rowCount ?? 0), 0);
  return `${runs.length} 条查询 · ${completed} 完成 · ${failed} 失败 · ${rows} 行`;
}

function buildChartModel(result: BQLResult): ChartModel | null {
  const valueIndex = result.columns.findIndex(isNumericColumn);
  if (valueIndex < 0) return null;
  const labelIndex = result.columns.findIndex((column, index) => index !== valueIndex && !isNumericColumn(column));
  if (labelIndex < 0) return null;
  const valueColumn = result.columns[valueIndex];
  const labelColumn = result.columns[labelIndex];
  const data = result.rows.map((row, index) => {
    const rawLabel = row[labelIndex];
    const rawValue = row[valueIndex];
    return {
      label: rawLabel == null || rawLabel === "" ? `行 ${index + 1}` : String(rawLabel),
      value: typeof rawValue === "number" ? rawValue : Number(rawValue),
    };
  }).filter((item) => Number.isFinite(item.value));
  if (data.length === 0) return null;
  return {
    labelColumn,
    valueColumn,
    data,
    canLine: isTimeColumn(labelColumn),
  };
}

function supportsChart(chart: ChartModel | null, kind: ChartKind) {
  if (kind === "table") return true;
  if (!chart) return false;
  if (kind === "line") return chart.canLine;
  if (kind === "pie") return chart.data.some((item) => item.value > 0);
  return chart.data.length > 0;
}

function isNumericColumn(column: BQLColumn) {
  return column.type === "money" || column.type === "number";
}

function isTimeColumn(column: BQLColumn) {
  const name = column.name.toLowerCase();
  return column.type === "date" || name === "date" || name === "month" || name.endsWith("_date") || name.endsWith("_month");
}

function formatCell(value: unknown, column: BQLColumn) {
  if (value == null) return "";
  if (column.type === "money" && typeof value === "number") return formatMoney(value, "");
  if (column.type === "number" && typeof value === "number") return new Intl.NumberFormat("zh-CN").format(value);
  return String(value);
}

function formatChartValue(value: number, column: BQLColumn) {
  if (column.type === "money") return formatMoney(value, "");
  return new Intl.NumberFormat("zh-CN", { maximumFractionDigits: 2 }).format(value);
}

function shortChartValue(value: number, column: BQLColumn) {
  const displayValue = column.type === "money" ? value / 100 : value;
  return new Intl.NumberFormat("zh-CN", { notation: "compact", maximumFractionDigits: 1 }).format(displayValue);
}

function formatMoney(cents: number, currency: string) {
  const value = cents / 100;
  const formatted = new Intl.NumberFormat("zh-CN", { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(value);
  return currency ? `${formatted} ${currency}` : formatted;
}

function currentStatement(raw: string, selection: EditorSelection) {
  const from = Math.min(selection.from, selection.to);
  const to = Math.max(selection.from, selection.to);
  if (to > from) return { text: raw.slice(from, to).trim(), start: from, end: to };
  const statements = splitBQLStatements(raw);
  const exact = statements.find((statement) => from >= statement.start && from <= statement.end);
  if (exact) return exact;
  return [...statements].reverse().find((statement) => statement.end <= from) ?? statements[0];
}

function splitBQLStatements(raw: string) {
  const statements: BQLStatement[] = [];
  let start = 0;
  let quote = "";
  let escaped = false;
  for (let index = 0; index < raw.length; index++) {
    const char = raw[index];
    if (quote) {
      if (escaped) {
        escaped = false;
        continue;
      }
      if (char === "\\") {
        escaped = true;
        continue;
      }
      if (char === quote) quote = "";
      continue;
    }
    if (char === "'" || char === "\"") {
      quote = char;
      continue;
    }
    if (char === ";") {
      pushStatement(statements, raw, start, index);
      start = index + 1;
    }
  }
  pushStatement(statements, raw, start, raw.length);
  return statements;
}

function pushStatement(statements: BQLStatement[], raw: string, start: number, end: number) {
  const text = raw.slice(start, end).trim();
  if (!text) return;
  const leading = raw.slice(start, end).search(/\S/);
  const trailing = raw.slice(start, end).match(/\s*$/)?.[0].length ?? 0;
  statements.push({ text, start: start + Math.max(leading, 0), end: end - trailing });
}

function sortHistory(records: BQLHistoryRecord[]) {
  return [...records].sort((left, right) => new Date(right.lastRunAt).getTime() - new Date(left.lastRunAt).getTime());
}

function formatHistoryTime(value: string) {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return "刚刚运行";
  return new Intl.DateTimeFormat("zh-CN", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" }).format(date);
}
