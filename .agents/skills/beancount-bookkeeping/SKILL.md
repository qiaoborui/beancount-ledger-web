---
name: "beancount-bookkeeping"
description: "Parse Chinese natural-language or multi-line expense, income, transfer, repayment, reimbursement, split, and adjustment drafts into Beancount transactions, preview them, and append confirmed entries safely."
globs:
  - "**/*.bean"
  - ".agents/skills/beancount-bookkeeping/scripts/*.py"
  - ".agents/skills/beancount-bookkeeping/references/*.md"
alwaysAllow:
  - "Bash"
---

# Beancount Bookkeeping Skill

Use this skill when the user wants to record, parse, preview, or append bookkeeping entries for a Beancount ledger. Typical trigger phrases include 记账, 记一笔, 消费记录, 多行账单, 收入, 转账, 还款, 报销, write transaction, or record expense.

This skill is owned by the **Beancount Ledger Web application repository**. The private ledger/data repository should contain ledger data only and should not be the source of truth for agent skills.

## Applicability

Use this skill for:

- Natural-language transaction parsing.
- Drafting expenses, income, transfers, repayments, reimbursements, refunds, and split transactions.
- Previewing entries before write.
- Appending confirmed entries through the approved append helper.

Do **not** use this skill for:

- Read-only financial analysis; use `beancount-insights`.
- Alipay/WeChat statement import workflows; use the corresponding bill import skill.
- Telegram reply orchestration; use `telegram-ledger-agent`.
- Bulk maintenance such as account renaming, file reformatting, or git operations.

## Ledger Data Directory

Resolve the ledger root in this order:

1. If `BUB_LEDGER_ROOT` is set, use it.
2. Else if `LEDGER_ROOT` is set, use it.
3. Else, if the user explicitly provides a ledger path, use it only after confirming that it contains `main.bean`.
4. Otherwise, report that the ledger root is not configured.

Do not hardcode private ledger paths in this skill. Do not assume the private data repository contains `.agents/skills`. Do not silently use an example ledger unless the user explicitly asks.

Useful guard:

```bash
LEDGER_ROOT="${BUB_LEDGER_ROOT:-${LEDGER_ROOT:-}}"
if [ -z "$LEDGER_ROOT" ]; then
  echo "Missing BUB_LEDGER_ROOT or LEDGER_ROOT"
  exit 2
fi
test -f "$LEDGER_ROOT/main.bean" || { echo "main.bean not found"; exit 2; }
```

## Packaged Helper Scripts

Prefer the scripts packaged with this skill:

```bash
python3 .agents/skills/beancount-bookkeeping/scripts/bub_query.py accounts
python3 .agents/skills/beancount-bookkeeping/scripts/bub_query.py recent 10
echo '<json>' | python3 .agents/skills/beancount-bookkeeping/scripts/bub_append.py
```

If the agent is running from a deployment where the packaged scripts are unavailable, fall back to the app repository root scripts:

```bash
python3 scripts/bub_query.py accounts
echo '<json>' | python3 scripts/bub_append.py
```

Always pass ledger location through `BUB_LEDGER_ROOT` or `LEDGER_ROOT`, or run from the resolved ledger root when required.

## Core Workflow

1. Treat user text as one or more possible ledger records.
2. Classify each record intent before drafting.
3. Parse each independent expense, income, repayment, reimbursement, refund, transfer, or split transaction into a Beancount transaction draft.
4. Query accounts when needed; do not invent accounts outside the known account set.
5. Always preview parsed entries before writing.
6. If any entry has uncertainty, ask a concise clarification question.
7. Only append after exact explicit approval.
8. Write only through `bub_append.py`, never by directly editing `.bean` files.
9. After writing, report success or validation failure briefly.

## Intent Classification

Classify records into one of these types:

- `expense`: user spent money, expense account positive, payment account negative.
- `income`: user received money, asset account positive, income account negative.
- `transfer`: money moved between two asset/liability accounts.
- `repayment`: user paid back debt or received repayment; clarify direction if ambiguous.
- `reimbursement`: business/personal reimbursement; preserve reimbursable context in metadata or tag.
- `refund`: merchant refund or reversal; usually income-like into payment account plus negative expense or dedicated refund convention.
- `split`: one payment covers multiple categories or people.
- `unknown`: insufficient information; ask one short clarification question.

