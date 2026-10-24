#!/usr/bin/env python3
"""Opt-in synthetic large-ledger generator and staged timing benchmark.

Everything here is synthetic: payees, narrations, amounts, prices and metadata
come from a fixed PRNG seed, so a tier is reproducible and contains no real
ledger data or machine-specific paths.

    # Generate one tier (10k / 50k / 100k transactions, 240 month files).
    python3 scripts/large_ledger_bench.py generate --tier 100k --output /tmp/ledger-100k

    # Generate all tiers and measure the real pipeline segments.
    python3 scripts/large_ledger_bench.py bench --tiers 10k,50k,100k

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
    return {
        "transactions": written,
        "monthFiles": len(month_files),
        "months": months,
        "sourceFiles": len(month_files) + 4,
        "seed": seed,
    }


def _require_imports():
    sys.path.insert(0, str(RUNTIME_DIR))
    try:
        import ledger_validator
    except ImportError as error:  # pragma: no cover - environment guidance
        raise SystemExit(
            "benchmark needs beancount 3.2.3 in this interpreter: {}".format(error))
    return ledger_validator


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

    args = parser.parse_args()
    if args.command == "generate":
        count = args.transactions if args.transactions is not None else TIERS[args.tier]
        summary = generate(args.output, count, seed=args.seed)
        print(json.dumps({"output": str(args.output), **summary}, ensure_ascii=False, indent=2))
        return 0
    return bench(args)


if __name__ == "__main__":
    sys.exit(main())
