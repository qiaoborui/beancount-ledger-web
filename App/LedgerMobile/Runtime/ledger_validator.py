"""Canonical Beancount validation inside the application process.

The shipped parser and plugins are trusted application code. Imported ledgers
are data: preflight every parsed include before invoking loader transformations.
"""
import contextlib
import functools
import glob
import hashlib
import json
import os
import re
from datetime import date
from decimal import Decimal
from pathlib import Path

import beancount
from beancount import loader
from beancount.core import data
from beancount.core.amount import Amount
from beancount.ops import validation
from beancount.parser import booking, booking_full, parser


# Optional per-stage loader timings for the opt-in scale benchmark and the app's
# os_signpost instrumentation. Off by default: unset means the loader runs with
# log_timings=None and every payload keeps its original bytes. The app sets this
# variable before a canonical export, then reads the breakdown from the stream
# descriptor; the exported records themselves never change.
TIMINGS_ENVIRONMENT = "LEDGER_VALIDATION_TIMINGS"
_TIMING_LINE = re.compile(r"^Operation: '([^']+)'\s+Time:\s+([0-9.]+) ms$")
# Sum only the top-level loader stages. beancount's log_time nests per-file and
# per-validation-function entries under these, so counting nested lines too
# would bill the same milliseconds more than once.
_TIMED_LOAD_STAGES = {
    "parse": "parse",
    "booking": "booking",
    "run_transformations": "plugins",
    "beancount.ops.validate": "validate",
}


def _load_timings_enabled():
    return os.environ.get(TIMINGS_ENVIRONMENT, "").strip().lower() in {"1", "true", "yes", "on"}


def _timing_breakdown(lines):
    """Fold beancount's log_timings lines into per-stage milliseconds."""
    totals = {"parse": 0.0, "booking": 0.0, "plugins": 0.0, "validate": 0.0}
    for line in lines:
        match = _TIMING_LINE.match(line)
        if match is None:
            continue
        stage = _TIMED_LOAD_STAGES.get(match.group(1))
        if stage is not None:
            totals[stage] += float(match.group(2))
    return {stage: round(value, 3) for stage, value in totals.items()}


ALLOWED_PLUGINS = frozenset({
    "beancount.plugins.auto_accounts",
    "beancount.plugins.check_closing",
    "beancount.plugins.check_drained",
    "beancount.plugins.close_tree",
    "beancount.plugins.coherent_cost",
    "beancount.plugins.implicit_prices",
    "beancount.plugins.leafonly",
    "beancount.plugins.noduplicates",
    "beancount.plugins.nounused",
    "beancount.plugins.onecommodity",
    "beancount.plugins.sellgains",
    "beancount.plugins.unique_prices",
})


def _confined(root, path):
    candidate = Path(os.path.abspath(path))
    if not candidate.is_relative_to(root):
        raise ValueError("账本引用超出本地目录")
    current = root
    for part in candidate.relative_to(root).parts:
        current = current / part
        if current.is_symlink():
            raise ValueError("账本引用包含符号链接")
    if not candidate.resolve().is_relative_to(root):
        raise ValueError("账本引用超出本地目录")
    return candidate


# A file that can yield a policy-relevant directive contains at least one of
# these lowercase beancount keywords. The parser recognizes lowercase directive
# keywords only (an uppercase word is a flag or a syntax error), so a file
# without any of these bytes cannot hide an include, plugin, option, or
# Document. "document" also covers the "documents" option; "option" already
# covers insert_pythonpath values, which is listed anyway for reviewability.
# Any keyword hit keeps the parse-based policy checks below exactly as they
# were: this screen only removes a duplicate parse for files with nothing to
# check.
_POLICY_KEYWORDS = (
    b"include", b"plugin", b"option", b"document", b"insert_pythonpath",
)


def _may_declare_policy(filename):
    content = filename.read_bytes()
    return any(keyword in content for keyword in _POLICY_KEYWORDS)


def _preflight(root, entry):
    """Check every file the loader will read and return that file set."""
    pending, seen = [entry], set()
    while pending:
        filename = _confined(root, pending.pop())
        if filename in seen:
            continue
        seen.add(filename)
        if len(seen) > 10000:
            raise ValueError("账本引用文件数量超过限制")
        if filename.suffix.lower() in {".gpg", ".asc"}:
            raise ValueError("请先解密账本再导入")
        if not _may_declare_policy(filename):
            # The canonical loader below parses every file once; a file
            # without directive keywords has no options, plugin declarations,
            # includes, or Documents for preflight to check, so parsing it
            # here would only duplicate that work.
            continue
        entries, errors, options = parser.parse_file(str(filename))
        # Parser errors are returned by the canonical full load below; options
        # recovered by the parser still receive the same policy checks.
        if options.get("insert_pythonpath"):
            raise ValueError("本地账本仅支持应用内置插件，需移除 insert_pythonpath")
        for name, config in options.get("plugin", []):
            if name not in ALLOWED_PLUGINS:
                raise ValueError("本地账本暂不支持插件：" + name)
        for directory in options.get("documents", []):
            _confined(root, filename.parent / directory)
        for item in entries:
            if isinstance(item, data.Document):
                _confined(root, filename.parent / item.filename)
        for include in options.get("include", []):
            pattern = _confined(root, filename.parent / include)
            # Check each glob result before the loader can open it.
            pending.extend(_confined(root, path) for path in glob.glob(str(pattern)))
    return seen


def _amount(value):
    return {"Number": str(value.number), "Currency": value.currency}


def _metadata_value(value):
    if isinstance(value, Amount):
        # Metadata and custom values use the application's scalar API
        # contract; posting units/cost/price use _amount separately.
        return str(value)
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, (set, frozenset, tuple, list)):
        return [_metadata_value(item) for item in value]
    if value is None or isinstance(value, (str, bool, int, float)):
        return value
    return str(value)


@functools.lru_cache(maxsize=8192)
def _relative_source(root, filename):
    # Thousands of entries share a few source files; build each Path once.
    if filename and Path(filename).is_absolute() and Path(filename).is_relative_to(root):
        return str(Path(filename).relative_to(root))
    return filename


def _canonical_entry(root, entry, *, include_postings=True):
    """Export loader results directly; booking and plugin output stay intact.

    Decimal quantities remain strings across the language bridge. File/Line
    identify the original source; Go attaches the editor draft from that source
    independently of the transformed postings used by the read model.
    """
    meta = entry.meta or {}
    filename = _relative_source(root, meta.get("filename", ""))
    result = {"Kind": type(entry).__name__.lower(), "Date": entry.date.isoformat(),
              "File": filename, "Line": meta.get("lineno", 0),
              "Metadata": {key: _metadata_value(value) for key, value in meta.items()
                           if key not in {"filename", "lineno"} and not key.startswith("__")}}
    for field, key in (("account", "Account"), ("source_account", "Account2"),
                       ("currency", "Currency"), ("flag", "Flag"), ("payee", "Payee"),
                       ("narration", "Narration"), ("comment", "Narration"),
                       ("name", "Name"), ("query_string", "Value"),
                       ("description", "Value"), ("filename", "Filename")):
        value = getattr(entry, field, None)
        if value is not None:
            result[key] = value
    for field, key in (("currencies", "Currencies"), ("tags", "Tags"), ("links", "Links")):
        value = getattr(entry, field, None)
        if value is not None:
            result[key] = list(value) if field == "currencies" else sorted(value)
    if isinstance(entry, data.Event):
        result["Name"] = entry.type
    if isinstance(entry, (data.Balance, data.Price)):
        result["AmountValue"] = _amount(entry.amount)
        result["QuoteCurrency" if isinstance(entry, data.Price) else "Currency"] = entry.amount.currency
    if isinstance(entry, data.Balance) and entry.tolerance is not None:
        result["Tolerance"] = str(entry.tolerance)
    if isinstance(entry, data.Custom):
        result["CustomType"] = entry.type
        result["CustomValues"] = [_metadata_value(value.value) for value in entry.values]
    if include_postings and isinstance(entry, data.Transaction):
        result["Postings"] = [_canonical_posting(posting) for posting in entry.postings]
    return result


