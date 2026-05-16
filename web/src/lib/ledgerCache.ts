import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {
  currentBalances,
  parseAccounts,
  parseBalances,
  parseBudgets,
  parseTransactions,
  readLedgerLines,
  type AccountView,
  type BalanceAssertionView,
  type BeanLine,
  type BudgetView,
  type TransactionView,
} from "./beancountParser";
import { ledgerRoot } from "./ledgerPaths";

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

let cachedSnapshot: LedgerSnapshot | null = null;

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

export function getLedgerVersion(): LedgerVersion {
  const root = ledgerRoot();
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

export function getLedgerSnapshot(): LedgerSnapshot {
  const version = getLedgerVersion();
  if (cachedSnapshot?.version === version.version) return cachedSnapshot;

  const lines = readLedgerLines();
  const transactions = parseTransactions(lines);
  const snapshot: LedgerSnapshot = {
    ...version,
    lines,
    transactions,
    balances: currentBalances(transactions),
    balanceAssertions: parseBalances(lines),
    budgets: parseBudgets(lines),
    accounts: parseAccounts(),
    parsedAt: Date.now(),
  };
  cachedSnapshot = snapshot;
  return snapshot;
}

export function clearLedgerCacheForTests() {
  cachedSnapshot = null;
}
