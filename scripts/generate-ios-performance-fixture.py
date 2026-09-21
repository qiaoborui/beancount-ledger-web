#!/usr/bin/env python3
"""Generate a synthetic disposable fixture outside the public application tree.

Requires the same Beancount version as the embedded runtime. No real data is read.
"""
import argparse
import importlib.util
import json
from decimal import Decimal
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--transactions", type=int, default=10000)
    parser.add_argument("--includes", type=int, default=120)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    destination = args.destination.resolve()
    if destination == repo or repo in destination.parents:
        parser.error("destination must be outside the public repository")
    if not 1 <= args.includes <= min(args.transactions, 1200) or args.transactions > 100000:
        parser.error("require 1 <= includes <= transactions <= 100000, includes <= 1200")
    destination.mkdir(parents=True, exist_ok=False)
    root = destination / "generations" / "initial" / "workspace"
    transactions = root / "transactions"
    transactions.mkdir(parents=True)
    buckets = [[] for _ in range(args.includes)]
    for i in range(args.transactions):
        month, day = i % 9 + 1, i % 28 + 1
        buckets[i % args.includes].append(
            f'2026-{month:02d}-{day:02d} * "Synthetic" "Fixture {i}"\n'
            '  Expenses:Food  1 CNY\n  Assets:Cash  -1 CNY\n'
        )
    includes = []
    for i, rows in enumerate(buckets):
        relative = f"transactions/{i:04d}.bean"
        (root / relative).write_text("".join(rows), encoding="utf-8")
        includes.append(f'include "{relative}"\n')
    (root / "main.bean").write_text(
        'option "operating_currency" "CNY"\n'
        '2000-01-01 commodity CNY\n'
        '2000-01-01 open Assets:Cash CNY\n'
        '2000-01-01 open Expenses:Food CNY\n' + "".join(includes), encoding="utf-8"
    )
    spec = importlib.util.spec_from_file_location(
        "ledger_validator", repo / "App/LedgerMobile/Runtime/ledger_validator.py"
    )
    validator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(validator)
    result = json.loads(validator.validate_json(str(root)))
    if result["errors"]:
        raise SystemExit("Synthetic fixture failed canonical validation")
    entries = [e for e in result["canonical"]["entries"] if e["Kind"] == "transaction"]
    totals = {"Expenses:Food": Decimal(0), "Assets:Cash": Decimal(0)}
    if len(entries) != args.transactions or any(len(e["Postings"]) != 2 for e in entries):
        raise SystemExit("Canonical transaction/posting count differs from fixture golden")
    for entry in entries:
        for posting in entry["Postings"]:
            if posting["account"] not in totals or posting["Quantity"]["Currency"] != "CNY":
                raise SystemExit("Canonical posting differs from fixture golden")
            totals[posting["account"]] += Decimal(posting["Quantity"]["Number"])
    if totals != {"Expenses:Food": Decimal(args.transactions), "Assets:Cash": Decimal(-args.transactions)}:
        raise SystemExit("Canonical totals differ from fixture golden")
    canonical = json.dumps(result["canonical"], ensure_ascii=False, separators=(",", ":"))
    (destination / "canonical.json").write_text(canonical, encoding="utf-8")
    manifest = {
        "schema": 1, "generator": "deterministic-two-account-cny-v1",
        "transactions": args.transactions, "include_files": args.includes,
        "canonical_bytes": len(canonical.encode("utf-8")),
        "source_bytes": sum(p.stat().st_size for p in root.rglob("*.bean")),
        "expected_expense_cny": args.transactions,
        "expected_cash_cny": -args.transactions,
        "validation_errors": 0,
    }
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, sort_keys=True))


if __name__ == "__main__":
    main()
