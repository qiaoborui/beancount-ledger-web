#!/usr/bin/env python3
"""Small import dedup helper for the public preview ledger.

The private ledger uses a richer version of this script. This example keeps the
same CLI shape used by the web app while avoiding private matching rules.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


TX_HEADER = re.compile(r"^\d{4}-\d{2}-\d{2}\s+[*!]\s+", re.MULTILINE)
ORDER_ID = re.compile(r'^\s+orderId:\s+"?([^"\n]+)"?', re.MULTILINE)
POSTING = re.compile(r"^\s+([A-Za-z][A-Za-z0-9:_-]+)\s+(-?\d+(?:\.\d+)?)\s+([A-Z][A-Z0-9]*)\s*$", re.MULTILINE)


def transaction_blocks(text: str) -> list[str]:
  matches = list(TX_HEADER.finditer(text))
  blocks: list[str] = []
  for index, match in enumerate(matches):
    end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
    blocks.append(text[match.start():end].strip())
  return blocks


def order_ids(text: str) -> set[str]:
  return {match.group(1).strip() for match in ORDER_ID.finditer(text)}


def fallback_identity(block: str) -> tuple[str, str, str]:
  date = block[:10]
  postings = [(account, abs(float(amount)), currency) for account, amount, currency in POSTING.findall(block)]
  if not postings:
    return (date, "0.00", "")
  account, amount, currency = max(postings, key=lambda item: item[1])
  return (date, f"{amount:.2f}", currency if account else "")


def fallback_identities(blocks: list[str]) -> set[tuple[str, str, str]]:
  return {fallback_identity(block) for block in blocks}


def main() -> int:
  parser = argparse.ArgumentParser()
  parser.add_argument("import_file")
  parser.add_argument("-o", "--output")
  parser.add_argument("--dry-run", action="store_true")
  parser.add_argument("--alipay-fund-rounding", action="store_true")
  parser.add_argument("--credit-card", action="store_true")
  parser.add_argument("--bank-card", action="store_true")
  args = parser.parse_args()

  root = Path.cwd()
  import_text = Path(args.import_file).read_text(encoding="utf8")
  main_text = (root / "main.bean").read_text(encoding="utf8")
  existing_blocks = transaction_blocks(main_text)
  existing_order_ids = order_ids(main_text)
  existing_fallbacks = fallback_identities(existing_blocks)

  kept: list[str] = []
  skipped = 0
  for block in transaction_blocks(import_text):
    ids = order_ids(block)
    if ids and ids <= existing_order_ids:
      skipped += 1
      continue
    if args.bank_card and fallback_identity(block) in existing_fallbacks:
      skipped += 1
      continue
    if not ids and fallback_identity(block) in existing_fallbacks:
      skipped += 1
      continue
    kept.append(block)

  if args.output and not args.dry_run:
    Path(args.output).write_text(("\n\n".join(kept).strip() + "\n") if kept else "", encoding="utf8")

  print(f"candidates={len(kept) + skipped}")
  print(f"new={len(kept)}")
  print(f"skipped={skipped}")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