Do not force uncertain records into expense drafts when direction or account is unclear.

## Date Handling

- Preserve the user's intended date.
- If no date is provided, use today in the user's timezone.
- Use `Asia/Shanghai` for Borui unless a different timezone is explicitly configured.
- Interpret “今天”, “昨天”, “本月”, and similar relative dates in that timezone.
- Include the resolved date in every preview.

## Confirmation Rule

Before writing, show a draft that includes:

- date
- payee
- narration
- metadata if relevant
- tags if relevant
- all postings
- amount signs
- currency

Accepted confirmation phrases:

- `确认写入`
- `确认入账`
- `confirm write`

Do **not** treat casual replies such as “好”, “OK”, “嗯”, “可以”, “对”, “没问题”, or emoji reactions as sufficient confirmation.

If the user changes any detail after a preview, regenerate the draft and ask for confirmation again.

## Multi-entry Rule

A single user message can contain many records, for example:

```text
昨天 星巴克 38 招行信用卡
今天 午餐 56 支付宝
5/8 打车 24 微信
```

Each independent expense, income, repayment, reimbursement, refund, or transfer must become a separate transaction. Do not merge separate purchases into one transaction.

If a single payment intentionally covers multiple categories, represent it as one split transaction only when the user says it is one payment.

## Recommended Preview Format

Reply concisely:

```text
解析到 3 条，还没有写入：

1. 2026-05-08 星巴克 38.00 CNY
   Expenses:Food:Drinks +38.00 CNY
   Liabilities:CN:CMB:CreditCard -38.00 CNY

2. ...

确认无误请回复：确认写入
```

For uncertain entries:

```text
第 2 条需要确认：付款账户不确定，是支付宝还是招行信用卡？
```

## Batch Import / Statement Reconciliation Workflow

When reconciling exported statements, use this source priority:

```text
manual real-time entries
> WeChat / Alipay payment-platform statements
> credit-card statements as supplement and balance check
```

Operational rules:

1. Import and reconcile WeChat/Alipay first because they contain richer merchant details.
2. Run the private ledger helper, e.g. `scripts/dedup_import.py <platform-output.bean> --dry-run`, before folding transactions into monthly ledgers.
3. Ask before replacing manual lump-sum entries with detailed imported rows.
4. For Alipay fund purchases, preserve confirmed 9.99 -> 10.00 fixed investment differences with an explicit income/discount posting; do not silently lose the 0.01.
5. Import credit-card statements after payment platforms. Use `scripts/dedup_import.py <card-output.bean> --credit-card --dry-run` so platform transactions are excluded and date tolerance handles settlement-date drift.
6. Credit-card imports should primarily add direct card transactions and verify statement/app balances, not duplicate WeChat/Alipay details.
7. Never add arbitrary balance adjustments merely to make statement balances fit; trace missing or duplicate real transactions.

## Reading the Ledger

Use the query helper script for structured information:

```bash
python3 .agents/skills/beancount-bookkeeping/scripts/bub_query.py balances
python3 .agents/skills/beancount-bookkeeping/scripts/bub_query.py recent 10
python3 .agents/skills/beancount-bookkeeping/scripts/bub_query.py summary YYYY-MM
python3 .agents/skills/beancount-bookkeeping/scripts/bub_query.py budget YYYY-MM
python3 .agents/skills/beancount-bookkeeping/scripts/bub_query.py accounts
python3 .agents/skills/beancount-bookkeeping/scripts/bub_query.py search "keyword" 20
python3 .agents/skills/beancount-bookkeeping/scripts/bub_query.py check
```

Do not parse large ledger files manually when an existing helper script can answer the question.

## Writing Transactions

Only after preview and exact confirmation, write using:

```bash
echo '<json>' | python3 .agents/skills/beancount-bookkeeping/scripts/bub_append.py
```

The append script handles validation, account whitelist checks, locking, `bean-check`, and rollback. Do not bypass it.

## Entry JSON Schema for Writing

