#!/usr/bin/env python3
"""Ensure the current month's transaction file exists and is included in main.bean.

Usage:
    python3 scripts/ensure_month.py

This script:
1. Determines the current year and month
2. Creates transactions/YYYY/MM.bean if it doesn't exist
3. Ensures main.bean includes the new file
"""

import os
import sys
from datetime import date


def ensure_current_month(
    bean_dir: str = "transactions",
    main_file: str = "main.bean",
) -> bool:
    """Create current month file and add include line. Returns True if anything changed."""
    today = date.today()
    year = str(today.year)
    month = f"{today.month:02d}"

    file_path = os.path.join(bean_dir, year, f"{month}.bean")
    include_line = f'include "{file_path}"'

    changed = False

    # 1. Create the monthly file if it doesn't exist
    if not os.path.exists(file_path):
        os.makedirs(os.path.dirname(file_path), exist_ok=True)
        with open(file_path, "w") as f:
            f.write(f"; {year}-{month} 交易记录\n")
        print(f"✅ Created: {file_path}")
        changed = True
    else:
        print(f"ℹ️  Already exists: {file_path}")

    # 2. Ensure main.bean includes this file
    with open(main_file) as f:
        content = f.read()

    if include_line not in content:
        # Append to the end of main.bean
        with open(main_file, "a") as f:
            f.write(f"\n{include_line}\n")
        print(f"✅ Added to {main_file}: {include_line}")
        changed = True
    else:
        print(f"ℹ️  Already included: {include_line}")

    return changed


if __name__ == "__main__":
    os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    changed = ensure_current_month()
    sys.exit(0)
