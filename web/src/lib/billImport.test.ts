import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { __billImportTest } from "./billImport";

const originalLedgerRoot = process.env.LEDGER_ROOT;
let tempDir = "";

beforeEach(() => {
  tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "bill-import-"));
  process.env.LEDGER_ROOT = tempDir;
  fs.mkdirSync(path.join(tempDir, "imports"), { recursive: true });
  fs.writeFileSync(
    path.join(tempDir, "imports", "cmb-credit-card-config.yaml"),
    [
      "cmb:",
      "  paymentSourceHandledExternally:",
      "    - 支付宝-",
      "    - 财付通-",
      "    - 微信支付-",
      "",
    ].join("\n"),
    "utf8",
  );
});

afterEach(() => {
  process.env.LEDGER_ROOT = originalLedgerRoot;
  if (tempDir) fs.rmSync(tempDir, { recursive: true, force: true });
});

describe("CMB bill import helpers", () => {
  it("prefilters only strict CMB wallet prefixes before DEG", () => {
    const input = path.join(tempDir, "cmb.csv");
    const output = path.join(tempDir, "cmb-prefiltered.csv");
    fs.writeFileSync(
      input,
      [
        "招商银行信用卡对账单",
        "交易日,记账日,交易摘要,人民币金额,卡号末四位,交易地金额",
        "05/01,05/02,支付宝-中国铁路网络有限公司,10.00,1234,10.00(CNY)",
        "05/02,05/03,财付通-福州超体健康科技有限公司,20.00,1234,20.00(CNY)",
        "05/03,05/04,微信支付-某商户,30.00,1234,30.00(CNY)",
        "05/04,05/05,云闪付扫码-财付通(银联云闪付),40.00,1234,40.00(CNY)",
        "05/05,05/06,上海一嗨汽车租赁有限公司-Apple Pay:6131,50.00,1234,50.00(CNY)",
      ].join("\n"),
      "utf8",
    );

    const result = __billImportTest.prefilterCmbCsv(input, output);
    const filtered = fs.readFileSync(output, "utf8");

    expect(result.raw).toBe(5);
    expect(result.skipped).toBe(3);
    expect(result.kept).toBe(2);
    expect(filtered).not.toContain("支付宝-中国铁路网络有限公司");
    expect(filtered).not.toContain("财付通-福州超体健康科技有限公司");
    expect(filtered).not.toContain("微信支付-某商户");
    expect(filtered).toContain("云闪付扫码-财付通(银联云闪付)");
    expect(filtered).toContain("上海一嗨汽车租赁有限公司-Apple Pay:6131");
  });

  it("archives CMB import documents on the CMB credit-card liability account", () => {
    const accounts = new Set(["Assets:CN:CMB:Checking", "Liabilities:CN:CMB:CreditCard"]);
    expect(__billImportTest.providerDocumentAccount("cmb", accounts, "Assets:CN:CMB:Checking")).toBe("Liabilities:CN:CMB:CreditCard");
  });
});
