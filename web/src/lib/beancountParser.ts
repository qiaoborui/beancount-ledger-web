import fs from "node:fs";
import path from "node:path";
import { accountsBeanPath, mainBeanPath } from "./ledgerPaths";
import { cents, monthRange } from "./money";

export type BeanLine = { file: string; line: number; text: string };
export type PostingView = { account: string; amount: number; currency: "CNY" };
export type MetadataValue = string | number | boolean;
export type TransactionView = {
  date: string;
  payee: string;
  narration: string;
  metadata: Record<string, MetadataValue>;
  tags: string[];
  postings: PostingView[];
  source: { file: string; line: number };
};
export type BalanceAssertionView = { date: string; account: string; amount: number; currency: "CNY" };
export type BudgetView = { date: string; account: string; amount: number; currency: "CNY" };
export type IncomeStatementNode = { account: string; label: string; amount: number; children: IncomeStatementNode[]; depth: number; txCount: number };
export type AccountGroup = "cash" | "credit" | "wealth" | "receivable" | "expense" | "income" | "equity" | "other";
export type AccountView = { account: string; openDate: string; closeDate: string | null; currency: "CNY"; alias: string | null; label: string; group: AccountGroup; active: boolean };
export type AccountStatus = {
  account: string;
  status: "green" | "red" | "yellow" | "grey";
  lastEntryDate: string | null;
  lastEntryType: "balance" | "transaction" | null;
  assertionAmount: number | null;
  computedBalance: number | null;
};

export type AccountDetailRow = {
  date: string;
  payee: string;
  narration: string;
  change: number;
  balance: number;
  txn: TransactionView;
};

const includeRe = /^include\s+"([^"]+)"\s*$/;
const txnRe = /^(\d{4}-\d{2}-\d{2})\s+[*!]\s+"([^"]*)"\s+"([^"]*)"(.*)$/;
const postingRe = /^\s+([A-Z][A-Za-z0-9-:]+)\s+(-?\d+(?:\.\d+)?)\s+(CNY)\b/;
const metadataRe = /^\s+([a-z][a-zA-Z0-9_-]*):\s+(.+)$/;
const balanceRe = /^(\d{4}-\d{2}-\d{2})\s+balance\s+([A-Z][A-Za-z0-9-:]+)\s+(-?\d+(?:\.\d+)?)\s+(CNY)\b/;
const budgetRe = /^(\d{4}-\d{2}-\d{2})\s+custom\s+"budget"\s+(Expenses(?::[A-Za-z0-9-]+)+)\s+"monthly"\s+(-?\d+(?:\.\d+)?)\s+(CNY)\b/;
const openRe = /^(\d{4}-\d{2}-\d{2})\s+open\s+([A-Z][A-Za-z0-9-:]+)\s+(CNY)\b/;
const closeRe = /^(\d{4}-\d{2}-\d{2})\s+close\s+([A-Z][A-Za-z0-9-:]+)\b/;
const aliasRe = /^\s+alias:\s+"([^"]+)"\s*$/;

export function readLedgerLines(entry = mainBeanPath(), seen = new Set<string>()): BeanLine[] {
  const full = path.resolve(entry);
  if (seen.has(full)) return [];
  seen.add(full);
  const dir = path.dirname(full);
  const text = fs.readFileSync(full, "utf8");
  const out: BeanLine[] = [];
  text.split(/\r?\n/).forEach((line, index) => {
    const trimmed = line.trim();
    const include = trimmed.match(includeRe);
    if (include) {
      out.push(...readLedgerLines(path.join(dir, include[1]), seen));
      return;
    }
    out.push({ file: full, line: index + 1, text: line });
  });
  return out;
}

