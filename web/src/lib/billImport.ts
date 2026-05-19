import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { ledgerRoot, runtimeRoot } from "./ledgerPaths";
import { writeImportedBeanFile } from "./ledgerWriter";
import { parseAccounts } from "./beancountParser";

export type BillProvider = "alipay" | "wechat";

export type ImportPreviewPosting = { account: string; amount: string; currency: string };

export type ImportPreviewEntry = {
  id: string;
  date: string;
  flag: "*" | "!";
  payee: string;
  narration: string;
  source?: string;
  orderId?: string;
  merchantId?: string;
  payTime?: string;
  method?: string;
  txType?: string;
  status?: string;
  type?: string;
  categoryAccount: string;
  fundingAccount: string;
  amount: number;
  currency: string;
  metadata: Record<string, string>;
  postings: ImportPreviewPosting[];
};

export type ImportPreview = {
  importId: string;
  provider: BillProvider;
  providerDetection: { provider: BillProvider; reason: string; confidence: "high" | "medium" | "low" };
  originalFilename: string;
  generatedBean: string;
  dedupReport: string;
  entries: ImportPreviewEntry[];
  accountOptions: { account: string; label: string; group: string; active: boolean }[];
  candidateCount: number;
  dateStart: string | null;
  dateEnd: string | null;
  warnings: string[];
};

export type ImportCommitResult = {
  ok: true;
  outputFile: string;
  includeFile: string;
  documentFile?: string;
  count: number;
  beanText: string;
};

const providerConfig: Record<BillProvider, { config: string; output: string; extensions: string[] }> = {
  alipay: { config: "imports/alipay-config.yaml", output: "alipay-output.bean", extensions: [".csv"] },
  wechat: { config: "imports/wechat-config.yaml", output: "wechat-output.bean", extensions: [".xlsx", ".xls"] },
};

function assertProvider(value: FormDataEntryValue | string | null): BillProvider {
  if (value === "alipay" || value === "wechat") return value;
  throw new Error("provider must be alipay or wechat");
}

function optionalProvider(value: FormDataEntryValue | string | null): BillProvider | undefined {
  if (value === null || value === "" || value === "auto") return undefined;
  return assertProvider(value);
}

function importRuntimeDir(importId: string) {
  if (!/^[a-zA-Z0-9_-]+$/.test(importId)) throw new Error("importId invalid");
  const dir = path.join(runtimeRoot(), "imports", importId);
  const resolved = path.resolve(dir);
  const root = path.resolve(runtimeRoot(), "imports");
  if (!resolved.startsWith(`${root}${path.sep}`)) throw new Error("import path invalid");
  return resolved;
}

function ensureLedgerRequirements(provider: BillProvider) {
  const root = ledgerRoot();
  const required = ["main.bean", providerConfig[provider].config, "scripts/dedup_import.py"];
  for (const relative of required) {
    const file = path.join(root, relative);
    if (!fs.existsSync(file)) throw new Error(`账本缺少必要文件: ${relative}`);
  }
}

function commandEnv() {
  return {
    ...process.env,
    PATH: [process.env.PATH, path.join(process.env.HOME || "", ".local", "bin"), "/opt/homebrew/bin", "/usr/local/bin"].filter(Boolean).join(path.delimiter),
  };
}

function doubleEntryGeneratorCommand() {
  return process.env.DOUBLE_ENTRY_GENERATOR_BIN || "double-entry-generator";
}

function pythonCommand() {
  return process.env.PYTHON_BIN || "python3";
}

