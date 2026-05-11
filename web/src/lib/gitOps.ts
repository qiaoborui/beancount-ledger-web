import { execFileSync } from "node:child_process";
import { ledgerRoot } from "./ledgerPaths";

const TRACKED_PATHS = ["transactions", "budgets.bean", "README.md", "accounts.bean", "prices.bean"];

export type GitChange = {
  path: string;
  originalPath?: string;
  indexStatus: string;
  workTreeStatus: string;
  status: string;
  label: string;
};

function git(args: string[], options: { cwd?: string; encoding?: BufferEncoding } = {}) {
  return execFileSync("git", args, {
    cwd: options.cwd ?? ledgerRoot(),
    encoding: options.encoding ?? "utf8",
    stdio: "pipe",
  }) as string;
}

function statusLabel(indexStatus: string, workTreeStatus: string) {
  const combined = `${indexStatus}${workTreeStatus}`;
  if (combined === "??") return "未跟踪";
  if (indexStatus === "R" || workTreeStatus === "R") return "重命名";
  if (indexStatus === "C" || workTreeStatus === "C") return "复制";
  if (indexStatus === "A" || workTreeStatus === "A") return "新增";
  if (indexStatus === "D" || workTreeStatus === "D") return "删除";
  if (indexStatus === "M" || workTreeStatus === "M") return "修改";
  if (indexStatus === "U" || workTreeStatus === "U") return "冲突";
  return "变更";
}

export function parseGitStatus(status: string): GitChange[] {
  return status
    .split("\n")
    .map((line) => line.trimEnd())
    .filter(Boolean)
    .map((line) => {
      const indexStatus = line[0] ?? " ";
      const workTreeStatus = line[1] ?? " ";
      const rawPath = line.slice(3);
      const renameMatch = rawPath.match(/^(.*?) -> (.*)$/);
      const path = renameMatch ? renameMatch[2] : rawPath;
      const originalPath = renameMatch ? renameMatch[1] : undefined;
      return {
        path,
        originalPath,
        indexStatus,
        workTreeStatus,
        status: `${indexStatus}${workTreeStatus}`.trim() || "changed",
        label: statusLabel(indexStatus, workTreeStatus),
      };
    });
}

export function gitStatus() {
  const cwd = ledgerRoot();
  const status = git(["status", "--short"], { cwd });
  const branch = git(["status", "--short", "--branch"], { cwd });
  const changes = parseGitStatus(status);
  return { status, branch, dirty: changes.length > 0, changedFileCount: changes.length, changes };
}

export function gitPullRebase() {
  return git(["pull", "--rebase", "--autostash"]);
}

export function gitCommitPullPush(message = "chore: update ledger") {
  const cwd = ledgerRoot();
  git(["add", ...TRACKED_PATHS], { cwd });
  const before = git(["status", "--short"], { cwd });
  const changedFileCount = parseGitStatus(before).length;
  let commit = "No changes to commit\n";
  if (before.trim()) commit = git(["commit", "-m", message], { cwd });
  const pull = git(["pull", "--rebase", "--autostash"], { cwd });
  const push = git(["push"], { cwd });
  return { output: `${commit}\n${pull}\n${push}`, changedFileCount };
}
