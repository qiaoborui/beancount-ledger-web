import { useCallback, useState } from "react";
import { fetchJson, readJson } from "@/lib/clientFetch";
import type { GitChange } from "../GitSaveModal";

type GitStatusPayload = { changes?: GitChange[]; changedFileCount?: number; dirty?: boolean; status?: string };

export function useGitStatus(showToast: (kind: "info" | "success" | "error", text: string) => void) {
  const [gitDirty, setGitDirty] = useState(false);
  const [changedFileCount, setChangedFileCount] = useState(0);
  const [gitChanges, setGitChanges] = useState<GitChange[]>([]);
  const [gitStatusLoading, setGitStatusLoading] = useState(false);
  const [gitCommitting, setGitCommitting] = useState(false);

  const applyGitStatus = useCallback((data: GitStatusPayload) => {
    const changes = Array.isArray(data.changes) ? data.changes as GitChange[] : [];
    const count = typeof data.changedFileCount === "number" ? data.changedFileCount : changes.length;
    setGitChanges(changes);
    setChangedFileCount(count);
    setGitDirty(Boolean(data.dirty ?? data.status?.trim() ?? count));
  }, []);

  const refreshGitStatus = useCallback(async () => {
    setGitStatusLoading(true);
    try {
      const data = await fetchJson<GitStatusPayload>("/api/git/status", undefined, { changes: [], changedFileCount: 0, dirty: false });
      applyGitStatus(data);
    } catch (error) {
      setGitChanges([]);
      setChangedFileCount(0);
      setGitDirty(false);
      showToast("error", error instanceof Error ? `读取 Git 状态失败：${error.message}` : "读取 Git 状态失败");
    } finally {
      setGitStatusLoading(false);
    }
  }, [applyGitStatus, showToast]);

  async function gitCommit(message = "chore: update ledger") {
    if (!changedFileCount) {
      showToast("info", "当前没有需要提交的变更");
      return;
    }
    setGitCommitting(true);
    try {
      const res = await fetch("/api/git/commit", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ message }) });
      const data = await readJson<{ error?: string; changedFileCount?: number; output?: string }>(res);
      if (!res.ok) throw new Error(data.error || "Git 提交失败");
      const count = typeof data.changedFileCount === "number" ? data.changedFileCount : changedFileCount;
      showToast("success", count > 0 ? `已提交并推送 ${count} 个文件` : data.output || "已提交并推送");
      await refreshGitStatus();
    } catch (error) {
      showToast("error", error instanceof Error ? error.message : "Git 提交失败");
      throw error;
    } finally {
      setGitCommitting(false);
    }
  }

  return { gitDirty, changedFileCount, gitChanges, gitStatusLoading, gitCommitting, refreshGitStatus, applyGitStatus, gitCommit };
}
