import { useCallback, useState } from "react";

export function useGitStatus(showToast: (kind: "info" | "success" | "error", text: string) => void) {
  const [gitDirty, setGitDirty] = useState(false);

  const refreshGitStatus = useCallback(async () => {
    try {
      const data = await fetch("/api/git/status").then((r) => r.json());
      setGitDirty(Boolean(data.dirty ?? data.status?.trim()));
    } catch {
      setGitDirty(false);
    }
  }, []);

  async function gitCommit() {
    if (!confirm("提交并推送当前账本修改？")) return;
    const res = await fetch("/api/git/commit", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ message: "chore: update ledger" }) });
    const data = await res.json();
    if (res.ok) { showToast("success", data.output || "已提交并推送"); refreshGitStatus(); }
    else showToast("error", data.error || "Git 提交失败");
  }

  return { gitDirty, refreshGitStatus, gitCommit };
}
