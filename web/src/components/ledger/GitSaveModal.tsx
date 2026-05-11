"use client";

import { GitBranch, X } from "lucide-react";
import { useState } from "react";

export type GitChange = {
  path: string;
  originalPath?: string;
  indexStatus: string;
  workTreeStatus: string;
  status: string;
  label: string;
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

  if (!open) return null;

  const hasChanges = changedFileCount > 0;

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-ink/35 p-0 sm:items-center sm:p-4" onClick={onClose}>
      <div className="kami-float max-h-[90vh] w-full max-w-2xl overflow-y-auto rounded-t-3xl bg-paper p-5 shadow-xl sm:rounded-3xl sm:p-6" onClick={(event) => event.stopPropagation()}>
        <div className="flex items-start justify-between gap-4">
          <div>
            <div className="text-xs uppercase tracking-[0.24em] text-stone">git save preview</div>
            <h2 className="mt-2 font-serif text-3xl font-medium">保存到 Git</h2>
            <p className="mt-2 text-sm leading-6 text-olive">
              {loading ? "正在读取账本仓库变更…" : hasChanges ? `本次将提交 ${changedFileCount} 个变动文件。` : "当前没有需要提交的账本变更。"}
            </p>
          </div>
          <button className="rounded-xl border border-line bg-panel p-2 text-stone hover:text-ink" onClick={onClose} aria-label="关闭 Git 保存预览" disabled={committing}>
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="mt-5 rounded-2xl border border-line bg-panel">
          <div className="flex items-center justify-between gap-3 border-b border-line px-4 py-3">
            <div className="text-sm font-medium text-warm">变动文件</div>
            <button className="rounded-xl border border-line bg-paper px-3 py-1.5 text-xs text-brand disabled:opacity-60" onClick={onRefresh} disabled={loading || committing}>刷新</button>
          </div>
          <div className="max-h-72 overflow-y-auto p-2">
            {loading ? (
              <div className="px-3 py-8 text-center text-sm text-stone">读取中…</div>
            ) : changes.length ? (
              <div className="space-y-2">
                {changes.map((change) => (
                  <div key={`${change.status}:${change.path}`} className="flex items-start gap-3 rounded-xl bg-paper px-3 py-2 text-sm">
                    <span className="shrink-0 rounded-full bg-tag px-2 py-0.5 text-xs text-warm">{change.label}</span>
                    <span className="min-w-0 flex-1 break-all text-olive">
                      {change.originalPath ? <><span className="text-stone">{change.originalPath}</span> → </> : null}{change.path}
                    </span>
                    <span className="shrink-0 font-mono text-xs text-stone">{change.status}</span>
                  </div>
                ))}
              </div>
            ) : (
              <div className="px-3 py-8 text-center text-sm text-stone">没有变动文件</div>
            )}
          </div>
        </div>

        <label className="mt-5 block text-sm font-medium text-warm">
          提交信息
          <input
            className="mt-2 w-full rounded-2xl border border-line bg-panel px-4 py-3 text-sm text-ink outline-none focus:border-brand disabled:opacity-60"
            value={message}
            onChange={(event) => setMessage(event.target.value)}
            disabled={!hasChanges || committing}
            placeholder="chore: update ledger"
          />
        </label>

        <div className="mt-5 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
          <button className="rounded-xl border border-line bg-paper px-4 py-2 text-warm disabled:opacity-60" onClick={onClose} disabled={committing}>取消</button>
          <button className="rounded-xl bg-brand px-4 py-2 text-paper disabled:opacity-60" onClick={() => onCommit(message)} disabled={!hasChanges || loading || committing || !message.trim()}>
            <GitBranch className="mr-1 inline h-4 w-4" /> {committing ? "提交中…" : `提交并推送 ${changedFileCount} 个文件`}
          </button>
        </div>
      </div>
    </div>
  );
}
