"use client";

import { ChevronDown, ChevronUp, GitBranch } from "lucide-react";
import { useState } from "react";
import { fetchJson } from "@/lib/clientFetch";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { MobileSheet } from "./MobileSheet";

export type GitChange = {
  path: string;
  originalPath?: string;
  indexStatus: string;
  workTreeStatus: string;
  status: string;
  label: string;
};

type GitDiffPayload = {
  path: string;
  diff?: string;
  truncated?: boolean;
};

export function GitSaveModal({
  open,
  changes,
  changedFileCount,
  loading,
  committing,
  onRefresh,
  onClose,
  onCommit,
}: {
  open: boolean;
  changes: GitChange[];
  changedFileCount: number;
  loading: boolean;
  committing: boolean;
  onRefresh: () => void | Promise<void>;
  onClose: () => void;
  onCommit: (message: string) => void | Promise<void>;
}) {
  const [message, setMessage] = useState("chore: update ledger");
  const [openDiffPath, setOpenDiffPath] = useState<string | null>(null);
  const [diffs, setDiffs] = useState<Record<string, GitDiffPayload>>({});
  const [diffErrors, setDiffErrors] = useState<Record<string, string>>({});
  const [loadingDiffPath, setLoadingDiffPath] = useState<string | null>(null);

  if (!open) return null;

  const hasChanges = changedFileCount > 0;

  async function toggleDiff(path: string) {
    if (openDiffPath === path) {
      setOpenDiffPath(null);
      return;
    }
    setOpenDiffPath(path);
    if (diffs[path] || diffErrors[path]) return;
    setLoadingDiffPath(path);
    setDiffErrors((current) => ({ ...current, [path]: "" }));
    try {
      const params = new URLSearchParams({ path });
      const data = await fetchJson<GitDiffPayload>(`/api/git/diff?${params.toString()}`);
      setDiffs((current) => ({ ...current, [path]: data }));
    } catch (error) {
      setDiffErrors((current) => ({ ...current, [path]: error instanceof Error ? error.message : "读取 diff 失败" }));
    } finally {
      setLoadingDiffPath(null);
    }
  }

  const footer = <div className="flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
    <Button variant="outline" className="rounded-xl bg-paper text-warm" onClick={onClose} disabled={committing}>取消</Button>
    <Button className="rounded-xl" onClick={() => onCommit(message)} disabled={!hasChanges || loading || committing || !message.trim()}>
      <GitBranch className="h-4 w-4" /> {committing ? "提交中…" : `提交并推送 ${changedFileCount} 个文件`}
    </Button>
  </div>;

  return (
    <MobileSheet open title="保存到 Git" onClose={onClose} shouldClose={() => !committing} size="md" align="center" footer={footer} zIndexClassName="z-[110]">
        <div>
          <div className="text-xs uppercase tracking-[0.24em] text-stone">git save preview</div>
          <p className="mt-2 text-sm leading-6 text-olive">
            {loading ? "正在读取账本仓库变更…" : hasChanges ? `本次将提交 ${changedFileCount} 个变动文件。` : "当前没有需要提交的账本变更。"}
          </p>
        </div>

        <div className="mt-5 rounded-2xl border border-line bg-panel">
          <div className="flex items-center justify-between gap-3 border-b border-line px-4 py-3">
            <div className="text-sm font-medium text-warm">变动文件</div>
            <Button variant="outline" size="xs" className="rounded-xl bg-paper text-brand" onClick={onRefresh} disabled={loading || committing}>刷新</Button>
          </div>
          <div className="max-h-72 overflow-y-auto p-2">
            {loading ? (
              <div className="px-3 py-8 text-center text-sm text-stone">读取中…</div>
            ) : changes.length ? (
              <div className="space-y-2">
                {changes.map((change) => {
                  const diffOpen = openDiffPath === change.path;
                  const diff = diffs[change.path];
                  const diffError = diffErrors[change.path];
                  const loadingDiff = loadingDiffPath === change.path;
                  return (
                    <div key={`${change.status}:${change.path}`} className="overflow-hidden rounded-xl bg-paper text-sm">
                      <button type="button" className="flex w-full items-start gap-3 px-3 py-2 text-left hover:bg-tag" onClick={() => void toggleDiff(change.path)}>
                        <span className="shrink-0 rounded-full bg-tag px-2 py-0.5 text-xs text-warm">{change.label}</span>
                        <span className="min-w-0 flex-1 break-all text-olive">
                          {change.originalPath ? <><span className="text-stone">{change.originalPath}</span> → </> : null}{change.path}
                        </span>
                        <span className="shrink-0 font-mono text-xs text-stone">{change.status}</span>
                        {diffOpen ? <ChevronUp className="h-4 w-4 shrink-0 text-stone" /> : <ChevronDown className="h-4 w-4 shrink-0 text-stone" />}
                      </button>
                      {diffOpen && (
                        <div className="border-t border-line bg-panel px-3 py-3">
                          {loadingDiff ? (
                            <div className="text-sm text-stone">正在读取 diff…</div>
                          ) : diffError ? (
                            <div className="text-sm text-[var(--danger)]">{diffError}</div>
                          ) : diff?.diff ? (
                            <>
                              {diff.truncated && <div className="mb-2 rounded-lg border border-line bg-tag px-2 py-1 text-xs text-stone">diff 较大，已截断显示。</div>}
                              <DiffViewer diff={diff.diff} />
                            </>
                          ) : (
                            <div className="text-sm text-stone">暂无 diff 内容。</div>
                          )}
                        </div>
                      )}
                    </div>
                  );
                })}
              </div>
            ) : (
              <div className="px-3 py-8 text-center text-sm text-stone">没有变动文件</div>
            )}
          </div>
        </div>

        <label className="mt-5 block text-sm font-medium text-warm">
          提交信息
          <Input
            className="mt-2 h-12 rounded-2xl bg-panel text-sm text-ink"
            value={message}
            onChange={(event) => setMessage(event.target.value)}
            disabled={!hasChanges || committing}
            placeholder="chore: update ledger"
          />
        </label>
    </MobileSheet>
  );
}

function DiffViewer({ diff }: { diff: string }) {
  const lines = diff.split("\n");
  return (
    <div className="max-h-80 overflow-auto rounded-xl border border-line bg-paper p-3 text-xs leading-5 text-warm">
      {lines.map((line, index) => {
        const cls = line.startsWith("+") && !line.startsWith("+++")
          ? "text-[var(--success)]"
          : line.startsWith("-") && !line.startsWith("---")
            ? "text-[var(--danger)]"
            : line.startsWith("@@")
              ? "text-brand"
              : "text-stone";
        return <div key={index} className={`${cls} min-w-max whitespace-pre-wrap break-words font-mono`}>{line || " "}</div>;
      })}
    </div>
  );
}
