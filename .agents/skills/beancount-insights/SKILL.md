---
name: "Beancount Insights"
description: "Analyze Beancount ledger data for monthly summaries, budget explanations, spending trends, and anomaly review using safe read-only workflows."
globs:
  - "**/*.bean"
  - "scripts/bub_query.py"
  - "scripts/budget_report.py"
  - "scripts/check_date_order.py"
alwaysAllow:
  - "Bash"
---

# Beancount Insights Skill

Use this skill when the user asks for financial insight from a Beancount ledger: summaries, budgets, trends, category explanations, unusual spending, or comparisons across periods.

This skill is **read-mostly and analysis-focused**. It must not directly modify ledger files.

## Core Principles

1. **Prefer project helper scripts over direct parsing.**
   - Use `scripts/bub_query.py` for common read-only queries.
   - Use `scripts/budget_report.py` for detailed budget reports when available.
   - Use `scripts/check_date_order.py` only for ordering checks.
2. **Do not hardcode private paths.**
   - Ledger paths must come from `BUB_LEDGER_ROOT`, `LEDGER_ROOT`, or explicit user-provided configuration.
   - If no ledger path is configured, report a configuration error instead of guessing.
3. **Do not write ledger data.**
   - Do not edit, move, delete, append, or reformat `.bean` files.
   - Do not run `git commit`, `git push`, or destructive maintenance tasks.
4. **Protect privacy.**
   - Do not expose absolute private ledger paths in final user-visible messages.
   - Do not dump full transaction history unless the user explicitly asks.
   - Summarize sensitive outputs and show only the relevant details.

## Supported User Intents

Handle requests such as:

- “这个月花了多少？” / “How much did I spend this month?”
- “预算执行怎么样？” / “How is my budget doing?”
- “根据历史消费帮我制定预算。” / “Help me design a budget from recent spending.”
- “预算不用太细，给我几个大类就行。”
- “为什么餐饮支出这么高？”
- “找一下星巴克的消费。”
- “最近有什么异常支出？”
- “本月和上月比有什么变化？”
- “检查账本有没有错误。”

## Date Handling

- Interpret relative dates using the user's configured timezone when available; for Borui, use `Asia/Shanghai`.
- “本月 / this month” should become `YYYY-MM`.
- “上月 / last month” should become the previous calendar month.
- If a requested period is ambiguous, ask a short clarifying question.

## Read-Only Command Recipes

Run commands from the app repository root when possible.

### Monthly Summary

```bash
python3 scripts/bub_query.py summary YYYY-MM
```

### Budget Report

```bash
python3 scripts/bub_query.py budget YYYY-MM
```

For a more detailed report if the script is available and compatible:

```bash
python3 scripts/budget_report.py YYYY-MM --ledger "$LEDGER_ROOT/main.bean"
```

### Recent Transactions

```bash
python3 scripts/bub_query.py recent 10
python3 scripts/bub_query.py recent 20 Expenses:Food
```

### Search Transactions

```bash
python3 scripts/bub_query.py search "keyword" 20
```

### Accounts

```bash
python3 scripts/bub_query.py accounts
```

### Ledger Check

```bash
python3 scripts/bub_query.py check
```

## Environment Guard

Before running ledger commands, make sure a ledger root is configured.

Preferred logic:

```bash
if [ -z "${BUB_LEDGER_ROOT:-${LEDGER_ROOT:-}}" ]; then
  echo "Missing BUB_LEDGER_ROOT or LEDGER_ROOT"
  exit 2
fi
```

Do **not** silently rely on a default test ledger unless the user explicitly asks to use the example ledger.

## Analysis Workflow

For insight questions:

1. Identify the target period, usually a month.
2. Gather summary and budget data first.
3. If the user asks “why”, gather relevant recent or searched transactions.
4. Compare with prior period only when useful and feasible.
5. Produce a concise explanation with numbers, likely drivers, and optional next steps.

## Budget Planning Workflow

