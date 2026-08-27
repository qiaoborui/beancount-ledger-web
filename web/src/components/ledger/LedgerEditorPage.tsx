import { indentWithTab } from "@codemirror/commands";
import { HighlightStyle, StreamLanguage, indentUnit, syntaxHighlighting, type StreamParser, type StringStream } from "@codemirror/language";
import { Text, type EditorState } from "@codemirror/state";
import { EditorView, keymap, type ViewUpdate } from "@codemirror/view";
import { tags } from "@lezer/highlight";
import CodeMirror, { type ReactCodeMirrorRef } from "@uiw/react-codemirror";
import { ChevronDown, ChevronRight, FileCode2, FolderOpen, RotateCcw, Save, Search } from "lucide-react";
import { memo, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import i18n from "@/i18n";
import { Button } from "@/components/ui/button";
import { apiFetch } from "@/lib/apiEndpoints";

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

type EditorStats = {
  lines: number;
  chars: number;
};

type BeanStreamState = Record<string, never>;

const beancountStreamParser: StreamParser<BeanStreamState> = {
  startState: () => ({}),
  token(stream: StringStream) {
    if (stream.eatSpace()) return null;
    if (stream.peek() === ";") {
      stream.skipToEnd();
      return "comment";
    }
    if (stream.peek() === '"') {
      stream.next();
      let escaped = false;
      while (!stream.eol()) {
        const character = stream.next();
        if (character === '"' && !escaped) break;
        escaped = character === "\\" && !escaped;
        if (character !== "\\") escaped = false;
      }
      return "string";
    }
    if (stream.match(/^\d{4}-\d{2}-\d{2}\b/)) return "meta";
    if (stream.match(/^[#^][A-Za-z0-9_-]+/)) return "tagName";
    if (stream.match(/^(?:option|include|plugin|pushtag|poptag|pushmeta|popmeta|open|close|commodity|pad|balance|event|query|price|note|document|custom|txn)\b/)) return "keyword";
    if (stream.match(/^[A-Z][A-Za-z0-9-]*(?::[A-Za-z0-9-]+)+/)) return "variableName";
    if (stream.match(/^-?(?:\d+(?:\.\d+)?|\.\d+)\b/)) return "number";
    if (stream.match(/^[A-Z][A-Z0-9._-]{1,}\b/)) return "typeName";
    stream.next();
    return null;
  },
};

const beancountLanguage = StreamLanguage.define(beancountStreamParser);
const beancountHighlightStyle = HighlightStyle.define([
  { tag: tags.comment, color: "var(--ledger-code-muted)" },
  { tag: tags.meta, color: "var(--ledger-token-date)" },
  { tag: tags.keyword, color: "var(--ledger-token-directive)", fontWeight: "600" },
  { tag: tags.string, color: "var(--ledger-token-string)" },
  { tag: tags.tagName, color: "var(--ledger-token-tag)" },
  { tag: tags.variableName, color: "var(--ledger-token-account)" },
  { tag: tags.number, color: "var(--ledger-token-number)" },
  { tag: tags.typeName, color: "var(--ledger-token-currency)" },
]);

const ledgerEditorTheme = EditorView.theme({
  "&": {
    height: "100%",
    background: "var(--ledger-code-bg)",
    color: "var(--ledger-code-fg)",
    fontSize: "0.875rem",
  },
  ".cm-scroller": {
    overflow: "auto",
    background: "transparent",
    fontFamily: '"SFMono-Regular", "Cascadia Code", "Roboto Mono", ui-monospace, monospace',
    lineHeight: "1.5rem",
  },
  ".cm-content": {
    minWidth: "max-content",
    padding: "1rem 0",
    caretColor: "var(--ledger-code-fg)",
  },
  ".cm-line": {
    padding: "0 1.5rem 0 1rem",
  },
  ".cm-gutters": {
    background: "var(--ledger-code-gutter-bg)",
    borderRight: "1px solid var(--ledger-code-border)",
    color: "var(--ledger-code-muted)",
  },
  ".cm-activeLine, .cm-activeLineGutter": {
    background: "color-mix(in srgb, var(--ledger-code-selection) 34%, transparent)",
  },
  ".cm-cursor, .cm-dropCursor": {
    borderLeftColor: "var(--ledger-code-fg)",
  },
  ".cm-focused": {
    outline: "none",
  },
  ".cm-selectionBackground, &.cm-focused .cm-selectionBackground": {
    background: "var(--ledger-code-selection)",
  },
  ".cm-panels, .cm-tooltip": {
    background: "var(--ledger-code-bg)",
    borderColor: "var(--ledger-code-border)",
    color: "var(--ledger-code-fg)",
  },
});

const ledgerEditorExtensions = [
  beancountLanguage,
  syntaxHighlighting(beancountHighlightStyle),
  indentUnit.of("  "),
  keymap.of([indentWithTab]),
];

const ledgerEditorBasicSetup = {
  foldGutter: false,
  highlightActiveLine: true,
  highlightActiveLineGutter: true,
} as const;

export function LedgerEditorPage({ online, onSaved, showToast }: { online: boolean; onSaved: () => void; showToast: ToastFn }) {
  const { t } = useTranslation();
  const [files, setFiles] = useState<LedgerEditorFile[]>([]);
  const [fileQuery, setFileQuery] = useState("");
  const [expandedDirs, setExpandedDirs] = useState<Set<string>>(() => new Set([""]));
  const [mode, setMode] = useState<EditorMode>("edit");
  const [selectedPath, setSelectedPath] = useState("");
  const [editorValue, setEditorValue] = useState("");
  const [editorGeneration, setEditorGeneration] = useState(0);
  const [originalContent, setOriginalContent] = useState("");
  const [hash, setHash] = useState("");
  const [modTime, setModTime] = useState("");
  const [loadingFiles, setLoadingFiles] = useState(true);
  const [loadingFile, setLoadingFile] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [stats, setStats] = useState<EditorStats>({ lines: 1, chars: 0 });
  const [dirty, setDirty] = useState(false);
  const editorRef = useRef<ReactCodeMirrorRef>(null);
  const originalDocRef = useRef(Text.of([""]));
  const dirtyRef = useRef(false);
  const editorGenerationRef = useRef(0);
  const loadingFileRef = useRef(false);
  const savingRef = useRef(false);
  const selectedPathRef = useRef("");
  const saveFileRef = useRef<() => void>(() => undefined);

  const selectedFile = useMemo(() => files.find((file) => file.path === selectedPath), [files, selectedPath]);
  const visibleFiles = useMemo(() => {
    const query = fileQuery.trim().toLowerCase();
    if (!query) return files;
    return files.filter((file) => file.path.toLowerCase().includes(query));
  }, [fileQuery, files]);
  const tree = useMemo(() => buildFileTree(visibleFiles), [visibleFiles]);
  const diffLines = useMemo(() => mode === "diff" ? buildLineDiff(originalContent, editorValue) : [], [editorValue, mode, originalContent]);
  const changeStats = useMemo(() => diffLines.reduce((acc, line) => {
    if (line.kind === "added") acc.added += 1;
    if (line.kind === "removed") acc.removed += 1;
    return acc;
  }, { added: 0, removed: 0 }), [diffLines]);

  useEffect(() => {
    selectedPathRef.current = selectedPath;
  }, [selectedPath]);

  useEffect(() => {
    if (!selectedPath) return;
    setExpandedDirs((current) => {
      const next = new Set(current);
      next.add("");
      for (const dir of parentDirs(selectedPath)) next.add(dir);
      return next;
    });
  }, [selectedPath]);

  const updateDirty = useCallback((nextDirty: boolean) => {
    dirtyRef.current = nextDirty;
    setDirty(nextDirty);
  }, []);

  const getEditorContent = useCallback(() => editorRef.current?.view?.state.doc.toString() ?? editorValue, [editorValue]);

  const resetEditor = useCallback((nextValue: string) => {
    editorGenerationRef.current += 1;
    setEditorValue(nextValue);
    setEditorGeneration(editorGenerationRef.current);
  }, []);

  const loadFile = useCallback(async (path: string, options: { force?: boolean } = {}) => {
    if (!path || loadingFileRef.current || savingRef.current) return;
    if (!options.force && dirtyRef.current && !window.confirm(t("editorPage.confirmSwitch"))) return;
    loadingFileRef.current = true;
    setLoadingFile(true);
    setError("");
    try {
      const data = await fetchJSON<LedgerEditorFileResponse>(`/api/ledger/editor/file?path=${encodeURIComponent(path)}`);
      selectedPathRef.current = data.path;
      setSelectedPath(data.path);
      resetEditor(data.content);
      setOriginalContent(data.content);
      originalDocRef.current = Text.of(data.content.split("\n"));
      updateDirty(false);
      setStats(countEditorStats(data.content));
      setHash(data.hash);
      setModTime(data.modTime);
      if (shouldAutoFocusEditor()) {
        window.setTimeout(() => editorRef.current?.view?.focus(), 40);
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : t("editorPage.readFailed");
      setError(message);
      showToast("error", message);
    } finally {
      loadingFileRef.current = false;
      setLoadingFile(false);
    }
  }, [resetEditor, showToast, t, updateDirty]);

  const loadFiles = useCallback(async () => {
    setLoadingFiles(true);
    setError("");
    try {
      const data = await fetchJSON<{ files: LedgerEditorFile[] }>("/api/ledger/editor/files");
      setFiles(data.files);
      const currentPath = selectedPathRef.current;
      const firstPath = data.files.find((file) => file.path === currentPath)?.path ?? data.files.find((file) => file.path === "main.bean")?.path ?? data.files[0]?.path ?? "";
      if (firstPath && (!currentPath || !data.files.some((file) => file.path === currentPath))) {
        await loadFile(firstPath, { force: true });
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : t("editorPage.listFailed");
      setError(message);
      showToast("error", message);
    } finally {
      setLoadingFiles(false);
    }
  }, [loadFile, showToast, t]);

  const saveFile = useCallback(async () => {
    if (!selectedPath || loadingFileRef.current || savingRef.current) return;
    if (!online) {
      showToast("error", t("editorPage.offlineCannotSave"));
      return;
    }
    const savePath = selectedPath;
    const saveGeneration = editorGenerationRef.current;
    const savedDoc = editorRef.current?.view?.state.doc;
    const nextContent = getEditorContent();
    savingRef.current = true;
    setSaving(true);
    setError("");
    try {
      const data = await fetchJSON<{ ok: boolean; hash: string; modTime: string; size: number }>("/api/ledger/editor/file", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ path: savePath, content: nextContent, previousHash: hash }),
      });
      if (selectedPathRef.current === savePath && editorGenerationRef.current === saveGeneration) {
        const savedBaseline = savedDoc ?? Text.of(nextContent.split("\n"));
        setHash(data.hash);
        setModTime(data.modTime);
        setOriginalContent(nextContent);
        originalDocRef.current = savedBaseline;
        const currentDoc = editorRef.current?.view?.state.doc;
        updateDirty(currentDoc ? !currentDoc.eq(savedBaseline) : false);
      }
      showToast("success", t("editorPage.saved"));
      onSaved();
      void loadFiles();
    } catch (err) {
      const message = err instanceof Error ? err.message : t("editorPage.saveFailed");
      setError(message);
      showToast("error", message);
    } finally {
      savingRef.current = false;
      setSaving(false);
    }
  }, [getEditorContent, hash, loadFiles, onSaved, online, selectedPath, showToast, t, updateDirty]);

  useEffect(() => {
    saveFileRef.current = () => {
      void saveFile();
    };
  }, [saveFile]);

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
        saveFileRef.current();
      }
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, []);

  const handleEditorUpdate = useCallback((update: ViewUpdate) => {
    if (!update.docChanged) return;
    updateDirty(!update.state.doc.eq(originalDocRef.current));
    setStats({ lines: update.state.doc.lines, chars: update.state.doc.length });
  }, [updateDirty]);

  const handleCreateEditor = useCallback((_view: EditorView, state: EditorState) => {
    if (!dirtyRef.current) originalDocRef.current = state.doc;
  }, []);

  const switchMode = useCallback((nextMode: EditorMode) => {
    if (nextMode === "diff") setEditorValue(getEditorContent());
    setMode(nextMode);
  }, [getEditorContent]);

  const revertFile = useCallback(() => {
    resetEditor(originalContent);
    setStats(countEditorStats(originalContent));
    updateDirty(false);
    showToast("info", t("editorPage.reverted"));
  }, [originalContent, resetEditor, showToast, t, updateDirty]);

  const toggleDir = useCallback((path: string) => {
    setExpandedDirs((current) => {
      const next = new Set(current);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return next;
    });
  }, []);

  return (
    <section className="ledger-editor-shell min-w-0 overflow-hidden border-y border-line bg-panel">
      <div className="grid min-h-0 min-w-0 lg:h-full lg:grid-cols-[270px_minmax(0,1fr)]">
        <aside className="flex min-h-0 min-w-0 flex-col border-b border-line bg-paper/70 lg:border-b-0 lg:border-r" aria-label={t("editorPage.ledgerFiles")}>
          <div className="shrink-0 border-b border-line p-3">
            <div className="flex items-center gap-2 text-xs font-semibold text-stone"><FolderOpen className="h-3.5 w-3.5" /> {t("editorPage.ledgerFiles")}</div>
            <label className="mt-2 flex h-11 items-center gap-2 rounded-md border border-line bg-panel px-3 text-sm text-stone focus-within:ring-2 focus-within:ring-brand/30 lg:h-9">
              <Search className="h-4 w-4 shrink-0 text-brand" />
              <input className="min-w-0 flex-1 border-0 bg-transparent p-0 text-sm text-ink shadow-none outline-none focus:shadow-none" aria-label={t("editorPage.searchFiles")} placeholder={t("editorPage.searchFiles")} value={fileQuery} onChange={(event) => setFileQuery(event.target.value)} />
            </label>
          </div>
          <div className="max-h-[36dvh] min-h-0 overflow-auto p-2 lg:max-h-none lg:flex-1" role="tree" aria-busy={loadingFiles}>
            {loadingFiles ? <div className="rounded-md border border-line bg-panel p-4 text-sm text-stone" role="status">{t("editorPage.loadingFiles")}</div> : tree.children.length ? tree.children.map((node) => (
              <FileTreeNode key={node.path || node.name} node={node} depth={0} selectedPath={selectedPath} queryActive={fileQuery.trim() !== ""} expandedDirs={expandedDirs} onToggleDir={toggleDir} onOpenFile={loadFile} />
            )) : <div className="rounded-md border border-line bg-panel p-4 text-sm text-stone">{t("editorPage.noMatch")}</div>}
          </div>
        </aside>

        <div className="flex min-h-[32rem] min-w-0 flex-col bg-panel lg:min-h-0">
          <div className="flex min-w-0 shrink-0 flex-col gap-2 border-b border-line bg-paper px-3 py-2 md:flex-row md:items-center md:justify-between">
            <div className="flex min-w-0 items-center gap-2">
              <FileCode2 className="h-4 w-4 shrink-0 text-brand" aria-hidden="true" />
              <div className="truncate font-mono text-sm font-semibold text-ink">{selectedPath || t("editorPage.noFileSelected")}</div>
              {dirty && <span className="inline-flex shrink-0 items-center gap-1 text-xs font-medium text-brand"><span aria-hidden="true">●</span><span className="sr-only">{t("editorPage.unsavedChanges")}</span></span>}
            </div>
            <div className="flex shrink-0 items-center gap-2">
              <div className="grid h-10 grid-cols-2 overflow-hidden rounded-md border border-line bg-panel lg:h-8" role="group" aria-label={t("editorPage.viewMode")}>
                <button type="button" aria-pressed={mode === "edit"} className={`px-3 text-sm ${mode === "edit" ? "bg-brand text-paper" : "text-warm hover:bg-tag"}`} onClick={() => switchMode("edit")}>{t("editorPage.edit")}</button>
                <button type="button" aria-pressed={mode === "diff"} className={`px-3 text-sm ${mode === "diff" ? "bg-brand text-paper" : "text-warm hover:bg-tag"}`} onClick={() => switchMode("diff")}>{t("editorPage.diff")}</button>
              </div>
              <Button variant="outline" size="sm" className="h-10 rounded-md bg-panel text-stone lg:h-8" disabled={!dirty || loadingFile || saving} onClick={revertFile}>
                <RotateCcw className="h-4 w-4" /> {t("editorPage.revert")}
              </Button>
              <Button size="sm" className="h-10 rounded-md lg:h-8" disabled={!dirty || loadingFile || saving || !selectedPath || !online} onClick={() => void saveFile()}>
                <Save className="h-4 w-4" /> {saving ? t("editorPage.saving") : t("editorPage.save")}
              </Button>
            </div>
          </div>

          {error && <div className="shrink-0 border-b border-line bg-[var(--danger)]/10 px-4 py-2 text-sm text-[var(--danger)]" role="alert">{error}</div>}
          <div className={mode === "edit" ? "ledger-code-editor ledger-code-surface relative min-h-0 flex-1 overflow-hidden focus-within:ring-2 focus-within:ring-inset focus-within:ring-brand/30" : "hidden"} aria-busy={loadingFile}>
            {loadingFile && <div className="ledger-code-loading absolute inset-0 z-20 grid place-items-center text-sm" role="status" aria-live="polite">{t("editorPage.loadingFile")}</div>}
            <CodeMirror
              key={`${selectedPath}:${editorGeneration}`}
              ref={editorRef}
              basicSetup={ledgerEditorBasicSetup}
              className="h-full"
              editable={mode === "edit" && !loadingFile && Boolean(selectedPath)}
              extensions={ledgerEditorExtensions}
              height="100%"
              theme={ledgerEditorTheme}
              value={editorValue}
              onCreateEditor={handleCreateEditor}
              onUpdate={handleEditorUpdate}
              aria-label={t("editorPage.editorLabel")}
            />
          </div>
          {mode === "diff" && <DiffView lines={diffLines} added={changeStats.added} removed={changeStats.removed} />}
          <div className="ledger-editor-statusbar flex min-h-7 shrink-0 flex-wrap items-center justify-between gap-x-4 gap-y-1 border-t border-line bg-paper px-3 py-1 text-[11px] text-stone">
            <div className="flex items-center gap-2">
              <span className={dirty ? "font-medium text-brand" : ""}>{dirty ? t("editorPage.unsavedChanges") : t("editorPage.noChanges")}</span>
              <span aria-hidden="true">·</span>
              <span>{online ? t("editorPage.online") : t("editorPage.offline")}</span>
            </div>
            <div className="flex flex-wrap items-center justify-end gap-x-3 gap-y-1 font-mono tabular-nums">
              <span>{t("editorPage.lines", { count: stats.lines })}</span>
              <span>{t("editorPage.chars", { count: stats.chars })}</span>
              {selectedFile && <span>{formatBytes(selectedFile.size)}</span>}
              {modTime && <span>{new Date(modTime).toLocaleString(i18n.language)}</span>}
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

const FileTreeNode = memo(function FileTreeNode({ node, depth, selectedPath, queryActive, expandedDirs, onToggleDir, onOpenFile }: { node: TreeNode; depth: number; selectedPath: string; queryActive: boolean; expandedDirs: Set<string>; onToggleDir: (path: string) => void; onOpenFile: (path: string) => Promise<void> }) {
  const expanded = queryActive || expandedDirs.has(node.path);
  const paddingLeft = `${0.5 + depth * 0.875}rem`;
  if (node.type === "directory") {
    return (
      <div>
        <button type="button" role="treeitem" aria-level={depth + 1} className="mb-1 flex h-11 w-full min-w-0 items-center gap-1 rounded-md px-2 text-left text-sm font-medium text-olive hover:bg-panel hover:text-ink lg:h-8" style={{ paddingLeft }} onClick={() => onToggleDir(node.path)} aria-expanded={expanded}>
          {expanded ? <ChevronDown className="h-3.5 w-3.5 shrink-0 text-stone" /> : <ChevronRight className="h-3.5 w-3.5 shrink-0 text-stone" />}
          <FolderOpen className="h-4 w-4 shrink-0 text-brand" />
          <span className="truncate">{node.name}</span>
        </button>
        {expanded && <div role="group">{node.children.map((child) => <FileTreeNode key={child.path} node={child} depth={depth + 1} selectedPath={selectedPath} queryActive={queryActive} expandedDirs={expandedDirs} onToggleDir={onToggleDir} onOpenFile={onOpenFile} />)}</div>}
      </div>
    );
  }
  const active = node.path === selectedPath;
  return (
    <button type="button" role="treeitem" aria-level={depth + 1} aria-selected={active} className={`mb-1 flex h-11 w-full min-w-0 items-center gap-2 rounded-md border px-2 text-left text-sm lg:h-8 ${active ? "border-brand bg-[var(--selected-bg)] text-ink" : "border-transparent text-olive hover:border-line hover:bg-panel hover:text-ink"}`} style={{ paddingLeft }} onClick={() => void onOpenFile(node.path)} title={node.path}>
      <span className="w-3.5 shrink-0" />
      <FileCode2 className="h-4 w-4 shrink-0 text-brand" />
      <span className="truncate">{node.name}</span>
    </button>
  );
});

function DiffView({ lines, added, removed }: { lines: DiffLine[]; added: number; removed: number }) {
  const { t } = useTranslation();
  const hasChanges = added > 0 || removed > 0;
  return (
    <div className="ledger-code-surface flex min-h-0 flex-1 flex-col">
      <div className="ledger-diff-toolbar flex shrink-0 items-center justify-between px-4 py-2 font-mono text-xs">
        <span>{hasChanges ? `+${added} / -${removed}` : t("editorPage.noChanges")}</span>
        <span>{t("editorPage.workingCopyDiff")}</span>
      </div>
      <div className="ledger-diff-view flex-1 overflow-auto py-3">
        {hasChanges ? lines.map((line, index) => <DiffLineRow key={`${index}-${line.kind}`} line={line} />) : <div className="ledger-diff-empty grid min-h-80 place-items-center text-sm">{t("editorPage.diffEmpty")}</div>}
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
  const response = await apiFetch(input, init);
  const text = await response.text();
  const data = text ? JSON.parse(text) as T & { error?: string } : null;
  if (!response.ok) {
    throw new Error(data?.error ?? i18n.t("editorPage.requestFailed"));
  }
  return data as T;
}

function countEditorStats(content: string): EditorStats {
  if (!content) return { lines: 1, chars: 0 };
  let lines = 1;
  for (let index = 0; index < content.length; index += 1) {
    if (content.charCodeAt(index) === 10) lines += 1;
  }
  return { lines, chars: content.length };
}

function formatBytes(size: number) {
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`;
  return `${(size / 1024 / 1024).toFixed(1)} MB`;
}

function shouldAutoFocusEditor() {
  return window.matchMedia("(hover: hover) and (pointer: fine)").matches;
}
