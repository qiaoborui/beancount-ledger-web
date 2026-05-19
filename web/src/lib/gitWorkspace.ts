import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { ensureLedgerRootForUser, ledgerRootForUser } from "./ledgerPaths";
import { publicLedgerRepoConfig, readLedgerRepoConfig, writeLedgerRepoConfig, type UserLedgerRepoConfig } from "./ledgerRepoConfig";
import { encryptToken } from "./tokenCrypto";

function execGit(args: string[], cwd: string) {
  return execFileSync("git", args, { cwd, encoding: "utf8", stdio: "pipe" }) as string;
}

export function isGitWorkspace(userId: string): boolean {
  return fs.existsSync(path.join(ledgerRootForUser(userId), ".git"));
}

export function ensureUserLedgerWorkspace(userId: string): string {
  return ensureLedgerRootForUser(userId);
}

function credentialsFromRemoteUrl(remoteUrl: string): { token?: string; username?: string } {
  try {
    const url = new URL(remoteUrl);
    const username = url.username ? decodeURIComponent(url.username) : undefined;
    const password = url.password ? decodeURIComponent(url.password) : undefined;
    const token = password || (username && username !== "x-access-token" ? username : undefined);
    return { token, username };
  } catch {
    const match = remoteUrl.match(/^https:\/\/([^:@/]+)(?::([^@/]+))?@/i);
    if (!match) return {};
    return { username: decodeURIComponent(match[1]), token: decodeURIComponent(match[2] || match[1]) };
  }
}

export function sanitizeRemoteUrl(remoteUrl: string): string {
  try {
    const url = new URL(remoteUrl);
    url.username = "";
    url.password = "";
    return url.toString();
  } catch {
    return remoteUrl.replace(/^(https:\/\/)[^@/]+@/i, "$1");
  }
}

export function connectUserLedgerRepo(userId: string, input: { remoteUrl: string; branch?: string; provider?: "github" | "git"; owner?: string; repo?: string; token?: string; tokenUsername?: string }): UserLedgerRepoConfig {
  const localPath = ledgerRootForUser(userId);
  const sanitizedRemoteUrl = sanitizeRemoteUrl(input.remoteUrl);
  const urlCredentials = credentialsFromRemoteUrl(input.remoteUrl);
  const token = input.token || urlCredentials.token;
  const tokenUsername = input.tokenUsername || urlCredentials.username || (input.provider === "github" ? "x-access-token" : undefined);

  if (fs.existsSync(localPath) && fs.readdirSync(localPath).length > 0 && !isGitWorkspace(userId)) {
    throw new Error("用户账本目录已存在但不是 Git 仓库，无法直接 clone");
  }

  if (!isGitWorkspace(userId)) {
    fs.mkdirSync(path.dirname(localPath), { recursive: true, mode: 0o700 });
    if (fs.existsSync(localPath)) fs.rmSync(localPath, { recursive: true, force: true });
    execFileSync("git", ["clone", input.remoteUrl, localPath], { encoding: "utf8", stdio: "pipe" });
    execGit(["remote", "set-url", "origin", sanitizedRemoteUrl], localPath);
  }

  if (input.branch) execGit(["checkout", input.branch], localPath);

  return writeLedgerRepoConfig(userId, {
    provider: input.provider ?? "git",
    owner: input.owner,
    repo: input.repo,
    branch: input.branch,
    remoteUrl: sanitizedRemoteUrl,
    localPath,
    encryptedToken: token ? encryptToken(token) : readLedgerRepoConfig(userId)?.encryptedToken,
    tokenUsername,
    initializedAt: new Date().toISOString(),
  });
}

export function userLedgerRepoStatus(userId: string) {
  const localPath = ledgerRootForUser(userId);
  const config = readLedgerRepoConfig(userId);
  return {
    configured: Boolean(config),
    gitWorkspace: isGitWorkspace(userId),
    localPath,
    config: config ? publicLedgerRepoConfig(config) : null,
  };
}
