"""Canonical Beancount validation inside the application process.

The shipped parser and plugins are trusted application code. Imported ledgers
are data: preflight every parsed include before invoking loader transformations.
"""
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


def _canonical_entry(root, entry, *, include_postings=True):
    """Export loader results directly; booking and plugin output stay intact.

    Decimal quantities remain strings across the language bridge. File/Line
    identify the original source; Go attaches the editor draft from that source
    independently of the transformed postings used by the read model.
    """
    meta = entry.meta or {}
    filename = meta.get("filename", "")
    if filename and Path(filename).is_absolute() and Path(filename).is_relative_to(root):
        filename = str(Path(filename).relative_to(root))
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


def _check_export_value(value, budget):
    """Conservative pre-allocation bound, including worst-case JSON escaping.

    This deliberately rejects pathological single records rather than building
    huge projected dicts/strings to discover that they exceed the wire limit.
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


def _check_export_entry(entry):
    budget = STREAM_RECORD_LIMIT - 4096
    # Check only projected fields. Open.booking and Custom ValueType.dtype are
    # canonical internal objects, not exported metadata values.
    for key in ("account", "source_account", "currency", "flag", "payee", "narration",
                "comment", "name", "query_string", "description", "filename",
                "currencies", "tags", "links", "type", "amount", "tolerance"):
        if hasattr(entry, key):
            budget = _check_export_value(getattr(entry, key), budget)
    for key, value in (entry.meta or {}).items():
        if key not in {"filename", "lineno"} and not key.startswith("__"):
            budget = _check_export_value(key, budget)
            budget = _check_export_value(value, budget)
    # File is projected separately from source metadata.
    budget = _check_export_value((entry.meta or {}).get("filename", ""), budget)
    if isinstance(entry, data.Custom):
        for value in entry.values:
            budget = _check_export_value(value.value, budget)


def _write_canonical_stream(root, entries, options, output):
    """One bounded record at a time; never serialize an all-entry array.

    Called only after the canonical loader has validated successfully. This
    bounds additional serialization, not the canonical loader's booked AST.
    The caller owns an isolated output directory; never overwrite an artifact.
    """
    path = Path(os.path.abspath(output))
    parent = path.parent.resolve(strict=True)
    if parent == root or parent.is_relative_to(root):
        raise ValueError("Canonical export must be outside source workspace")
    if path.parent != parent:
        raise ValueError("Canonical export parent must be resolved and non-symlinked")
    digest = hashlib.sha256()
    total = 0
    count = 0
    encoder = json.JSONEncoder(ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        stream_file = os.fdopen(fd, "wb")
        fd = None  # ownership transferred
        with stream_file as stream:
            def emit(record, *, hashed=True):
                nonlocal total
                _check_export_value(record, STREAM_RECORD_LIMIT)
                encoded = bytearray()
                for chunk in encoder.iterencode(record):
                    raw = chunk.encode("utf-8")
                    if len(encoded) + len(raw) + 1 > STREAM_RECORD_LIMIT:
                        raise ValueError("Canonical export record exceeds byte budget")
                    encoded.extend(raw)
                encoded.append(10)
                if total + len(encoded) > STREAM_TOTAL_LIMIT:
                    raise ValueError("Canonical export exceeds total byte budget")
                stream.write(encoded)
                total += len(encoded)
                if hashed:
                    digest.update(encoded)

            emit({"type": "header", "version": 1})
            # Catalog records are separate so even many options do not require
            # a second aggregate dictionary or a huge header.
            for key, value in options.items():
                if isinstance(value, str):
                    emit({"type": "option", "key": key, "value": value})
                elif isinstance(value, list) and value and all(isinstance(item, str) for item in value):
                    emit({"type": "option", "key": key, "value": value[-1]})
            for currency in sorted(set(options.get("commodities", ())) | set(options.get("operating_currency", ()))):
                emit({"type": "commodity", "value": currency})
            for entry in entries:
                _check_export_entry(entry)
                emit({"type": "entry", "entry": _canonical_entry(root, entry, include_postings=False)})
                if isinstance(entry, data.Transaction):
                    for posting in entry.postings:
                        _check_export_value(posting, STREAM_RECORD_LIMIT - 4096)
                        emit({"type": "posting", "posting": _canonical_posting(posting)})
                emit({"type": "end_entry"})
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
            # The public option map is string-valued, matching the existing
            # API. List options retain its last-declaration behavior.
            option_values = {}
            for key, value in options.items():
                if isinstance(value, str):
                    option_values[key] = value
                elif isinstance(value, list) and value and all(isinstance(item, str) for item in value):
                    option_values[key] = value[-1]
            payload["canonical"] = {"version": 1,
                                    "entries": [_canonical_entry(root, item) for item in entries],
                                    "commodities": sorted(set(options.get("commodities", ())) |
                                                          set(options.get("operating_currency", ()))),
                                    "options": option_values}
        return json.dumps(payload, ensure_ascii=False)
    except Exception as error:
        return json.dumps({"errors": [{"message": str(error)}]}, ensure_ascii=False)
