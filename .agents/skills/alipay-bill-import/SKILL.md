---
name: "alipay-bill-import"
description: "Import Alipay CSV bills into a private Beancount ledger using manual-first reconciliation, funding-account deduplication, special-case handling, and balance/fund verification."
globs:
  - ".agents/skills/alipay-bill-import/**"
  - "**/*.bean"
  - "scripts/**/*.py"
alwaysAllow:
  - "Bash"
---

# Alipay Bill Import Skill

Use this skill when importing 支付宝交易明细 CSV files into a private Beancount ledger.

This skill is owned by the **Beancount Ledger Web application repository**. The private ledger/data repository should contain ledger data, import configs, and generated results, but should not be the source of truth for agent skills.

## Applicability

Use this skill for:

- Alipay CSV bill conversion into Beancount draft entries.
- Manual-first reconciliation between existing ledger entries and Alipay bill rows.
- Funding-account duplicate detection across Alipay balance, Yu'E Bao, cards, MYBank, and fund purchases.
- Alipay cash balance, fund balance, and liability verification.

Do **not** use this skill for:

- Generic real-time bookkeeping; use `beancount-bookkeeping`.
- Read-only spending summaries; use `beancount-insights`.
- WeChat bill imports; use `wechat-bill-import`.
- Telegram chat orchestration; use `telegram-ledger-agent`.

## Ledger Data Directory

Resolve the private ledger root in this order:

1. If `BUB_LEDGER_ROOT` is set, use it.
2. Else if `LEDGER_ROOT` is set, use it.
3. Else, if the user explicitly provides a ledger path, use that path only after confirming it contains `main.bean`.
4. Otherwise, report that the ledger root is not configured.

Do **not** hardcode private ledger paths in this skill or in user-visible final answers. Do not silently use an example ledger unless the user explicitly asks.

Useful shell pattern:

```bash
LEDGER_ROOT="${BUB_LEDGER_ROOT:-${LEDGER_ROOT:-}}"
if [ -z "$LEDGER_ROOT" ]; then
  echo "Missing BUB_LEDGER_ROOT or LEDGER_ROOT"
  exit 2
fi
test -f "$LEDGER_ROOT/main.bean" || { echo "main.bean not found"; exit 2; }
cd "$LEDGER_ROOT"
```

## Core Principle

**Manual records are primary. Imports are for reconciliation and detail completion.**

Source priority:

```text
manual real-time entries
> WeChat / Alipay payment-platform statements
> credit-card statements as supplement and balance check
```

- Keep manually entered transactions when they express the correct intent, category, or user-confirmed interpretation.
- Use the Alipay bill to find missing transactions, verify balances, and provide better detail.
- Treat Alipay/WeChat bills as richer merchant-detail sources than credit-card statements.
- Never add arbitrary balance adjustments merely to make numbers fit. Find the real missing or duplicate transaction first.
- Ask for user-provided app balances when a cash balance, fund balance, or liability cannot be reconciled.

## Required Private Ledger Files

The private ledger repository should provide:

- `main.bean`
- monthly ledgers such as `transactions/YYYY/MM.bean`
- Alipay import config such as `imports/alipay-config.yaml`
- a dedup/reconciliation helper such as `scripts/dedup_import.py`
- optionally `scripts/check_date_order.py`

If any required file is missing, explain what is missing instead of guessing.

## Standard Workflow

### 1. Inspect and decode the CSV

Alipay exports are often GBK/GB18030 encoded. Inspect with an explicit encoding if needed:

```bash
python3 - <<'PY'
from pathlib import Path
p = Path('/path/to/alipay.csv')
for enc in ['gb18030', 'gbk', 'utf-8-sig', 'utf-8']:
    try:
        text = p.read_bytes().decode(enc)
        print('encoding', enc)
        print('\n'.join(text.splitlines()[:40]))
        break
    except UnicodeDecodeError:
        pass
else:
    raise SystemExit('Unable to decode CSV with common encodings')
PY
```

