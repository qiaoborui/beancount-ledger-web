# Ledger layout

The app expects `LEDGER_ROOT` to point to a Beancount ledger directory.

Minimum structure:

```text
main.bean
accounts.bean
commodities.bean
prices.bean
transactions/
```

Example `main.bean`:

```beancount
option "title" "My Beancount Ledger"
option "operating_currency" "CNY"
option "booking_method" "FIFO"

include "commodities.bean"
include "accounts.bean"
include "prices.bean"
include "transactions/2026.bean"
```

Accounts are loaded from `accounts.bean`. AI-generated entries are validated against active accounts from this file.

Transactions can be organized however you prefer as long as they are included from `main.bean`. New Web writes append to `transactions/YYYY/MM.bean`; importing a statement also links its generated `.bean` file from that month.

## Agent skills

The iOS assistant loads instructions on demand, so only their names and one-line descriptions are in its prompt. It writes and edits them like any other ledger file, which means a skill is shared through Git with the user's other devices:

```text
skills/october-close/SKILL.md
```

A `SKILL.md` starts with frontmatter and is followed by Markdown steps:

```markdown
---
name: october-close
description: 月底对账，先补空白再对上账单
---

1. 先看这个月有没有空白天。
2. 再用上传的账单对账。
```

The name is lowercase letters, digits and hyphens and replaces a built-in skill of the same name. Steps should only use the assistant's own tools (file tools, `bean_check`, `reconcile_attachment`, `archive_statement`); a ledger has no shell or network for it to call.

## Categories and tags

Use expense accounts to describe what was purchased, and Beancount tags to describe the context or event. For example, a train ticket and hotel stay keep their specific categories while sharing trip tags:

```beancount
2026-02-10 * "Railway" "Train ticket" #travel #trip-2026-hokkaido
  Expenses:Transport:Public        368.00 CNY
  Assets:Bank:Checking            -368.00 CNY

2026-02-12 * "Hotel" "Two nights" #travel #trip-2026-hokkaido
  Expenses:Accommodation:Hotel     520.00 CNY
  Liabilities:CreditCard          -520.00 CNY
```

This keeps category reports useful across every trip while tags can answer questions about one journey or all travel. Tags written through the app use ASCII letters, numbers, underscores, and hyphens. Import Review can add or remove tags before commit, and the transaction list can add tags to up to 200 selected transactions in one atomic write.
