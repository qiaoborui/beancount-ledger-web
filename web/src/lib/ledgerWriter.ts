import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { accountsBeanPath, mainBeanPath, transactionFileForDate, transactionsDir } from "./ledgerPaths";
import type { BalanceAssertion, LedgerEntry, MetadataValue, ParsedTransaction } from "./schemas";

let writeQueue: Promise<unknown> = Promise.resolve();

function withWriteLock<T>(fn: () => Promise<T>): Promise<T> {
  const next = writeQueue.then(fn, fn);
  writeQueue = next.catch(() => undefined);
  return next;
}

export function transactionToBean(entry: ParsedTransaction): string {
  const tagText = entry.tags?.length ? ` ${entry.tags.map((tag) => `#${tag}`).join(" ")}` : "";
  const lines = [`${entry.date} * "${escapeBean(entry.payee)}" "${escapeBean(entry.narration)}"${tagText}`];
  for (const [key, value] of Object.entries(entry.metadata ?? {}).sort(([a], [b]) => a.localeCompare(b))) {
    lines.push(`  ${key}: ${metadataValueToBean(value)}`);
  }
  for (const posting of entry.postings) {
    lines.push(`  ${posting.account.padEnd(34)} ${posting.amount.padStart(12)} ${posting.currency}`);
  }
  return `${lines.join("\n")}\n`;
}

export function balanceToBean(entry: BalanceAssertion): string {
  return `${entry.date} balance ${entry.account} ${entry.amount} ${entry.currency}\n`;
}

function escapeBean(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/"/g, "\\\"");
}

function metadataValueToBean(value: MetadataValue): string {
  if (typeof value === "boolean") return value ? "TRUE" : "FALSE";
  if (typeof value === "number") return Number.isFinite(value) ? String(value) : `"${escapeBean(String(value))}"`;
  return `"${escapeBean(value)}"`;
}

export function accountToBean(entry: { date: string; account: string; alias?: string; currency?: "CNY" }): string {
  const lines = [`${entry.date} open ${entry.account} ${entry.currency ?? "CNY"}`];
  if (entry.alias?.trim()) lines.push(`  alias: "${escapeBean(entry.alias.trim())}"`);
  return `${lines.join("\n")}\n`;
}

function beanCheckCommand() {
  const configured = process.env.BEAN_CHECK_BIN;
  if (configured) return configured;

  const candidates = [
    "bean-check",
    path.join(process.env.HOME || "", ".local", "bin", "bean-check"),
    path.join(process.env.HOME || "", ".local", "share", "uv", "tools", "beancount", "bin", "bean-check"),
  ];

  return candidates.find((candidate) => candidate === "bean-check" || fs.existsSync(candidate)) ?? "bean-check";
}

function runBeanCheck() {
  const envPath = [
    process.env.PATH,
    path.join(process.env.HOME || "", ".local", "bin"),
    "/opt/homebrew/bin",
    "/usr/local/bin",
  ].filter(Boolean).join(path.delimiter);

  try {
    execFileSync(beanCheckCommand(), [mainBeanPath()], {
      cwd: path.dirname(mainBeanPath()),
      stdio: "pipe",
      env: { ...process.env, PATH: envPath },
    });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      throw new Error("找不到 bean-check。请设置 BEAN_CHECK_BIN 为 bean-check 的绝对路径，或确保运行 Web 服务的 PATH 包含 bean-check。");
    }
    throw error;
  }
}

type FileSnapshot = { existed: boolean; content: string };

type AppendItem = { date: string; beanText: string };

type ImportProvider = "alipay" | "wechat";
type ImportDocumentSource = { file: string; originalFilename: string; account: string };

function includeLineForTransactionFile(file: string) {
  const relative = path.relative(path.dirname(mainBeanPath()), file).split(path.sep).join("/");
  return `include "${relative}"`;
}

function includeLineRelativeTo(baseFile: string, includedFile: string) {
  const relative = path.relative(path.dirname(baseFile), includedFile).split(path.sep).join("/");
  return `include "${relative}"`;
}

function monthHeaderForDate(date: string) {
  return `; ${date.slice(0, 7)} 交易记录\n`;
}

function snapshotFile(file: string): FileSnapshot {
  return { existed: fs.existsSync(file), content: fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "" };
}

function restoreSnapshots(snapshots: Map<string, FileSnapshot>) {
  for (const [file, snapshot] of snapshots) {
    if (snapshot.existed) {
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, snapshot.content, "utf8");
    } else if (fs.existsSync(file)) {
      fs.rmSync(file);
    }
  }
}

function ensureSnapshot(snapshots: Map<string, FileSnapshot>, file: string) {
  if (!snapshots.has(file)) snapshots.set(file, snapshotFile(file));
}

function appendText(before: string, beanText: string) {
  const trimmed = beanText.trimEnd();
  if (!trimmed) return before;
  const separator = before.length === 0 ? "" : before.endsWith("\n") ? "\n" : "\n\n";
  return `${before}${separator}${trimmed}\n`;
}

