import { execFileSync } from "node:child_process";
import { ledgerRoot, ledgerRootForUser } from "./ledgerPaths";
import { readLedgerRepoConfig } from "./ledgerRepoConfig";
import { decryptToken } from "./tokenCrypto";

const TRACKED_PATHS = ["transactions", "budgets.bean", "README.md", "accounts.bean", "prices.bean"];

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

function credentialRemoteUrl(userId: string): string | undefined {
  const config = readLedgerRepoConfig(userId);
  if (!config?.encryptedToken || !config.remoteUrl.startsWith("https://")) return undefined;
  const token = decryptToken(config.encryptedToken);
  const username = encodeURIComponent(config.tokenUsername || (config.provider === "github" ? "x-access-token" : "token"));
  const password = encodeURIComponent(token);
  const url = new URL(config.remoteUrl);
  url.username = username;
  url.password = password;
  return url.toString();
}

function git(args: string[], options: { cwd?: string; encoding?: BufferEncoding } = {}) {
  return execFileSync("git", args, {
    cwd: options.cwd ?? ledgerRoot(),
    encoding: options.encoding ?? "utf8",
    stdio: "pipe",
  }) as string;
}

function gitForUser(userId: string, args: string[], options: { cwd?: string; encoding?: BufferEncoding; injectCredentials?: boolean } = {}) {
  const credentialUrl = options.injectCredentials ? credentialRemoteUrl(userId) : undefined;
  const finalArgs = credentialUrl ? ["-c", `url.${credentialUrl}.insteadOf=https://`, ...args] : args;
  return execFileSync("git", finalArgs, {
    cwd: options.cwd ?? ledgerRootForUser(userId),
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

export function gitStatusForUser(userId: string) {
  const cwd = ledgerRootForUser(userId);
  const status = gitForUser(userId, ["status", "--short", "--", ...TRACKED_PATHS], { cwd });
  const branch = gitForUser(userId, ["status", "--short", "--branch"], { cwd });
  const changes = parseGitStatus(status).filter(isTrackedChange);
  return { status, branch, dirty: changes.length > 0, changedFileCount: changes.length, changes };
}

export function gitStatus() {
  const cwd = ledgerRoot();
  const status = git(["status", "--short", "--", ...TRACKED_PATHS], { cwd });
  const branch = git(["status", "--short", "--branch"], { cwd });
  const changes = parseGitStatus(status).filter(isTrackedChange);
  return { status, branch, dirty: changes.length > 0, changedFileCount: changes.length, changes };
}

export function gitPullRebaseForUser(userId: string) {
  return gitForUser(userId, ["pull", "--rebase", "--autostash"], { injectCredentials: true });
}

export function gitPullRebase() {
  return git(["pull", "--rebase", "--autostash"], { cwd: ledgerRoot() });
}

export function gitCommitPullPushForUser(userId: string, message = "chore: update ledger") {
  const cwd = ledgerRootForUser(userId);
  gitForUser(userId, ["add", "--", ...TRACKED_PATHS], { cwd });
  const before = gitForUser(userId, ["status", "--short", "--", ...TRACKED_PATHS], { cwd });
  const changedFileCount = parseGitStatus(before).filter(isTrackedChange).length;
  let commit = "No changes to commit\n";
  if (before.trim()) commit = gitForUser(userId, ["commit", "-m", message, "--", ...TRACKED_PATHS], { cwd });
  const pull = gitForUser(userId, ["pull", "--rebase", "--autostash"], { cwd, injectCredentials: true });
  const push = gitForUser(userId, ["push"], { cwd, injectCredentials: true });
  return { output: `${commit}\n${pull}\n${push}`, changedFileCount };
}

export function gitCommitPullPush(message = "chore: update ledger") {
  const cwd = ledgerRoot();
  git(["add", "--", ...TRACKED_PATHS], { cwd });
  const before = git(["status", "--short", "--", ...TRACKED_PATHS], { cwd });
  const changedFileCount = parseGitStatus(before).filter(isTrackedChange).length;
  let commit = "No changes to commit\n";
  if (before.trim()) commit = git(["commit", "-m", message, "--", ...TRACKED_PATHS], { cwd });
  const pull = git(["pull", "--rebase", "--autostash"], { cwd });
  const push = git(["push"], { cwd });
  return { output: `${commit}\n${pull}\n${push}`, changedFileCount };
}