Before conversion, check that the file looks like an Alipay transaction export and includes the expected period. Important columns usually include:

- `交易时间`
- `交易分类`
- `交易对方`
- `商品说明`
- `收/支`
- `金额`
- `收/付款方式`
- `交易状态`
- `交易订单号`
- `商家订单号`

If columns are missing or the export period is unclear, stop and ask for clarification.

### 2. Convert the CSV bill

Run from the private ledger root:

```bash
double-entry-generator translate \
  --provider alipay \
  --target beancount \
  --config imports/alipay-config.yaml \
  --output imports/alipay-output.bean \
  "/path/to/支付宝交易明细(...).csv"
```

The generated `.bean` file is a temporary artifact. Do not commit generated Alipay import `.bean` files unless the user explicitly requests an import snapshot.

### 3. Preview dedup results

```bash
python3 scripts/dedup_import.py imports/alipay-output.bean --dry-run
```

Review the dry-run output for:

- exact duplicates by funding account, amount, and date;
- adjacent-day duplicates caused by posting/settlement delays;
- manual entries that represent the same purchase with better category/context;
- same-amount repeated transactions that must not be collapsed blindly;
- payment method strings that are not recognized by config or helper scripts;
- generated `open` directives or placeholder accounts that should not be folded into monthly ledgers.

For confirmed fixed 9.99 -> 10.00 fund purchases, generate the deduped output with:

```bash
python3 scripts/dedup_import.py \
  imports/alipay-output.bean \
  --alipay-fund-rounding \
  -o imports/alipay-deduped.bean
```

Use `--alipay-fund-rounding` only after confirming the user's app fund balance and the fact that the 9.99 payment is a fixed 10.00 investment with a 0.01 subsidy/discount/income component.

The helper should match duplicates by:

- funding account, such as `Assets:CN:Alipay:Balance`, `Liabilities:CN:CMB:CreditCard`, `Assets:CN:CMB:Checking`, or `Assets:CN:MYBank:Wealth`;
- amount;
- date, with optional tolerance when supported.

The helper should understand `网商银行储蓄卡`, `余额宝`, `招商银行信用卡`, and `招商银行储蓄卡` method strings. If a new method string appears, supplement with an explicit diagnostic script rather than blindly importing everything.

### 4. Reconcile before writing

For each candidate import transaction:

1. Check whether a manual entry already represents it.
2. If the manual entry is more accurate, keep manual and drop import.
3. If imported detail is better than a manual lump sum, explain the overlap and ask whether to replace the manual entry.
4. If there is a balance difference, identify the real missing/duplicate transaction.
5. Ask the user for exact Alipay cash balance or fund balance when needed.
6. Do not insert `Equity:Balance-Adjustments` unless the user explicitly confirms that the difference is an actual adjustment.

Do not silently delete manual entries. If replacing manual rows with imported detail is approved, show the before/after intent and keep the ledger balanced.

### 5. Handle special Alipay cases

#### Cash balance / Yu'E Bao

`余额` and `余额宝` cash-like methods usually map to `Assets:CN:Alipay:Balance` unless the private ledger distinguishes them.

Always compare the final computed balance to the user's Alipay app balance before committing.

#### Funds / investment purchases

Alipay fund purchases may be exported as `不计收支` with category `投资理财` and method such as `网商银行储蓄卡(...)`.

Typical mapping:

```text
Assets:CN:Alipay:Fund      +amount
Assets:CN:MYBank:Wealth    -amount
```

However, do **not** import fund purchases merely because they appear in the CSV. First compare to the user's app fund balance and to existing manual fund entries. Pending-confirmation purchases may not yet be reflected in app fund total.

When the user confirms that a 9.99 Alipay fund purchase is a fixed 10.00 investment, preserve the 0.01 difference as income/discount via `scripts/dedup_import.py --alipay-fund-rounding` rather than importing only 9.99 into the fund asset.

#### Huabei

