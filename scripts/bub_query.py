#!/usr/bin/env python3
"""Read-only Beancount query script for Bub Telegram bot.

Usage:
    python3 scripts/bub_query.py balances
    python3 scripts/bub_query.py recent [limit] [account_filter]
    python3 scripts/bub_query.py summary YYYY-MM
    python3 scripts/bub_query.py accounts
    python3 scripts/bub_query.py search <keyword> [limit]
    python3 scripts/bub_query.py check
"""

import calendar
import os
import re
import subprocess
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path


LEDGER_ROOT = Path(os.environ.get("BUB_LEDGER_ROOT", os.environ.get("LEDGER_ROOT", str(Path.home() / "beancount-ledger"))))
MAIN_BEAN = LEDGER_ROOT / "main.bean"


# ---- Beancount line parser (lightweight, no deps) ----

_INCLUDE_RE = re.compile(r'^include\s+"([^"]+)"\s*$')
_TXN_RE = re.compile(r'^(\d{4}-\d{2}-\d{2})\s+[*!]\s+"([^"]*)"\s+"([^"]*)"(.*)$')
_POSTING_RE = re.compile(r'^\s+([A-Z][A-Za-z0-9\-:]+)\s+(-?\d+(?:\.\d+)?)\s+CNY\b')
_TAG_RE = re.compile(r'#([A-Za-z0-9_-]+)')
_BALANCE_RE = re.compile(r'^(\d{4}-\d{2}-\d{2})\s+balance\s+([A-Z][A-Za-z0-9\-:]+)\s+(-?\d+(?:\.\d+)?)\s+CNY\b')


