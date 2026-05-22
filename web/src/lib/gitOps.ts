import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { ledgerRoot } from "./ledgerPaths";

const TRACKED_PATHS = ["main.bean", "transactions", "budgets.bean", "README.md", "accounts.bean", "prices.bean"];

function isTrackedPath(filePath: string) {
  return TRACKED_PATHS.some((trackedPath) => filePath === trackedPath || filePath.startsWith(`${trackedPath}/`));
}

function isTrackedChange(change: GitChange) {
  return isTrackedPath(change.path) || Boolean(change.originalPath && isTrackedPath(change.originalPath));
}

export type GitChange = {
  path: string;
  originalPath?: string;
  indexStatus: string;
  workTreeStatus: string;
  status: string;
  label: string;
};

function git(args: string[], options: { cwd?: string; encoding?: BufferEncoding } = {}) {
  const cwd = options.cwd ?? ledgerRoot();
  return execFileSync("git", ["-c", `safe.directory=${cwd}`, ...args], {
    cwd,
    encoding: options.encoding ?? "utf8",
    stdio: "pipe",
  }) as string;
}

function remoteDisabled() {
  const raw = process.env.LEDGER_GIT_REMOTE_DISABLED?.trim().toLowerCase();
  return raw === "1" || raw === "true" || raw === "yes" || raw === "on";
}

function trackedPathspecs(cwd = ledgerRoot()) {
  return TRACKED_PATHS.filter((trackedPath) => {
    if (fs.existsSync(path.join(cwd, trackedPath))) return true;
    return git(["ls-files", "--", trackedPath], { cwd }).trim() !== "";
  });
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
  const trackedPaths = trackedPathspecs(cwd);
  const status = git(["status", "--short", "--", ...trackedPaths], { cwd });
  const branch = git(["status", "--short", "--branch"], { cwd });
  const changes = parseGitStatus(status).filter(isTrackedChange);
  return { status, branch, dirty: changes.length > 0, changedFileCount: changes.length, changes };
}

export function gitPullRebase() {
  if (remoteDisabled()) return "Git remote sync disabled\n";
  return git(["pull", "--rebase", "--autostash"]);
}

export function gitCommitPullPush(message = "chore: update ledger") {
  const cwd = ledgerRoot();
  const trackedPaths = trackedPathspecs(cwd);
  git(["add", "--", ...trackedPaths], { cwd });
  const before = git(["status", "--short", "--", ...trackedPaths], { cwd });
  const changedFileCount = parseGitStatus(before).filter(isTrackedChange).length;
  let commit = "No changes to commit\n";
  if (before.trim()) commit = git(["commit", "-m", message, "--", ...trackedPaths], { cwd });
  if (remoteDisabled()) return { output: `${commit}\nGit remote sync disabled\n`, changedFileCount };
  const pull = git(["pull", "--rebase", "--autostash"], { cwd });
  const push = git(["push"], { cwd });
  return { output: `${commit}\n${pull}\n${push}`, changedFileCount };
}