def _canonical_posting(posting):
    row = {"account": posting.account, "Quantity": _amount(posting.units)}
    if posting.flag:
        row["flag"] = posting.flag
    if posting.cost is not None:
        row["Cost"] = _amount(posting.cost)
        if posting.cost.date is not None:
            row["CostDate"] = posting.cost.date.isoformat()
        if posting.cost.label is not None:
            row["CostLabel"] = posting.cost.label
    if posting.price is not None:
        row["Price"] = _amount(posting.price)
    return row


STREAM_RECORD_LIMIT = 1 << 20
STREAM_TOTAL_LIMIT = 256 << 20

# Fields _canonical_entry projects from the raw directive. Which of them exist
# is a property of the directive class, so _ENTRY_FIELD_MAP resolves it once;
# this replaces seventeen hasattr probes per record. Unknown directive kinds
# fall back to probing every name, matching the previous behavior.
_EXPORT_ENTRY_FIELDS = (
    "account", "source_account", "currency", "flag", "payee", "narration",
    "comment", "name", "query_string", "description", "filename", "currencies",
    "tags", "links", "type", "amount", "tolerance",
)
_METADATA_UNEXPORTED = frozenset({"filename", "lineno"})


def _entry_field_map():
    return {
        cls: tuple(name for name in _EXPORT_ENTRY_FIELDS if hasattr(cls, name))
        for cls in (data.Open, data.Close, data.Commodity, data.Pad,
                    data.Balance, data.Transaction, data.Note, data.Event,
                    data.Query, data.Price, data.Document, data.Custom)
    }


_ENTRY_FIELD_MAP = _entry_field_map()