Do not map 花呗 to a credit-card account. If the private ledger has no dedicated Huabei liability account and the user does not want Huabei tracked, exclude Huabei consumption and repayments from the import.

If the user wants Huabei tracked, ask before adding a liability account such as:

```text
Liabilities:CN:Alipay:Huabei
```

#### Refunds and reversals

Refunds may appear on a different date from the original purchase. Match them semantically by merchant, order id, amount, and narrative. Do not net refunds into purchases unless the ledger already uses that convention or the user asks.

#### Balance assertions

Beancount balance assertions are checked at their position in file order. If importing earlier transactions changes a balance before an assertion, move or update the assertion only after understanding the real statement date/time.

Do not assume a credit-card balance assertion on the first ledger day is a beginning-of-month assertion. The user may have recorded a later app/statement balance.

### 6. Insert confirmed transactions

Prefer folding confirmed import transactions into the monthly ledger in chronological order.

Exclude by default:

- generated `open` directives from temporary import files;
- canceled/closed transactions;
- zero-value authorizations;
- fund purchases that would break the user-confirmed fund total;
- Huabei transactions when the user chooses not to track Huabei;
- transactions already represented by manual entries;
- placeholder accounts such as `Assets:FIXME` or `Expenses:FIXME` unless explicitly resolved.

### 7. Verify the ledger

Run from the private ledger root:

```bash
python3 - <<'PY'
from beancount import loader
from beancount.core.data import Transaction
entries, errors, _ = loader.load_file('main.bean')
print(f'errors: {len(errors)}')
for e in errors:
    print(e.message)
for account in [
    'Assets:CN:Alipay:Balance',
    'Assets:CN:Alipay:Fund',
    'Assets:CN:MYBank:Wealth',
    'Assets:CN:CMB:Checking',
    'Liabilities:CN:CMB:CreditCard',
]:
    bal = 0.0
    for entry in entries:
        if isinstance(entry, Transaction):
            for posting in entry.postings:
                if posting.account == account:
                    bal += float(posting.units.number)
    print(f'{account}: {bal:.2f}')
PY
```

Also run the date-order check if available:

```bash
python3 scripts/check_date_order.py main.bean
```

Compare computed balances against user-provided app balances when applicable.

### 8. Cleanup

Remove temporary generated import files after confirmed transactions are folded into the ledger:

```bash
rm -f imports/alipay-output.bean imports/alipay-deduped.bean imports/alipay-latest.bean
```

Keep only reusable private config/scripts in the private ledger repo.

## Account Mapping Expectations

The private `imports/alipay-config.yaml` should map payment methods to funding accounts. Typical mapping:

- `余额`, `余额宝` → `Assets:CN:Alipay:Balance`
- credit card methods → the relevant liability account, e.g. `Liabilities:CN:CMB:CreditCard`
- debit card methods → the relevant checking account, e.g. `Assets:CN:CMB:Checking`
- `网商银行储蓄卡` → the relevant MYBank asset account, e.g. `Assets:CN:MYBank:Wealth`
- fund purchases → `Assets:CN:Alipay:Fund` only after app-balance confirmation

Rules should put broad category fallbacks before specific merchant/item matches, because double-entry-generator allows multiple matching rules and later matching rules override earlier account assignments.

## Output Style

When reporting progress:

- Summarize counts: total rows, skipped duplicates, candidate inserts, unresolved rows.
- Highlight balance differences and unresolved payment methods.
- Do not print full private paths or raw full CSV content.
- Ask concise questions when user confirmation is required.

## Safety Rules

- Do not silently delete manual entries.
- Do not invent missing transactions.
- Do not add arbitrary balance adjustments.
- Do not map Huabei to credit card unless the user explicitly chooses that model.
- Do not commit downloaded CSV files or generated temporary import `.bean` files unless explicitly requested.
- Do not expose private absolute ledger paths, tokens, or environment values in final responses.
- When committing, include `Co-Authored-By: Craft Agent <agents-noreply@craft.do>`.
