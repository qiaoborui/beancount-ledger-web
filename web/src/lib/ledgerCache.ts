import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {
  currentBalances,
  parseAccountsForUser,
  parseBalances,
  parseBudgets,
  parseTransactions,
  readLedgerLinesForUser,
  type AccountView,
  type BalanceAssertionView,
  type BeanLine,
  type BudgetView,
  type TransactionView,
} from "./beancountParser";
import { ledgerRoot, ledgerRootForUser } from "./ledgerPaths";

export type LedgerVersion = {
  version: string;
  latestMtimeMs: number;
  fileCount: number;
};

export type LedgerSnapshot = LedgerVersion & {
  lines: BeanLine[];
  transactions: TransactionView[];
  balances: Record<string, number>;
  balanceAssertions: BalanceAssertionView[];
  budgets: BudgetView[];
  accounts: AccountView[];
  parsedAt: number;
};

type BeanFileStat = {
  relativePath: string;
  size: number;
  mtimeMs: number;
};

const cachedSnapshots = new Map<string, LedgerSnapshot>();

function collectBeanFileStats(root: string): BeanFileStat[] {
  const stats: BeanFileStat[] = [];

  function visit(dir: string) {
    if (!fs.existsSync(dir)) return;
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (entry.name === ".git" || entry.name === ".runtime" || entry.name === "node_modules") continue;
      const fullPath = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        visit(fullPath);
        continue;
      }
      if (!entry.isFile() || !entry.name.endsWith(".bean")) continue;
      const stat = fs.statSync(fullPath);
      stats.push({
        relativePath: path.relative(root, fullPath).split(path.sep).join("/"),
        size: stat.size,
        mtimeMs: stat.mtimeMs,
      });
    }
  }

  visit(root);
  return stats.sort((a, b) => a.relativePath.localeCompare(b.relativePath));
}

function versionForRoot(root: string): LedgerVersion {
  const files = collectBeanFileStats(root);
  const latestMtimeMs = files.reduce((max, file) => Math.max(max, file.mtimeMs), 0);
  const hash = crypto.createHash("sha256");
  for (const file of files) {
    hash.update(file.relativePath);
    hash.update("\0");
    hash.update(String(file.size));
    hash.update("\0");
    hash.update(String(file.mtimeMs));
    hash.update("\0");
  }
  return {
    version: hash.digest("hex"),
    latestMtimeMs,
    fileCount: files.length,
  };
}

export function getLedgerVersionForUser(userId: string): LedgerVersion {
  return versionForRoot(ledgerRootForUser(userId));
}

export function getLedgerVersion(): LedgerVersion {
  return versionForRoot(ledgerRoot());
}

export function getLedgerSnapshotForUser(userId: string): LedgerSnapshot {
  const version = getLedgerVersionForUser(userId);
  const cached = cachedSnapshots.get(userId);
  if (cached?.version === version.version) return cached;

  const lines = readLedgerLinesForUser(userId);
  const transactions = parseTransactions(lines);
  const snapshot: LedgerSnapshot = {
    ...version,
    lines,
    transactions,
    balances: currentBalances(transactions),
    balanceAssertions: parseBalances(lines),
    budgets: parseBudgets(lines),
    accounts: parseAccountsForUser(userId),
    parsedAt: Date.now(),
  };
  cachedSnapshots.set(userId, snapshot);
  return snapshot;
}

export function getLedgerSnapshot(): LedgerSnapshot {
  return getLedgerSnapshotForUser("owner");
}

export function clearLedgerCacheForUser(userId: string) {
  cachedSnapshots.delete(userId);
}

export function clearLedgerCacheForTests() {
  cachedSnapshots.clear();
}
