#!/usr/bin/env python3
"""Safe Beancount transaction appender for Bub Telegram bot.

Writes a transaction to transactions/YYYY/MM.bean, auto-creates directories
and adds include line to main.bean if needed. Runs bean-check after write.
On failure, automatically rolls back. Uses cross-process file locking.

Usage:
    echo '<json>' | python3 scripts/bub_append.py
    python3 scripts/bub_append.py '<json_entry>'

JSON format:
{
    "date": "2026-05-11",
    "payee": "星巴克",
    "narration": "咖啡",
    "tags": [],
    "metadata": {},
    "postings": [
        {"account": "Liabilities:CreditCard", "amount": "-38.00", "currency": "CNY"},
        {"account": "Expenses:Food:Drinks", "amount": "38.00", "currency": "CNY"}
    ]
}
"""

import fcntl
import json
import os
import re
import subprocess
import sys
from pathlib import Path


# ---- Config ----
LEDGER_ROOT = Path(os.environ.get(
    "BUB_LEDGER_ROOT",
    os.environ.get("LEDGER_ROOT", str(Path.home() / "beancount-ledger")),
))
RUNTIME_ROOT = Path(os.environ.get("BUB_RUNTIME_ROOT", os.environ.get("RUNTIME_DIR", str(LEDGER_ROOT / ".runtime"))))
TRANSACTIONS_DIR = LEDGER_ROOT / "transactions"
MAIN_BEAN = LEDGER_ROOT / "main.bean"
LOCK_FILE = RUNTIME_ROOT / "ledger-write.lock"

# Find bean-check
_BEAN_CHECK = os.environ.get("BEAN_CHECK_BIN")
if not _BEAN_CHECK:
    for _cand in [
        (Path.home() / ".local" / "bin" / "bean-check"),
        (Path.home() / ".local" / "share" / "uv" / "tools" / "beancount" / "bin" / "bean-check"),
        Path("bean-check"),
    ]:
        if os.access(_cand, os.X_OK):
            _BEAN_CHECK = str(_cand)
            break
    else:
        _BEAN_CHECK = "bean-check"

# ---- Account whitelist ----
_OPEN_RE = re.compile(r"^\d{4}-\d{2}-\d{2}\s+open\s+([A-Z][A-Za-z0-9:-]+)\b")
_CLOSE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}\s+close\s+([A-Z][A-Za-z0-9:-]+)\b")
_INCLUDE_RE = re.compile(r'^include\s+"([^"]+)"\s*$')


def iter_ledger_lines(path: Path, seen=None):
    seen = seen or set()
    full = path.resolve()
    if full in seen or not full.exists():
        return
    seen.add(full)
    for raw in full.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        include_match = _INCLUDE_RE.match(line)
        if include_match:
            yield from iter_ledger_lines(full.parent / include_match.group(1), seen)
            continue
        yield raw


def load_allowed_accounts():
    opened = set()
    closed = set()
    if not MAIN_BEAN.exists():
        return opened
    for raw in iter_ledger_lines(MAIN_BEAN):
        line = raw.strip()
        open_match = _OPEN_RE.match(line)
        if open_match:
            account = open_match.group(1)
            opened.add(account)
            closed.discard(account)
            continue
        close_match = _CLOSE_RE.match(line)
        if close_match:
            closed.add(close_match.group(1))
    return opened - closed


ALLOWED_ACCOUNTS = load_allowed_accounts()

_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def validate_entry(entry: dict) -> list[str]:
    """Return list of validation errors (empty = valid)."""
    errors = []

    if not entry.get("date"):
        errors.append("缺少 'date' 字段")
    elif not isinstance(entry["date"], str) or not _DATE_RE.match(entry["date"]):
        errors.append(f"日期格式无效: {entry['date']}（应为 YYYY-MM-DD）")
    else:
        try:
            from datetime import datetime
            datetime.strptime(entry["date"], "%Y-%m-%d")
        except ValueError:
            errors.append(f"日期无效: {entry['date']}")

    if not entry.get("payee") or not isinstance(entry["payee"], str):
        errors.append("缺少 'payee' 字段")

    postings = entry.get("postings", [])
    if len(postings) < 2:
        errors.append("至少需要 2 条 postings")

    total = 0.0
    for i, p in enumerate(postings):
        acct = p.get("account", "")
        if acct not in ALLOWED_ACCOUNTS:
            errors.append(f"Posting {i+1}: 账户 '{acct}' 不在白名单中")
        amt_str = p.get("amount", "")
        try:
            total += float(amt_str)
        except (ValueError, TypeError):
            errors.append(f"Posting {i+1}: 金额无效 '{amt_str}'")
        if p.get("currency", "CNY") != "CNY":
            errors.append(f"Posting {i+1}: 只支持 CNY")

    if abs(total) > 0.005:
        errors.append(f"Postings 不平衡 (sum={total:.2f}, 期望 0)")

    return errors


def entry_to_bean(entry: dict) -> str:
    """Convert a validated entry dict to Beancount text."""
    lines = []
    tag_part = ""
    if entry.get("tags"):
        tag_part = " " + " ".join(f"#{t}" for t in entry["tags"])
    narration = entry.get("narration", "")
    payee = entry["payee"]
    lines.append(f'{entry["date"]} * "{_escape(payee)}" "{_escape(narration)}"{tag_part}')

    for key, value in sorted((entry.get("metadata") or {}).items()):
        lines.append(f"  {key}: {_meta_value(value)}")

    for p in entry["postings"]:
        acct = p["account"].ljust(34)
        amt = p["amount"].rjust(12)
        curr = p.get("currency", "CNY")
        lines.append(f"  {acct} {amt} {curr}")

    return "\n".join(lines) + "\n"


