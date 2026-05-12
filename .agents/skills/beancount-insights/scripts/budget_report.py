#!/usr/bin/env python3
"""Generate a simple monthly budget report for this Beancount 3 ledger.

Usage:
  python3 scripts/budget_report.py 2026-05
  python3 scripts/budget_report.py 2026-05 --ledger main.bean

This script is intentionally Beancount-3-friendly:
- It does NOT require bean-query.
- It does NOT import the beancount Python package.
- It reads .bean files directly, follows include directives, parses budget custom
  directives, and sums Expenses:* postings for the target month.

Budget directive format:
  2026-05-01 custom "budget" Expenses:Food:Meals "monthly" 2500.00 CNY

For each account, the latest budget on or before the target month is used.
"""

from __future__ import annotations

import argparse
import calendar
import re
import sys
from dataclasses import dataclass
from datetime import date
from decimal import Decimal, InvalidOperation
from pathlib import Path


INCLUDE_RE = re.compile(r'^include\s+"(?P<path>[^"]+)"\s*$')

BUDGET_RE = re.compile(
    r'^(?P<date>\d{4}-\d{2}-\d{2})\s+custom\s+"budget"\s+'
    r'(?P<account>Expenses(?::[A-Za-z0-9-]+)+)\s+'
    r'"(?P<period>monthly)"\s+'
    r'(?P<amount>-?\d+(?:\.\d+)?)\s+'
    r'(?P<currency>[A-Z][A-Z0-9]*)\s*$'
)

TRANSACTION_RE = re.compile(r'^(?P<date>\d{4}-\d{2}-\d{2})\s+[*!]\s+')

POSTING_RE = re.compile(
    r'^\s+(?P<account>Expenses(?::[A-Za-z0-9-]+)+)\s+'
    r'(?P<amount>-?\d+(?:\.\d+)?)\s+'
    r'(?P<currency>[A-Z][A-Z0-9]*)\b'
)


@dataclass(frozen=True)
class BeanLine:
    path: Path
    line_no: int
    text: str


@dataclass(frozen=True)
class Budget:
    effective_date: date
    account: str
    amount: Decimal
    currency: str


def parse_month(value: str) -> tuple[date, date]:
    try:
        year_s, month_s = value.split("-", 1)
        year = int(year_s)
        month = int(month_s)
        if not 1 <= month <= 12:
            raise ValueError("month out of range")
        start = date(year, month, 1)
        _, _days = calendar.monthrange(year, month)
        end = date(year + 1, 1, 1) if month == 12 else date(year, month + 1, 1)
        return start, end
    except Exception as exc:  # noqa: BLE001
        raise SystemExit(f"Invalid month {value!r}; expected YYYY-MM") from exc


def read_ledger_lines(path: Path, seen: set[Path] | None = None) -> list[BeanLine]:
    """Read a ledger and its includes recursively, preserving line origin."""
    seen = seen or set()
    path = path.resolve()
    if path in seen:
        return []
    seen.add(path)

    if not path.exists():
        raise SystemExit(f"Ledger file not found: {path}")

    result: list[BeanLine] = []
    for line_no, text in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = text.strip()
        match = INCLUDE_RE.match(stripped)
        if match:
            include_path = (path.parent / match.group("path")).resolve()
            result.extend(read_ledger_lines(include_path, seen))
            continue
        result.append(BeanLine(path=path, line_no=line_no, text=text))
    return result


def parse_budgets(lines: list[BeanLine], month_start: date) -> dict[str, Budget]:
    selected: dict[str, Budget] = {}

    for bean_line in lines:
        line = bean_line.text.strip()
        if not line or line.startswith(";"):
            continue
        match = BUDGET_RE.match(line)
        if not match:
            continue

        effective_date = date.fromisoformat(match.group("date"))
        if effective_date > month_start:
            continue

        account = match.group("account")
        try:
            amount = Decimal(match.group("amount"))
        except InvalidOperation as exc:
            raise SystemExit(f"Invalid budget amount at {bean_line.path}:{bean_line.line_no}") from exc

        budget = Budget(
            effective_date=effective_date,
            account=account,
            amount=amount,
            currency=match.group("currency"),
        )
        current = selected.get(account)
        if current is None or budget.effective_date >= current.effective_date:
            selected[account] = budget

    return selected


