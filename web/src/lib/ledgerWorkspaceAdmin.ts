import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { appRoot, ledgerRootForUser } from "./ledgerPaths";
import { readLedgerRepoConfig, writeLedgerRepoConfig } from "./ledgerRepoConfig";
import { encryptToken } from "./tokenCrypto";

const TEMPLATE_ROOT = path.join(appRoot(), "examples", "minimal-ledger");

function copyDirIfMissing(src: string, dest: string) {
  fs.mkdirSync(dest, { recursive: true, mode: 0o700 });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const srcPath = path.join(src, entry.name);
    const destPath = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      copyDirIfMissing(srcPath, destPath);
      continue;
    }
    if (fs.existsSync(destPath)) continue;
    fs.copyFileSync(srcPath, destPath);
  }
}

function git(args: string[], cwd: string) {
  return execFileSync("git", args, { cwd, encoding: "utf8", stdio: "pipe" }) as string;
}

export function initializeLedgerTemplateForUser(userId: string, options: { commit?: boolean; message?: string } = {}) {
  const root = ledgerRootForUser(userId);
  fs.mkdirSync(root, { recursive: true, mode: 0o700 });
  copyDirIfMissing(TEMPLATE_ROOT, root);

  let gitOutput = "";
  if (options.commit) {
    if (!fs.existsSync(path.join(root, ".git"))) git(["init"], root);
    git(["add", "main.bean", "accounts.bean", "commodities.bean", "budgets.bean", "prices.bean", "transactions"], root);
    const status = git(["status", "--short"], root);
    if (status.trim()) gitOutput = git(["commit", "-m", options.message || "chore: initialize ledger"], root);
  }

  return { root, gitOutput };
}

export function updateLedgerRepoToken(userId: string, token: string, tokenUsername?: string) {
  const config = readLedgerRepoConfig(userId);
  if (!config) throw new Error("当前用户尚未配置 Git 仓库");
  return writeLedgerRepoConfig(userId, {
    ...config,
    encryptedToken: encryptToken(token),
    tokenUsername: tokenUsername || config.tokenUsername || (config.provider === "github" ? "x-access-token" : "token"),
  });
}

export function clearLedgerRepoToken(userId: string) {
  const config = readLedgerRepoConfig(userId);
  if (!config) throw new Error("当前用户尚未配置 Git 仓库");
  const { encryptedToken: _encryptedToken, tokenUsername: _tokenUsername, ...rest } = config;
  return writeLedgerRepoConfig(userId, rest);
}