function ensureMonthlyFileAndInclude(file: string, date: string, snapshots: Map<string, FileSnapshot>) {
  const main = mainBeanPath();
  ensureSnapshot(snapshots, main);
  ensureSnapshot(snapshots, file);

  fs.mkdirSync(path.dirname(file), { recursive: true });
  if (!fs.existsSync(file)) fs.writeFileSync(file, monthHeaderForDate(date), "utf8");

  const includeLine = includeLineForTransactionFile(file);
  const mainBefore = fs.readFileSync(main, "utf8");
  const hasInclude = mainBefore.split(/\r?\n/).some((line) => line.trim() === includeLine);
  if (!hasInclude) {
    const separator = mainBefore.endsWith("\n") ? "" : "\n";
    fs.writeFileSync(main, `${mainBefore}${separator}${includeLine}\n`, "utf8");
  }
}

function appendItemsChecked(items: AppendItem[]) {
  const snapshots = new Map<string, FileSnapshot>();
  try {
    const byFile = new Map<string, AppendItem[]>();
    for (const item of items) {
      const file = transactionFileForDate(item.date);
      const existing = byFile.get(file) ?? [];
      existing.push(item);
      byFile.set(file, existing);
    }

    for (const [file, fileItems] of byFile) {
      ensureMonthlyFileAndInclude(file, fileItems[0].date, snapshots);
      const before = fs.readFileSync(file, "utf8");
      const next = fileItems.reduce((content, item) => appendText(content, item.beanText), before);
      fs.writeFileSync(file, next, "utf8");
    }

    runBeanCheck();
  } catch (error) {
    restoreSnapshots(snapshots);
    throw error;
  }
}

export async function appendBeanText(dateOrYear: string | number, beanText: string): Promise<void> {
  const date = typeof dateOrYear === "number" ? `${dateOrYear}-01-01` : dateOrYear;
  await withWriteLock(async () => appendItemsChecked([{ date, beanText }]));
}

export async function appendLedgerEntries(entries: LedgerEntry[]): Promise<string[]> {
  const items = entries.map((entry) => ({
    date: entry.date,
    beanText: entry.kind === "transaction" ? transactionToBean(entry) : balanceToBean(entry),
  }));
  await withWriteLock(async () => appendItemsChecked(items));
  return items.map((item) => item.beanText);
}

function importOutputPath(dateStart: string, dateEnd: string, provider: ImportProvider, suffix?: string) {
  const match = dateStart.match(/^(\d{4})-(\d{2})-\d{2}$/);
  if (!match || !/^\d{4}-\d{2}-\d{2}$/.test(dateEnd)) throw new Error("导入交易缺少有效日期范围");
  const safeSuffix = suffix?.replace(/[^a-zA-Z0-9_-]/g, "").slice(0, 12);
  const basename = `${dateStart}_${dateEnd}-${provider}${safeSuffix ? `-${safeSuffix}` : ""}.bean`;
  return path.join(transactionsDir(), match[1], "imports", basename);
}

function importDocumentPath(dateStart: string, dateEnd: string, provider: ImportProvider, originalFilename: string, suffix?: string) {
  const match = dateStart.match(/^(\d{4})-(\d{2})-\d{2}$/);
  if (!match || !/^\d{4}-\d{2}-\d{2}$/.test(dateEnd)) throw new Error("导入文档缺少有效日期范围");
  const safeSuffix = suffix?.replace(/[^a-zA-Z0-9_-]/g, "").slice(0, 12);
  const ext = path.extname(originalFilename).toLowerCase() || (provider === "wechat" ? ".xlsx" : ".csv");
  const basename = `${dateStart}_${dateEnd}-${provider}${safeSuffix ? `-${safeSuffix}` : ""}${ext}`;
  return path.join(transactionsDir(), match[1], "documents", "imports", basename);
}

function documentDirective(date: string, account: string, outputFile: string, documentFile: string) {
  const relative = path.relative(path.dirname(outputFile), documentFile).split(path.sep).join("/");
  return `${date} document ${account} "${relative}"`;
}

function uniquePath(file: string) {
  if (!fs.existsSync(file)) return file;
  const ext = path.extname(file);
  const base = file.slice(0, -ext.length);
  for (let i = 2; i < 1000; i += 1) {
    const candidate = `${base}-${i}${ext}`;
    if (!fs.existsSync(candidate)) return candidate;
  }
  throw new Error("无法生成不冲突的导入文件名");
}

