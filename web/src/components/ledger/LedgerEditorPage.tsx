import { ChevronDown, ChevronRight, FileCode2, FolderOpen, RotateCcw, Save, Search } from "lucide-react";
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
type EditorMode = "edit" | "diff";
type TreeNode = {
  name: string;
  path: string;
  type: "directory" | "file";
  file?: LedgerEditorFile;
  children: TreeNode[];
};
type DiffLine = {
  kind: "same" | "added" | "removed";
  oldLine?: number;
  newLine?: number;
  text: string;
};

export function LedgerEditorPage({ online, onSaved, showToast }: { online: boolean; onSaved: () => void; showToast: ToastFn }) {
  const [files, setFiles] = useState<LedgerEditorFile[]>([]);
  const [fileQuery, setFileQuery] = useState("");
  const [expandedDirs, setExpandedDirs] = useState<Set<string>>(() => new Set([""]));
  const [mode, setMode] = useState<EditorMode>("edit");
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
  const visibleFiles = useMemo(() => {
    const query = fileQuery.trim().toLowerCase();
    if (!query) return files;
    return files.filter((file) => file.path.toLowerCase().includes(query));
  }, [fileQuery, files]);
  const tree = useMemo(() => buildFileTree(visibleFiles), [visibleFiles]);
  const diffLines = useMemo(() => buildLineDiff(originalContent, content), [content, originalContent]);
  const changeStats = useMemo(() => diffLines.reduce((acc, line) => {
    if (line.kind === "added") acc.added += 1;
    if (line.kind === "removed") acc.removed += 1;
    return acc;
  }, { added: 0, removed: 0 }), [diffLines]);
  const stats = useMemo(() => {
    const lines = content === "" ? 1 : content.split("\n").length;
    return { lines, chars: content.length };
  }, [content]);

  useEffect(() => {
    dirtyRef.current = dirty;
  }, [dirty]);

  useEffect(() => {
    if (!selectedPath) return;
    setExpandedDirs((current) => {
      const next = new Set(current);
      next.add("");
      for (const dir of parentDirs(selectedPath)) next.add(dir);
      return next;
    });
  }, [selectedPath]);

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

  function toggleDir(path: string) {
    setExpandedDirs((current) => {
      const next = new Set(current);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return next;
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
            {loadingFiles ? <div className="rounded-xl border border-line bg-panel p-4 text-sm text-stone">正在读取文件列表…</div> : tree.children.length ? tree.children.map((node) => (
              <FileTreeNode key={node.path || node.name} node={node} depth={0} selectedPath={selectedPath} queryActive={fileQuery.trim() !== ""} expandedDirs={expandedDirs} onToggleDir={toggleDir} onOpenFile={loadFile} />
            )) : <div className="rounded-xl border border-line bg-panel p-4 text-sm text-stone">没有匹配的可编辑账本文件。</div>}
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
              <div className="grid h-9 grid-cols-2 overflow-hidden rounded-xl border border-line bg-panel">
                <button type="button" className={`px-3 text-sm ${mode === "edit" ? "bg-brand text-paper" : "text-warm hover:bg-tag"}`} onClick={() => setMode("edit")}>编辑</button>
                <button type="button" className={`px-3 text-sm ${mode === "diff" ? "bg-brand text-paper" : "text-warm hover:bg-tag"}`} onClick={() => setMode("diff")}>Diff</button>
              </div>
              <Button variant="outline" className="rounded-xl bg-panel text-stone" disabled={!dirty || loadingFile || saving} onClick={() => { setContent(originalContent); showToast("info", "已恢复为上次读取的内容。"); }}>
                <RotateCcw className="h-4 w-4" /> 还原
              </Button>
              <Button className="rounded-xl" disabled={!dirty || loadingFile || saving || !selectedPath} onClick={() => void saveFile()}>
                <Save className="h-4 w-4" /> {saving ? "保存中…" : "保存"}
              </Button>
            </div>
          </div>

          {error && <div className="border-b border-line bg-[var(--danger)]/10 px-4 py-2 text-sm text-[var(--danger)]">{error}</div>}
          {mode === "edit" ? (
            <div className="ledger-code-surface relative min-h-[520px] flex-1 lg:min-h-0">
              {loadingFile && <div className="ledger-code-loading absolute inset-0 z-20 grid place-items-center text-sm backdrop-blur-sm">正在读取文件…</div>}
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
          ) : (
            <DiffView lines={diffLines} added={changeStats.added} removed={changeStats.removed} />
          )}
        </div>
      </div>
    </section>
  );
}

function FileTreeNode({ node, depth, selectedPath, queryActive, expandedDirs, onToggleDir, onOpenFile }: { node: TreeNode; depth: number; selectedPath: string; queryActive: boolean; expandedDirs: Set<string>; onToggleDir: (path: string) => void; onOpenFile: (path: string) => Promise<void> }) {
  const expanded = queryActive || expandedDirs.has(node.path);
  const paddingLeft = `${0.5 + depth * 0.875}rem`;
  if (node.type === "directory") {
    return (
      <div>
        <button type="button" className="mb-1 flex h-8 w-full min-w-0 items-center gap-1 rounded-lg px-2 text-left text-sm font-medium text-olive hover:bg-panel hover:text-ink" style={{ paddingLeft }} onClick={() => onToggleDir(node.path)} aria-expanded={expanded}>
          {expanded ? <ChevronDown className="h-3.5 w-3.5 shrink-0 text-stone" /> : <ChevronRight className="h-3.5 w-3.5 shrink-0 text-stone" />}
          <FolderOpen className="h-4 w-4 shrink-0 text-brand" />
          <span className="truncate">{node.name}</span>
        </button>
        {expanded && node.children.map((child) => <FileTreeNode key={child.path} node={child} depth={depth + 1} selectedPath={selectedPath} queryActive={queryActive} expandedDirs={expandedDirs} onToggleDir={onToggleDir} onOpenFile={onOpenFile} />)}
      </div>
    );
  }
  const active = node.path === selectedPath;
  return (
    <button type="button" className={`mb-1 flex h-8 w-full min-w-0 items-center gap-2 rounded-lg border px-2 text-left text-sm ${active ? "border-brand bg-[var(--selected-bg)] text-ink" : "border-transparent text-olive hover:border-line hover:bg-panel hover:text-ink"}`} style={{ paddingLeft }} onClick={() => void onOpenFile(node.path)} title={node.path}>
      <span className="w-3.5 shrink-0" />
      <FileCode2 className="h-4 w-4 shrink-0 text-brand" />
      <span className="truncate">{node.name}</span>
    </button>
  );
}

function DiffView({ lines, added, removed }: { lines: DiffLine[]; added: number; removed: number }) {
  const hasChanges = added > 0 || removed > 0;
  return (
    <div className="ledger-code-surface flex min-h-[520px] flex-1 flex-col lg:min-h-0">
      <div className="ledger-diff-toolbar flex shrink-0 items-center justify-between px-4 py-2 font-mono text-xs">
        <span>{hasChanges ? `+${added} / -${removed}` : "没有未保存改动"}</span>
        <span>working copy diff</span>
      </div>
      <div className="ledger-diff-view flex-1 overflow-auto py-3">
        {hasChanges ? lines.map((line, index) => <DiffLineRow key={`${index}-${line.kind}`} line={line} />) : <div className="ledger-diff-empty grid min-h-80 place-items-center text-sm">编辑文件后，这里会显示相对加载版本的 Diff。</div>}
      </div>
    </div>
  );
}

function DiffLineRow({ line }: { line: DiffLine }) {
  const marker = line.kind === "added" ? "+" : line.kind === "removed" ? "-" : " ";
  return (
    <div className={`ledger-diff-line ledger-diff-line-${line.kind}`}>
      <span className="ledger-diff-gutter">{line.oldLine ?? ""}</span>
      <span className="ledger-diff-gutter">{line.newLine ?? ""}</span>
      <span className="ledger-diff-marker">{marker}</span>
      <span className="ledger-diff-code">{line.text || " "}</span>
    </div>
  );
}

function buildFileTree(files: LedgerEditorFile[]): TreeNode {
  const root: TreeNode = { name: "ledger", path: "", type: "directory", children: [] };
  const dirs = new Map<string, TreeNode>([["", root]]);
  for (const file of files) {
    const parts = file.path.split("/");
    let current = root;
    let currentPath = "";
    for (let index = 0; index < parts.length; index += 1) {
      const part = parts[index];
      const nextPath = currentPath ? `${currentPath}/${part}` : part;
      if (index === parts.length - 1) {
        current.children.push({ name: part, path: file.path, type: "file", file, children: [] });
        continue;
      }
      let dir = dirs.get(nextPath);
      if (!dir) {
        dir = { name: part, path: nextPath, type: "directory", children: [] };
        dirs.set(nextPath, dir);
        current.children.push(dir);
      }
      current = dir;
      currentPath = nextPath;
    }
  }
  sortTree(root);
  return root;
}

function sortTree(node: TreeNode) {
  node.children.sort((a, b) => {
    if (a.type !== b.type) return a.type === "directory" ? -1 : 1;
    return a.name.localeCompare(b.name, undefined, { numeric: true });
  });
  for (const child of node.children) sortTree(child);
}

function parentDirs(path: string) {
  const parts = path.split("/").slice(0, -1);
  const dirs: string[] = [];
  for (let index = 0; index < parts.length; index += 1) {
    dirs.push(parts.slice(0, index + 1).join("/"));
  }
  return dirs;
}

function buildLineDiff(before: string, after: string): DiffLine[] {
  if (before === after) return [];
  const beforeLines = before.split("\n");
  const afterLines = after.split("\n");
  let prefix = 0;
  while (prefix < beforeLines.length && prefix < afterLines.length && beforeLines[prefix] === afterLines[prefix]) {
    prefix += 1;
  }
  let suffix = 0;
  while (
    suffix < beforeLines.length - prefix &&
    suffix < afterLines.length - prefix &&
    beforeLines[beforeLines.length - 1 - suffix] === afterLines[afterLines.length - 1 - suffix]
  ) {
    suffix += 1;
  }
  const rows: DiffLine[] = [];
  const contextBefore = Math.max(0, prefix - 4);
  for (let index = contextBefore; index < prefix; index += 1) {
    rows.push({ kind: "same", oldLine: index + 1, newLine: index + 1, text: beforeLines[index] });
  }
  for (let index = prefix; index < beforeLines.length - suffix; index += 1) {
    rows.push({ kind: "removed", oldLine: index + 1, text: beforeLines[index] });
  }
  for (let index = prefix; index < afterLines.length - suffix; index += 1) {
    rows.push({ kind: "added", newLine: index + 1, text: afterLines[index] });
  }
  const suffixStartBefore = beforeLines.length - suffix;
  const suffixStartAfter = afterLines.length - suffix;
  for (let offset = 0; offset < Math.min(suffix, 4); offset += 1) {
    rows.push({ kind: "same", oldLine: suffixStartBefore + offset + 1, newLine: suffixStartAfter + offset + 1, text: beforeLines[suffixStartBefore + offset] });
  }
  return rows;
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
