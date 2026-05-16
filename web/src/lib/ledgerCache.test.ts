import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { clearLedgerCacheForTests, getLedgerSnapshot, getLedgerVersion } from "./ledgerCache";

let tmpDir: string;
let previousLedgerRoot: string | undefined;

function writeBaseLedger() {
  fs.mkdirSync(path.join(tmpDir, "transactions", "2026"), { recursive: true });
  fs.writeFileSync(path.join(tmpDir, "commodities.bean"), "2026-01-01 commodity CNY\n", "utf8");
  fs.writeFileSync(path.join(tmpDir, "accounts.bean"), [
    "2026-01-01 open Assets:Cash CNY",
    "2026-01-01 open Expenses:Food CNY",
    "2026-01-01 open Equity:Opening-Balances CNY",
    "",
  ].join("\n"), "utf8");
  fs.writeFileSync(path.join(tmpDir, "budgets.bean"), "2026-01-01 custom \"budget\" Expenses:Food \"monthly\" 1000.00 CNY\n", "utf8");
  fs.writeFileSync(path.join(tmpDir, "prices.bean"), "", "utf8");
  fs.writeFileSync(path.join(tmpDir, "transactions", "2026", "05.bean"), [
    "2026-05-01 * \"Cafe\" \"Lunch\"",
    "  Expenses:Food 12.00 CNY",
    "  Assets:Cash -12.00 CNY",
    "",
  ].join("\n"), "utf8");
  fs.writeFileSync(path.join(tmpDir, "main.bean"), [
    "option \"title\" \"Test Ledger\"",
    "option \"operating_currency\" \"CNY\"",
    "include \"commodities.bean\"",
    "include \"accounts.bean\"",
    "include \"budgets.bean\"",
    "include \"prices.bean\"",
    "include \"transactions/2026/05.bean\"",
    "",
  ].join("\n"), "utf8");
}

function bumpFileMtime(file: string) {
  const now = new Date(Date.now() + 10_000);
  fs.utimesSync(file, now, now);
}

beforeEach(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ledger-cache-"));
  previousLedgerRoot = process.env.LEDGER_ROOT;
  process.env.LEDGER_ROOT = tmpDir;
  writeBaseLedger();
  clearLedgerCacheForTests();
});

afterEach(() => {
  clearLedgerCacheForTests();
  if (previousLedgerRoot === undefined) delete process.env.LEDGER_ROOT;
  else process.env.LEDGER_ROOT = previousLedgerRoot;
  fs.rmSync(tmpDir, { recursive: true, force: true });
});

describe("getLedgerVersion", () => {
  it("changes when a ledger bean file changes", () => {
    const before = getLedgerVersion();
    const txnFile = path.join(tmpDir, "transactions", "2026", "05.bean");
    fs.appendFileSync(txnFile, "; changed\n", "utf8");
    bumpFileMtime(txnFile);

    const after = getLedgerVersion();

    expect(after.fileCount).toBe(before.fileCount);
    expect(after.latestMtimeMs).toBeGreaterThanOrEqual(before.latestMtimeMs);
    expect(after.version).not.toBe(before.version);
  });
});

describe("getLedgerSnapshot", () => {
  it("reuses the cached snapshot while the version is unchanged", () => {
    const first = getLedgerSnapshot();
    const second = getLedgerSnapshot();

    expect(second).toBe(first);
    expect(first.transactions).toHaveLength(1);
    expect(first.accounts.map((account) => account.account)).toContain("Assets:Cash");
    expect(first.budgets).toHaveLength(1);
    expect(first.balances["Assets:Cash"]).toBe(-1200);
  });

  it("invalidates the cached snapshot when a ledger file changes", () => {
    const first = getLedgerSnapshot();
    const txnFile = path.join(tmpDir, "transactions", "2026", "05.bean");
    fs.appendFileSync(txnFile, [
      "2026-05-02 * \"Market\" \"Groceries\"",
      "  Expenses:Food 8.00 CNY",
      "  Assets:Cash -8.00 CNY",
      "",
    ].join("\n"), "utf8");
    bumpFileMtime(txnFile);

    const second = getLedgerSnapshot();

    expect(second).not.toBe(first);
    expect(second.transactions).toHaveLength(2);
    expect(second.balances["Assets:Cash"]).toBe(-2000);
  });
});