export function parseTransactions(lines = readLedgerLines()): TransactionView[] {
  const txns: TransactionView[] = [];
  let current: TransactionView | null = null;

  for (const line of lines) {
    const trimmed = line.text.trim();
    if (!trimmed || trimmed.startsWith(";")) continue;

    const txn = line.text.match(txnRe);
    if (txn) {
      current = {
        date: txn[1],
        payee: txn[2],
        narration: txn[3],
        metadata: {},
        tags: Array.from(txn[4].matchAll(/#([A-Za-z0-9_-]+)/g)).map((match) => match[1]),
        postings: [],
        source: { file: line.file, line: line.line },
      };
      txns.push(current);
      continue;
    }

    if (/^\d{4}-\d{2}-\d{2}\s+/.test(line.text)) {
      current = null;
      continue;
    }

    if (!current) continue;
    const metadata = line.text.match(metadataRe);
    if (metadata) {
      current.metadata[metadata[1]] = parseMetadataValue(metadata[2]);
      continue;
    }
    const posting = line.text.match(postingRe);
    if (!posting) continue;
    current.postings.push({ account: posting[1], amount: cents(posting[2]), currency: "CNY" });
  }

  return txns;
}

function parseMetadataValue(raw: string): MetadataValue {
  const value = raw.trim();
  const quoted = value.match(/^"(.*)"$/);
  if (quoted) return quoted[1].replace(/\\"/g, '"').replace(/\\\\/g, "\\");
  if (value === "TRUE") return true;
  if (value === "FALSE") return false;
  const n = Number(value);
  if (Number.isFinite(n)) return n;
  return value;
}

export function parseBalances(lines = readLedgerLines()): BalanceAssertionView[] {
  return lines.flatMap((line) => {
    const match = line.text.trim().match(balanceRe);
    if (!match) return [];
    return [{ date: match[1], account: match[2], amount: cents(match[3]), currency: "CNY" as const }];
  });
}

export function parseBudgets(lines = readLedgerLines()): BudgetView[] {
  return lines.flatMap((line) => {
    const match = line.text.trim().match(budgetRe);
    if (!match) return [];
    return [{ date: match[1], account: match[2], amount: cents(match[3]), currency: "CNY" as const }];
  });
}

export function accountGroup(account: string): AccountGroup {
  if (account.startsWith("Expenses:")) return "expense";
  if (account.startsWith("Income:")) return "income";
  if (account.startsWith("Equity:")) return "equity";
  if (account.startsWith("Assets:Receivable") || account.startsWith("Liabilities:Payable")) return "receivable";
  if (account.startsWith("Liabilities:")) return "credit";
  if (account.includes(":Wealth") || account.includes(":Fund") || account.includes(":Stock") || account.includes(":Bond") || account.includes(":HousingFund") || account.includes(":Insurance")) return "wealth";
  if (account.startsWith("Assets:")) return "cash";
  return "other";
}

export function parseAccounts(): AccountView[] {
  const text = fs.readFileSync(accountsBeanPath(), "utf8");
  const accounts = new Map<string, AccountView>();
  let current: string | null = null;

  for (const line of text.split(/\r?\n/)) {
    const open = line.match(openRe);
    if (open) {
      const account = open[2];
      accounts.set(account, { account, openDate: open[1], closeDate: null, currency: "CNY", alias: null, label: account, group: accountGroup(account), active: true });
      current = account;
      continue;
    }

    const close = line.match(closeRe);
    if (close) {
      const account = accounts.get(close[2]);
      if (account) {
        account.closeDate = close[1];
        account.active = false;
      }
      current = null;
      continue;
    }

    const alias = line.match(aliasRe);
    if (alias && current) {
      const account = accounts.get(current);
      if (account) {
        account.alias = alias[1];
        account.label = alias[1].split("/")[0].trim() || current;
      }
      continue;
    }

    if (line.trim() && !line.startsWith(" ")) current = null;
  }

  return Array.from(accounts.values()).sort((a, b) => a.account.localeCompare(b.account));
}

export function currentBalances(txns = parseTransactions()): Record<string, number> {
  const balances: Record<string, number> = {};
  for (const txn of txns) {
    for (const posting of txn.postings) {
      balances[posting.account] = (balances[posting.account] ?? 0) + posting.amount;
    }
  }
  return balances;
}

/** 按日期范围汇总收入/支出，支持两种调用方式：
 *  - monthSummary(month: string, txns?) — 向后兼容
 *  - monthSummary(start: string, end: string, txns?) — 新版
 */
export function monthSummary(
  startOrMonth: string,
  endOrTxns: string | TransactionView[],
  maybeTxns?: TransactionView[],
) {
  let start: string, end: string, txns: TransactionView[];
  if (Array.isArray(endOrTxns)) {
    // Old: monthSummary(month, txns)
    ({ start, end } = monthRange(startOrMonth));
    txns = endOrTxns;
  } else {
    // New: monthSummary(start, end, txns?)
    start = startOrMonth;
    end = endOrTxns;
    txns = maybeTxns ?? parseTransactions();
  }

  let income = 0;
  let expense = 0;
  const days: Record<string, { income: number; expense: number }> = {};
  const categories: Record<string, number> = {};

  for (const txn of txns) {
    if (txn.date < start || txn.date >= end) continue;
    for (const posting of txn.postings) {
      if (posting.account.startsWith("Income:")) income += Math.abs(posting.amount);
      if (posting.account.startsWith("Expenses:")) {
        expense += posting.amount;
        categories[posting.account] = (categories[posting.account] ?? 0) + posting.amount;
      }
    }
    const day = txn.date.slice(8, 10);
    days[day] ??= { income: 0, expense: 0 };
    for (const posting of txn.postings) {
      if (posting.account.startsWith("Income:")) days[day].income += Math.abs(posting.amount);
      if (posting.account.startsWith("Expenses:")) days[day].expense += posting.amount;
    }
  }

  return { income, expense, net: income - expense, days, categories };
}

/** 按日期范围生成损益树，支持两种调用方式：
 *  - incomeStatementTree(month: string, txns?) — 向后兼容
 *  - incomeStatementTree(start: string, end: string, txns?) — 新版
 */
export function incomeStatementTree(
  startOrMonth: string,
  endOrTxns: string | TransactionView[],
  maybeTxns?: TransactionView[],
): { income: IncomeStatementNode[]; expense: IncomeStatementNode[]; totalIncome: number; totalExpense: number; netIncome: number } {
  let start: string, end: string, txns: TransactionView[];
  if (Array.isArray(endOrTxns)) {
    ({ start, end } = monthRange(startOrMonth));
    txns = endOrTxns;
  } else {
    start = startOrMonth;
    end = endOrTxns;
    txns = maybeTxns ?? parseTransactions();
  }

  const incomeMap = new Map<string, { amount: number; txns: Set<string> }>();
  const expenseMap = new Map<string, { amount: number; txns: Set<string> }>();

  for (const txn of txns) {
    if (txn.date < start || txn.date >= end) continue;
    const txnId = `${txn.source.file}:${txn.source.line}`;
    for (const posting of txn.postings) {
      if (posting.account.startsWith("Income:")) {
        const entry = incomeMap.get(posting.account) ?? { amount: 0, txns: new Set() };
        entry.amount += Math.abs(posting.amount);
        entry.txns.add(txnId);
        incomeMap.set(posting.account, entry);
      }
      if (posting.account.startsWith("Expenses:")) {
        const entry = expenseMap.get(posting.account) ?? { amount: 0, txns: new Set() };
        entry.amount += posting.amount;
        entry.txns.add(txnId);
        expenseMap.set(posting.account, entry);
      }
    }
  }

  function buildTree(root: string, map: Map<string, { amount: number; txns: Set<string> }>): IncomeStatementNode[] {
    const prefix = root ? `${root}:` : "";
    const directChildren = new Map<string, { amount: number; children: IncomeStatementNode[]; txns: Set<string> }>();

    for (const [account, data] of map) {
      if (!account.startsWith(prefix)) continue;
      const rest = account.slice(prefix.length);
      const nextColon = rest.indexOf(":");
      const childKey = nextColon === -1 ? rest : rest.slice(0, nextColon);
      const childFull = prefix ? `${root}:${childKey}` : childKey;

      let node = directChildren.get(childFull);
      if (!node) { node = { amount: 0, children: [], txns: new Set() }; directChildren.set(childFull, node); }

      if (nextColon === -1) {
        // Leaf node
        node.amount += data.amount;
        for (const id of data.txns) node.txns.add(id);
      } else {
        // Intermediate node — the amount will be summed from children below
        for (const id of data.txns) node.txns.add(id);
      }
    }

    // Recursively build children
    const result: IncomeStatementNode[] = [];
    for (const [fullAccount, node] of directChildren) {
      const children = buildTree(fullAccount, map);
      const childrenAmount = children.reduce((s, c) => s + c.amount, 0);
      const childrenTxCount = children.reduce((s, c) => s + c.txCount, 0);
      const totalAmount = node.amount + childrenAmount;
      const totalTxCount = node.txns.size + childrenTxCount;
      const depth = fullAccount.split(":").length - 2;

      result.push({
        account: fullAccount,
        label: fullAccount.split(":").pop() ?? fullAccount,
        amount: totalAmount || node.amount,
        children: children.sort((a, b) => b.amount - a.amount),
        depth,
        txCount: totalTxCount || node.txns.size,
      });
    }

    return result.sort((a, b) => b.amount - a.amount);
  }

  const income = buildTree("Income", incomeMap);
  const expense = buildTree("Expenses", expenseMap);
  const totalIncome = income.reduce((s, n) => s + n.amount, 0);
  const totalExpense = expense.reduce((s, n) => s + n.amount, 0);

  return { income, expense, totalIncome, totalExpense, netIncome: totalIncome - totalExpense };
}

export function netWorthHistory(txns = parseTransactions()) {
  const sorted = [...txns].sort((a, b) => a.date.localeCompare(b.date));
  const balances: Record<string, number> = {};
  const rows: { date: string; assets: number; liabilities: number; netWorth: number }[] = [];
  let lastDate = "";

  for (const txn of sorted) {
    for (const posting of txn.postings) {
      balances[posting.account] = (balances[posting.account] ?? 0) + posting.amount;
    }
    if (txn.date === lastDate && rows.length) rows.pop();
    const assets = Object.entries(balances)
      .filter(([account]) => account.startsWith("Assets:"))
      .reduce((sum, [, amount]) => sum + amount, 0);
    const liabilities = Object.entries(balances)
      .filter(([account]) => account.startsWith("Liabilities:"))
      .reduce((sum, [, amount]) => sum + Math.abs(amount), 0);
    rows.push({ date: txn.date, assets, liabilities, netWorth: assets - liabilities });
    lastDate = txn.date;
  }

  return rows;
}

// ── Account Detail (per-account running balance) ──

/**
 * 计算单个账户的变动明细，按日期排序，带 running balance。
 * 返回该账户涉及的每一笔交易，以及交易后该账户的余额。
 */
export function accountDetail(
  account: string,
  txns: TransactionView[] = parseTransactions(),
): AccountDetailRow[] {
  // 筛选出涉及目标账户的交易
  const relevant: { txn: TransactionView; change: number }[] = [];
  for (const txn of txns) {
    for (const posting of txn.postings) {
      if (posting.account === account) {
        relevant.push({ txn, change: posting.amount });
        break; // 每笔交易只取第一条匹配的 posting
      }
    }
  }

  // 按日期 + 源位置排序（确保确定性）
  relevant.sort((a, b) => {
    const dateCmp = a.txn.date.localeCompare(b.txn.date);
    if (dateCmp !== 0) return dateCmp;
    return a.txn.source.line - b.txn.source.line;
  });

  // 计算 running balance
  let balance = 0;
  return relevant.map(({ txn, change }) => {
    balance += change;
    return { date: txn.date, payee: txn.payee, narration: txn.narration, change, balance, txn };
  });
}

// ── Account Status Indicators ──

function computeBalanceBefore(account: string, txns: TransactionView[], dateStr: string): number {
  let balance = 0;
  for (const txn of txns) {
    if (txn.date < dateStr) {
      for (const posting of txn.postings) {
        if (posting.account === account) {
          balance += posting.amount;
        }
      }
    }
  }
  return balance;
}

/**
 * 计算每个活跃的非 Expenses/Income/Equity 账户的对账状态指示。
 *
 * - green: 最近记录是 balance 断言，且断言金额与账本余额一致
 * - red:   最近记录是 balance 断言，但断言金额与账本余额不一致
 * - yellow: 最近记录是交易 posting，没有 balance 断言
 * - grey:  没有记录，或最近记录超过 staleDays 天
 */
export function accountStatusIndicators(
  txns: TransactionView[] = parseTransactions(),
  assertions: BalanceAssertionView[] = parseBalances(),
  accounts: AccountView[] = parseAccounts(),
  staleDays: number = 60,
): AccountStatus[] {
  const targetAccounts = accounts.filter(
    (a) =>
      a.active &&
      (a.account.startsWith("Assets:") || a.account.startsWith("Liabilities:")),
  );

  const today = new Date();
  const staleCutoff = new Date(today);
  staleCutoff.setDate(staleCutoff.getDate() - staleDays);
  const staleCutoffStr = staleCutoff.toISOString().slice(0, 10);

  return targetAccounts.map((acct) => {
    const accountName = acct.account;

    // 该账户的所有 balance 断言，按日期降序
    const accountAssertions = assertions
      .filter((a) => a.account === accountName)
      .sort((a, b) => b.date.localeCompare(a.date));

    // 该账户涉及的所有交易 posting，按日期降序
    const txnEntries: { date: string }[] = [];
    for (const txn of txns) {
      for (const posting of txn.postings) {
        if (posting.account === accountName) {
          txnEntries.push({ date: txn.date });
        }
      }
    }
    txnEntries.sort((a, b) => b.date.localeCompare(a.date));

    const lastAssertion = accountAssertions[0] ?? null;
    const lastTxn = txnEntries[0] ?? null;

    // 确定最近一条记录
    let lastEntryDate: string | null = null;
    let lastEntryType: "balance" | "transaction" | null = null;

    if (lastAssertion && lastTxn) {
      if (lastAssertion.date >= lastTxn.date) {
        lastEntryDate = lastAssertion.date;
        lastEntryType = "balance";
      } else {
        lastEntryDate = lastTxn.date;
        lastEntryType = "transaction";
      }
    } else if (lastAssertion) {
      lastEntryDate = lastAssertion.date;
      lastEntryType = "balance";
    } else if (lastTxn) {
      lastEntryDate = lastTxn.date;
      lastEntryType = "transaction";
    }

    // 没有任何记录 → 灰色
    if (!lastEntryDate) {
      return {
        account: accountName,
        status: "grey",
        lastEntryDate: null,
        lastEntryType: null,
        assertionAmount: null,
        computedBalance: null,
      };
    }

    // 超过 staleDays → 灰色（覆盖前面的状态）
    if (lastEntryDate < staleCutoffStr) {
      return {
        account: accountName,
        status: "grey",
        lastEntryDate,
        lastEntryType,
        assertionAmount: lastAssertion?.amount ?? null,
        computedBalance: null,
      };
    }

    // 最近是 balance 断言 → 比较断言金额与账本余额
    if (lastEntryType === "balance" && lastAssertion) {
      const computedBalance = computeBalanceBefore(accountName, txns, lastAssertion.date);
      const passes = computedBalance === lastAssertion.amount;

      return {
        account: accountName,
        status: passes ? "green" : "red",
        lastEntryDate,
        lastEntryType: "balance",
        assertionAmount: lastAssertion.amount,
        computedBalance,
      };
    }

    // 最近是交易 posting → 黄色
    return {
      account: accountName,
      status: "yellow",
      lastEntryDate,
      lastEntryType: "transaction",
      assertionAmount: null,
      computedBalance: null,
    };
  });
}
