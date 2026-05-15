import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("node:child_process", () => ({
  execFileSync: vi.fn(),
}));

import { execFileSync } from "node:child_process";
import { appendBeanText, appendLedgerEntries } from "./ledgerWriter";
import { mainBeanPath, transactionFileForDate } from "./ledgerPaths";
import type { LedgerEntry } from "./schemas";

const mockedExecFileSync = vi.mocked(execFileSync);

let tmpDir: string;
let previousLedgerRoot: string | undefined;
let previousBeanCheckBin: string | undefined;

function writeBaseLedger() {
  fs.writeFileSync(path.join(tmpDir, "commodities.bean"), "2026-01-01 commodity CNY\n", "utf8");
  fs.writeFileSync(path.join(tmpDir, "accounts.bean"), [
    "2026-01-01 open Assets:Cash CNY",
    "2026-01-01 open Expenses:Food CNY",
    "2026-01-01 open Equity:Opening-Balances CNY",
    "",
  ].join("\n"), "utf8");
  fs.writeFileSync(path.join(tmpDir, "budgets.bean"), "", "utf8");
  fs.writeFileSync(path.join(tmpDir, "prices.bean"), "", "utf8");
  fs.writeFileSync(path.join(tmpDir, "main.bean"), [
    "option \"title\" \"Test Ledger\"",
    "option \"operating_currency\" \"CNY\"",
    "include \"commodities.bean\"",
    "include \"accounts.bean\"",
    "include \"budgets.bean\"",
    "include \"prices.bean\"",
    "",
  ].join("\n"), "utf8");
}

function transaction(date: string, amount = "12.00"): LedgerEntry {
  return {
    kind: "transaction",
    date,
    payee: "Test Payee",
    narration: "Test Narration",
    metadata: {},
    tags: [],
    postings: [
      { account: "Expenses:Food", amount, currency: "CNY" },
      { account: "Assets:Cash", amount: `-${amount}`, currency: "CNY" },
    ],
    confidence: 1,
    needsReview: false,
    questions: [],
  };
}

beforeEach(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ledger-writer-"));
  previousLedgerRoot = process.env.LEDGER_ROOT;
  previousBeanCheckBin = process.env.BEAN_CHECK_BIN;
  process.env.LEDGER_ROOT = tmpDir;
  process.env.BEAN_CHECK_BIN = "bean-check";
  mockedExecFileSync.mockReset();
  writeBaseLedger();
});

afterEach(() => {
  if (previousLedgerRoot === undefined) delete process.env.LEDGER_ROOT;
  else process.env.LEDGER_ROOT = previousLedgerRoot;

  if (previousBeanCheckBin === undefined) delete process.env.BEAN_CHECK_BIN;
  else process.env.BEAN_CHECK_BIN = previousBeanCheckBin;

  fs.rmSync(tmpDir, { recursive: true, force: true });
});

describe("transactionFileForDate", () => {
  it("uses transactions/YYYY/MM.bean layout", () => {
    expect(transactionFileForDate("2026-05-15")).toBe(path.join(tmpDir, "transactions", "2026", "05.bean"));
  });
});

describe("appendBeanText", () => {
  it("creates a monthly transaction file and includes it from main.bean", async () => {
    await appendBeanText("2026-05-15", "2026-05-15 * \"Lunch\" \"Meal\"\n  Expenses:Food 12.00 CNY\n  Assets:Cash -12.00 CNY\n");

    const monthFile = path.join(tmpDir, "transactions", "2026", "05.bean");
    expect(fs.readFileSync(mainBeanPath(), "utf8")).toContain('include "transactions/2026/05.bean"');
    expect(fs.readFileSync(monthFile, "utf8")).toContain("; 2026-05 交易记录");
    expect(fs.readFileSync(monthFile, "utf8")).toContain('2026-05-15 * "Lunch" "Meal"');
    expect(mockedExecFileSync).toHaveBeenCalledOnce();
  });

  it("rolls back the monthly file and main.bean include when validation fails", async () => {
    const mainBefore = fs.readFileSync(mainBeanPath(), "utf8");
    mockedExecFileSync.mockImplementationOnce(() => {
      throw new Error("bean-check failed");
    });

    await expect(appendBeanText("2026-05-15", "invalid bean text\n")).rejects.toThrow("bean-check failed");

    expect(fs.readFileSync(mainBeanPath(), "utf8")).toBe(mainBefore);
    expect(fs.existsSync(path.join(tmpDir, "transactions", "2026", "05.bean"))).toBe(false);
  });
});

describe("appendLedgerEntries", () => {
  it("writes a multi-month batch atomically", async () => {
    const beanTexts = await appendLedgerEntries([transaction("2026-05-15"), transaction("2026-06-01", "8.50")]);

    expect(beanTexts).toHaveLength(2);
    expect(fs.readFileSync(mainBeanPath(), "utf8")).toContain('include "transactions/2026/05.bean"');
    expect(fs.readFileSync(mainBeanPath(), "utf8")).toContain('include "transactions/2026/06.bean"');
    expect(fs.readFileSync(path.join(tmpDir, "transactions", "2026", "05.bean"), "utf8")).toContain("2026-05-15");
    expect(fs.readFileSync(path.join(tmpDir, "transactions", "2026", "06.bean"), "utf8")).toContain("2026-06-01");
    expect(mockedExecFileSync).toHaveBeenCalledOnce();
  });

  it("rolls back all touched files when a batch fails validation", async () => {
    const mainBefore = fs.readFileSync(mainBeanPath(), "utf8");
    mockedExecFileSync.mockImplementationOnce(() => {
      throw new Error("bean-check failed");
    });

    await expect(appendLedgerEntries([transaction("2026-05-15"), transaction("2026-06-01")])).rejects.toThrow("bean-check failed");

    expect(fs.readFileSync(mainBeanPath(), "utf8")).toBe(mainBefore);
    expect(fs.existsSync(path.join(tmpDir, "transactions", "2026", "05.bean"))).toBe(false);
    expect(fs.existsSync(path.join(tmpDir, "transactions", "2026", "06.bean"))).toBe(false);
  });
});