def _escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def _meta_value(v) -> str:
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, (int, float)):
        return str(v)
    return f'"{_escape(str(v))}"'


def _tx_file_for_date(date_str: str) -> Path:
    """Get the transactions file path for a given date: transactions/YYYY/MM.bean."""
    year, month = date_str[:4], date_str[5:7]
    return TRANSACTIONS_DIR / year / f"{month}.bean"


def acquire_lock() -> int:
    """Acquire exclusive file lock. Returns fd."""
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(LOCK_FILE), os.O_CREAT | os.O_RDWR)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def release_lock(fd: int):
    """Release file lock and close fd."""
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    except Exception:
        pass
    try:
        os.close(fd)
    except Exception:
        pass


def run_bean_check() -> subprocess.CompletedProcess:
    """Run bean-check against main.bean."""
    env = os.environ.copy()
    env["PATH"] = f"{Path.home() / '.local' / 'bin'}:{env.get('PATH', '')}"
    return subprocess.run(
        [_BEAN_CHECK, str(MAIN_BEAN)],
        cwd=str(LEDGER_ROOT),
        capture_output=True,
        text=True,
        timeout=30,
        env=env,
    )


def ensure_included(tx_rel_path: str):
    """Ensure main.bean has an include line for the given relative path."""
    include_line = f'include "{tx_rel_path}"'
    content = MAIN_BEAN.read_text(encoding="utf-8")
    if include_line in content:
        return  # Already included

    # Find the last transaction include line and add after it
    lines = content.splitlines()
    last_tx_include_idx = -1
    for i, line in enumerate(lines):
        if re.match(r'^\s*include\s+"transactions/', line):
            last_tx_include_idx = i

    if last_tx_include_idx >= 0:
        lines.insert(last_tx_include_idx + 1, include_line)
    else:
        # No transaction includes yet — add after accounts.bean include
        for i, line in enumerate(lines):
            if 'accounts.bean' in line:
                lines.insert(i + 1, include_line)
                break
        else:
            # Fallback: add at end
            lines.append(include_line)

    MAIN_BEAN.write_text("\n".join(lines) + "\n", encoding="utf-8")


def append_entry(entry: dict) -> dict:
    """Append a validated entry to the ledger. Returns result dict."""
    bean_text = entry_to_bean(entry)
    tx_file = _tx_file_for_date(entry["date"])
    tx_rel = str(tx_file.relative_to(LEDGER_ROOT))
    main_before = MAIN_BEAN.read_text(encoding="utf-8") if MAIN_BEAN.exists() else ""
    is_new_file = not tx_file.exists()
    tx_before = ""

    fd = acquire_lock()
    try:
        # Ensure directory exists
        tx_file.parent.mkdir(parents=True, exist_ok=True)

        # Read current transaction file content
        if not is_new_file:
            tx_before = tx_file.read_text(encoding="utf-8")

        # Append — always ensure proper block separation
        before_clean = tx_before.rstrip("\n") if not is_new_file else ""
        if before_clean:
            after = before_clean + "\n\n" + bean_text.rstrip() + "\n"
        else:
            after = bean_text.rstrip() + "\n"
        tx_file.write_text(after, encoding="utf-8")

        # Ensure include in main.bean (for new files)
        if is_new_file:
            ensure_included(tx_rel)

        # Run bean-check
        result = run_bean_check()
        if result.returncode != 0:
            # Rollback
            if is_new_file:
                tx_file.unlink(missing_ok=True)
                # Revert main.bean if we modified it
                if main_before != MAIN_BEAN.read_text(encoding="utf-8"):
                    MAIN_BEAN.write_text(main_before, encoding="utf-8")
            elif tx_before:
                tx_file.write_text(tx_before, encoding="utf-8")
            else:
                tx_file.unlink(missing_ok=True)

            return {
                "ok": False,
                "error": f"bean-check 失败:\n{result.stderr.strip() or result.stdout.strip()}",
            }

        return {
            "ok": True,
            "beanText": bean_text.rstrip(),
            "file": str(tx_file),
            "new_file": is_new_file,
            "message": f"已写入 {tx_rel}，通过 bean-check",
        }
    finally:
        release_lock(fd)


def main():
    raw = ""
    if len(sys.argv) > 1:
        raw = sys.argv[1]
    elif not sys.stdin.isatty():
        raw = sys.stdin.read().strip()

    if not raw:
        print(json.dumps({"ok": False, "error": "无输入。请通过管道或参数传入 JSON。"}))
        sys.exit(1)

    try:
        entry = json.loads(raw)
    except json.JSONDecodeError as e:
        print(json.dumps({"ok": False, "error": f"JSON 无效: {e}"}))
        sys.exit(1)

    errors = validate_entry(entry)
    if errors:
        print(json.dumps({"ok": False, "error": "校验失败", "details": errors}, ensure_ascii=False))
        sys.exit(1)

    result = append_entry(entry)
    print(json.dumps(result, ensure_ascii=False))
    if not result["ok"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
