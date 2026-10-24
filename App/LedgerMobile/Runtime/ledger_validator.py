"""Canonical Beancount validation inside the application process.

The shipped parser and plugins are trusted application code. Imported ledgers
are data: preflight every parsed include before invoking loader transformations.
"""
import functools
import glob
import hashlib
import json
import os
from datetime import date
from decimal import Decimal
from pathlib import Path

from beancount import loader
from beancount.core import data
from beancount.core.amount import Amount
from beancount.ops import validation
from beancount.parser import parser


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


def _preflight(root, entry):
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


def _validate_json(workspace, entry_file, *, export_canonical, stream_output=None):
    try:
        root = Path(workspace).resolve(strict=True)
        if not root.is_dir() or Path(entry_file).is_absolute():
            raise ValueError("账本入口路径无效")
        entry = _confined(root, root / entry_file)
        _preflight(root, entry)
        # The uncached entry point avoids loading or removing any imported
        # pickle cache. This is the same loader pipeline used by bean-check.
        entries, errors, options = loader._uncached_load_file(
            str(entry), None, validation.HARDCORE_VALIDATIONS, None
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
