import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { accountsBeanPath, mainBeanPath, transactionFileForYear, transactionsDir } from "./ledgerPaths";
import type { BalanceAssertion, MetadataValue, ParsedTransaction } from "./schemas";

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

export async function appendBeanText(year: number, beanText: string): Promise<void> {
  await withWriteLock(async () => {
    fs.mkdirSync(transactionsDir(), { recursive: true });
    const file = transactionFileForYear(year);
    const before = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
    const separator = before.endsWith("\n") ? "\n" : "\n\n";
    const next = `${before}${separator}${beanText.trimEnd()}\n`;
    fs.writeFileSync(file, next, "utf8");
    try {
      runBeanCheck();
    } catch (error) {
      fs.writeFileSync(file, before, "utf8");
      throw error;
    }
  });
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
