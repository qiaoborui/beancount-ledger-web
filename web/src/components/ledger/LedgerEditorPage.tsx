import { FileCode2, FolderOpen, RotateCcw, Save, Search } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import { Button } from "@/components/ui/button";

type LedgerEditorFile = {
  path: string;
  name: string;
  dir: string;
  size: number;
  modTime: string;
};

type LedgerEditorFileResponse = {
  path: string;
  content: string;
  hash: string;
  modTime: string;
  size: number;
};

type ToastFn = (kind: "info" | "success" | "error", text: string) => void;

export function LedgerEditorPage({ online, onSaved, showToast }: { online: boolean; onSaved: () => void; showToast: ToastFn }) {
  const [files, setFiles] = useState<LedgerEditorFile[]>([]);
  const [fileQuery, setFileQuery] = useState("");
  const [selectedPath, setSelectedPath] = useState("");
  const [content, setContent] = useState("");
  const [originalContent, setOriginalContent] = useState("");
  const [hash, setHash] = useState("");
  const [modTime, setModTime] = useState("");
  const [loadingFiles, setLoadingFiles] = useState(true);
  const [loadingFile, setLoadingFile] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const highlightRef = useRef<HTMLPreElement | null>(null);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  const dirtyRef = useRef(false);

  const dirty = content !== originalContent;
  const selectedFile = files.find((file) => file.path === selectedPath);
  const filteredFiles = useMemo(() => {
    const query = fileQuery.trim().toLowerCase();
    if (!query) return files;
    return files.filter((file) => file.path.toLowerCase().includes(query));
  }, [fileQuery, files]);
  const stats = useMemo(() => {
    const lines = content === "" ? 1 : content.split("\n").length;
    return { lines, chars: content.length };
  }, [content]);

  useEffect(() => {
    dirtyRef.current = dirty;
  }, [dirty]);

  const loadFile = useCallback(async (path: string, options: { force?: boolean } = {}) => {
    if (!path) return;
    if (!options.force && dirtyRef.current && !window.confirm("当前文件尚未保存，确定切换到其他文件？")) return;
    setLoadingFile(true);
    setError("");
    try {
      const data = await fetchJSON<LedgerEditorFileResponse>(`/api/ledger/editor/file?path=${encodeURIComponent(path)}`);
      setSelectedPath(data.path);
      setContent(data.content);
      setOriginalContent(data.content);
      setHash(data.hash);
      setModTime(data.modTime);
      window.setTimeout(() => textareaRef.current?.focus(), 40);
    } catch (err) {
      const message = err instanceof Error ? err.message : "读取文件失败";
      setError(message);
      showToast("error", message);
    } finally {
      setLoadingFile(false);
    }
  }, [showToast]);

  const loadFiles = useCallback(async () => {
    setLoadingFiles(true);
    setError("");
    try {
      const data = await fetchJSON<{ files: LedgerEditorFile[] }>("/api/ledger/editor/files");
      setFiles(data.files);
      const firstPath = data.files.find((file) => file.path === selectedPath)?.path ?? data.files.find((file) => file.path === "main.bean")?.path ?? data.files[0]?.path ?? "";
      if (firstPath && (!selectedPath || !data.files.some((file) => file.path === selectedPath))) {
        await loadFile(firstPath, { force: true });
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : "读取文件列表失败";
      setError(message);
      showToast("error", message);
    } finally {
      setLoadingFiles(false);
    }
  }, [loadFile, selectedPath, showToast]);

  const saveFile = useCallback(async () => {
    if (!selectedPath || saving) return;
    if (!online) {
      showToast("error", "当前离线，无法保存账本文件。");
      return;
    }
    setSaving(true);
    setError("");
    try {
      const data = await fetchJSON<{ ok: boolean; hash: string; modTime: string; size: number }>("/api/ledger/editor/file", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ path: selectedPath, content, previousHash: hash }),
      });
      setHash(data.hash);
      setModTime(data.modTime);
      setOriginalContent(content);
      showToast("success", "账本文件已保存，并通过 bean-check。");
      onSaved();
      void loadFiles();
    } catch (err) {
      const message = err instanceof Error ? err.message : "保存失败";
      setError(message);
      showToast("error", message);
    } finally {
      setSaving(false);
    }
  }, [content, hash, loadFiles, onSaved, online, saving, selectedPath, showToast]);

  useEffect(() => {
    void loadFiles();
  }, [loadFiles]);

  useEffect(() => {
    const handleBeforeUnload = (event: BeforeUnloadEvent) => {
      if (!dirty) return;
      event.preventDefault();
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", handleBeforeUnload);
    return () => window.removeEventListener("beforeunload", handleBeforeUnload);
  }, [dirty]);

  useEffect(() => {
    const handleKeyDown = (event: globalThis.KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
        event.preventDefault();
        void saveFile();
      }
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [saveFile]);

  function handleEditorScroll() {
    const textarea = textareaRef.current;
    const highlight = highlightRef.current;
    if (!textarea || !highlight) return;
    highlight.scrollTop = textarea.scrollTop;
    highlight.scrollLeft = textarea.scrollLeft;
  }

  function handleEditorKeyDown(event: KeyboardEvent<HTMLTextAreaElement>) {
    if (event.key !== "Tab") return;
    event.preventDefault();
    const textarea = event.currentTarget;
    const start = textarea.selectionStart;
    const end = textarea.selectionEnd;
    const next = content.slice(0, start) + "  " + content.slice(end);
    setContent(next);
    window.requestAnimationFrame(() => {
      textarea.selectionStart = start + 2;
      textarea.selectionEnd = start + 2;
    });
  }

  return (
    <section className="ledger-editor-shell min-w-0 overflow-hidden rounded-2xl border border-line bg-panel shadow-sm">
      <div className="grid min-h-[calc(100dvh-13rem)] min-w-0 lg:grid-cols-[310px_minmax(0,1fr)]">
        <aside className="min-w-0 border-b border-line bg-paper/70 lg:border-b-0 lg:border-r">
          <div className="border-b border-line p-4">
            <div className="flex items-center gap-2 text-xs uppercase tracking-[0.2em] text-stone"><FolderOpen className="h-3.5 w-3.5" /> ledger files</div>
            <label className="mt-3 flex h-10 items-center gap-2 rounded-xl border border-line bg-panel px-3 text-sm text-stone">
              <Search className="h-4 w-4 shrink-0 text-brand" />
              <input className="min-w-0 flex-1 border-0 bg-transparent p-0 text-sm text-ink shadow-none focus:shadow-none" placeholder="搜索文件" value={fileQuery} onChange={(event) => setFileQuery(event.target.value)} />
            </label>
          </div>
          <div className="max-h-[42dvh] overflow-auto p-2 lg:max-h-[calc(100dvh-18rem)]">
            {loadingFiles ? <div className="rounded-xl border border-line bg-panel p-4 text-sm text-stone">正在读取文件列表…</div> : filteredFiles.length ? filteredFiles.map((file) => {
              const active = file.path === selectedPath;
              return (
                <button key={file.path} type="button" className={`mb-1 flex w-full min-w-0 items-start gap-2 rounded-xl border px-3 py-2 text-left ${active ? "border-brand bg-[var(--selected-bg)] text-ink" : "border-transparent text-olive hover:border-line hover:bg-panel"}`} onClick={() => void loadFile(file.path)} title={file.path}>
                  <FileCode2 className="mt-0.5 h-4 w-4 shrink-0 text-brand" />
                  <span className="min-w-0 flex-1">
                    <span className="block truncate text-sm font-medium">{file.name}</span>
                    <span className="mt-0.5 block truncate font-mono text-[11px] text-stone">{file.dir === "." ? "/" : file.dir}</span>
                  </span>
                </button>
              );
            }) : <div className="rounded-xl border border-line bg-panel p-4 text-sm text-stone">没有匹配的可编辑账本文件。</div>}
          </div>
        </aside>

        <div className="flex min-w-0 flex-col bg-panel">
          <div className="flex min-w-0 flex-col gap-3 border-b border-line bg-paper px-4 py-3 md:flex-row md:items-center md:justify-between">
            <div className="min-w-0">
              <div className="truncate font-mono text-sm font-semibold text-ink">{selectedPath || "未选择文件"}{dirty && <span className="ml-2 text-brand">●</span>}</div>
              <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-stone">
                <span>{stats.lines} 行</span>
                <span>{stats.chars} 字符</span>
                {selectedFile && <span>{formatBytes(selectedFile.size)}</span>}
                {modTime && <span>{new Date(modTime).toLocaleString()}</span>}
              </div>
            </div>
            <div className="flex shrink-0 items-center gap-2">
              <Button variant="outline" className="rounded-xl bg-panel text-stone" disabled={!dirty || loadingFile || saving} onClick={() => { setContent(originalContent); showToast("info", "已恢复为上次读取的内容。"); }}>
                <RotateCcw className="h-4 w-4" /> 还原
              </Button>
              <Button className="rounded-xl" disabled={!dirty || loadingFile || saving || !selectedPath} onClick={() => void saveFile()}>
                <Save className="h-4 w-4" /> {saving ? "保存中…" : "保存"}
              </Button>
            </div>
          </div>

          {error && <div className="border-b border-line bg-[var(--danger)]/10 px-4 py-2 text-sm text-[var(--danger)]">{error}</div>}
          <div className="relative min-h-[520px] flex-1 bg-[rgb(var(--color-ink))] text-[rgb(var(--color-paper))] lg:min-h-0">
            {loadingFile && <div className="absolute inset-0 z-20 grid place-items-center bg-ink/45 text-sm text-paper backdrop-blur-sm">正在读取文件…</div>}
            <pre ref={highlightRef} aria-hidden="true" className="ledger-editor-highlight absolute inset-0 overflow-auto p-0">
              <code className="block min-w-max py-4 pr-6">{renderHighlightedLines(content)}</code>
            </pre>
            <textarea
              ref={textareaRef}
              className="ledger-editor-input absolute inset-0 resize-none overflow-auto border-0 bg-transparent py-4 pr-6 outline-none"
              value={content}
              spellCheck={false}
              wrap="off"
              onChange={(event) => setContent(event.target.value)}
              onScroll={handleEditorScroll}
              onKeyDown={handleEditorKeyDown}
              aria-label="Beancount 文件编辑器"
            />
          </div>
        </div>
      </div>
    </section>
  );
}

async function fetchJSON<T>(input: RequestInfo | URL, init?: RequestInit): Promise<T> {
  const response = await fetch(input, init);
  const text = await response.text();
  const data = text ? JSON.parse(text) as T & { error?: string } : null;
  if (!response.ok) {
    throw new Error(data?.error ?? "请求失败");
  }
  return data as T;
}

function renderHighlightedLines(content: string) {
  const lines = content.split("\n");
  if (lines.length === 0) lines.push("");
  return lines.map((line, index) => (
    <span key={index} className="ledger-editor-line">
      <span className="ledger-editor-line-number">{index + 1}</span>
      <span className="ledger-editor-code">{highlightBeanLine(line)}</span>
    </span>
  ));
}

function highlightBeanLine(line: string) {
  if (line.trimStart().startsWith(";")) {
    return <span className="ledger-token-comment">{line || " "}</span>;
  }
  const tokenRe = /("(?:[^"\\]|\\.)*"|#[A-Za-z0-9_-]+|\b\d{4}-\d{2}-\d{2}\b|\b(?:option|include|open|close|balance|commodity|price|custom|event|note|document|pad|txn)\b|[A-Z][A-Za-z0-9-]*(?::[A-Za-z0-9-]+)+|-?\d+(?:\.\d+)?|[A-Z][A-Z0-9._-]{1,})/g;
  const parts: ReactNode[] = [];
  let cursor = 0;
  let match: RegExpExecArray | null;
  while ((match = tokenRe.exec(line)) !== null) {
    if (match.index > cursor) {
      parts.push(<span key={`plain-${cursor}`}>{line.slice(cursor, match.index)}</span>);
    }
    const token = match[0];
    parts.push(<span key={`${match.index}-${token}`} className={beanTokenClass(token)}>{token}</span>);
    cursor = match.index + token.length;
  }
  if (cursor < line.length) {
    parts.push(<span key={`plain-${cursor}`}>{line.slice(cursor)}</span>);
  }
  return parts.length ? parts : " ";
}

function beanTokenClass(token: string) {
  if (token.startsWith("\"")) return "ledger-token-string";
  if (token.startsWith("#")) return "ledger-token-tag";
  if (/^\d{4}-\d{2}-\d{2}$/.test(token)) return "ledger-token-date";
  if (/^-?\d/.test(token)) return "ledger-token-number";
  if (/^(option|include|open|close|balance|commodity|price|custom|event|note|document|pad|txn)$/.test(token)) return "ledger-token-directive";
  if (token.startsWith("Expenses:") || token.startsWith("Liabilities:")) return "ledger-token-expense";
  if (token.startsWith("Income:") || token.startsWith("Assets:")) return "ledger-token-income";
  if (token.includes(":")) return "ledger-token-account";
  return "ledger-token-currency";
}

function formatBytes(size: number) {
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`;
  return `${(size / 1024 / 1024).toFixed(1)} MB`;
}