def _check_export_value(value, budget):
    """Conservative pre-allocation bound, including worst-case JSON escaping.

    This deliberately rejects pathological single records rather than building
    huge projected dicts/strings to discover that they exceed the wire limit.
    It stays the generic path for metadata values, options, and the small
    constant records; entries and postings have specialized checks below.
    """
    if budget < 0:
        raise ValueError("Canonical export record exceeds byte budget")
    if isinstance(value, str):
        cost = 6 * len(value) + 2
    elif isinstance(value, dict):
        budget -= 2
        for key, child in value.items():
            budget = _check_export_value(key, budget - 2)
            budget = _check_export_value(child, budget)
        return budget
    elif isinstance(value, (list, tuple, set, frozenset)):
        budget -= 2
        for child in value:
            budget = _check_export_value(child, budget - 1)
        return budget
    elif isinstance(value, Decimal):
        # Decimal wire spelling includes digits, exponent and sign.
        cost = len(value.as_tuple().digits) + 128
    elif isinstance(value, Amount):
        budget = _check_export_value(value.currency, budget)
        return _check_export_value(value.number, budget)
    elif value is None or isinstance(value, (bool, int, float, date)):
        cost = 128 if not isinstance(value, int) else max(128, value.bit_length() // 3 + 4)
    else:
        raise ValueError("Unsupported canonical stream metadata value")
    if cost > budget:
        raise ValueError("Canonical export record exceeds byte budget")
    return budget - cost


def _check_export_metadata(meta, budget):
    """Generic metadata dict walk with the common scalar values inlined.

    Mirrors _check_export_value's dict branch exactly: container cost, a
    two-byte key offset, then each key and value cost. Posting metadata is
    present on every booked posting, so this walk is on the per-posting path.
    """
    budget -= 2
    for key, value in meta.items():
        if type(key) is str:
            budget -= 6 * len(key) + 4
        else:
            budget = _check_export_value(key, budget - 2)
        if type(value) is str:
            budget -= 6 * len(value) + 2
        elif type(value) is int:
            budget -= max(128, value.bit_length() // 3 + 4)
        elif value is None or isinstance(value, (bool, float, date)):
            budget -= 128
        else:
            budget = _check_export_value(value, budget)
    return budget


def _check_export_entry(entry):
    """Bound one raw directive before _canonical_entry projects a dict.

    The cost model is exactly the generic one, specialized to the fields that
    are actually projected: scalar strings and string containers are costed
    inline and only metadata values, Amounts, Custom values, and None-valued
    fields take the generic walk. Oversized narration or metadata is therefore
    still rejected before any projected record exists.
    Metadata keys deliberately carry no dict-container offset here: the
    pre-specialization loop walked meta.items() directly, so its key cost was
    the bare string cost. Only posting metadata (which used to go through the
    generic dict walk) keeps the two-byte key offset in _check_export_metadata.
    """
    budget = STREAM_RECORD_LIMIT - 4096
    meta = entry.meta or {}
    for key, value in meta.items():
        if isinstance(key, str) and (key in _METADATA_UNEXPORTED or key.startswith("__")):
            continue
        if type(key) is str:
            budget -= 6 * len(key) + 2
        else:
            budget = _check_export_value(key, budget)
        if type(value) is str:
            budget -= 6 * len(value) + 2
        elif type(value) is int:
            budget -= max(128, value.bit_length() // 3 + 4)
        elif value is None or isinstance(value, (bool, float, date)):
            budget -= 128
        else:
            budget = _check_export_value(value, budget)
    # File is projected separately from source metadata.
    filename = meta.get("filename", "")
    if type(filename) is str:
        budget -= 6 * len(filename) + 2
    else:
        budget = _check_export_value(filename, budget)
    fields = _ENTRY_FIELD_MAP.get(type(entry))
    if fields is None:
        # Unknown directive kind: probe exactly like the generic version did.
        fields = tuple(name for name in _EXPORT_ENTRY_FIELDS if hasattr(entry, name))
    for field in fields:
        value = getattr(entry, field)
        if type(value) is str:
            budget -= 6 * len(value) + 2
        elif type(value) in (list, set, frozenset):
            budget -= 2
            for child in value:
                if type(child) is str:
                    budget -= 6 * len(child) + 3
                else:
                    budget = _check_export_value(child, budget - 1)
        else:
            budget = _check_export_value(value, budget)
    if isinstance(entry, data.Custom):
        for value in entry.values:
            budget = _check_export_value(value.value, budget)
    if budget < 0:
        raise ValueError("Canonical export record exceeds byte budget")


def _check_export_posting(posting):
    """Bound one raw posting with the same total as the generic tuple walk.

    The generic walk charges a container offset for the posting namedtuple and
    for Amount/Cost (both tuples), so those offsets are kept here to leave
    every accept/reject decision identical; only the per-field function calls
    and isinstance chains are removed.
    """
    budget = STREAM_RECORD_LIMIT - 4096 - 2
    account = posting.account
    if type(account) is str:
        budget -= 6 * len(account) + 3  # tuple child offset plus string cost
    else:
        budget = _check_export_value(account, budget - 1)
    units = posting.units
    if isinstance(units, Amount) and type(units.number) is Decimal and type(units.currency) is str:
        # Child offset + Amount container + one offset and cost per child.
        budget -= 5 + 6 * len(units.currency) + 2 + len(units.number.as_tuple().digits) + 128
    else:
        budget = _check_export_value(units, budget - 1)
    flag = posting.flag
    if flag is None:
        budget -= 129
    elif type(flag) is str:
        budget -= 6 * len(flag) + 3
    else:
        budget = _check_export_value(flag, budget - 1)
    cost = posting.cost
    if cost is None:
        budget -= 129
    else:
        # Child offset + Cost container + one offset per field.
        budget -= 7
        budget -= len(cost.number.as_tuple().digits) + 128
        budget -= 6 * len(cost.currency) + 2
        budget -= 128  # date, or None, both cost a fixed 128
        label = cost.label
        budget -= 128 if label is None else 6 * len(label) + 2
    price = posting.price
    if price is None:
        budget -= 129
    elif isinstance(price, Amount) and type(price.number) is Decimal and type(price.currency) is str:
        budget -= 5 + 6 * len(price.currency) + 2 + len(price.number.as_tuple().digits) + 128
    else:
        budget = _check_export_value(price, budget - 1)
    meta = posting.meta
    if meta is None:
        budget -= 129
    else:
        budget = _check_export_metadata(meta, budget - 1)
    if budget < 0:
        raise ValueError("Canonical export record exceeds byte budget")


# The stream must depend only on source bytes so that it can be reused for
# any copy of the same tree (a validated stage and the generation it becomes).
# input_hash serves Beancount's pickle cache, which the app never uses.
_LOCATION_DEPENDENT_OPTIONS = frozenset({"input_hash"})
_PATH_OPTIONS = frozenset({"filename", "include"})


def _exported_options(root, options):
    """The public option map is string-valued, matching the existing API.

    List options retain its last-declaration behavior.
    """
    values = {}
    for key, value in options.items():
        if key in _LOCATION_DEPENDENT_OPTIONS:
            continue
        if isinstance(value, list) and value and all(isinstance(item, str) for item in value):
            value = value[-1]
        if not isinstance(value, str):
            continue
        values[key] = _relative_option_path(root, value) if key in _PATH_OPTIONS else value
    return values


def _relative_option_path(root, value):
    path = Path(value)
    if path.is_absolute():
        try:
            return path.resolve().relative_to(root).as_posix()
        except (OSError, ValueError):
            return path.name
    return value


# The terminator is a constant record; the encoded-length check remains the
# authority for it, so it does not need a per-entry recursive bound.
_END_ENTRY_RECORD = {"type": "end_entry"}


def _write_canonical_stream(root, entries, options, output):
    """One bounded record at a time; never serialize an all-entry array.

    Called only after the canonical loader has validated successfully. This
    bounds additional serialization, not the canonical loader's booked AST.
    The caller owns an isolated output directory; never overwrite an artifact.
    """
    requested = Path(os.path.abspath(output))
    parent = requested.parent.resolve(strict=True)
    if parent == root or parent.is_relative_to(root):
        raise ValueError("Canonical export must be outside source workspace")
    # Use the resolved parent for the actual open as well as the confinement
    # check. System container paths can have aliases even when caller-owned.
    path = parent / requested.name
    digest = hashlib.sha256()
    total = 0
    count = 0
    encoder = json.JSONEncoder(ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        stream_file = os.fdopen(fd, "wb")
        fd = None  # ownership transferred
        with stream_file as stream:
            def emit(record, *, hashed=True, prechecked=False):
                nonlocal total
                # The worst-case bound (every character escaped) is checked
                # before encoding, so a single C-accelerated encode cannot
                # build an over-budget string; chunked iterencode runs the
                # pure-Python encoder and dominated export time. Entries and
                # postings were already bounded from their raw fields before
                # they were projected, and the terminator is constant, so they
                # skip a second recursive walk; the encoded length below stays
                # the authority.
                if not prechecked:
                    _check_export_value(record, STREAM_RECORD_LIMIT)
                encoded = encoder.encode(record).encode("utf-8") + b"\n"
                if len(encoded) > STREAM_RECORD_LIMIT:
                    raise ValueError("Canonical export record exceeds byte budget")
                if total + len(encoded) > STREAM_TOTAL_LIMIT:
                    raise ValueError("Canonical export exceeds total byte budget")
                stream.write(encoded)
                total += len(encoded)
                if hashed:
                    digest.update(encoded)

            emit({"type": "header", "version": 1})
            # Catalog records are separate so even many options do not require
            # a second aggregate dictionary or a huge header.
            for key, value in _exported_options(root, options).items():
                emit({"type": "option", "key": key, "value": value})
            for currency in sorted(set(options.get("commodities", ())) | set(options.get("operating_currency", ()))):
                emit({"type": "commodity", "value": currency})
            for entry in entries:
                _check_export_entry(entry)
                emit({"type": "entry", "entry": _canonical_entry(root, entry, include_postings=False)}, prechecked=True)
                if isinstance(entry, data.Transaction):
                    for posting in entry.postings:
                        _check_export_posting(posting)
                        emit({"type": "posting", "posting": _canonical_posting(posting)}, prechecked=True)
                emit(_END_ENTRY_RECORD, prechecked=True)
                count += 1
            checksum = digest.hexdigest()
            emit({"type": "footer", "entries": count, "sha256": checksum}, hashed=False)
            stream.flush()
            os.fsync(stream.fileno())
        return {"version": 1, "entries": count, "bytes": total, "sha256": checksum}
    except BaseException:
        if fd is not None:
            os.close(fd)
        # Our O_EXCL-created file only. Partial exports must never register.
        path.unlink(missing_ok=True)
        raise


def export_canonical_json(workspace, entry_file, output):
    """Validate and write a bounded stream; return only diagnostics/descriptor."""
    return _validate_json(workspace, entry_file, export_canonical=False, stream_output=output)


def validate_json(workspace, entry_file="main.bean"):
    """Compatibility entrypoint: validate and export the canonical read model."""
    return _validate_json(workspace, entry_file, export_canonical=True)


def validate_only_json(workspace, entry_file="main.bean"):
    """Run identical canonical validation without constructing unused read JSON."""
    return _validate_json(workspace, entry_file, export_canonical=False)


# beancount's loader can reuse a pickled (entries, errors, options) triple across
# processes, which on a 100k ledger replaces ~27s of parse+booking with a ~2s
# unpickle. Two reasons it is not enabled unconditionally here:
#
#  - Unpickling executes whatever the file says, so this module only ever reads a
#    cache file it can prove belongs to the current source version and that this
#    process created in a directory the caller handed us.
#  - beancount decides staleness from file mtimes. An app generation is written
#    to a new directory on every publish, so a mtime check alone would happily
#    reuse a cache for different content. The source version goes in the file
#    name instead: different content means a different cache file.
LOAD_CACHE_ENVIRONMENT = "LEDGER_LOAD_CACHE_DIR"
# A pickle holds beancount's own objects, so one written by another app build
# (different Python, beancount, plugins or this module) must never be read back.
# The caller passes its build fingerprint; without one the cache stays off.
LOAD_CACHE_RUNTIME_ENVIRONMENT = "LEDGER_LOAD_CACHE_RUNTIME"


@functools.lru_cache(maxsize=1)
def _load_cache_runtime_identity():
    import sys
    import beancount
    digest = hashlib.sha256()
    digest.update(sys.version.encode("utf-8"))
    digest.update(str(getattr(beancount, "__version__", "")).encode("utf-8"))
    try:
        digest.update(Path(__file__).read_bytes())
    except (NameError, OSError):
        return None
    return digest.digest()


def _load_cache_path(root, entry, files):
    """Return this call's cache file, or None when caching is off or unsafe.

    The caller opts in by setting LOAD_CACHE_ENVIRONMENT to a directory it owns
    and wrote itself, and LOAD_CACHE_RUNTIME_ENVIRONMENT to its build
    fingerprint. Anything surprising about that directory (missing, a symlink,
    not a directory) disables the cache rather than risking a read of a file
    this process did not create.
    """
    raw = os.environ.get(LOAD_CACHE_ENVIRONMENT, "").strip()
    runtime = os.environ.get(LOAD_CACHE_RUNTIME_ENVIRONMENT, "").strip()
    if not raw or not runtime:
        return None
    identity = _load_cache_runtime_identity()
    if identity is None:
        return None
    directory = _owned_directory(raw)
    if directory is None:
        return None
    # Identity of the content this load covers: the runtime that produced it,
    # the entry path, and every source file's path and digest, so a moved or
    # edited ledger or a different build cannot alias an older cache. `files` is
    # _preflight's result, i.e. exactly the include set the loader resolves.
    digest = hashlib.sha256()
    digest.update(runtime.encode("utf-8") + b"\0")
    digest.update(identity)
    digest.update(str(entry.resolve()).encode("utf-8"))
    for filename in sorted(files):
        relative = filename.relative_to(root).as_posix()
        digest.update(relative.encode("utf-8"))
        with open(filename, "rb") as handle:
            file_digest = hashlib.sha256()
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                file_digest.update(chunk)
        digest.update(file_digest.digest())
    return directory / (digest.hexdigest() + ".picklecache")


def _load_with_optional_cache(root, entry, files, log_timings):
    directory = _parse_cache_directory()
    load = functools.partial(_checkpointed_load, root, _booking_checkpoint_path(root, entry),
                             parse_cache=None if directory is None else _ParseCache(root, directory))
    cache_path = _load_cache_path(root, entry, files)
    if cache_path is None:
        # No cache directory offered: keep the original uncached pipeline.
        return load(str(entry), log_timings, validation.HARDCORE_VALIDATIONS, None)
    # Wrap the same pipeline in beancount's own pickle memoizer. Only our own
    # file name can be in this directory, and it is derived from the content
    # digest above, so it reads nothing we did not write. The threshold is read
    # per call so tests can force a write.
    cached = loader.pickle_cache_function(
        lambda _filename: str(cache_path), loader.PICKLE_CACHE_THRESHOLD, load)
    return cached(str(entry), log_timings, validation.HARDCORE_VALIDATIONS, None)


# Closed-period booking checkpoint.
#
# beancount's booking is a left fold over the date-sorted entries whose only
# state is each account's inventory (lots with cost, date and label); its own
# API accepts that state as `initial_balances`. So the booked transactions
# before a closing date, together with the inventories at that date, are a
# complete substitute for re-booking that prefix, as long as the prefix the
# fold would see is the same. Everything after booking (documents, the
# allowlisted plugins, pad, balance, and every validation) still runs over the
# whole ledger, so diagnostics and the exported model are those of a full load.
#
# What "the same prefix" covers, and why each part is in the key:
#  - the Transactions dated before the closing date, file by file, including
#    metadata and line numbers (they end up in the booked output); other
#    directives are taken from the fresh parse and never stored;
#  - the order of the files that contribute them (stable-sort tie-break);
#  - the five options booking reads and every account's booking method;
#  - the Python and beancount builds that produced the pickled objects.
# The app build is deliberately not in the key: booking is beancount's code, so
# a checkpoint survives an app update that keeps the same Python and beancount.
# Bump CHECKPOINT_FORMAT whenever the digest or the stored layout changes.
BOOKING_CHECKPOINT_ENVIRONMENT = "LEDGER_BOOKING_CHECKPOINT_DIR"
CHECKPOINT_FORMAT = 1
# The loader stages are re-composed below from beancount internals; any other
# version runs the stock loader until the composition is re-verified.
_CHECKPOINT_BEANCOUNT_VERSION = "3.2.3"
# Every options_map key read by booking.book / booking_full / interpolate.
_BOOKING_OPTIONS = ("booking_method", "use_precise_interpolation", "infer_tolerance_from_cost",
                    "tolerance_multiplier", "inferred_tolerance_default")
# The closing date is the first day of the month this many whole months before
# the current one, so the current and the previous CLOSED_MONTHS months stay
# open for edits without invalidating the checkpoint.
CLOSED_MONTHS = 2


def _today():
    return date.today()


@functools.lru_cache(maxsize=1)
def _checkpoint_runtime_identity():
    import sys
    return "\0".join((str(CHECKPOINT_FORMAT), sys.version, str(getattr(beancount, "__version__", ""))))


def _owned_directory(raw):
    """Return `raw` as a directory this process owns, or None."""
    if not raw:
        return None
    directory = Path(os.path.abspath(raw))
    try:
        info = os.lstat(directory)
    except OSError:
        return None
    import stat as _stat
    if not _stat.S_ISDIR(info.st_mode) or _stat.S_ISLNK(info.st_mode) or info.st_uid != os.getuid():
        return None
    return directory


def _booking_checkpoint_path(root, entry):
    if getattr(beancount, "__version__", "") != _CHECKPOINT_BEANCOUNT_VERSION:
        return None
    directory = _owned_directory(os.environ.get(BOOKING_CHECKPOINT_ENVIRONMENT, "").strip())
    if directory is None:
        return None
    # One checkpoint per entry file; generations and staging copies of the same
    # ledger share it, which is the point.
    name = hashlib.sha256(entry.relative_to(root).as_posix().encode("utf-8")).hexdigest()[:32]
    return directory / (name + ".bookcp")


def _closing_date(entries, today):
    # Anchor on the last entry when the ledger stops before today, so a ledger
    # that is not kept up to date still has open months at its end.
    anchor = min(today, entries[-1].date) if entries else today
    month = anchor.year * 12 + anchor.month - 1 - CLOSED_MONTHS
    return date(month // 12, month % 12 + 1, 1)


def _booking_key(options, methods):
    values = [(name, options[name]) for name in _BOOKING_OPTIONS]
    values.append(sorted((account, method) for account, method in methods.items()))
    return hashlib.sha256(repr(values).encode("utf-8")).hexdigest()


# Booking marks interpolated postings by adding this key to the parsed
# posting's own metadata dict, in place. The parser cannot produce it (metadata
# keys start with a lowercase letter), so leaving it out keeps a digest of the
# parsed input the same whether or not that input has been booked already.
_AUTOMATIC_META = "__automatic__"


def _source_meta(meta):
    return tuple((key, value) for key, value in (meta or {}).items()
                 if key != "filename" and key != _AUTOMATIC_META)


def _transaction_digest(transactions):
    """Digest parsed (unbooked) transactions independent of the ledger directory."""
    digest = hashlib.sha256()
    for entry in transactions:
        item = (entry.date, entry.flag, entry.payee, entry.narration,
                tuple(sorted(entry.tags or ())), tuple(sorted(entry.links or ())),
                _source_meta(entry.meta),
                tuple((posting.account, posting.units, posting.cost, posting.price, posting.flag,
                       _source_meta(posting.meta)) for posting in entry.postings))
        digest.update(repr(item).encode("utf-8"))
        digest.update(b"\n")
    return digest.hexdigest()


def _prefix_transactions_by_file(entries, end, file_order):
    """Group the transactions in entries[:end] by source file, in parse order."""
    groups = {}
    for entry in entries[:end]:
        if isinstance(entry, data.Transaction):
            groups.setdefault(entry.meta.get("filename"), []).append(entry)
    if len(groups) != sum(name in groups for name in file_order):
        raise ValueError("transaction outside the parsed file set")
    return [(name, groups[name]) for name in file_order if name in groups]


def _prefix_order(root, groups):
    return [Path(name).relative_to(root).as_posix() for name, _ in groups]


def _source_digest(filename, cache):
    digest = cache.get(filename)
    if digest is None:
        file_digest = hashlib.sha256()
        with open(filename, "rb") as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                file_digest.update(chunk)
        digest = cache[filename] = file_digest.hexdigest()
    return digest


def _prefix_files(root, groups, stored_files, file_digests):
    """Return {relative: (source sha256, transaction digest, count)} for the prefix.

    A file whose bytes match the stored ones parses to the same transactions,
    so when it also contributes as many of them as it did for the stored
    closing date (which is never later than this one), it contributes the same
    ones and its stored digest is reused instead of recomputed. That keeps a hit
    cheap when only open months' files changed, and moving the closing date
    forward only digests the files that gained closed transactions.
    """
    result = {}
    for filename, transactions in groups:
        relative = Path(filename).relative_to(root).as_posix()
        source = _source_digest(filename, file_digests)
        stored = stored_files.get(relative)
        if stored is not None and stored[0] == source and stored[2] == len(transactions):
            result[relative] = stored
        else:
            result[relative] = (source, _transaction_digest(transactions), len(transactions))
    return result


_CHECKPOINT_KEYS = frozenset({"runtime", "closing", "booking", "order", "files", "transactions", "balances"})


def _read_checkpoint(path):
    if path is None:
        return None
    import pickle
    try:
        with open(path, "rb") as handle:
            stored = pickle.load(handle)
    except Exception:
        # Missing, truncated or written by something else: rebuild it.
        return None
    if not isinstance(stored, dict) or stored.get("runtime") != _checkpoint_runtime_identity():
        return None
    if not _CHECKPOINT_KEYS <= stored.keys():
        return None
    return stored


def _write_checkpoint(path, checkpoint):
    import pickle
    temporary = path.with_name(path.name + ".tmp")
    try:
        with open(temporary, "wb") as handle:
            pickle.dump(checkpoint, handle, protocol=pickle.HIGHEST_PROTOCOL)
        os.replace(temporary, path)
    except OSError:
        # A checkpoint is an optimisation; failing to store one changes nothing.
        temporary.unlink(missing_ok=True)


def _encode_booked(parsed, booked):
    """Describe booked transactions as edits of their parsed counterparts.

    Unpickling 100k booked transactions costs about as much as booking them, so
    the checkpoint stores only what booking changed: per transaction, the
    automatic tolerances (interned; they are immutable and few) and, per booked
    posting, either the index of the parsed posting it kept as is, or that
    index plus the units, cost and price booking filled in and whether booking
    marked it interpolated. booking_full only ever derives postings with
    Posting._replace, which keeps the parsed posting's metadata object, so that
    object identifies the source posting; the interpolation mark is written
    into that shared dict, so decoding writes it into the fresh parse's.
    Returns None when a transaction does not fit this shape, and the caller
    then stores no checkpoint.
    """
    from beancount.core import interpolate
    tolerance_index, tolerances, patches = {}, [], []
    for source, result in zip(parsed, booked):
        by_meta = {id(posting.meta): index for index, posting in enumerate(source.postings)}
        spec = []
        for posting in result.postings:
            index = by_meta.get(id(posting.meta))
            if index is None:
                return None
            original = source.postings[index]
            if posting is original:
                spec.append(index)
            elif posting.account == original.account and posting.flag == original.flag:
                spec.append((index, posting.units, posting.cost, posting.price,
                             bool(posting.meta.get(_AUTOMATIC_META))))
            else:
                return None
        tolerance = result.meta.get(interpolate.AUTOMATIC_TOLERANCES)
        key = repr((getattr(tolerance, "default", None), sorted((tolerance or {}).items())))
        if key not in tolerance_index:
            tolerance_index[key] = len(tolerances)
            tolerances.append(tolerance)
        patches.append((tolerance_index[key], tuple(spec)))
    encoded = (tolerances, patches)
    if _decode_booked(parsed, encoded) != booked:
        return None
    return encoded


def _decode_booked(parsed, encoded):
    from beancount.core import interpolate
    tolerances, patches = encoded
    booked, marked = [], []
    for source, (tolerance, spec) in zip(parsed, patches, strict=True):
        postings = source.postings
        meta = source.meta.copy()
        meta[interpolate.AUTOMATIC_TOLERANCES] = tolerances[tolerance]
        result = []
        for item in spec:
            if type(item) is int:
                result.append(postings[item])
                continue
            original = postings[item[0]]
            if item[4]:
                marked.append(original.meta)
            result.append(original._replace(units=item[1], cost=item[2], price=item[3]))
        booked.append(source._replace(meta=meta, postings=result))
    # Everything that can fail has run; only now touch the parsed metadata, so
    # a failed decode leaves the parse fit for a full booking.
    for meta in marked:
        meta[_AUTOMATIC_META] = True
    return booked


def _checkpoint_prefix(root, entries, dates, file_order, stored, file_digests):
    """Return the length of the prefix `stored` was booked from, or None.

    It matches only when this parse has exactly the stored closed
    transactions, in the same file order, so booking them would reproduce the
    stored result.
    """
    import bisect
    end = bisect.bisect_left(dates, stored["closing"])
    groups = _prefix_transactions_by_file(entries, end, file_order)
    if _prefix_order(root, groups) != stored["order"]:
        return None
    # The source digest only short-cuts the comparison; a file whose bytes
    # changed outside its closed transactions (a later entry, a balance, a
    # comment at the end) still matches on its transactions.
    current = _prefix_files(root, groups, stored["files"], file_digests)
    if {name: value[1:] for name, value in current.items()} != {
            name: value[1:] for name, value in stored["files"].items()}:
        return None
    if sum(len(group) for _, group in groups) != len(stored["transactions"][1]):
        return None
    return end


def _book_with_checkpoint(root, entries, options, file_order, checkpoint_path):
    """booking.book(entries, options), reusing and refreshing a checkpoint.

    Returns (booked entries, errors, checkpoint to store or None). The errors
    are in booking.book's order: every booking error, then every
    incomplete-posting error.
    """
    import bisect
    import collections
    import pickle
    from beancount.core import inventory

    # booking.book derives these from every Open in the ledger; a segment must
    # not see only its own Opens.
    methods = collections.defaultdict(lambda: options["booking_method"])
    for item in entries:
        if isinstance(item, data.Open) and item.booking:
            methods[item.account] = item.booking
    booking_key = _booking_key(options, methods)
    closing = _closing_date(entries, _today())
    dates = [item.date for item in entries]
    file_digests = {}

    booked, booking_errors, missing_errors = [], [], []
    balances = collections.defaultdict(inventory.Inventory)
    start = 0
    stored = _read_checkpoint(checkpoint_path)
    previous_files = {}
    if stored is not None and stored["booking"] == booking_key and stored["closing"] <= closing:
        # Unchanged files keep their digests even when the prefix is not reused.
        previous_files = stored["files"]
        try:
            end = _checkpoint_prefix(root, entries, dates, file_order, stored, file_digests)
            if end is not None:
                prefix_balances = pickle.loads(stored["balances"])
                decoded = iter(_decode_booked(
                    [item for item in entries[:end] if isinstance(item, data.Transaction)],
                    stored["transactions"]))
        except Exception:
            # Whatever is wrong with a checkpoint only costs a full booking.
            end = None
        if end is not None:
            booked = [next(decoded) if isinstance(item, data.Transaction) else item for item in entries[:end]]
            balances = prefix_balances
            start = end
        else:
            stored = None
    else:
        stored = None

    def book_segment(segment):
        segment_booked, segment_errors = booking_full.book(segment, options, methods, balances)
        booked.extend(segment_booked)
        booking_errors.extend(segment_errors)
        missing_errors.extend(booking.validate_missing_eliminated(segment_booked, options))

    refreshed = None
    if stored is None or stored["closing"] < closing:
        end = bisect.bisect_left(dates, closing)
        book_segment(entries[start:end])
        start = end
        # Only an error-free prefix is stored: booking drops a transaction it
        # cannot categorize, and reuse relies on a one-to-one prefix.
        encoded = None
        if end and not booking_errors and not missing_errors:
            encoded = _encode_booked([item for item in entries[:end] if isinstance(item, data.Transaction)],
                                     [item for item in booked if isinstance(item, data.Transaction)])
        if encoded is not None:
            try:
                groups = _prefix_transactions_by_file(entries, end, file_order)
                refreshed = {
                    "runtime": _checkpoint_runtime_identity(),
                    "closing": closing,
                    "booking": booking_key,
                    "order": _prefix_order(root, groups),
                    "files": _prefix_files(root, groups, previous_files, file_digests),
                    # The inventories are serialised now, before the suffix is
                    # booked into them. The encoded transactions hold only
                    # immutable values and are safe to keep as objects.
                    "transactions": encoded,
                    "balances": pickle.dumps(balances, protocol=pickle.HIGHEST_PROTOCOL),
                }
            except (ValueError, OSError):
                # A transaction whose metadata names a file outside the
                # ledger (`filename:` is ordinary metadata) cannot be keyed;
                # book it in full every time instead of failing the load.
                refreshed = None
    book_segment(entries[start:])
    return booked, booking_errors + missing_errors, refreshed


# Per-file parse cache.
#
# beancount parses every file of a load on its own: each parse_file call
# starts a fresh grammar Builder, so a file's (entries, errors, options) are a
# function of its bytes and of the path the loader opens it by, nothing else.
# Options and pushed tags never leak into an included file, and the include
# walk, the duplicate checks and the option aggregation happen in the loader
# after each parse. So a stored parse of the same bytes, under the same
# relative path, is a complete substitute for re-parsing the file, as long as
# every place the parse records the path is rebound to the current directory.
#
# Only the meta "filename" values and the options' own "filename" carry the
# path in a clean parse. The stored form names neither: they are written back
# on decode. Anything else that would carry the directory (a Document's
# resolved path, the path quoted in an error message, a path typed into the
# file) makes the file uncacheable: a store refuses any payload that still
# contains the workspace path, and any source that contains it. Files with
# parse errors are never stored; the ledger is not loadable anyway.
#
# The entries are not pickled. Unpickling a parse costs about as much as
# parsing it, because every namedtuple, Decimal and date is rebuilt through
# Python; instead the immutable values are interned in a table and the
# entries reference it, in a marshal payload that decodes several times
# faster than parsing (100k transactions: about 0.5s against 3.5s). Decoded entries share equal immutable values (amounts,
# dates, cost specs); every metadata dict and list is a fresh object, as
# booking writes into posting metadata.
#
# The key is the file's relative path and bytes, the Python and beancount
# builds, the parts of the decimal context the parser's arithmetic uses, and
# PARSE_CACHE_FORMAT. One file per relative path is kept, so the directory
# holds at most one entry per ledger file and generations and staging trees
# share it. Bump PARSE_CACHE_FORMAT whenever the payload layout changes.
PARSE_CACHE_ENVIRONMENT = "LEDGER_PARSE_CACHE_DIR"
PARSE_CACHE_FORMAT = 1


def _parse_cache_directory():
    # _parse_recursive below is beancount 3.2.3's, and the payload knows its
    # directive types; any other version parses every file.
    if getattr(beancount, "__version__", "") != _CHECKPOINT_BEANCOUNT_VERSION:
        return None
    return _owned_directory(os.environ.get(PARSE_CACHE_ENVIRONMENT, "").strip())


def _parse_cache_identity():
    import decimal
    import sys
    context = decimal.getcontext()
    traps = sorted(signal.__name__ for signal, enabled in context.traps.items() if enabled)
    return repr((PARSE_CACHE_FORMAT, sys.version, getattr(beancount, "__version__", ""),
                 context.prec, context.rounding, context.Emin, context.Emax, context.capitals,
                 context.clamp, traps)).encode("utf-8")


class _Uncacheable(Exception):
    pass


@functools.lru_cache(maxsize=1)
def _parse_codec_types():
    from beancount.core import number, position
    from beancount.parser import grammar
    import datetime
    # Index 0 is the Transaction fast path; 1..11 are the other directives.
    directives = (data.Transaction, data.Open, data.Close, data.Commodity, data.Pad, data.Balance,
                  data.Note, data.Event, data.Query, data.Price, data.Document, data.Custom)
    # Immutable values that can sit in the table.
    values = (Amount, position.Cost, position.CostSpec, grammar.ValueType)
    # Singletons the parser returns by identity: number.MISSING, booking
    # methods, and the dtype of a custom value.
    constants = (number.MISSING, str, Decimal, bool, int, datetime.date, Amount) + tuple(data.Booking)
    return directives, values, constants


def _encode_parsed(entries, filename):
    """Return a marshal payload for a clean parse of `filename`, or raise _Uncacheable."""
    import datetime
    import marshal
    directives, values, constants = _parse_codec_types()
    directive_ids = {kind: index for index, kind in enumerate(directives)}
    value_ids = {kind: index for index, kind in enumerate(values)}
    constant_ids = {id(item): index for index, item in enumerate(constants)}
    table, index = [], {}

    def ref(value):
        kind = value.__class__
        if kind is str or kind is int or kind is bool or value is None:
            spec, key = value, (kind, value)
        elif id(value) in constant_ids:
            spec = key = ("C", constant_ids[id(value)])
        elif kind is Decimal:
            # By string: equal Decimals with different exponents are distinct.
            spec = key = ("D", str(value))
        elif kind is datetime.date:
            spec = key = ("d", value.toordinal())
        elif kind is frozenset:
            spec = key = ("F",) + tuple(ref(item) for item in value)
        elif kind in value_ids:
            spec = key = ("T", value_ids[kind]) + tuple(ref(item) for item in value)
        else:
            raise _Uncacheable(kind)
        found = index.get(key)
        if found is None:
            found = index[key] = len(table)
            table.append(spec)
        return found

    def meta(value):
        if value is None:
            return None
        if value.__class__ is not dict:
            raise _Uncacheable(type(value))
        items = list(value.items())
        if (len(items) >= 2 and items[0] == ("filename", filename) and items[0][1].__class__ is str
                and items[1][0] == "lineno" and items[1][1].__class__ is int):
            # The parser's own layout: filename, lineno, then the key-values.
            out = [items[1][1]]
            for key, item in items[2:]:
                out.append(ref(key))
                out.append(ref(item))
            return tuple(out)
        # Anything else is stored as is; a path in it fails the store.
        out = []
        for key, item in items:
            out.append(ref(key))
            out.append(ref(item))
        return out

    def field(value):
        if value.__class__ is list:
            return [ref(item) for item in value]
        return ref(value)

    nodes = []
    for entry in entries:
        kind = entry.__class__
        if kind is data.Transaction:
            if entry.postings.__class__ is not list:
                raise _Uncacheable(type(entry.postings))
            postings = []
            for posting in entry.postings:
                if posting.__class__ is not data.Posting:
                    raise _Uncacheable(type(posting))
                postings.append((meta(posting.meta), ref(posting.account), ref(posting.units),
                                 ref(posting.cost), ref(posting.price), ref(posting.flag)))
            nodes.append((0, meta(entry.meta), ref(entry.date), ref(entry.flag), ref(entry.payee),
                          ref(entry.narration), ref(entry.tags), ref(entry.links), postings))
        elif kind in directive_ids:
            nodes.append((directive_ids[kind], meta(entry.meta)) + tuple(field(item) for item in entry[1:]))
        else:
            raise _Uncacheable(kind)
    return marshal.dumps((table, nodes))


def _decode_parsed(payload, filename):
    import datetime
    import marshal
    directives, value_types, constants = _parse_codec_types()
    table, nodes = marshal.loads(payload)
    values = []
    append = values.append
    new = tuple.__new__
    decimal, from_ordinal = Decimal, datetime.date.fromordinal
    for spec in table:
        if spec.__class__ is not tuple:
            append(spec)
            continue
        tag = spec[0]
        if tag == "D":
            append(decimal(spec[1]))
        elif tag == "d":
            append(from_ordinal(spec[1]))
        elif tag == "T":
            append(new(value_types[spec[1]], [values[item] for item in spec[2:]]))
        elif tag == "F":
            append(frozenset([values[item] for item in spec[1:]]))
        elif tag == "C":
            append(constants[spec[1]])
        else:
            raise ValueError("unknown parse cache value")

    def meta(encoded):
        if encoded is None:
            return None
        if encoded.__class__ is tuple:
            result = {"filename": filename, "lineno": encoded[0]}
            for position in range(1, len(encoded), 2):
                result[values[encoded[position]]] = values[encoded[position + 1]]
            return result
        result = {}
        for position in range(0, len(encoded), 2):
            result[values[encoded[position]]] = values[encoded[position + 1]]
        return result

    transaction, posting = data.Transaction, data.Posting
    entries = []
    add = entries.append
    for node in nodes:
        if node[0] == 0:
            _, encoded, day, flag, payee, narration, tags, links, postings = node
            add(new(transaction, (meta(encoded), values[day], values[flag], values[payee], values[narration],
                                  values[tags], values[links],
                                  [new(posting, (values[account], values[units], values[cost], values[price],
                                                 values[posting_flag], meta(posting_meta)))
                                   for posting_meta, account, units, cost, price, posting_flag in postings])))
        else:
            fields = [meta(node[1])]
            for item in node[2:]:
                fields.append([values[value] for value in item] if item.__class__ is list else values[item])
            add(new(directives[node[0]], fields))
    return entries


class _ParseCache:
    """parser.parse_file for files under `root`, served from `directory`."""

    def __init__(self, root, directory):
        self.root = root
        self.directory = directory
        self.identity = _parse_cache_identity()
        self.root_bytes = os.fsencode(str(root))

    def parse_file(self, filename, encoding=None):
        if encoding is not None:
            return parser.parse_file(filename, encoding=encoding)
        try:
            relative = Path(filename).relative_to(self.root).as_posix()
            content = Path(filename).read_bytes()
        except (ValueError, OSError):
            return parser.parse_file(filename, encoding=encoding)
        key = hashlib.sha256(self.identity + b"\0" + relative.encode("utf-8") + b"\0"
                             + hashlib.sha256(content).digest()).hexdigest()
        path = self.directory / (hashlib.sha256(relative.encode("utf-8")).hexdigest()[:32] + ".parse")
        stored = self._read(path, key, filename)
        if stored is not None:
            return stored
        result = parser.parse_file(filename, encoding=encoding)
        self._write(path, key, filename, content, result)
        return result

    def _read(self, path, key, filename):
        import pickle
        try:
            with open(path, "rb") as handle:
                stored = pickle.load(handle)
            if not isinstance(stored, dict) or stored.get("key") != key:
                return None
            options = pickle.loads(stored["options"])
            options["filename"] = filename
            entries = _decode_parsed(stored["entries"], filename)
        except Exception:
            # Missing, truncated or written by something else: parse instead.
            return None
        return entries, [], options

    def _write(self, path, key, filename, content, result):
        import pickle
        entries, errors, options = result
        if errors or self.root_bytes in content or options.get("filename") != filename:
            return
        try:
            payload = _encode_parsed(entries, filename)
            stored_options = dict(options)
            stored_options["filename"] = None
            stored_options = pickle.dumps(stored_options, protocol=pickle.HIGHEST_PROTOCOL)
        except Exception:
            # _Uncacheable, or options that do not pickle: parse it every time.
            return
        if self.root_bytes in payload or self.root_bytes in stored_options:
            return
        try:
            # The parse read the file again; store only if it read these bytes.
            if Path(filename).read_bytes() != content:
                return
        except OSError:
            return
        stored = {"key": key, "options": stored_options, "entries": payload}
        temporary = path.with_name(path.name + ".tmp")
        try:
            with open(temporary, "wb") as handle:
                pickle.dump(stored, handle, protocol=pickle.HIGHEST_PROTOCOL)
            os.replace(temporary, path)
        except OSError:
            temporary.unlink(missing_ok=True)


@contextlib.contextmanager
def _collection_paused():
    """Hold off the cyclic garbage collector.

    Parsing and decoding allocate hundreds of thousands of acyclic objects; on
    a large ledger the collector's repeated scans of them cost more than the
    decode itself. Nothing here creates garbage cycles, and the collector
    resumes, unchanged, as soon as the block ends.
    """
    import gc
    enabled = gc.isenabled()
    gc.disable()
    try:
        yield
    finally:
        if enabled:
            gc.enable()


def _parse_recursive(sources, log_timings, encoding, parse_file):
    """beancount 3.2.3's loader._parse_recursive with parse_file injected.

    Statement for statement the same as the original, so the include walk,
    duplicate and missing-file errors, option aggregation and the order of the
    entries are beancount's own; only the parser.parse_file call goes through
    `parse_file`.
    """
    import itertools
    from os import path
    from beancount.parser import options as beancount_options
    from beancount.utils import encryption, misc_utils
    assert isinstance(sources, list) and all(isinstance(el, tuple) for el in sources)
    entries = []
    parse_errors = []
    options_map = None
    other_options_map = []
    source_stack = list(sources)
    filenames_seen = set()
    with misc_utils.log_time("beancount.parser.parser", log_timings, indent=1):
        while source_stack:
            source, is_file = source_stack.pop(0)
            is_top_level = options_map is None
            if is_file:
                cwd = path.dirname(source)
                source_filename = source
                if encryption.is_encrypted_file(source):
                    source = encryption.read_encrypted_file(source)
                    is_file = False
            else:
                cwd = os.getcwd()
                source_filename = None
            if is_file:
                assert path.isabs(source)
                filename = path.normpath(source)
                if filename in filenames_seen:
                    parse_errors.append(loader.LoadError(
                        data.new_metadata("<load>", 0), 'Duplicate filename parsed: "{}"'.format(filename)))
                    continue
                if not path.exists(filename):
                    parse_errors.append(loader.LoadError(
                        data.new_metadata("<load>", 0), 'File "{}" does not exist'.format(filename)))
                    continue
                filenames_seen.add(filename)
                with misc_utils.log_time("beancount.parser.parser.parse_file", log_timings, indent=2):
                    (src_entries, src_errors, src_options_map) = parse_file(filename, encoding=encoding)
                cwd = path.dirname(filename)
            else:
                if encoding:
                    if isinstance(source, bytes):
                        source = source.decode(encoding)
                    source = source.encode("ascii", "replace")
                with misc_utils.log_time("beancount.parser.parser.parse_string", log_timings, indent=2):
                    (src_entries, src_errors, src_options_map) = parser.parse_string(source, source_filename)
            entries.extend(src_entries)
            parse_errors.extend(src_errors)
            if is_top_level:
                options_map = src_options_map
            else:
                other_options_map.append(src_options_map)
            include_expanded = []
            for include_filename in src_options_map["include"]:
                search_path = include_filename
                if not os.path.isabs(include_filename):
                    search_path = os.path.join(cwd, include_filename)
                matched_filenames = glob.glob(search_path, recursive=True)
                if matched_filenames:
                    include_expanded.extend(matched_filenames)
                else:
                    parse_errors.append(loader.LoadError(
                        data.new_metadata("<load>", 0),
                        'File glob "{}" does not match any files'.format(include_filename)))
            for include_filename in include_expanded:
                if not path.isabs(include_filename):
                    include_filename = path.join(cwd, include_filename)
                include_filename = path.normpath(include_filename)
                source_stack.append((include_filename, True))
    if options_map is None:
        options_map = beancount_options.OPTIONS_DEFAULTS.copy()
    options_map["include"] = sorted(filenames_seen)
    options_map = loader.aggregate_options_map(options_map, other_options_map)
    return entries, parse_errors, options_map


def _checkpointed_load(root, checkpoint_path, filename, log_timings, extra_validations, encoding,
                       parse_cache=None):
    """loader._load for one file, with parsing and booking served from caches.

    Without a checkpoint directory or a parse cache this is exactly beancount's
    pipeline. With either, the stages are beancount 3.2.3's `_load`, in the
    same order, with only the per-file parse and the booking call replaced.
    """
    if checkpoint_path is None and parse_cache is None:
        return loader._uncached_load_file(filename, log_timings, extra_validations, encoding)
    import sys
    from beancount.utils import misc_utils
    with misc_utils.log_time("parse", log_timings, indent=1):
        if parse_cache is None:
            entries, parse_errors, options = loader._parse_recursive([(filename, True)], log_timings, encoding)
        else:
            with _collection_paused():
                entries, parse_errors, options = _parse_recursive(
                    [(filename, True)], log_timings, encoding, parse_cache.parse_file)
        # Files are parsed into contiguous runs; their order is the stable-sort
        # tie-break the prefix order has to reproduce.
        file_order, last = [], None
        for item in entries:
            name = item.meta.get("filename") if item.meta else None
            if name != last:
                file_order.append(name)
                last = name
        entries.sort(key=data.entry_sortkey)
    with misc_utils.log_time("booking", log_timings, indent=1):
        if checkpoint_path is None:
            entries, balance_errors = booking.book(entries, options)
            refreshed = None
        else:
            entries, balance_errors, refreshed = _book_with_checkpoint(
                root, entries, options, list(dict.fromkeys(file_order)), checkpoint_path)
        parse_errors.extend(balance_errors)
    with misc_utils.log_time("run_transformations", log_timings, indent=1):
        saved_pythonpath = list(sys.path)
        try:
            if "pythonpath" in options:
                sys.path[0:0] = options["pythonpath"]
            entries, errors = loader.run_transformations(entries, parse_errors, options, log_timings)
        finally:
            sys.path[:] = saved_pythonpath
    with misc_utils.log_time("beancount.ops.validate", log_timings, indent=1):
        errors.extend(validation.validate(entries, options, log_timings, extra_validations))
    options["input_hash"] = loader.compute_input_hash(options["include"])
    # A ledger that does not load cleanly never replaces a good checkpoint.
    if refreshed is not None and not errors:
        _write_checkpoint(checkpoint_path, refreshed)
    return entries, errors, options


def _validate_json(workspace, entry_file, *, export_canonical, stream_output=None):
    try:
        root = Path(workspace).resolve(strict=True)
        if not root.is_dir() or Path(entry_file).is_absolute():
            raise ValueError("账本入口路径无效")
        entry = _confined(root, root / entry_file)
        files = _preflight(root, entry)
        # Caching stays off unless the caller hands us a directory it owns; in
        # that case the same loader pipeline runs but reuses this source
        # version's unpickled result. bean-check semantics are unchanged either
        # way: posting/booking/validation all run before anything is cached.
        timing_lines = [] if _load_timings_enabled() else None
        entries, errors, options = _load_with_optional_cache(
            root, entry, files, timing_lines.append if timing_lines is not None else None
        )
        result = []
        for error in errors:
            source = error.source or {}
            filename = source.get("filename", "")
            if filename and Path(filename).is_relative_to(root):
                filename = str(Path(filename).relative_to(root))
            result.append({"message": error.message, "filename": filename,
                           "lineno": source.get("lineno", 0)})
        payload = {"errors": result}
        if not result and stream_output is not None:
            payload["stream"] = _write_canonical_stream(root, entries, options, stream_output)
            if timing_lines is not None:
                payload["stream"]["timings"] = _timing_breakdown(timing_lines)
        if not result and export_canonical:
            option_values = _exported_options(root, options)
            payload["canonical"] = {"version": 1,
                                    "entries": [_canonical_entry(root, item) for item in entries],
                                    "commodities": sorted(set(options.get("commodities", ())) |
                                                          set(options.get("operating_currency", ()))),
                                    "options": option_values}
        return json.dumps(payload, ensure_ascii=False)
    except Exception as error:
        return json.dumps({"errors": [{"message": str(error)}]}, ensure_ascii=False)
