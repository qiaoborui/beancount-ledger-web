#!/usr/bin/env python3
"""Check that all transactions in the beancount ledger are in strict date order.

Usage:
    python3 scripts/check_date_order.py

Exit code 0: all transactions are in date order.
Exit code 1: ordering violations found (prints details).
"""

import os
import sys
from beancount import loader
from beancount.core.data import Transaction


def check_date_order(bean_file: str = "main.bean") -> list[str]:
    """Check entries are in date order. Returns list of violation messages."""
    entries, errors, _ = loader.load_file(bean_file)

    violations = []
    prev = None

    for entry in entries:
        if not isinstance(entry, Transaction):
            continue

        if prev is not None and entry.date < prev.date:
            violations.append(
                f"❌ Date ordering violation:\n"
                f"     {prev.date}  {prev.payee:20s}  {prev.narration[:40]}\n"
                f"  →  {entry.date}  {entry.payee:20s}  {entry.narration[:40]}\n"
                f"     (file: {entry.meta.get('filename', '?')}, "
                f"prev file: {prev.meta.get('filename', '?')})"
            )

        prev = entry

    return violations


if __name__ == "__main__":
    os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

    violations = check_date_order()

    if violations:
        print(f"\nFound {len(violations)} date ordering violation(s):\n")
        for v in violations:
            print(v)
        sys.exit(1)
    else:
        print("✅ All transactions are in date order.")
        sys.exit(0)
