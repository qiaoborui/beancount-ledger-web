#!/usr/bin/env python3
"""Opt-in synthetic large-ledger generator and staged timing benchmark.

Everything here is synthetic: payees, narrations, amounts, prices and metadata
come from a fixed PRNG seed, so a tier is reproducible and contains no real
ledger data or machine-specific paths.

    # Generate one tier (10k / 50k / 100k transactions, 240 month files).
    # Writes the ledger plus manifest.json next to it.
    python3 scripts/large_ledger_bench.py generate --tier 100k --output /tmp/ledger-100k

    # Assemble an importable directory for a physical device and check that
    # regenerating the tier is byte-reproducible.
    python3 scripts/large_ledger_bench.py assemble --tier 10k --workdir /tmp/blw-tiers
    python3 scripts/large_ledger_bench.py verify --tier 10k --workdir /tmp/blw-tiers

    # Generate all tiers and measure the real pipeline segments.
    python3 scripts/large_ledger_bench.py bench --tiers 10k,50k,100k

`generate` also writes `manifest.json` next to the ledger (transaction count,
directive counts by kind, source files, source bytes, expected canonical entry
count and stream bytes, and the sha256 of the generated source tree). The
manifest is the identity of the workload a measurement run claims to measure:
`verify` regenerates the same tier from the same seed and fails unless every
byte matches. `assemble` copies a tier into a directory the app accepts through
its catalog import path, deliberately leaving `manifest.json` out of it.

See docs/ios-large-ledger-measurement-protocol.md for the device procedure.

`bench` runs the real `App/LedgerMobile/Runtime/ledger_validator.py` export with
`LEDGER_VALIDATION_TIMINGS=1` (so the stream descriptor carries the
parse/booking/plugins/validate split) and then, unless `--no-go`, runs
`BenchmarkLocalScaleStages` in `server/internal/app` for the Go canonical
ingest, model registration and first-page/snapshot stages.

Nothing in this file runs from `go test`, `swift test` or CI: it is only
triggered by invoking the script. The interpreter must have beancount 3.2.3
installed (the same version the app bundles).
"""
import argparse
import hashlib
import json
import os
import platform
import random
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from collections import deque
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME_DIR = ROOT / "App" / "LedgerMobile" / "Runtime"
SERVER_DIR = ROOT / "server"

TIERS = {"10k": 10_000, "50k": 50_000, "100k": 100_000}
DEFAULT_SEED = 20261024
MONTHS = 240
START_YEAR = 2006

MANIFEST_NAME = "manifest.json"
# Version of the manifest layout below. Bump it when keys are renamed or
# removed so a stale manifest is rejected instead of being read as current.
MANIFEST_VERSION = 1
SOURCE_TREE_DIGEST_PREFIX = "sha256:"

# The app's catalog import copies the chosen directory into a staging
# generation before validating it, and LocalLedgerWorkspace.TreeLimits caps
# that tree at 10,000 entries (files and directories), 256 MiB of file bytes
# and a path depth of 32. `assemble` refuses a tier that would not fit.
IMPORT_TREE_LIMITS = {"entries": 10_000, "bytes": 256 * 1024 * 1024, "depth": 32}

# Synthetic Chinese payees and narrations. A real ledger never appears here.
PAYEES = (
    "老王生鲜", "巷口早餐铺", "社区药房", "地铁出行", "外卖平台",
    "房东", "电力公司", "宽带营业厅", "城南书店", "健身工坊",
    "咖啡小馆", "水果超市", "电商平台", "出租车", "电影院",
    "社区医院", "物业服务中心", "燃气公司", "手机营业厅", "商务酒店",
)
CNY_CATEGORIES = (
    ("Expenses:Food:Groceries", "买菜"),
    ("Expenses:Food:Dining", "午餐"),
    ("Expenses:Food:Dining", "晚餐"),
    ("Expenses:Transport:Metro", "地铁"),
    ("Expenses:Transport:Taxi", "打车"),
    ("Expenses:Home:Rent", "房租"),
    ("Expenses:Home:Utilities", "电费"),
    ("Expenses:Home:Utilities", "燃气费"),
    ("Expenses:Home:Internet", "宽带费"),
    ("Expenses:Health:Pharmacy", "买药"),
    ("Expenses:Leisure:Books", "买书"),
    ("Expenses:Leisure:Movies", "看电影"),
    ("Expenses:Leisure:Fitness", "健身"),
    ("Expenses:Shopping:Online", "网购"),
    ("Expenses:Food:Coffee", "咖啡"),
)
CNY_FUNDING = ("Assets:Bank:Checking", "Assets:Alipay", "Assets:WeChat", "Liabilities:CreditCard")
TAGS = ("monthly", "work", "travel", "family", "yearly")
STOCKS = ("HOOL", "BYND")

OPENED_ACCOUNTS = (
    "Assets:Bank:Checking CNY",
    "Assets:Bank:USD USD",
    "Assets:Cash CNY",
    "Assets:Cash:HKD HKD",
    "Assets:Alipay CNY",
    "Assets:WeChat CNY",
    "Assets:Broker:Stock HOOL,BYND",
    "Assets:Broker:Cash USD",
    "Liabilities:CreditCard CNY",
    "Income:Salary CNY",
    "Equity:Opening-Balances CNY",
)

COMMODITIES = ("CNY", "USD", "HKD", "HOOL", "BYND")


