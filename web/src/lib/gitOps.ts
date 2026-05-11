import { execFileSync } from "node:child_process";
import { ledgerRoot } from "./ledgerPaths";

const TRACKED_PATHS = ["transactions", "budgets.bean", "README.md", "accounts.bean", "prices.bean"];

function git(args: string[], options: { cwd?: string; encoding?: BufferEncoding } = {}) {
  return execFileSync("git", args, {
    cwd: options.cwd ?? ledgerRoot(),
    encoding: options.encoding ?? "utf8",
    stdio: "pipe",
  }) as string;
}

export function gitStatus() {
  const cwd = ledgerRoot();
  const status = git(["status", "--short"], { cwd });
  const branch = git(["status", "--short", "--branch"], { cwd });
  return { status, branch, dirty: Boolean(status.trim()) };
}

export function gitPullRebase() {
  return git(["pull", "--rebase", "--autostash"]);
}

export function gitCommitPullPush(message = "chore: update ledger") {
  const cwd = ledgerRoot();
  git(["add", ...TRACKED_PATHS], { cwd });
  const before = git(["status", "--short"], { cwd });
  let commit = "No changes to commit\n";
  if (before.trim()) commit = git(["commit", "-m", message], { cwd });
  const pull = git(["pull", "--rebase", "--autostash"], { cwd });
  const push = git(["push"], { cwd });
  return `${commit}\n${pull}\n${push}`;
}