```json
{
  "date": "2026-05-11",
  "payee": "星巴克",
  "narration": "拿铁",
  "tags": ["coffee-weekly"],
  "metadata": {"platform": "meituan", "channel": "online"},
  "postings": [
    {"account": "Liabilities:CN:CMB:CreditCard", "amount": "-38.00", "currency": "CNY"},
    {"account": "Expenses:Food:Drinks", "amount": "38.00", "currency": "CNY"}
  ]
}
```

Rules:

- `date`: `YYYY-MM-DD`. Use today only when not specified.
- `payee`: merchant or counterparty.
- `narration`: brief description.
- `postings`: exactly 2 or more entries that sum to `0.00` per currency.
- `amount`: string decimal with two fractional digits when possible.
- Currency defaults to `CNY` unless explicitly supported otherwise.
- For expenses: the expense account gets a positive amount; the payment account gets a negative amount.
- For income: the receiving account gets a positive amount; the income account gets a negative amount.
- For transfers: source account is negative; destination account is positive.
- For split transactions: one payment posting may balance several expense/income postings.

## Metadata Rules

Account names describe what the money was spent on. Everything else — platform, channel, person, event, purpose — belongs in metadata.

- Do not create new accounts for platforms, people, or events.
- Every transaction should have a `metadata` object. Use `{}` only when there is no extractable context.
- Metadata keys should be lowercase English.

Recommended keys:

- `platform` — app/platform: `taobao`, `pdd`, `jd`, `meituan`, `eleme`, `wechat`, `alipay`, `offline`, `apple`, `google`, `steam`
- `channel` — `online`, `offline`, `transfer`, `subscription`
- `person` — other party involved
- `relationship` — `family`, `friend`, `colleague`
- `event` — event or occasion
- `purpose` — `gift`, `repayment`, `reimbursement`, `refund`
- `review` — additional context

## Tags Rules

Tags are for stable, cross-cutting themes, not high-frequency dimensions.

- Tags are optional; use `[]` when no theme applies.
- Tag format: lowercase alphanumeric with hyphens or underscores, no `#` prefix.
- Good tags: `trip-2026-shanghai`, `moving`, `company-reimbursable`, `wedding`, `renovation`.
- Bad tags: `taobao`, `pdd`, `mom`, `wechat`, `meituan`; use metadata instead.

## Account Selection

Prefer querying actual open accounts with:

```bash
python3 .agents/skills/beancount-bookkeeping/scripts/bub_query.py accounts
```

Use known aliases and the ledger's actual account list. If the account is unclear, ask one short clarification question instead of inventing a new account.

Common account groups:

- Payment accounts: assets, cash, bank, Alipay, WeChat, credit cards, liabilities.
- Expense categories: food, transport, housing, shopping, communication, digital subscriptions, health, entertainment, travel, social, fees, unknown.
- Income accounts: salary, bonus, benefits, interest, rental, reimbursement, side project, other.
- Transfer accounts: savings, funds, receivables, payables, stored-value cards.

Use `Expenses:Unknown` only as a draft placeholder and ask for confirmation before writing.

## Error Handling

If query or append fails:

- Explain the failure briefly and actionably.
- Do not expose tokens, environment dumps, runtime directories, or full private paths.
- If validation fails, state that the entry was not written or was rolled back.
- If an account is unknown, ask the user to choose an existing account or configure it in maintenance mode.
- If postings do not balance, do not patch with `Equity:Balance-Adjustments`; fix the draft or ask for clarification.

Example:

```text
写入失败，账本校验没有通过，已回滚。原因看起来是账户不存在：Expenses:Food:Coffee。请选择一个已有账户后我再重新生成草稿。
```

## Safety Rules

- Never invent accounts outside the ledger account whitelist or known open accounts.
- Never write unbalanced postings.
- Never silently append entries that require review.
- Never write without exact confirmation.
- For unknown categories, use `Expenses:Unknown` only as a draft and ask for confirmation before writing.
- Preserve the user’s intended date. If no date is provided, use today in the user's timezone.
- Use `Asia/Shanghai` for Borui unless a different timezone is explicitly configured.
- Do not delete, move, rewrite, or reformat existing ledger files.
- Do not run git commit, push, or pull as part of bookkeeping.
- Do not expose private absolute ledger paths, tokens, or environment values in final responses.

## References

- Examples: `references/examples.md`
- Web API contract: `references/web-api.md`