def parse_expenses(lines: list[BeanLine], month_start: date, month_end: date) -> dict[str, Decimal]:
    """Sum Expenses:* postings inside transactions dated in [month_start, month_end)."""
    expenses: dict[str, Decimal] = {}
    current_txn_date: date | None = None
    in_target_transaction = False

    for bean_line in lines:
        text = bean_line.text
        stripped = text.strip()

        if not stripped or stripped.startswith(";"):
            continue

        txn_match = TRANSACTION_RE.match(text)
        if txn_match:
            current_txn_date = date.fromisoformat(txn_match.group("date"))
            in_target_transaction = month_start <= current_txn_date < month_end
            continue

        # Any non-indented dated directive ends the current transaction context.
        if re.match(r'^\d{4}-\d{2}-\d{2}\s+', text):
            current_txn_date = None
            in_target_transaction = False
            continue

        if current_txn_date is None or not in_target_transaction:
            continue

        posting_match = POSTING_RE.match(text)
        if not posting_match:
            continue
        if posting_match.group("currency") != "CNY":
            continue

        account = posting_match.group("account")
        try:
            amount = Decimal(posting_match.group("amount"))
        except InvalidOperation as exc:
            raise SystemExit(f"Invalid expense amount at {bean_line.path}:{bean_line.line_no}") from exc
        expenses[account] = expenses.get(account, Decimal("0")) + amount

    return expenses


def fmt_money(value: Decimal) -> str:
    return f"{value.quantize(Decimal('0.01')):>10}"


def status_for(ratio: Decimal | None, remaining: Decimal) -> str:
    if ratio is None:
        return "n/a"
    if remaining < 0:
        return "⚠️ 超支"
    if ratio >= Decimal("0.8"):
        return "注意"
    return "正常"


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate monthly budget report for Beancount 3 ledgers.")
    parser.add_argument("month", help="Target month, e.g. 2026-05")
    parser.add_argument("--ledger", default="main.bean", help="Path to main.bean")
    args = parser.parse_args()

    month_start, month_end = parse_month(args.month)
    ledger = Path(args.ledger)

    lines = read_ledger_lines(ledger)
    budgets = parse_budgets(lines, month_start)
    expenses = parse_expenses(lines, month_start, month_end)

    accounts = sorted(set(budgets) | set(expenses))
    if not accounts:
        print(f"{args.month} 没有预算或支出数据。")
        return 0

    print(f"{args.month} 预算执行情况")
    print()
    print(f"{'分类':45} {'预算':>10} {'实际':>10} {'剩余':>10} {'使用率':>8}  状态")
    print("-" * 96)

    total_budget = Decimal("0")
    total_actual = Decimal("0")

    for account in accounts:
        budget = budgets.get(account)
        budget_amount = budget.amount if budget else Decimal("0")
        actual = expenses.get(account, Decimal("0"))
        remaining = budget_amount - actual
        ratio = None if budget_amount == 0 else actual / budget_amount
        ratio_text = "n/a" if ratio is None else f"{(ratio * 100).quantize(Decimal('1'))}%"

        total_budget += budget_amount
        total_actual += actual

        print(
            f"{account:45} {fmt_money(budget_amount)} {fmt_money(actual)} "
            f"{fmt_money(remaining)} {ratio_text:>8}  {status_for(ratio, remaining)}"
        )

    total_remaining = total_budget - total_actual
    total_ratio = None if total_budget == 0 else total_actual / total_budget
    total_ratio_text = "n/a" if total_ratio is None else f"{(total_ratio * 100).quantize(Decimal('1'))}%"
    print("-" * 96)
    print(
        f"{'TOTAL':45} {fmt_money(total_budget)} {fmt_money(total_actual)} "
        f"{fmt_money(total_remaining)} {total_ratio_text:>8}  {status_for(total_ratio, total_remaining)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
