import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { ledgerRoot, runtimeRoot } from "./ledgerPaths";
import { writeImportedBeanFile } from "./ledgerWriter";

export type BillProvider = "alipay" | "wechat";

export type ImportPreview = {
  importId: string;
  provider: BillProvider;
  originalFilename: string;
  generatedBean: string;
  dedupReport: string;
  candidateCount: number;
  dateStart: string | null;
  dateEnd: string | null;
  warnings: string[];
};

export type ImportCommitResult = {
  ok: true;
  outputFile: string;
  includeFile: string;
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

function runCommand(command: string, args: string[], cwd: string) {
  try {
    return execFileSync(command, args, { cwd, env: commandEnv(), encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  } catch (error) {
    const err = error as Error & { stderr?: Buffer | string; stdout?: Buffer | string; code?: string };
    if (err.code === "ENOENT") throw new Error(`找不到命令 ${command}。请确认 Web 服务 PATH 中可以访问 double-entry-generator / python3。`);
    const stderr = Buffer.isBuffer(err.stderr) ? err.stderr.toString("utf8") : err.stderr;
    const stdout = Buffer.isBuffer(err.stdout) ? err.stdout.toString("utf8") : err.stdout;
    throw new Error([stderr, stdout, err.message].filter(Boolean).join("\n").trim());
  }
}

function runTranslate(provider: BillProvider, inputFile: string, outputFile: string) {
  const cfg = providerConfig[provider];
  runCommand("double-entry-generator", ["translate", "--provider", provider, "--target", "beancount", "--config", cfg.config, "--output", outputFile, inputFile], ledgerRoot());
}

function runDedup(generatedFile: string, outputFile: string | null, alipayFundRounding: boolean, dryRun: boolean) {
  const args = ["scripts/dedup_import.py", generatedFile];
  if (dryRun) args.push("--dry-run");
  if (outputFile) args.push("-o", outputFile);
  if (alipayFundRounding) args.push("--alipay-fund-rounding");
  return runCommand("python3", args, ledgerRoot());
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

function previewPath(importId: string, name: string) {
  return path.join(importRuntimeDir(importId), name);
}

async function saveUpload(file: File, provider: BillProvider, importId: string) {
  const cfg = providerConfig[provider];
  const originalName = file.name || `bill${cfg.extensions[0]}`;
  const ext = path.extname(originalName).toLowerCase();
  if (!cfg.extensions.includes(ext)) throw new Error(`${provider === "alipay" ? "支付宝" : "微信"}账单文件类型不正确，应为 ${cfg.extensions.join("/")}`);
  if (file.size > 10 * 1024 * 1024) throw new Error("账单文件超过 10MB");

  const dir = importRuntimeDir(importId);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const inputFile = path.join(dir, `original${ext}`);
  const buffer = Buffer.from(await file.arrayBuffer());
  fs.writeFileSync(inputFile, buffer, { mode: 0o600 });
  fs.writeFileSync(path.join(dir, "meta.json"), JSON.stringify({ provider, originalFilename: originalName, inputFile }, null, 2), "utf8");
  return { inputFile, originalFilename: originalName };
}

export async function createBillImportPreview(input: { provider: BillProvider; file: File; alipayFundRounding?: boolean }): Promise<ImportPreview> {
  ensureLedgerRequirements(input.provider);
  const importId = randomUUID().replace(/-/g, "").slice(0, 16);
  const upload = await saveUpload(input.file, input.provider, importId);
  const generatedFile = previewPath(importId, providerConfig[input.provider].output);

  runTranslate(input.provider, upload.inputFile, generatedFile);
  const generatedBean = fs.readFileSync(generatedFile, "utf8");
  const dedupReport = runDedup(generatedFile, null, Boolean(input.alipayFundRounding), true);
  const summary = parseBeanSummary(generatedBean);
  const warnings: string[] = [];
  if (!summary.candidateCount) warnings.push("没有在生成结果中发现交易分录。");
  if (!generatedBean.includes("orderId")) warnings.push("生成结果中没有发现 orderId，将只能使用 fallback 去重。");

  return { importId, provider: input.provider, originalFilename: upload.originalFilename, generatedBean, dedupReport, ...summary, warnings };
}

export async function commitBillImportAsync(input: { importId: string; provider: BillProvider; alipayFundRounding?: boolean }): Promise<ImportCommitResult> {
  ensureLedgerRequirements(input.provider);
  const dir = importRuntimeDir(input.importId);
  const metaPath = path.join(dir, "meta.json");
  if (!fs.existsSync(metaPath)) throw new Error("找不到导入预览，请重新上传账单");
  const meta = JSON.parse(fs.readFileSync(metaPath, "utf8")) as { provider: BillProvider; originalFilename: string; inputFile: string };
  if (meta.provider !== input.provider) throw new Error("导入 provider 与预览不一致");

  const generatedFile = previewPath(input.importId, providerConfig[input.provider].output);
  const dedupedFile = previewPath(input.importId, `${input.provider}-deduped.bean`);
  if (!fs.existsSync(generatedFile)) runTranslate(input.provider, meta.inputFile, generatedFile);
  runDedup(generatedFile, dedupedFile, Boolean(input.alipayFundRounding), false);
  if (!fs.existsSync(dedupedFile)) throw new Error("没有新交易可写入");

  const beanText = fs.readFileSync(dedupedFile, "utf8").trim();
  const summary = parseBeanSummary(beanText);
  if (!summary.candidateCount || !summary.dateStart || !summary.dateEnd) throw new Error("去重后没有可写入的交易");

  const written = await writeImportedBeanFile({
    dateStart: summary.dateStart,
    dateEnd: summary.dateEnd,
    provider: input.provider,
    beanText,
    suffix: input.importId.slice(0, 6),
  });

  return { ok: true, ...written, count: summary.candidateCount, beanText };
}

export { assertProvider };