def read_all_lines(entry=None, seen=None):
    """Recursively read all non-comment lines from main.bean (following includes)."""
    if entry is None:
        entry = MAIN_BEAN
    if seen is None:
        seen = set()

    full = entry.resolve()
    if full in seen:
        return []
    seen.add(full)

    if not full.exists():
        return []

    directory = full.parent
    lines = []
    for lineno, raw in enumerate(full.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        m = _INCLUDE_RE.match(line)
        if m:
            lines.extend(read_all_lines(directory / m.group(1), seen))
            continue
        lines.append({"file": str(full), "line": lineno, "text": raw})
    return lines


def parse_transactions(lines=None):
    if lines is None:
        lines = read_all_lines()

    txns = []
    current = None
    for line in lines:
        text = line["text"].strip()
        if not text or text.startswith(";"):
            continue

        m = _TXN_RE.match(line["text"])
        if m:
            current = {
                "date": m.group(1),
                "payee": m.group(2),
                "narration": m.group(3),
                "tags": _TAG_RE.findall(m.group(4)),
                "postings": [],
                "source": {"file": line["file"], "line": line["line"]},
            }
            txns.append(current)
            continue

        # A new top-level directive ends the current transaction
        if re.match(r'^\d{4}-\d{2}-\d{2}\s+', line["text"]):
            current = None
            continue

        if not current:
            continue

        m = _POSTING_RE.match(line["text"])
        if m:
            current["postings"].append({
                "account": m.group(1),
                "amount": float(m.group(2)),
                "currency": "CNY",
            })

    return txns


def parse_balances(lines=None):
    if lines is None:
        lines = read_all_lines()
    return [
        {"date": m.group(1), "account": m.group(2), "amount": float(m.group(3))}
        for line in lines
        if (m := _BALANCE_RE.match(line["text"].strip()))
    ]


# ---- Query commands ----

def cmd_balances():
    txns = parse_transactions()
    bal = defaultdict(float)
    for t in txns:
        for p in t["postings"]:
            bal[p["account"]] += p["amount"]

    print("Account".ljust(38) + "Balance".rjust(14))
    print("-" * 52)
    for acct in sorted(bal):
        if abs(bal[acct]) < 0.001:
            continue
        print(f"{acct.ljust(38)} {bal[acct]:>13.2f} CNY")


def cmd_recent(limit=10, account_filter=None):
    txns = parse_transactions()
    if account_filter:
        txns = [t for t in txns if any(p["account"] == account_filter for p in t["postings"])]

    for t in txns[-limit:]:
        accounts = ", ".join(f"{p['account']} {p['amount']:+.2f}" for p in t["postings"])
        print(f'{t["date"]} | {t["payee"]} | {t["narration"]} | {accounts}')


def cmd_summary(month):
    year, mon = map(int, month.split("-"))
    last_day = calendar.monthrange(year, mon)[1]
    start = f"{year}-{mon:02d}-01"
    end = f"{year}-{mon:02d}-{last_day + 1:02d}"

    all_txns = parse_transactions()
    txns = [t for t in all_txns if start <= t["date"] < end]

    income = 0.0
    expense = 0.0
    by_cat = defaultdict(float)

    for t in txns:
        for p in t["postings"]:
            if p["account"].startswith("Income:"):
                income += abs(p["amount"])
            elif p["account"].startswith("Expenses:"):
                expense += p["amount"]
                by_cat[p["account"]] += p["amount"]

    print(f"=== {month} 月汇总 ===")
    print(f"收入:  {income:>10.2f} CNY")
    print(f"支出:  {expense:>10.2f} CNY")
    print(f"结余:  {income - expense:>10.2f} CNY")
    if by_cat:
        print()
        print("支出分类:")
        print("-" * 50)
        max_amt = max(abs(v) for v in by_cat.values()) if by_cat else 1
        for cat in sorted(by_cat, key=by_cat.get, reverse=True):
            bar = "█" * min(30, int(abs(by_cat[cat]) / max_amt * 30))
            print(f"  {cat.ljust(34)} {by_cat[cat]:>8.2f} {bar}")
    else:
        print()
        print("(本月暂无支出记录)")


def cmd_accounts():
    lines = read_all_lines()
    print(f"{'Account':<40} {'Alias'}")
    print("-" * 60)
    for line in lines:
        m = re.match(r'^(\d{4}-\d{2}-\d{2})\s+open\s+([A-Z][A-Za-z0-9\-:]+)\s+CNY\b', line["text"].strip())
        if m:
            acct = m.group(2)
            # Find alias in the next few lines
            alias = ""
            idx = lines.index(line)
            for look in lines[idx+1:idx+4]:
                am = re.match(r'^\s+alias:\s+"([^"]+)"', look["text"].strip())
                if am:
                    alias = am.group(1)
                    break
            print(f"{acct:<40} {alias}")


def cmd_search(keyword, limit=20):
    txns = parse_transactions()
    keyword_lower = keyword.lower()
    matches = [
        t for t in txns
        if keyword_lower in t["payee"].lower()
        or keyword_lower in t["narration"].lower()
    ]
    for t in matches[-limit:]:
        accounts = ", ".join(f"{p['account']} {p['amount']:+.2f}" for p in t["postings"])
        print(f'{t["date"]} | {t["payee"]} | {t["narration"]} | {accounts}')
    if not matches:
        print(f"(没有找到包含 '{keyword}' 的交易)")


def cmd_check():
    bean_check = os.environ.get("BEAN_CHECK_BIN")
    if not bean_check:
        for cand in [
            (Path.home() / ".local" / "bin" / "bean-check"),
            Path("bean-check"),
        ]:
            if os.access(cand, os.X_OK):
                bean_check = str(cand)
                break
        else:
            bean_check = "bean-check"

    env = os.environ.copy()
    env["PATH"] = f"{Path.home() / '.local' / 'bin'}:{env.get('PATH', '')}"
    result = subprocess.run(
        [bean_check, str(MAIN_BEAN)],
        cwd=str(LEDGER_ROOT),
        capture_output=True,
        text=True,
        timeout=30,
        env=env,
    )
    if result.returncode == 0:
        print("✅ bean-check 通过，账本无错误。")
    else:
        print("❌ bean-check 发现错误：")
        print(result.stderr.strip() or result.stdout.strip())


# ---- Main ----

COMMANDS = {
    "balances": cmd_balances,
    "recent": cmd_recent,
    "summary": cmd_summary,
    "accounts": cmd_accounts,
    "search": cmd_search,
    "check": cmd_check,
}


def usage():
    print("Usage: python3 scripts/bub_query.py <command> [args...]")
    print()
    print("Commands:")
    print("  balances                  Show current balances")
    print("  recent [N] [account]      Show recent N transactions")
    print("  summary YYYY-MM           Monthly income/expense summary")
    print("  accounts                  List all accounts")
    print("  search <keyword> [N]      Search transactions by keyword")
    print("  check                     Run bean-check")


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help", "help"):
        usage()
        sys.exit(1)

    cmd = sys.argv[1]
    args = sys.argv[2:]

    if cmd not in COMMANDS:
        print(f"Unknown command: {cmd}")
        usage()
        sys.exit(1)

    fn = COMMANDS[cmd]
    # Dispatch with typed arguments
    if cmd == "recent":
        limit = int(args[0]) if args and args[0].isdigit() else 10
        account = args[1] if len(args) > 1 and not args[0].isdigit() else (args[0] if args and not args[0].isdigit() else None)
        if len(args) > 1 and args[0].isdigit():
            account = args[1] if len(args) > 1 else None
        elif args and not args[0].isdigit():
            account = args[0]
        fn(limit=limit, account_filter=account)
    elif cmd == "summary":
        fn(args[0])
    elif cmd == "search":
        keyword = args[0]
        limit = int(args[1]) if len(args) > 1 and args[1].isdigit() else 20
        fn(keyword, limit)
    else:
        fn()  # balances, accounts, check
