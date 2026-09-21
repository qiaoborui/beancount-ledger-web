"""Canonical Beancount validation inside the application process.

The shipped parser and plugins are trusted application code. Imported ledgers
are data: preflight every parsed include before invoking loader transformations.
"""
import glob
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


def _canonical_entry(root, entry):
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
    if isinstance(entry, data.Transaction):
        postings = []
        for posting in entry.postings:
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
            postings.append(row)
        result["Postings"] = postings
    return result


def validate_json(workspace, entry_file="main.bean"):
    """Compatibility entrypoint: validate and export the canonical read model."""
    return _validate_json(workspace, entry_file, export_canonical=True)


def validate_only_json(workspace, entry_file="main.bean"):
    """Run identical canonical validation without constructing unused read JSON."""
    return _validate_json(workspace, entry_file, export_canonical=False)


def _validate_json(workspace, entry_file, *, export_canonical):
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