Use this workflow when the user wants help designing a budget, especially if the current budget system is not formally enabled yet.

### Assumptions

- Treat budget planning as a collaborative proposal, not a finalized ledger write.
- Do not assume existing `custom "budget"` directives are authoritative unless the user says they are active.
- If the user says the budget system is not ready, explicitly frame the output as a **draft monthly budget plan**.
- Keep categories coarse. Do not split the budget too finely.

### Historical Data Window

Prefer recent historical spending rather than one isolated month:

1. Use the latest 3–6 complete months when available.
2. Exclude the current partial month from baseline calculations unless the user asks to include it.
3. If fewer than 3 months are available, explain the limitation and still provide a tentative plan.
4. For abnormal one-off expenses, call them out separately instead of baking them directly into the recurring budget.

### Coarse Budget Categories

Start with broad categories such as:

- Food & Dining
- Transport
- Housing / Rent / Utilities
- Shopping / Personal
- Health
- Entertainment / Subscriptions
- Travel
- Family / Gifts
- Other Flexible Spending
- Savings / Buffer

Map these to the user’s existing Beancount expense accounts when possible, but do not invent detailed account structures. If account mappings are unclear, show the proposed category and ask for confirmation.

### Suggested Method

For each broad category:

1. Estimate the historical monthly average.
2. Compare it to the recent high/low range.
3. Suggest a rounded monthly budget number.
4. Explain whether the suggestion is conservative, normal, or aggressive.
5. Separate fixed costs from flexible spending when possible.

Recommended budget formula:

```text
suggested budget = rounded recent average + small buffer
```

Adjust manually for:

- predictable fixed costs
- one-off purchases
- seasonal travel or holidays
- categories the user wants to intentionally reduce
- categories the user wants to protect, such as health or learning

### Output Format

Keep the output practical and not too detailed:

```text
这是一个基于最近 3–6 个月消费的粗粒度月预算草案，还没有写入账本：

建议总预算：8,500 CNY / 月

大类建议：
- 餐饮：2,000 CNY（历史均值约 1,850，留一点缓冲）
- 交通：800 CNY（比较稳定）
- 购物/个人：1,500 CNY（波动较大，建议先设软上限）
- 娱乐/订阅：500 CNY
- 其他弹性支出：1,000 CNY
- 缓冲/储蓄：2,700 CNY

我建议先运行 1–2 个月，不要一开始分太细。你可以告诉我想控制哪一类，我再帮你调。
```

### What Not To Do

- Do not create or edit `custom "budget"` directives automatically.
- Do not split every Beancount account into its own budget category by default.
- Do not present the plan as final or enforced.
- Do not ignore the user’s lifestyle preferences just because historical averages suggest a lower number.

## Output Style

Use clear, compact summaries:

- Start with the answer.
- Include 3–8 bullets when helpful.
- Highlight income, expense, balance, budget usage, and over-budget categories.
- Avoid large tables in chat-style output.
- For Telegram-facing responses, keep the result short and mobile-friendly.

Example:

```text
5 月目前支出 3,420.50 CNY，主要集中在：

- 餐饮：1,240.00 CNY，约占 36%
- 交通：520.00 CNY
- 购物：880.50 CNY

餐饮偏高主要来自 6 笔外食和 3 笔咖啡消费。要不要我继续列出最大的 5 笔？
```

## Error Handling

If a command fails:

- Explain the error briefly.
- Do not expose tokens, env vars, or full private paths.
- If `bean-check` fails, summarize that the ledger has validation errors and include only the relevant error excerpt.
- If the ledger path is missing, ask the user to configure `BUB_LEDGER_ROOT` or `LEDGER_ROOT`.

## Hard Prohibitions

Never do the following under this skill:

- Directly edit `.bean` files.
- Append transactions.
- Auto-fix balances.
- Rename accounts.
- Reorder transaction files.
- Run destructive shell commands.
- Commit or push ledger changes.