function runCommand(command: string, args: string[], cwd: string) {
  try {
    return execFileSync(command, args, { cwd, env: commandEnv(), encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  } catch (error) {
    const err = error as Error & { stderr?: Buffer | string; stdout?: Buffer | string; code?: string };
    if (err.code === "ENOENT") throw new Error(`找不到命令 ${command}。请设置 DOUBLE_ENTRY_GENERATOR_BIN/PYTHON_BIN 为绝对路径，或确认 Web 服务 PATH 中可以访问 double-entry-generator / python3。`);
    const stderr = Buffer.isBuffer(err.stderr) ? err.stderr.toString("utf8") : err.stderr;
    const stdout = Buffer.isBuffer(err.stdout) ? err.stdout.toString("utf8") : err.stdout;
    throw new Error([stderr, stdout, err.message].filter(Boolean).join("\n").trim());
  }
}

function runTranslate(provider: BillProvider, inputFile: string, outputFile: string) {
  const cfg = providerConfig[provider];
  runCommand(doubleEntryGeneratorCommand(), ["translate", "--provider", provider, "--target", "beancount", "--config", cfg.config, "--output", outputFile, inputFile], ledgerRoot());
}

function runDedup(generatedFile: string, outputFile: string | null, alipayFundRounding: boolean, dryRun: boolean) {
  const args = ["scripts/dedup_import.py", generatedFile];
  if (dryRun) args.push("--dry-run");
  if (outputFile) args.push("-o", outputFile);
  if (alipayFundRounding) args.push("--alipay-fund-rounding");
  return runCommand(pythonCommand(), args, ledgerRoot());
}

function detectBillProvider(fileName: string, buffer: Buffer, override?: BillProvider) {
  if (override) return { provider: override, reason: "手动指定", confidence: "high" as const };
  const ext = path.extname(fileName).toLowerCase();
  if (ext === ".xlsx" || ext === ".xls") return { provider: "wechat" as const, reason: "Excel 文件通常为微信支付账单", confidence: "high" as const };
  const sample = buffer.subarray(0, 8192).toString("utf8");
  if (ext === ".csv") {
    if (/支付宝|交易号|商家订单号|交易创建时间|收支/.test(sample)) return { provider: "alipay" as const, reason: "CSV 内容包含支付宝账单字段", confidence: "high" as const };
    return { provider: "alipay" as const, reason: "CSV 文件默认按支付宝账单处理", confidence: "medium" as const };
  }
  throw new Error("无法自动识别账单类型，请上传支付宝 CSV 或微信 XLSX/XLS。需要时可使用手动覆盖。");
}

function transactionBlocks(beanText: string) {
  const lines = beanText.replace(/\r\n/g, "\n").split("\n");
  const chunks: string[] = [];
  let current: string[] | null = null;

  for (const line of lines) {
    if (/^\d{4}-\d{2}-\d{2}\s+[*!]\s+/.test(line)) {
      if (current?.length) chunks.push(current.join("\n").trimEnd());
      current = [line];
      continue;
    }
    if (current && (/^[\t ]/.test(line) || line.trim() === "")) current.push(line);
  }

  if (current?.length) chunks.push(current.join("\n").trimEnd());
  return chunks;
}

function transactionOnlyBeanText(beanText: string) {
  return transactionBlocks(beanText).join("\n\n").trim();
}

function unquoteBean(value: string) {
  const trimmed = value.trim();
  if (trimmed.startsWith('"') && trimmed.endsWith('"')) return trimmed.slice(1, -1).replace(/\\"/g, '"').replace(/\\\\/g, "\\");
  return trimmed;
}

function quoteBean(value: string) {
  return value.replace(/\\/g, "\\\\").replace(/"/g, "\\\"");
}

function parseHeader(line: string) {
  const match = line.match(/^(\d{4}-\d{2}-\d{2})\s+([*!])\s+"((?:\\.|[^"])*)"\s+"((?:\\.|[^"])*)"/);
  if (!match) throw new Error(`无法解析交易行: ${line}`);
  return { date: match[1], flag: match[2] as "*" | "!", payee: unquoteBean(`"${match[3]}"`), narration: unquoteBean(`"${match[4]}"`) };
}

function parsePreviewEntry(block: string, index: number): ImportPreviewEntry {
  const lines = block.split("\n");
  const header = parseHeader(lines[0]);
  const metadata: Record<string, string> = {};
  const postings: ImportPreviewPosting[] = [];

  for (const line of lines.slice(1)) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const meta = trimmed.match(/^([A-Za-z_][A-Za-z0-9_-]*):\s+(.+)$/);
    if (meta) {
      metadata[meta[1]] = unquoteBean(meta[2]);
      continue;
    }
    const posting = trimmed.match(/^([A-Za-z][A-Za-z0-9:_-]+)\s+(-?\d+(?:\.\d+)?)\s+([A-Z][A-Z0-9]*)$/);
    if (posting) postings.push({ account: posting[1], amount: posting[2], currency: posting[3] });
  }

  const numeric = postings.map((posting) => ({ ...posting, numeric: Number(posting.amount) }));
  const category = numeric.find((posting) => posting.numeric > 0 && /^(Expenses|Income):/.test(posting.account)) ?? numeric.find((posting) => /^(Expenses|Income):/.test(posting.account)) ?? numeric[0];
  const funding = numeric.find((posting) => posting.account !== category?.account && Math.sign(posting.numeric) !== Math.sign(category?.numeric ?? 0)) ?? numeric.find((posting) => posting.account !== category?.account) ?? numeric[1] ?? numeric[0];
  const amount = Math.max(...numeric.map((posting) => Math.abs(posting.numeric)).filter(Number.isFinite), 0);

  return {
    id: metadata.orderId || `${header.date}-${index}`,
    ...header,
    source: metadata.source,
    orderId: metadata.orderId,
    merchantId: metadata.merchantId,
    payTime: metadata.payTime,
    method: metadata.method,
    txType: metadata.txType,
    status: metadata.status,
    type: metadata.type,
    categoryAccount: category?.account ?? "Expenses:Unknown",
    fundingAccount: funding?.account ?? "",
    amount,
    currency: category?.currency ?? funding?.currency ?? "CNY",
    metadata,
    postings,
  };
}

function parsePreviewEntries(beanText: string) {
  return transactionBlocks(beanText).map((block, index) => parsePreviewEntry(block, index));
}

function parseBeanSummary(beanText: string) {
  const dates = Array.from(beanText.matchAll(/^(\d{4}-\d{2}-\d{2})\s+[*!]\s+/gm)).map((m) => m[1]);
  dates.sort();
  return {
    candidateCount: dates.length,
    dateStart: dates[0] ?? null,
    dateEnd: dates[dates.length - 1] ?? null,
  };
}

function providerDocumentAccount(provider: BillProvider, accounts: Set<string>, fallback?: string) {
  const preferred = provider === "alipay" ? "Assets:CN:Alipay:Balance" : "Assets:CN:Wechat:Balance";
  if (accounts.has(preferred)) return preferred;
  if (fallback && accounts.has(fallback)) return fallback;
  return preferred;
}

function previewPath(importId: string, name: string) {
  return path.join(importRuntimeDir(importId), name);
}

async function saveUpload(file: File, providerOverride: BillProvider | undefined, importId: string) {
  const originalName = file.name || "bill";
  const ext = path.extname(originalName).toLowerCase();
  const buffer = Buffer.from(await file.arrayBuffer());
  if (file.size > 10 * 1024 * 1024) throw new Error("账单文件超过 10MB");
  const detection = detectBillProvider(originalName, buffer, providerOverride);
  const cfg = providerConfig[detection.provider];
  if (!cfg.extensions.includes(ext)) throw new Error(`${detection.provider === "alipay" ? "支付宝" : "微信"}账单文件类型不正确，应为 ${cfg.extensions.join("/")}`);

  const dir = importRuntimeDir(importId);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const inputFile = path.join(dir, `original${ext}`);
  fs.writeFileSync(inputFile, buffer, { mode: 0o600 });
  fs.writeFileSync(path.join(dir, "meta.json"), JSON.stringify({ provider: detection.provider, originalFilename: originalName, inputFile, providerDetection: detection }, null, 2), "utf8");
  return { inputFile, originalFilename: originalName, provider: detection.provider, providerDetection: detection };
}

function accountOptions() {
  return parseAccounts()
    .filter((account) => account.active)
    .map(({ account, label, group, active }) => ({ account, label, group, active }));
}

function validateAndRenderEntries(entries: ImportPreviewEntry[]) {
  const accounts = new Set(parseAccounts().map((account) => account.account));
  const blocks = entries.map((entry, index) => {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(entry.date)) throw new Error(`第 ${index + 1} 条日期无效`);
    const postings = entry.postings.map((posting) => ({ ...posting }));
    const categoryIndex = postings.findIndex((posting) => posting.account === entry.categoryAccount || /^(Expenses|Income):/.test(posting.account));
    if (!accounts.has(entry.categoryAccount)) throw new Error(`账户不存在: ${entry.categoryAccount}`);
    if (entry.fundingAccount && !accounts.has(entry.fundingAccount)) throw new Error(`账户不存在: ${entry.fundingAccount}`);
    if (categoryIndex >= 0) postings[categoryIndex].account = entry.categoryAccount;

    for (const posting of postings) {
      if (!accounts.has(posting.account)) throw new Error(`账户不存在: ${posting.account}`);
    }

    const metadata = { ...entry.metadata };
    delete metadata.filename;
    const lines = [`${entry.date} ${entry.flag ?? "*"} "${quoteBean(entry.payee)}" "${quoteBean(entry.narration)}"`];
    for (const [key, value] of Object.entries(metadata).sort(([a], [b]) => a.localeCompare(b))) {
      if (!/^[A-Za-z_][A-Za-z0-9_-]*$/.test(key) || value === "") continue;
      lines.push(`  ${key}: "${quoteBean(String(value))}"`);
    }
    for (const posting of postings) {
      lines.push(`  ${posting.account.padEnd(34)} ${posting.amount.padStart(12)} ${posting.currency}`);
    }
    return lines.join("\n");
  });
  return blocks.join("\n\n").trim();
}

export async function createBillImportPreview(input: { provider?: BillProvider; file: File; alipayFundRounding?: boolean }): Promise<ImportPreview> {
  const importId = randomUUID().replace(/-/g, "").slice(0, 16);
  const upload = await saveUpload(input.file, input.provider, importId);
  ensureLedgerRequirements(upload.provider);
  const generatedFile = previewPath(importId, providerConfig[upload.provider].output);
  const dedupedFile = previewPath(importId, `${upload.provider}-preview-deduped.bean`);

  runTranslate(upload.provider, upload.inputFile, generatedFile);
  const rawGeneratedBean = fs.readFileSync(generatedFile, "utf8");
  const dedupReport = runDedup(generatedFile, null, Boolean(input.alipayFundRounding), true);
  runDedup(generatedFile, dedupedFile, Boolean(input.alipayFundRounding), false);
  const dedupedBean = fs.existsSync(dedupedFile) ? transactionOnlyBeanText(fs.readFileSync(dedupedFile, "utf8")) : "";
  const generatedBean = transactionOnlyBeanText(rawGeneratedBean);
  const entries = parsePreviewEntries(dedupedBean);
  const summary = parseBeanSummary(dedupedBean);
  const warnings: string[] = [];
  if (!summary.candidateCount) warnings.push("去重后没有发现可写入的新交易。");
  if (!generatedBean.includes("orderId")) warnings.push("生成结果中没有发现 orderId，将只能使用 fallback 去重。");

  return { importId, provider: upload.provider, providerDetection: upload.providerDetection, originalFilename: upload.originalFilename, generatedBean, dedupReport, entries, accountOptions: accountOptions(), ...summary, warnings };
}

export async function commitBillImportAsync(input: { importId: string; provider: BillProvider; entries: ImportPreviewEntry[]; alipayFundRounding?: boolean }): Promise<ImportCommitResult> {
  ensureLedgerRequirements(input.provider);
  const dir = importRuntimeDir(input.importId);
  const metaPath = path.join(dir, "meta.json");
  if (!fs.existsSync(metaPath)) throw new Error("找不到导入预览，请重新上传账单");
  const meta = JSON.parse(fs.readFileSync(metaPath, "utf8")) as { provider: BillProvider; originalFilename: string; inputFile: string };
  if (meta.provider !== input.provider) throw new Error("导入 provider 与预览不一致");
  if (!input.entries.length) throw new Error("没有可写入的交易");

  const beanText = validateAndRenderEntries(input.entries);
  const summary = parseBeanSummary(beanText);
  if (!summary.candidateCount || !summary.dateStart || !summary.dateEnd) throw new Error("去重后没有可写入的交易");
  const accounts = new Set(parseAccounts().map((account) => account.account));
  const fallbackDocumentAccount = input.entries[0].fundingAccount || input.entries[0].postings.at(-1)?.account;

  const written = await writeImportedBeanFile({
    dateStart: summary.dateStart,
    dateEnd: summary.dateEnd,
    provider: input.provider,
    beanText,
    suffix: input.importId.slice(0, 6),
    documentSource: { file: meta.inputFile, originalFilename: meta.originalFilename, account: providerDocumentAccount(input.provider, accounts, fallbackDocumentAccount) },
  });

  return { ok: true, ...written, count: summary.candidateCount, beanText };
}

export { assertProvider, optionalProvider };
