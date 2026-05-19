import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { accountsBeanPathForUser, mainBeanPathForUser, transactionFileForDateForUser } from "./ledgerPaths";
import type { BalanceAssertion, LedgerEntry, MetadataValue, ParsedTransaction } from "./schemas";

const writeQueues = new Map<string, Promise<unknown>>();

function withWriteLock<T>(userId: string, fn: () => Promise<T>): Promise<T> {
  const queue = writeQueues.get(userId) ?? Promise.resolve();
  const next = queue.then(fn, fn);
  writeQueues.set(userId, next.catch(() => undefined));
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

function runBeanCheckForUser(userId: string) {
  const main = mainBeanPathForUser(userId);
  const envPath = [
    process.env.PATH,
    path.join(process.env.HOME || "", ".local", "bin"),
    "/opt/homebrew/bin",
    "/usr/local/bin",
  ].filter(Boolean).join(path.delimiter);

  try {
    execFileSync(beanCheckCommand(), [main], {
      cwd: path.dirname(main),
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

function includeLineForTransactionFile(userId: string, file: string) {
  const relative = path.relative(path.dirname(mainBeanPathForUser(userId)), file).split(path.sep).join("/");
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

function ensureMonthlyFileAndInclude(userId: string, file: string, date: string, snapshots: Map<string, FileSnapshot>) {
  const main = mainBeanPathForUser(userId);
  ensureSnapshot(snapshots, main);
  ensureSnapshot(snapshots, file);

  fs.mkdirSync(path.dirname(file), { recursive: true });
  if (!fs.existsSync(file)) fs.writeFileSync(file, monthHeaderForDate(date), "utf8");

  const includeLine = includeLineForTransactionFile(userId, file);
  const mainBefore = fs.readFileSync(main, "utf8");
  const hasInclude = mainBefore.split(/\r?\n/).some((line) => line.trim() === includeLine);
  if (!hasInclude) {
    const separator = mainBefore.endsWith("\n") ? "" : "\n";
    fs.writeFileSync(main, `${mainBefore}${separator}${includeLine}\n`, "utf8");
  }
}

function appendItemsCheckedForUser(userId: string, items: AppendItem[]) {
  const snapshots = new Map<string, FileSnapshot>();
  try {
    const byFile = new Map<string, AppendItem[]>();
    for (const item of items) {
      const file = transactionFileForDateForUser(userId, item.date);
      const existing = byFile.get(file) ?? [];
      existing.push(item);
      byFile.set(file, existing);
    }

    for (const [file, fileItems] of byFile) {
      ensureMonthlyFileAndInclude(userId, file, fileItems[0].date, snapshots);
      const before = fs.readFileSync(file, "utf8");
      const next = fileItems.reduce((content, item) => appendText(content, item.beanText), before);
      fs.writeFileSync(file, next, "utf8");
    }

    runBeanCheckForUser(userId);
  } catch (error) {
    restoreSnapshots(snapshots);
    throw error;
  }
}

export async function appendBeanTextForUser(userId: string, dateOrYear: string | number, beanText: string): Promise<void> {
  const date = typeof dateOrYear === "number" ? `${dateOrYear}-01-01` : dateOrYear;
  await withWriteLock(userId, async () => appendItemsCheckedForUser(userId, [{ date, beanText }]));
}

export async function appendBeanText(dateOrYear: string | number, beanText: string): Promise<void> {
  return appendBeanTextForUser("owner", dateOrYear, beanText);
}

export async function appendLedgerEntriesForUser(userId: string, entries: LedgerEntry[]): Promise<string[]> {
  const items = entries.map((entry) => ({
    date: entry.date,
    beanText: entry.kind === "transaction" ? transactionToBean(entry) : balanceToBean(entry),
  }));
  await withWriteLock(userId, async () => appendItemsCheckedForUser(userId, items));
  return items.map((item) => item.beanText);
}

export async function appendLedgerEntries(entries: LedgerEntry[]): Promise<string[]> {
  return appendLedgerEntriesForUser("owner", entries);
}

export async function appendAccountForUser(userId: string, entry: { date: string; account: string; alias?: string; currency?: "CNY" }): Promise<void> {
  await withWriteLock(userId, async () => {
    const file = accountsBeanPathForUser(userId);
    const before = fs.readFileSync(file, "utf8");
    const separator = before.endsWith("\n") ? "\n" : "\n\n";
    const next = `${before}${separator}${accountToBean(entry).trimEnd()}\n`;
    fs.writeFileSync(file, next, "utf8");
    try {
      runBeanCheckForUser(userId);
    } catch (error) {
      fs.writeFileSync(file, before, "utf8");
      throw error;
    }
  });
}

export async function appendAccount(entry: { date: string; account: string; alias?: string; currency?: "CNY" }): Promise<void> {
  return appendAccountForUser("owner", entry);
}

function editableLedgerFileForUser(userId: string, file: string) {
  const full = path.resolve(file);
  const root = path.dirname(mainBeanPathForUser(userId));
  if (full !== mainBeanPathForUser(userId) && !full.startsWith(`${root}${path.sep}`)) throw new Error("只能修改当前账本目录内的文件");
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

function writeCheckedForUser(userId: string, file: string, before: string, next: string) {
  fs.writeFileSync(file, next, "utf8");
  try {
    runBeanCheckForUser(userId);
  } catch (error) {
    fs.writeFileSync(file, before, "utf8");
    throw error;
  }
}

export async function replaceTransactionBlockForUser(userId: string, source: { file: string; line: number }, entry: ParsedTransaction): Promise<void> {
  await withWriteLock(userId, async () => {
    const file = editableLedgerFileForUser(userId, source.file);
    const before = fs.readFileSync(file, "utf8");
    const { lines, start, end } = transactionBlock(before, source.line);
    lines.splice(start, end - start, ...transactionToBean(entry).trimEnd().split("\n"));
    writeCheckedForUser(userId, file, before, `${lines.join("\n").replace(/\n+$/g, "")}\n`);
  });
}

export async function replaceTransactionBlock(source: { file: string; line: number }, entry: ParsedTransaction): Promise<void> {
  return replaceTransactionBlockForUser("owner", source, entry);
}

export async function commentTransactionBlockForUser(userId: string, source: { file: string; line: number }, reason = ""): Promise<void> {
  await withWriteLock(userId, async () => {
    const file = editableLedgerFileForUser(userId, source.file);
    const before = fs.readFileSync(file, "utf8");
    const { lines, start, end } = transactionBlock(before, source.line);
    const note = reason.trim() ? `: ${escapeBean(reason.trim())}` : "";
    lines.splice(start, end - start, `; deleted ${new Date().toISOString().slice(0, 10)}${note}`, ...lines.slice(start, end).map((line) => `; ${line}`));
    writeCheckedForUser(userId, file, before, `${lines.join("\n").replace(/\n+$/g, "")}\n`);
  });
}

export async function commentTransactionBlock(source: { file: string; line: number }, reason = ""): Promise<void> {
  return commentTransactionBlockForUser("owner", source, reason);
}
