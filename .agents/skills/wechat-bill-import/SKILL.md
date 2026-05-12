---
name: "wechat-bill-import"
description: "Import WeChat Pay XLSX bills into a private Beancount ledger using manual-first reconciliation, dedup review, and balance verification."
globs:
  - ".agents/skills/wechat-bill-import/**"
  - "**/*.bean"
  - "scripts/**/*.py"
alwaysAllow:
  - "Bash"
---

# WeChat Bill Import Skill

Use this skill when importing 微信支付账单流水 XLSX files into a private Beancount ledger.

This skill is owned by the **Beancount Ledger Web application repository**. The private ledger/data repository should contain ledger data, import configs, and generated results, but should not be the source of truth for agent skills.

## Ledger Data Directory

Resolve the private ledger root in this order:

1. If `BUB_LEDGER_ROOT` is set, use it.
2. Else if `LEDGER_ROOT` is set, use it.
3. Else, if the user explicitly provides a ledger path, use that path after confirming it contains `main.bean`.
4. Otherwise, report that the ledger root is not configured.

Do **not** hardcode private ledger paths in this skill or in user-visible final answers.

Useful shell pattern:

```bash
LEDGER_ROOT="${BUB_LEDGER_ROOT:-${LEDGER_ROOT:-}}"
if [ -z "$LEDGER_ROOT" ]; then
  echo "Missing BUB_LEDGER_ROOT or LEDGER_ROOT"
  exit 2
fi
cd "$LEDGER_ROOT"
```

## Core Principle

**Manual records are primary. Imports are for reconciliation and detail completion.**

Recommended source priority:

```text
manual real-time entries
> WeChat / Alipay payment-platform statements
> credit-card statements as supplement and balance check
```

- Keep manually entered transactions when they express the correct intent, category, or user-confirmed interpretation.
- Use the WeChat bill to find missing transactions, verify balances, and provide better detail.
- Replace a manual lump-sum entry with imported detailed entries only when the user explicitly agrees.
- Never add arbitrary balance adjustments merely to make the numbers fit. Find the real missing or duplicate transaction first.

## Required Private Ledger Files

The private ledger repository should provide:

- `main.bean`
- monthly ledgers such as `transactions/YYYY/MM.bean`
- WeChat import config such as `imports/wechat-config.yaml`
- a dedup/reconciliation helper such as `scripts/dedup_import.py`

If any required file is missing, explain what is missing instead of guessing.

## Standard Workflow

### 1. Convert the XLSX bill

Run from the private ledger root:

```bash
double-entry-generator translate \
  --provider wechat \
  --target beancount \
  --config imports/wechat-config.yaml \
  --output imports/wechat-output.bean \
  "/path/to/微信支付账单流水文件(...).xlsx"
```

The generated `.bean` file is a temporary artifact. Do not commit generated WeChat import `.bean` files unless the user explicitly requests an import snapshot.

### 2. Preview dedup results

```bash
python3 scripts/dedup_import.py imports/wechat-output.bean --dry-run
```

The helper usually matches duplicates by:

- funding account, such as `Assets:CN:Wechat:Balance` or `Liabilities:CN:CMB:CreditCard`,
- amount,
- date, with optional tolerance when supported.

Exact matching is not enough for every case. Actively look for:

- adjacent-day duplicates caused by late-night payments,
- manual lump sums that correspond to several imported detail rows,
- repeated same-amount transactions on the same day,
- user-corrected manual entries that should override imported details.

### 3. Reconcile before writing

For each candidate import transaction:

1. Check whether a manual entry already represents it.
2. If the manual entry is more accurate, keep manual and drop import.
3. If imported detail is better than a manual lump sum, explain the overlap and ask whether to replace the manual entry.
4. If there is a balance difference, identify the real missing/duplicate transaction.
5. Do not insert `Equity:Balance-Adjustments` unless the user explicitly confirms that the difference is an actual adjustment.

Example semantic duplicate:

```text
Manual:  2026-05-07 租车收款 +1062
Import:  2026-05-07 A +354, B +354, C +354
```

This is semantically duplicated even though exact amount matching will not catch it. Ask the user whether to keep the manual lump sum or use imported detail.

### 4. Insert confirmed transactions

Prefer folding confirmed import transactions into the monthly ledger in chronological order.

Important Beancount ordering rules:

- Balance assertions are checked at their position in file order.
- Do not insert earlier-dated import entries before an existing balance assertion unless the assertion amount is updated intentionally.
- If the user provides an app balance at a specific time, treat it as ground truth.
- If a transaction is missing, record the real transaction when identified rather than adding a vague adjustment.

### 5. Verify the ledger

Run from the private ledger root:

```bash
python3 - <<'PY'
from beancount import loader
from beancount.core.data import Transaction
entries, errors, _ = loader.load_file('main.bean')
print(f'errors: {len(errors)}')
for e in errors:
    print(e.message)
bal = 0.0
for e in entries:
    if isinstance(e, Transaction):
        for p in e.postings:
            if p.account == 'Assets:CN:Wechat:Balance':
                bal += float(p.units.number)
print(f'Wechat balance: {bal:.2f}')
PY
```

Also run the date-order check if available:

```bash
python3 scripts/check_date_order.py
```

Compare computed `Assets:CN:Wechat:Balance` against the user's WeChat app balance.

### 6. Cleanup

Remove temporary generated import files after confirmed transactions are folded into the ledger:

```bash
rm -f imports/wechat-output.bean imports/wechat-deduped.bean imports/wechat-latest.bean imports/wechat-*-plus.bean
```

Keep only reusable private config/scripts in the private ledger repo.

## Account Mapping Expectations

The private `imports/wechat-config.yaml` should map payment methods to funding accounts. Typical mapping:

- `零钱`, `零钱通` → `Assets:CN:Wechat:Balance`
- credit card methods → the relevant liability account
- debit card methods → the relevant checking account

Unmatched income such as red packets and cashback should map to a real income account such as `Income:Other`, not to `Assets:FIXME`.

## Safety Rules

- Do not silently delete manual entries.
- Do not invent missing transactions.
- Do not add arbitrary balance adjustments.
- Do not commit downloaded XLSX files or generated temporary import `.bean` files unless explicitly requested.
- Do not expose private absolute ledger paths in final responses.
- When committing, include `Co-Authored-By: Craft Agent <agents-noreply@craft.do>`.
