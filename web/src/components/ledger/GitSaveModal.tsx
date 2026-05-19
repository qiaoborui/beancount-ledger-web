"use client";

import { GitBranch } from "lucide-react";
import { useState } from "react";
import { MobileSheet } from "./MobileSheet";

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

  const footer = <div className="flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
    <button className="rounded-xl border border-line bg-paper px-4 py-2 text-warm disabled:opacity-60" onClick={onClose} disabled={committing}>取消</button>
    <button className="rounded-xl bg-brand px-4 py-2 text-paper disabled:opacity-60" onClick={() => onCommit(message)} disabled={!hasChanges || loading || committing || !message.trim()}>
      <GitBranch className="mr-1 inline h-4 w-4" /> {committing ? "提交中…" : `提交并推送 ${changedFileCount} 个文件`}
    </button>
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
    </MobileSheet>
  );
}