export async function writeImportedBeanFile(input: { dateStart: string; dateEnd: string; provider: ImportProvider; beanText: string; suffix?: string; documentSource?: ImportDocumentSource }): Promise<{ outputFile: string; includeFile: string; documentFile?: string }> {
  const outputFile = uniquePath(importOutputPath(input.dateStart, input.dateEnd, input.provider, input.suffix));
  const documentFile = input.documentSource ? uniquePath(importDocumentPath(input.dateStart, input.dateEnd, input.provider, input.documentSource.originalFilename, input.suffix)) : undefined;
  const monthFile = transactionFileForDate(input.dateStart);
  const snapshots = new Map<string, FileSnapshot>();

  await withWriteLock(async () => {
    try {
      ensureMonthlyFileAndInclude(monthFile, input.dateStart, snapshots);
      ensureSnapshot(snapshots, monthFile);
      ensureSnapshot(snapshots, outputFile);

      fs.mkdirSync(path.dirname(outputFile), { recursive: true });
      let documentLine = "";
      if (input.documentSource && documentFile) {
        ensureSnapshot(snapshots, documentFile);
        fs.mkdirSync(path.dirname(documentFile), { recursive: true });
        fs.copyFileSync(input.documentSource.file, documentFile);
        documentLine = `${documentDirective(input.dateEnd, input.documentSource.account, outputFile, documentFile)}\n\n`;
      }
      const header = `; ${input.provider === "alipay" ? "Alipay" : "WeChat Pay"} import: ${input.dateStart} .. ${input.dateEnd}\n`;
      fs.writeFileSync(outputFile, `${header}${documentLine}${input.beanText.trimEnd()}\n`, "utf8");

      const includeLine = includeLineRelativeTo(monthFile, outputFile);
      const monthBefore = fs.readFileSync(monthFile, "utf8");
      const hasInclude = monthBefore.split(/\r?\n/).some((line) => line.trim() === includeLine);
      if (!hasInclude) {
        const separator = monthBefore.endsWith("\n") ? "" : "\n";
        fs.writeFileSync(monthFile, `${monthBefore}${separator}${includeLine}\n`, "utf8");
      }

      runBeanCheck();
    } catch (error) {
      restoreSnapshots(snapshots);
      throw error;
    }
  });

  return { outputFile, includeFile: monthFile, documentFile };
}

export async function appendAccount(entry: { date: string; account: string; alias?: string; currency?: "CNY" }): Promise<void> {
  await withWriteLock(async () => {
    const file = accountsBeanPath();
    const before = fs.readFileSync(file, "utf8");
    const separator = before.endsWith("\n") ? "\n" : "\n\n";
    const next = `${before}${separator}${accountToBean(entry).trimEnd()}\n`;
    fs.writeFileSync(file, next, "utf8");
    try {
      runBeanCheck();
    } catch (error) {
      fs.writeFileSync(file, before, "utf8");
      throw error;
    }
  });
}

function editableLedgerFile(file: string) {
  const full = path.resolve(file);
  const root = path.dirname(mainBeanPath());
  if (full !== mainBeanPath() && !full.startsWith(`${root}${path.sep}`)) throw new Error("只能修改当前账本目录内的文件");
  if (!fs.existsSync(full)) throw new Error("找不到交易来源文件");
  return full;
}

function transactionBlock(text: string, line: number) {
  const lines = text.split(/\r?\n/);
  const start = line - 1;
  if (start < 0 || start >= lines.length || !/^\d{4}-\d{2}-\d{2}\s+[*!]\s+/.test(lines[start])) throw new Error("交易来源行无效");
  let end = start + 1;
  while (end < lines.length && !/^\d{4}-\d{2}-\d{2}\s+/.test(lines[end]) && !/^include\s+/.test(lines[end].trim())) end += 1;
  return { lines, start, end };
}

function writeChecked(file: string, before: string, next: string) {
  fs.writeFileSync(file, next, "utf8");
  try {
    runBeanCheck();
  } catch (error) {
    fs.writeFileSync(file, before, "utf8");
    throw error;
  }
}

export async function replaceTransactionBlock(source: { file: string; line: number }, entry: ParsedTransaction): Promise<void> {
  await withWriteLock(async () => {
    const file = editableLedgerFile(source.file);
    const before = fs.readFileSync(file, "utf8");
    const { lines, start, end } = transactionBlock(before, source.line);
    lines.splice(start, end - start, ...transactionToBean(entry).trimEnd().split("\n"));
    writeChecked(file, before, `${lines.join("\n").replace(/\n+$/g, "")}\n`);
  });
}

export async function commentTransactionBlock(source: { file: string; line: number }, reason = ""): Promise<void> {
  await withWriteLock(async () => {
    const file = editableLedgerFile(source.file);
    const before = fs.readFileSync(file, "utf8");
    const { lines, start, end } = transactionBlock(before, source.line);
    const note = reason.trim() ? `: ${escapeBean(reason.trim())}` : "";
    lines.splice(start, end - start, `; deleted ${new Date().toISOString().slice(0, 10)}${note}`, ...lines.slice(start, end).map((line) => `; ${line}`));
    writeChecked(file, before, `${lines.join("\n").replace(/\n+$/g, "")}\n`);
  });
}
