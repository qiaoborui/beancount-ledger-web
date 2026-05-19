import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { accountGroup, normalizeAccountGroup, parseAccounts } from "./beancountParser";

let tmpDir: string;
let previousLedgerRoot: string | undefined;

beforeEach(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "beancount-parser-"));
  previousLedgerRoot = process.env.LEDGER_ROOT;
  process.env.LEDGER_ROOT = tmpDir;
});

afterEach(() => {
  if (previousLedgerRoot === undefined) delete process.env.LEDGER_ROOT;
  else process.env.LEDGER_ROOT = previousLedgerRoot;
  fs.rmSync(tmpDir, { recursive: true, force: true });
});

function writeAccounts(lines: string[]) {
  fs.writeFileSync(path.join(tmpDir, "accounts.bean"), `${lines.join("\n")}\n`, "utf8");
}

describe("account metadata grouping", () => {
  it("uses group metadata before account-name heuristics", () => {
    writeAccounts([
      "2026-01-01 open Assets:CN:MYBank:WenLiBao CNY",
      "  alias: \"网商银行稳利宝\"",
      "  group: \"wealth\"",
    ]);

    const [account] = parseAccounts();

    expect(account.group).toBe("wealth");
    expect(account.alias).toBe("网商银行稳利宝");
    expect(account.metadata?.group).toBe("wealth");
  });

  it("normalizes Chinese group metadata values", () => {
    writeAccounts([
      "2026-01-01 open Assets:CN:MYBank:ZengLiBao CNY",
      "  alias: \"网商银行增利宝\"",
      "  group: \"理财\"",
    ]);

    const [account] = parseAccounts();

    expect(account.group).toBe("wealth");
  });

  it("falls back to heuristic classification when metadata is absent", () => {
    expect(accountGroup("Assets:CN:Bank:Checking")).toBe("cash");
    expect(accountGroup("Assets:CN:MYBank:WenLiBao", {}, "网商银行稳利宝")).toBe("wealth");
    expect(normalizeAccountGroup("现金")).toBe("cash");
  });
});