class LotBook:
    """Only tracks quantity; beancount's FIFO booking resolves the cost lots."""

    def __init__(self):
        self.remaining = {symbol: deque() for symbol in STOCKS}

    def available(self, symbol):
        return sum(self.remaining[symbol])

    def buy(self, symbol, quantity):
        self.remaining[symbol].append(quantity)

    def sell(self, symbol, quantity):
        lots = self.remaining[symbol]
        while quantity > 0:
            take = min(quantity, lots[0])
            lots[0] -= take
            quantity -= take
            if lots[0] == 0:
                lots.popleft()


def _transaction_line(day, payee, narration, tag, link):
    suffix = " #" + tag
    if link:
        suffix += " ^" + link
    return '{} * "{}" "{}"{}\n'.format(day.isoformat(), payee, narration, suffix)


def _metadata_lines(index):
    return ('  id: "tx-{:06d}"\n  source: "synthetic"\n'.format(index))


def generate(workspace, transactions, *, seed=DEFAULT_SEED, months=MONTHS, start_year=START_YEAR):
    """Write a balanced synthetic ledger and return a small summary dict."""
    workspace = Path(workspace)
    if workspace.exists():
        shutil.rmtree(workspace)
    transaction_dir = workspace / "transactions"
    transaction_dir.mkdir(parents=True)

    rng = random.Random(seed)
    counts = [transactions // months] * months
    for index in range(transactions % months):
        counts[index] += 1
    month_counts = {months - 1 - index: count for index, count in enumerate(counts)}

    stock_price = {"HOOL": 18.0, "BYND": 42.0}
    fx_rate = 7.10
    lots = LotBook()
    month_files = []
    transaction_index = 0
    written = 0
    # Directive counts by kind: what each generated file actually contains.
    # `auto_accounts` opens accounts on load, so the synthetic source never
    # carries `open` lines for the expense accounts it uses.
    directives = {"open": 0, "commodity": 0, "price": 0, "plugin": 0,
                  "option": 0, "include": 0, "transaction": 0}
    for month_index in range(months):
        year = start_year + month_index // 12
        month = month_index % 12 + 1
        count = month_counts[month_index]
        stock_price = {symbol: max(1.0, price * (1 + rng.uniform(-0.03, 0.04)))
                       for symbol, price in stock_price.items()}
        fx_rate = max(6.5, fx_rate * (1 + rng.uniform(-0.01, 0.01)))
        lines = []
        for position in range(count):
            # Ascending days inside the file keep FIFO buys before sells.
            day = date(year, month, 1 + (position * 28) // max(count, 1))
            tag = TAGS[transaction_index % len(TAGS)]
            link = "batch-{:04d}-{:02d}".format(year, month) if transaction_index % 10 == 0 else ""
            roll = rng.random()
            if roll < 0.045:
                amount = round(rng.uniform(18_000, 35_000), 2)
                body = ('  Income:Salary  -{:.2f} CNY\n  Assets:Bank:Checking\n'
                        .format(amount))
                lines.append(_transaction_line(day, "雇主", "月度工资", "work", link))
                lines.append(_metadata_lines(transaction_index))
                lines.append(body)
            elif roll < 0.165:
                symbol = STOCKS[transaction_index % len(STOCKS)]
                price = round(stock_price[symbol] * rng.uniform(0.97, 1.03), 2)
                if lots.available(symbol) > 0 and rng.random() < 0.5:
                    quantity = min(lots.available(symbol), rng.randint(5, 40))
                    lots.sell(symbol, quantity)
                    proceeds = round(quantity * price, 2)
                    body = ('  Assets:Broker:Stock  -{} {} {{}}\n'
                            '  Assets:Broker:Cash  {:.2f} USD\n'
                            '  Income:Invest:Gains\n'
                            .format(quantity, symbol, proceeds))
                    narration = "卖出 {}".format(symbol)
                else:
                    quantity = rng.choice((10, 20, 30, 50, 100))
                    cost = round(price + rng.uniform(-2.0, 2.0), 2)
                    lots.buy(symbol, quantity)
                    body = ('  Assets:Broker:Stock  {} {} {{{:.2f} USD}}\n'
                            '  Assets:Broker:Cash\n'
                            .format(quantity, symbol, cost))
                    narration = "买入 {}".format(symbol)
                lines.append(_transaction_line(day, "券商", narration, "work", link))
                lines.append(_metadata_lines(transaction_index))
                lines.append(body)
            elif roll < 0.22:
                usd = rng.randint(100, 900)
                rate = round(fx_rate, 2)
                lines.append(_transaction_line(day, "换汇", "美元结汇", "travel", link))
                lines.append(_metadata_lines(transaction_index))
                lines.append('  Assets:Bank:USD  -{} USD @ {:.2f} CNY\n'
                             '  Assets:Bank:Checking  {:.2f} CNY\n'
                             .format(usd, rate, usd * rate))
            elif roll < 0.29:
                amount = round(rng.uniform(5, 150), 2)
                lines.append(_transaction_line(day, rng.choice(PAYEES), "境外消费", "travel", link))
                lines.append(_metadata_lines(transaction_index))
                lines.append('  Expenses:Travel:US  {:.2f} USD\n'
                             '  Assets:Bank:USD\n'.format(amount))
            elif roll < 0.33:
                amount = round(rng.uniform(20, 1200), 2)
                lines.append(_transaction_line(day, "港澳商户", "港币消费", "travel", link))
                lines.append(_metadata_lines(transaction_index))
                lines.append('  Expenses:Travel:HongKong  {:.2f} HKD\n'
                             '  Assets:Cash:HKD\n'.format(amount))
            else:
                category, narration = CNY_CATEGORIES[transaction_index % len(CNY_CATEGORIES)]
                payee = PAYEES[transaction_index % len(PAYEES)]
                amount = round(rng.uniform(5, 800), 2)
                funding = CNY_FUNDING[transaction_index % len(CNY_FUNDING)]
                lines.append(_transaction_line(day, payee, narration, tag, link))
                lines.append(_metadata_lines(transaction_index))
                lines.append('  {}  {:.2f} CNY\n  {}\n'.format(category, amount, funding))
            transaction_index += 1
            written += 1
        month_files.append(("transactions/{:04d}-{:02d}.bean".format(year, month), "".join(lines)))

    price_lines = []
    for month_index in range(months):
        year = start_year + month_index // 12
        month = month_index % 12 + 1
        first = "{:04d}-{:02d}-01".format(year, month)
        for symbol in STOCKS:
            price_lines.append("{} price {} {:.2f} USD\n".format(first, symbol, stock_price[symbol]))
        price_lines.append("{} price USD {:.2f} CNY\n".format(first, round(fx_rate, 2)))

    write = lambda name, text: (workspace / name).write_text(text, encoding="utf-8")
    write("accounts.bean", "".join(
        "{} open {}\n".format("{:04d}-01-01".format(start_year), account)
        for account in OPENED_ACCOUNTS))
    write("commodities.bean", "".join(
        "{} commodity {}\n".format("{:04d}-01-01".format(start_year), commodity)
        for commodity in COMMODITIES))
    write("prices.bean", "".join(price_lines))
    for name, text in month_files:
        write(name, text)
    main = [
        'option "title" "Synthetic large ledger (generated)"\n',
        'option "operating_currency" "CNY"\n',
        # FIFO reductions let the generated sales match cost lots in order.
        'option "booking_method" "FIFO"\n',
        'plugin "beancount.plugins.auto_accounts"\n',
        'plugin "beancount.plugins.implicit_prices"\n',
        'include "accounts.bean"\n',
        'include "commodities.bean"\n',
        'include "prices.bean"\n',
        'include "transactions/*.bean"\n',
    ]
    write("main.bean", "".join(main))

    directives["open"] = len(OPENED_ACCOUNTS)
    directives["commodity"] = len(COMMODITIES)
    directives["price"] = len(price_lines)
    directives["plugin"] = sum(1 for line in main if line.startswith("plugin "))
    directives["option"] = sum(1 for line in main if line.startswith("option "))
    directives["include"] = sum(1 for line in main if line.startswith("include "))
    directives["transaction"] = written
    return {
        "transactions": written,
        "monthFiles": len(month_files),
        "months": months,
        "sourceFiles": len(month_files) + 4,
        "seed": seed,
        "directives": dict(directives),
    }


def _require_imports():
    sys.path.insert(0, str(RUNTIME_DIR))
    try:
        import ledger_validator
    except ImportError as error:  # pragma: no cover - environment guidance
        raise SystemExit(
            "benchmark needs beancount 3.2.3 in this interpreter: {}".format(error))
    return ledger_validator


# --- Manifest -----------------------------------------------------------------
#
# A tier is only a usable measurement workload if it can be re-identified later:
# "the 100k run" says nothing about which seed, which generator and which bytes
# produced that number. The manifest records the source tree digest and one
# canonical stream digest, and `verify` re-derives both from a fresh generation.


def _source_files(workspace):
    """Every regular file under `workspace` as relative POSIX paths.

    The generator's own manifest is excluded: it lives next to the ledger, but
    it describes the tree and must never be part of what it describes, or the
    digest would change the moment the manifest is written.
    """
    workspace = Path(workspace)
    found = []
    for path in workspace.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        relative = path.relative_to(workspace).as_posix()
        if relative == MANIFEST_NAME:
            continue
        found.append(relative)
    return sorted(found)


def _source_tree_sha256(workspace):
    """Digest the source tree by path, size and content, independent of mtime.

    The digest covers the Beancount sources only; the manifest itself is never
    an input, so writing it does not change the identity of the workload.
    """
    workspace = Path(workspace)
    digest = hashlib.sha256()
    files = []
    total_bytes = 0
    for relative in _source_files(workspace):
        data = (workspace / relative).read_bytes()
        total_bytes += len(data)
        file_digest = hashlib.sha256(data).hexdigest()
        files.append({"path": relative, "bytes": len(data), "sha256": file_digest})
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(file_digest.encode("ascii"))
        digest.update(b"\n")
    return SOURCE_TREE_DIGEST_PREFIX + digest.hexdigest(), files, total_bytes


def _stream_metrics(ledger_validator, workspace, entry="main.bean"):
    """Canonical entry count and stream bytes for this exact source tree.

    Uses the real export path the app uses, so the expected values match what a
    device run will register. The stream file is temporary and removed.
    """
    root = Path(workspace).resolve()
    with tempfile.TemporaryDirectory(prefix="blw-manifest-") as runtime:
        stream = Path(runtime) / "stream.records"
        payload = json.loads(ledger_validator.export_canonical_json(
            str(root), entry, str(stream)))
        if payload.get("errors"):
            raise SystemExit("synthetic ledger did not validate: {}".format(payload["errors"][:3]))
        descriptor = payload["stream"]
    return {
        "canonicalEntries": descriptor["entries"],
        "streamBytes": descriptor["bytes"],
        "streamSha256": descriptor["sha256"],
    }


def build_manifest(workspace, summary, stream=None, tier=None):
    """Describe one generated tier; `stream` is None when beancount is absent."""
    workspace = Path(workspace)
    tree_digest, files, total_bytes = _source_tree_sha256(workspace)
    manifest = {
        "manifestVersion": MANIFEST_VERSION,
        "generator": "scripts/large_ledger_bench.py",
        "seed": summary["seed"],
        "tier": tier,
        "transactions": summary["transactions"],
        "months": summary["months"],
        "monthFiles": summary["monthFiles"],
        "directiveCounts": summary["directives"],
        "sourceFileCount": len(files),
        "sourceBytes": total_bytes,
        "sourceTreeSha256": tree_digest,
        "sourceFiles": files,
        "canonical": None,
        "note": ("synthetic data generated from a fixed seed; no real ledger data. "
                 "Regenerate with the recorded seed to reproduce every digest here."),
    }
    if stream is not None:
        manifest["canonical"] = {
            "entrypoint": "main.bean",
            "entries": stream["canonicalEntries"],
            "streamBytes": stream["streamBytes"],
            "streamSha256": stream["streamSha256"],
        }
    return manifest


def _write_json(path, payload):
    Path(path).write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8")


def _check_importable(workspace, entry="main.bean"):
    """Fail early on trees the app's catalog import would reject.

    Mirrors the rules in `LocalLedgerWorkspace.importLedger`: a directory (not a
    link) entrypoint, no symbolic links, no filesystems objects other than
    regular files and directories, the TreeLimits budget, and case-insensitive
    path uniqueness. The app re-checks all of it on the device; this only turns
    a confusing import error into a local one.
    """
    workspace = Path(workspace)
    problems = []
    if workspace.is_symlink():
        problems.append("the tier directory is a symbolic link")
    if not (workspace / entry).is_file():
        problems.append("missing entrypoint {!r}".format(entry))
    entries = 0
    total_bytes = 0
    aliases = set()
    for path in sorted(workspace.rglob("*")):
        relative = path.relative_to(workspace).as_posix()
        entries += 1
        if path.is_symlink():
            problems.append("symbolic link: {}".format(relative))
            continue
        if not path.is_file() and not path.is_dir():
            problems.append("unsupported item: {}".format(relative))
            continue
        if len(relative.split("/")) > IMPORT_TREE_LIMITS["depth"]:
            problems.append("path too deep: {}".format(relative))
        if path.is_file():
            total_bytes += path.stat().st_size
        folded = relative.casefold()
        if folded in aliases:
            problems.append("case-insensitive duplicate path: {}".format(relative))
        aliases.add(folded)
    if entries + 1 > IMPORT_TREE_LIMITS["entries"]:
        problems.append("{} entries exceeds the {} entry limit".format(
            entries + 1, IMPORT_TREE_LIMITS["entries"]))
    if total_bytes > IMPORT_TREE_LIMITS["bytes"]:
        problems.append("{} bytes exceeds the {} byte limit".format(
            total_bytes, IMPORT_TREE_LIMITS["bytes"]))
    if problems:
        raise SystemExit("tier is not importable:\n  " + "\n  ".join(problems))
    return {"entries": entries + 1, "bytes": total_bytes}


def _manifest_diff(expected, actual, path=""):
    """Differences between two manifests, ignoring the fields `--transactions` changes."""
    differences = []
    for key in sorted(set(expected) | set(actual)):
        left, right = expected.get(key), actual.get(key)
        where = path + key
        if isinstance(left, dict) and isinstance(right, dict):
            differences.extend(_manifest_diff(left, right, where + "."))
        elif left != right:
            differences.append("{}: {} != {}".format(where, _short(left), _short(right)))
    return differences


def _short(value, limit=96):
    text = json.dumps(value, ensure_ascii=False, sort_keys=True) if not isinstance(value, str) else value
    return text if len(text) <= limit else text[:limit] + "..."


# --- Tiers on disk ------------------------------------------------------------


def tier_directory(workdir, tier):
    """`<workdir>/<tier>/ledger` holds the generated source, `<workdir>/<tier>` the records."""
    return Path(workdir) / tier / "ledger"


def device_directory(workdir, tier):
    """`<workdir>/<tier>/device` is the directory copied to the device."""
    return Path(workdir) / tier / "device"


def importable_files(workspace):
    """Source files the app should see: everything except the generator's manifest."""
    return [name for name in _source_files(workspace) if name != MANIFEST_NAME]


def _generate_tier(workdir, tier, seed, count=None):
    ledger = tier_directory(workdir, tier)
    summary = generate(ledger, count if count is not None else TIERS[tier], seed=seed)
    try:
        ledger_validator = _require_imports()
    except SystemExit:
        if count is not None:
            raise
        sys.stderr.write("beancount 3.2.3 is not importable here; manifest without canonical metrics\n")
        stream = None
    else:
        stream = _stream_metrics(ledger_validator, ledger)
    manifest = build_manifest(ledger, summary, stream=stream, tier=tier if count is None else None)
    _write_json(ledger / MANIFEST_NAME, manifest)
    return summary, manifest


def _print_manifest(tier, workdir, manifest):
    canonical = manifest["canonical"] or {}
    print("{}: {} transactions, {} month files, {} source files, {} source bytes".format(
        tier, manifest["transactions"], manifest["monthFiles"],
        manifest["sourceFileCount"], manifest["sourceBytes"]))
    print("  directives: {}".format(", ".join(
        "{} {}".format(kind, manifest["directiveCounts"][kind])
        for kind in sorted(manifest["directiveCounts"]))))
    print("  source tree: {}".format(manifest["sourceTreeSha256"]))
    if canonical:
        print("  canonical: {} entries, {} bytes, stream {}".format(
            canonical["entries"], canonical["streamBytes"], canonical["streamSha256"]))
    print("  manifest:   {}".format(tier_directory(workdir, tier) / MANIFEST_NAME))


def _timed(call):
    """Wall and this-process CPU milliseconds.

    CPU time stays comparable when the machine is busy with other work, so it
    is reported next to the wall time the user actually feels.
    """
    cpu_started = time.process_time()
    started = time.perf_counter()
    value = call()
    return (value, (time.perf_counter() - started) * 1000.0,
            (time.process_time() - cpu_started) * 1000.0)


def _load_stages(ledger_validator, workspace, runtime_dir, seed, attempt=0, keep_stream=True):
    """Run the real export once and split loader, preflight and stream write."""
    root = workspace.resolve()
    entry = (root / "main.bean").resolve()
    stream_dir = runtime_dir / "canonical-stream"
    stream_dir.mkdir(parents=True, exist_ok=True)
    _, preflight_ms, preflight_cpu_ms = _timed(
        lambda: ledger_validator._preflight(root, entry))
    stream_name = hashlib.sha256(
        "{}:{}:{}".format(seed, workspace, attempt).encode("utf-8")).hexdigest()[:32] + ".records"
    output = stream_dir / stream_name
    streamed, export_ms, export_cpu_ms = _timed(
        lambda: ledger_validator.export_canonical_json(
            str(root), "main.bean", str(output)))
    payload = json.loads(streamed)
    if payload["errors"]:
        output.unlink(missing_ok=True)
        raise SystemExit("synthetic ledger did not validate: {}".format(payload["errors"][:3]))
    descriptor = payload["stream"]
    timings = descriptor["timings"]
    loader_ms = sum(timings.values())
    run = {
        "preflightMs": round(preflight_ms, 1),
        "preflightCpuMs": round(preflight_cpu_ms, 1),
        "exportMs": round(export_ms, 1),
        "exportCpuMs": round(export_cpu_ms, 1),
        "loaderMs": round(loader_ms, 1),
        "exportNonLoaderMs": round(export_ms - loader_ms, 1),
        "stages": timings,
        "entries": descriptor["entries"],
        "streamBytes": descriptor["bytes"],
        "streamSha256": descriptor["sha256"],
    }
    if not keep_stream:
        output.unlink(missing_ok=True)
    return run


def _run_go_stages(tier_root):
    result_path = tier_root / "go-stages.json"
    environment = dict(os.environ)
    environment.update({
        "LOCAL_LEDGER_SCALE_BENCHMARK": "1",
        "LOCAL_LEDGER_SCALE_DIR": str(tier_root),
        "LOCAL_LEDGER_SCALE_RESULT": str(result_path),
    })
    command = ["go", "test", "./internal/app", "-run", "^$",
               "-bench", "^BenchmarkLocalScaleStages$", "-benchtime", "1x", "-count", "1"]
    completed = subprocess.run(command, cwd=str(SERVER_DIR), env=environment,
                               capture_output=True, text=True)
    if completed.returncode != 0 or not result_path.exists():
        sys.stderr.write("Go benchmark failed (exit {}):\n{}\n{}\n".format(
            completed.returncode, completed.stdout, completed.stderr))
        return None
    return json.loads(result_path.read_text(encoding="utf-8"))


def _format_ms(value):
    return "{:9.1f} ms".format(value)


def _format_mb(value):
    return "{:.0f} MiB".format(value / (1024 * 1024))


def _report(tier, count, summary, python, go):
    print("\n=== {} tier: {} transactions, {} month files ===".format(
        tier, summary["transactions"], summary["monthFiles"]))
    print("python (real ledger_validator.py export):")
    print("  preflight (standalone)      {}".format(_format_ms(python["preflightMs"])))
    for name in ("parse", "booking", "plugins", "validate"):
        print("  loader {:<21}{}".format(name, _format_ms(python["stages"][name])))
    print("  loader total               {}".format(_format_ms(python["loaderMs"])))
    print("  export total               {}".format(_format_ms(python["exportMs"])))
    print("  export non-loader          {}".format(_format_ms(python["exportNonLoaderMs"])))
    print("  export cpu (this process)  {}".format(_format_ms(python["exportCpuMs"])))
    print("  stream {} entries, {} (sha256 {})".format(
        python["entries"], _format_mb(python["streamBytes"]), python["streamSha256"][:12]))
    if go is None:
        print("go: unavailable (pass --no-go to hide, or check the go toolchain)")
        return
    print("go (canonical ingest / register / first page):")
    for stage in go["stages"]:
        print("  {:<27}{}".format(stage["name"], _format_ms(stage["ms"])))
    print("  entries {}  stream {}".format(go["entries"], _format_mb(go["streamBytes"])))
    print("  live heap after register   {}".format(_format_mb(go["heapAllocBytes"])))
    print("  allocated by this run      {}".format(_format_mb(go["totalAllocBytes"])))


def bench(args):
    ledger_validator = _require_imports()
    requested = [tier.strip() for tier in args.tiers.split(",") if tier.strip()]
    unknown = [tier for tier in requested if tier not in TIERS]
    if unknown:
        raise SystemExit("unknown tiers: {} (choose from {})".format(
            unknown, ", ".join(TIERS)))
    if len({TIERS[tier] for tier in requested}) != len(requested):
        raise SystemExit("tiers resolve to duplicate transaction counts")

    workdir = args.workdir or Path(tempfile.mkdtemp(prefix="blw-large-ledger-"))
    workdir.mkdir(parents=True, exist_ok=True)
    metadata = {
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "cpuCount": os.cpu_count(),
        "python": sys.version.split()[0],
        "seed": args.seed,
        "note": "synthetic data, local machine only; not a physical-device measurement",
    }
    print("workdir: {}".format(workdir))
    print("host: {} / {} CPUs / Python {} / beancount 3.2.3".format(
        platform.platform(), os.cpu_count(), sys.version.split()[0]))
    results = {}
    for tier in requested:
        count = TIERS[tier]
        tier_root = workdir / tier
        if tier_root.exists():
            shutil.rmtree(tier_root)
        workspace = tier_root / "generations" / "bench" / "workspace"
        runtime_dir = tier_root / "runtime"
        print("\n-- generating {} ({} transactions) --".format(tier, count))
        summary, generation_ms, _ = _timed(
            lambda: generate(workspace, count, seed=args.seed))
        print("   generated {} transactions in {} month files ({} ms)".format(
            summary["transactions"], summary["monthFiles"], round(generation_ms)))
        os.environ[ledger_validator.TIMINGS_ENVIRONMENT] = "1"
        runs = []
        # Source files and the parser's imports warm the OS page cache on the
        # first export; a discarded warm-up keeps cross-version comparisons fair.
        for warmup in range(max(args.warmup, 0)):
            _load_stages(ledger_validator, workspace, runtime_dir, args.seed,
                         attempt=1000 + warmup, keep_stream=False)
        print("-- python export x{} ({} warm-up) --".format(
            max(args.repeat, 1), max(args.warmup, 0)))
        for attempt in range(max(args.repeat, 1)):
            # Keep only the first stream: the Go benchmark ingests that one.
            run = _load_stages(ledger_validator, workspace, runtime_dir, args.seed,
                               attempt=attempt, keep_stream=attempt == 0)
            runs.append(run)
            print("   run {}: loader {} / export {}".format(
                attempt + 1, _format_ms(run["loaderMs"]), _format_ms(run["exportMs"])))
        python = {
            "preflightMs": statistics.median(run["preflightMs"] for run in runs),
            "preflightCpuMs": statistics.median(run["preflightCpuMs"] for run in runs),
            "loaderMs": statistics.median(run["loaderMs"] for run in runs),
            "exportMs": statistics.median(run["exportMs"] for run in runs),
            "exportCpuMs": statistics.median(run["exportCpuMs"] for run in runs),
            "exportNonLoaderMs": statistics.median(run["exportNonLoaderMs"] for run in runs),
            "stages": {name: statistics.median(run["stages"][name] for run in runs)
                       for name in ("parse", "booking", "plugins", "validate")},
            "entries": runs[0]["entries"],
            "streamBytes": runs[0]["streamBytes"],
            "streamSha256": runs[0]["streamSha256"],
            "runs": runs,
        }
        go = None if args.no_go else _run_go_stages(tier_root)
        _report(tier, count, summary, python, go)
        results[tier] = {"summary": summary, "python": python, "go": go}
        (tier_root / "baseline.json").write_text(json.dumps(
            {"metadata": metadata, "tier": tier, "transactions": count,
             "summary": summary, "python": python, "go": go},
            ensure_ascii=False, indent=2), encoding="utf-8")
    (workdir / "baseline.json").write_text(json.dumps(
        {"metadata": metadata, "tiers": results}, ensure_ascii=False, indent=2),
        encoding="utf-8")
    print("\nwrote {}".format(workdir / "baseline.json"))
    return 0


# --- Device tier workflow -----------------------------------------------------


def verify(args):
    """Regenerate a tier from its recorded seed and require identical bytes."""
    ledger = tier_directory(args.workdir, args.tier)
    manifest_path = ledger / MANIFEST_NAME
    if not manifest_path.is_file():
        raise SystemExit("no manifest at {}; run `generate` or `assemble` first".format(manifest_path))
    expected = json.loads(manifest_path.read_text(encoding="utf-8"))
    if expected.get("manifestVersion") != MANIFEST_VERSION:
        raise SystemExit("manifest version {} is not {}; regenerate the tier".format(
            expected.get("manifestVersion"), MANIFEST_VERSION))
    # The files actually sitting in the tier must still be the ones the
    # manifest describes; otherwise a hand edit would go unnoticed, because the
    # regeneration below never reads the existing tier.
    on_disk_digest, on_disk_files, _ = _source_tree_sha256(ledger)
    problems = []
    if on_disk_digest != expected["sourceTreeSha256"]:
        problems.append("the files in {} no longer match the manifest "
                        "(on disk {}, manifest {})".format(
                            ledger, on_disk_digest, expected["sourceTreeSha256"]))
    elif len(on_disk_files) != expected["sourceFileCount"]:
        problems.append("{} files on disk, {} in the manifest".format(
            len(on_disk_files), expected["sourceFileCount"]))
    if problems:
        raise SystemExit("cannot verify {}:\n  {}".format(args.tier, "\n  ".join(problems)))
    with tempfile.TemporaryDirectory(prefix="blw-verify-") as temporary:
        regenerated = Path(temporary) / "ledger"
        summary = generate(regenerated, expected["transactions"], seed=expected["seed"])
        actual = build_manifest(regenerated, summary, stream=None, tier=expected.get("tier"))
        # The original manifest carries canonical metrics that need beancount;
        # the source-tree part is what byte reproducibility means here.
        differences = []
        for key in ("sourceTreeSha256", "sourceBytes", "sourceFileCount", "sourceFiles",
                    "transactions", "directiveCounts"):
            if expected.get(key) != actual.get(key):
                differences.append(key)
        if not differences:
            try:
                ledger_validator = _require_imports()
            except SystemExit:
                pass
            else:
                stream = _stream_metrics(ledger_validator, regenerated)
                recorded = expected.get("canonical")
                if not recorded:
                    print("note: the original manifest has no canonical metrics; "
                          "re-run assemble on a machine with beancount to record them")
                elif (recorded.get("entries"), recorded.get("streamBytes"),
                      recorded.get("streamSha256")) != (
                          stream["canonicalEntries"], stream["streamBytes"],
                          stream["streamSha256"]):
                    differences.append("canonical")
                actual["canonical"] = {
                    "entrypoint": "main.bean",
                    "entries": stream["canonicalEntries"],
                    "streamBytes": stream["streamBytes"],
                    "streamSha256": stream["streamSha256"],
                }
        if differences:
            for difference in _manifest_diff(expected, actual):
                print("  differs: {}".format(difference))
            raise SystemExit("{} is not reproducible: {}".format(args.tier, ", ".join(differences)))
    print("{} is reproducible: {} files, {} bytes, tree {} (seed {})".format(
        args.tier, expected["sourceFileCount"], expected["sourceBytes"],
        expected["sourceTreeSha256"], expected["seed"]))
    if expected.get("canonical"):
        print("  canonical stream {} entries, {} bytes, {}".format(
            expected["canonical"]["entries"], expected["canonical"]["streamBytes"],
            expected["canonical"]["streamSha256"]))
    return 0


def assemble(args):
    """Produce the directory that gets copied to the device, and check it."""
    ledger = _copy_source_tier(args)
    destination = device_directory(args.workdir, args.tier)
    allowed = set(importable_files(ledger))
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    for relative in sorted(allowed):
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        # Never link: the app's import opens the source with O_NOFOLLOW and
        # rejects symbolic links anywhere in the tree.
        shutil.copyfile(ledger / relative, target)
    budget = _check_importable(destination)
    manifest_path = ledger / MANIFEST_NAME
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    _print_manifest(args.tier, args.workdir, manifest)
    print("  device dir: {}".format(destination))
    print("  import budget: {} entries (limit {}), {} bytes (limit {}), depth {}".format(
        budget["entries"], IMPORT_TREE_LIMITS["entries"], budget["bytes"],
        IMPORT_TREE_LIMITS["bytes"], IMPORT_TREE_LIMITS["depth"]))
    print("  the device directory must not contain {}".format(MANIFEST_NAME))
    return 0


def _copy_source_tier(args):
    """Return the tier's ledger directory, generating it when it is missing."""
    ledger = tier_directory(args.workdir, args.tier)
    manifest_path = ledger / MANIFEST_NAME
    if manifest_path.is_file():
        recorded = json.loads(manifest_path.read_text(encoding="utf-8"))
        if args.seed is not None and recorded.get("seed") != args.seed:
            raise SystemExit("{} was generated with seed {}; refusing a different workload".format(
                args.tier, recorded.get("seed")))
        return ledger
    if ledger.exists():
        shutil.rmtree(ledger)
    print("generating {} in {} (seed {})".format(args.tier, ledger, args.seed or DEFAULT_SEED))
    _generate_tier(args.workdir, args.tier, args.seed if args.seed is not None else DEFAULT_SEED)
    return ledger


def _read_notes(path):
    files = {}
    if path is not None:
        for name in sorted(Path(path).glob("*.json")):
            files[name.name] = json.loads(name.read_text(encoding="utf-8"))
    return files


def record(args):
    """Collect app recordings against a tier, refusing mismatched workloads."""
    ledger = tier_directory(args.workdir, args.tier)
    manifest_path = ledger / MANIFEST_NAME
    if not manifest_path.is_file():
        raise SystemExit("no manifest at {}; run assemble first".format(manifest_path))
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    recordings = {}
    failures = []
    for path in sorted(Path(args.input).glob("*.json")):
        payload = json.loads(path.read_text(encoding="utf-8"))
        workload = payload.get("workload") if isinstance(payload, dict) else None
        if not isinstance(workload, dict) or "sourceTreeSha256" not in workload:
            failures.append("{}: no workload.sourceTreeSha256".format(path.name))
        elif workload["sourceTreeSha256"] != manifest["sourceTreeSha256"]:
            failures.append("{}: measured a different ledger ({})".format(
                path.name, workload["sourceTreeSha256"]))
        else:
            recordings[path.name] = payload
    bundle = {
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "tier": args.tier,
        "manifest": manifest,
        "notes": _read_notes(args.notes),
        "recordings": recordings,
        "rejected": failures,
    }
    output = Path(args.output) if args.output else ledger / "measurement.json"
    _write_json(output, bundle)
    for failure in failures:
        print("  rejected: {}".format(failure))
    if failures:
        raise SystemExit("{} recording(s) do not match this tier's manifest".format(len(failures)))
    print("{} recording(s) matched the {} manifest".format(len(recordings), args.tier))
    print("wrote {}".format(output))
    return 0


def validate(args):
    """Load a ledger the way the app does and report its canonical metrics.

    This is the pre-flight for a device run: it is the same
    `ledger_validator.export_canonical_json` the app calls, so a ledger that
    passes here passes the device's import validation. It also prints the
    source-tree digest that a later recording must quote.
    """
    source = Path(args.source)
    tree_digest, files, total_bytes = _source_tree_sha256(source)
    ledger_validator = _require_imports()
    stream = _stream_metrics(ledger_validator, source, entry=args.entrypoint)
    print("{}: {} files, {} bytes, source tree {}".format(
        source, len(files), total_bytes, tree_digest))
    print("  entrypoint {}: {} canonical entries, {} stream bytes, stream {}".format(
        args.entrypoint, stream["canonicalEntries"], stream["streamBytes"],
        stream["streamSha256"]))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    subcommands = parser.add_subparsers(dest="command", required=True)

    generate_parser = subcommands.add_parser("generate", help="write one synthetic tier")
    generate_parser.add_argument("--tier", choices=sorted(TIERS), default="100k")
    generate_parser.add_argument("--transactions", type=int, help="override the tier count")
    generate_parser.add_argument("--output", type=Path, required=True)
    generate_parser.add_argument("--seed", type=int, default=DEFAULT_SEED)

    bench_parser = subcommands.add_parser("bench", help="measure all requested tiers")
    bench_parser.add_argument("--tiers", default="10k,50k,100k")
    bench_parser.add_argument("--workdir", type=Path, help="artifact directory (default: temp dir)")
    bench_parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    bench_parser.add_argument("--repeat", type=int, default=1,
                              help="python export runs per tier; medians are reported")
    bench_parser.add_argument("--warmup", type=int, default=1,
                              help="discarded warm-up exports per tier (default 1)")
    bench_parser.add_argument("--no-go", action="store_true", help="skip the Go stage benchmark")

    verify_parser = subcommands.add_parser(
        "verify", help="regenerate a tier from its manifest seed and compare digests")
    verify_parser.add_argument("--tier", choices=sorted(TIERS), required=True)
    verify_parser.add_argument("--workdir", type=Path, required=True,
                               help="directory holding <tier>/ledger/manifest.json")

    assemble_parser = subcommands.add_parser(
        "assemble", help="write the directory to copy to a device and check its import budget")
    assemble_parser.add_argument("--tier", choices=sorted(TIERS), required=True)
    assemble_parser.add_argument("--workdir", type=Path, required=True)
    assemble_parser.add_argument("--seed", type=int, default=None,
                                 help="generate the tier with this seed when it is missing")

    validate_parser = subcommands.add_parser(
        "validate", help="load a ledger through the app's export path and report its digests")
    validate_parser.add_argument("--source", type=Path, required=True,
                                 help="ledger directory; no --transactions needed")
    validate_parser.add_argument("--entrypoint", default="main.bean",
                                 help="entry file inside the directory (default: main.bean)")

    record_parser = subcommands.add_parser(
        "record", help="bundle app recordings that match this tier's manifest")
    record_parser.add_argument("--tier", choices=sorted(TIERS), required=True)
    record_parser.add_argument("--workdir", type=Path, required=True)
    record_parser.add_argument("--input", type=Path, required=True,
                               help="directory of recordings exported by the app")
    record_parser.add_argument("--notes", type=Path, default=None,
                               help="directory of session note JSON files")
    record_parser.add_argument("--output", type=Path, default=None,
                               help="bundle path (default: <tier>/ledger/measurement.json)")

    args = parser.parse_args()
    if args.command == "generate":
        count = args.transactions if args.transactions is not None else TIERS[args.tier]
        summary = generate(args.output, count, seed=args.seed)
        try:
            ledger_validator = _require_imports()
        except SystemExit:
            sys.stderr.write("beancount 3.2.3 is not importable here; "
                             "manifest without canonical metrics\n")
            stream = None
        else:
            stream = _stream_metrics(ledger_validator, args.output)
        # `--transactions N` no longer names one of the fixed tiers.
        manifest = build_manifest(args.output, summary, stream=stream,
                                  tier=args.tier if args.transactions is None else None)
        _write_json(Path(args.output) / MANIFEST_NAME, manifest)
        print(json.dumps({"output": str(args.output), **summary,
                          "manifest": manifest["sourceTreeSha256"],
                          "canonicalEntries": (manifest["canonical"] or {}).get("entries"),
                          "streamBytes": (manifest["canonical"] or {}).get("streamBytes")},
                         ensure_ascii=False, indent=2))
        return 0
    if args.command == "bench":
        return bench(args)
    if args.command == "verify":
        return verify(args)
    if args.command == "assemble":
        return assemble(args)
    if args.command == "validate":
        return validate(args)
    return record(args)



if __name__ == "__main__":
    sys.exit(main())
