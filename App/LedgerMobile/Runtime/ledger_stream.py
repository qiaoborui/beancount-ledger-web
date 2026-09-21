"""Canonical bounded-v1 export; opt-in tooling, not the default app read path.

export_stream(workspace, destination, entry_file='main.bean') validates with the
uncached Beancount HARDCORE pipeline and writes compact UTF-8 JSONL. Every line,
including LF, is <= 1048576 bytes. Header/version=1 precedes legacy string-valued
options and sorted commodities, then sequential directive IDs starting at 1.
Directive values use the legacy capitalized fields, without Metadata/Postings;
Booking preserves Open's booking policy. Postings retain the legacy lower-case
account/flag and exact Quantity/Cost/CostDate/CostLabel/Price representation.
Each metadata owner is limited to MAX_METADATA_KEYS=8192 total keys, including
internal keys, checked before sorting. The sorted key-reference list and sorting
scratch are thus O(MAX_METADATA_KEYS), not unbounded in the loaded AST size.
Metadata keys are strictly sorted within each owner. Metadata follows its
directive (posting=-1) or immediately follows its posting
(zero-based ordinal). Internal __*, filename and lineno metadata are omitted.
CustomValues and metadata use explicit decimal/date/str/bool/int/none/amount/list
or account tags. Decimal values are strings; amount values have Number/Currency.
Custom account values retain their parser type. Tuple/set/frozenset become typed
lists (sets deterministically sorted). No float/stringification fallback exists;
nesting deeper than 16 is rejected (root depth is zero).

Footer records counts all preceding records, directives/postings count their
respective records, and sha256 hashes exact preceding bytes including LF. Nothing
follows the footer. The returned summary contains only counts and digests.
source_digest hashes sorted parsed source paths: 8-byte big-endian UTF-8 path
length, path bytes, 8-byte big-endian file size, then exact file bytes. Sources
are checked before preflight, after load and after export, including glob changes.
Source locations and file-valued public options are workspace-relative. Wire
paths forbid backslashes, colons, ASCII controls/DEL, absolute paths and empty,
"." or ".." components. Only the documents option may be "." (workspace root);
relative documents options resolve against the entry file's parent directory.

Destination must be outside the ledger, in an existing owned 0700 directory.
All source/destination path components must be non-symlinks. Creation is exclusive
0600; success flushes/fsyncs, failure removes only this invocation's own inode.
Errors raise exceptions, never return success or a partial stream. The caller
must freeze the source generation against concurrent writers: before/after hashes
are change detection, not a filesystem snapshot or protection against malicious
change-and-restore races in the native loader. Canonical loading still holds its
O(N) AST; export adds bounded records, not an all-entry copy or SQLite dependency.
"""

import glob
import hashlib
import json
import os
import stat
import sys
from datetime import date
from decimal import Decimal
from pathlib import Path

import beancount
from beancount.core import account, data
from beancount.core.amount import Amount

import ledger_validator as validator

MAX_RECORD_BYTES = 1048576
MAX_VALUE_DEPTH = 16
MAX_METADATA_KEYS = 8192
_ENCODER = json.JSONEncoder(ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def _absolute(path):
    path = Path(path)
    # Do not normalize away a symlink/.. component before checking it.
    if ".." in path.parts:
        raise ValueError("Parent traversal is not allowed")
    return Path(os.path.abspath(path))


def _directory_fd(path):
    """Open each component without following links; caller owns returned fd."""
    path = _absolute(path)
    fd = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in path.parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def _wire_path(value, *, empty=False, documents=False):
    """Match boundedstream.safePath; root is allowed only for documents options."""
    if not isinstance(value, str):
        raise ValueError("Unsupported wire path")
    if (value == "" and empty) or (value == "." and documents):
        return value
    if (any(c in "\\:" or ord(c) < 32 or ord(c) == 127 for c in value)
            or any(part in {"", ".", ".."} for part in value.split("/"))):
        raise ValueError("Unsupported wire path")
    return value


def _relative(root, filename, *, empty=True, documents=False):
    if not filename:
        return _wire_path("", empty=empty)
    candidate = Path(filename)
    if not candidate.is_absolute():
        candidate = root / candidate
    candidate = validator._confined(root, _absolute(candidate))
    return _wire_path(candidate.relative_to(root).as_posix(),
                      empty=empty, documents=documents)


def _source_files(root, entry):
    """Discover includes, enforcing the same policy also for recursive globs."""
    pending, seen, patterns = [entry], set(), {}
    while pending:
        filename = validator._confined(root, _absolute(pending.pop()))
        if filename in seen:
            continue
        seen.add(filename)
        if len(seen) > 10000:
            raise ValueError("Too many source files")
        if filename.suffix.lower() in {".gpg", ".asc"}:
            raise ValueError("Encrypted sources are not supported")
        parent_fd = _directory_fd(filename.parent)
        try:
            fd = os.open(filename.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                         dir_fd=parent_fd)
            try:
                if not stat.S_ISREG(os.fstat(fd).st_mode):
                    raise ValueError("Source must be a regular file")
            finally:
                os.close(fd)
        finally:
            os.close(parent_fd)
        entries, _, options = validator.parser.parse_file(str(filename))
        if options.get("insert_pythonpath"):
            raise ValueError("insert_pythonpath is not supported")
        for name, _ in options.get("plugin", []):
            if name not in validator.ALLOWED_PLUGINS:
                raise ValueError("Unsupported plugin: " + name)
        for directory in options.get("documents", []):
            validator._confined(root, _absolute(filename.parent / directory))
        for item in entries:
            if isinstance(item, data.Document):
                validator._confined(root, _absolute(filename.parent / item.filename))
        for include in options.get("include", []):
            pattern = validator._confined(root, _absolute(filename.parent / include))
            matches = tuple(sorted(validator._confined(root, _absolute(p))
                                   for p in glob.iglob(str(pattern), recursive=True)))
            patterns[pattern] = matches
            pending.extend(matches)
        del entries
    return tuple(sorted(seen, key=lambda p: p.relative_to(root).as_posix())), patterns


def _source_digest(root, sources):
    files, patterns = sources
    for pattern, expected in patterns.items():
        matches = tuple(sorted(validator._confined(root, _absolute(p))
                               for p in glob.iglob(str(pattern), recursive=True)))
        if matches != expected:
            raise ValueError("Source include set changed")
    digest = hashlib.sha256()
    for filename in files:
        name = _wire_path(filename.relative_to(root).as_posix()).encode("utf-8")
        parent_fd = _directory_fd(filename.parent)
        try:
            fd = os.open(filename.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                         dir_fd=parent_fd)
        finally:
            os.close(parent_fd)
        with os.fdopen(fd, "rb") as source:
            before = os.fstat(source.fileno())
            if not stat.S_ISREG(before.st_mode):
                raise ValueError("Source must be a regular file")
            digest.update(len(name).to_bytes(8, "big"))
            digest.update(name)
            digest.update(before.st_size.to_bytes(8, "big"))
            size = 0
            while chunk := source.read(65536):
                digest.update(chunk)
                size += len(chunk)
            after = os.fstat(source.fileno())
            if (size != before.st_size or before.st_mtime_ns != after.st_mtime_ns
                    or before.st_ctime_ns != after.st_ctime_ns):
                raise ValueError("Source changed while hashing")
    return digest.hexdigest()


class _Budget:
    def __init__(self):
        self.remaining = MAX_RECORD_BYTES

    def use(self, size):
        self.remaining -= size
        if self.remaining < 0:
            raise ValueError("Record exceeds byte limit")


def _typed_value(value, depth=0, budget=None):
    if depth > MAX_VALUE_DEPTH:
        raise ValueError("Typed value depth exceeds 16")
    budget = budget if budget is not None else _Budget()
    budget.use(8)  # A lower bound on each typed wrapper's encoded size.
    if isinstance(value, Amount):
        result = {"type": "amount", "value": validator._amount(value)}
        if not isinstance(value.number, Decimal) or not value.number.is_finite():
            raise ValueError("Invalid amount number")
        budget.use(len(result["value"]["Number"]) + len(value.currency.encode("utf-8")))
        return result
    if isinstance(value, Decimal):
        if not value.is_finite():
            raise ValueError("Non-finite decimal")
        kind, scalar = "decimal", str(value)
    elif type(value) is date:
        kind, scalar = "date", value.isoformat()
    elif type(value) is str:
        kind, scalar = "str", value
    elif type(value) is bool:
        kind, scalar = "bool", value
    elif type(value) is int:
        kind, scalar = "int", value
    elif value is None:
        kind, scalar = "none", None
    elif isinstance(value, (list, tuple, set, frozenset)):
        # Check length before allocating the second sequence.
        if len(value) * 8 > budget.remaining:
            raise ValueError("Record exceeds byte limit")
        items = [_typed_value(item, depth + 1, budget) for item in value]
        if isinstance(value, (set, frozenset)):
            items.sort(key=_ENCODER.encode)
        return {"type": "list", "value": items}
    else:
        raise ValueError("Unsupported typed value: " + type(value).__name__)
    if isinstance(scalar, str):
        if len(scalar) > MAX_RECORD_BYTES:
            raise ValueError("Record exceeds byte limit")
        budget.use(len(scalar.encode("utf-8")))
    return {"type": kind, "value": scalar}


def _directive(root, entry):
    # Do not call _canonical_entry: it builds a transaction-wide posting list.
    if type(entry) not in data.ALL_DIRECTIVES:
        raise ValueError("Unsupported directive")
    meta = entry.meta or {}
    result = {"Kind": type(entry).__name__.lower(), "Date": entry.date.isoformat(),
              "File": _relative(root, meta.get("filename", "")),
              "Line": meta.get("lineno", 0)}
    for field, key in (("account", "Account"), ("source_account", "Account2"),
                       ("currency", "Currency"), ("flag", "Flag"), ("payee", "Payee"),
                       ("narration", "Narration"), ("comment", "Narration"),
                       ("name", "Name"), ("query_string", "Value"),
                       ("description", "Value"), ("filename", "Filename")):
        value = getattr(entry, field, None)
        if value is not None:
            result[key] = _relative(root, value, empty=False) if field == "filename" else value
    for field, key in (("currencies", "Currencies"), ("tags", "Tags"), ("links", "Links")):
        value = getattr(entry, field, None)
        if value is not None:
            if sum(len(item) + 3 for item in value) > MAX_RECORD_BYTES:
                raise ValueError("Record exceeds byte limit")
            result[key] = list(value) if field == "currencies" else sorted(value)
    if isinstance(entry, data.Open) and entry.booking is not None:
        result["Booking"] = entry.booking.name
    if isinstance(entry, data.Event):
        result["Name"] = entry.type
    if isinstance(entry, (data.Balance, data.Price)):
        result["AmountValue"] = validator._amount(entry.amount)
        result["QuoteCurrency" if isinstance(entry, data.Price) else "Currency"] = entry.amount.currency
    if isinstance(entry, data.Balance):
        if entry.tolerance is not None:
            result["Tolerance"] = str(entry.tolerance)
        if entry.diff_amount is not None:
            result["DiffAmount"] = validator._amount(entry.diff_amount)
    if isinstance(entry, data.Custom):
        result["CustomType"] = entry.type
        budget = _Budget()
        values = []
        for value in entry.values:
            typed = _typed_value(value.value, budget=budget)
            if value.dtype == account.TYPE and type(value.value) is str:
                typed["type"] = "account"
            elif value.dtype is not type(value.value):
                raise ValueError("Unsupported custom value type")
            values.append(typed)
        result["CustomValues"] = values
    return result


def _posting(posting):
    result = {"account": posting.account, "Quantity": validator._amount(posting.units)}
    if posting.flag:
        result["flag"] = posting.flag
    if posting.cost is not None:
        result["Cost"] = validator._amount(posting.cost)
        if posting.cost.date is not None:
            result["CostDate"] = posting.cost.date.isoformat()
        if posting.cost.label is not None:
            result["CostLabel"] = posting.cost.label
    if posting.price is not None:
        result["Price"] = validator._amount(posting.price)
    return result


def _check_record_size(value, budget):
    # Reject huge strings before JSONEncoder can allocate an escaped copy.
    if isinstance(value, str):
        budget.use(len(value))
    elif isinstance(value, dict):
        budget.use(len(value) * 3 + 2)
        for key, item in value.items():
            _check_record_size(key, budget)
            _check_record_size(item, budget)
    elif isinstance(value, (list, tuple)):
        budget.use(len(value) + 2)
        for item in value:
            _check_record_size(item, budget)


class _Writer:
    def __init__(self, output):
        self.output = output
        self.digest = hashlib.sha256()
        self.records = 0

    def write(self, record, *, footer=False):
        _check_record_size(record, _Budget())
        line = bytearray()
        for chunk in _ENCODER.iterencode(record):
            if len(chunk) > MAX_RECORD_BYTES:
                raise ValueError("Record exceeds byte limit")
            encoded = chunk.encode("utf-8")
            if len(line) + len(encoded) + 1 > MAX_RECORD_BYTES:
                raise ValueError("Record exceeds byte limit")
            line.extend(encoded)
        line.append(10)
        self.output.write(line)
        if not footer:
            self.digest.update(line)
            self.records += 1

    def metadata(self, entry_id, ordinal, meta):
        meta = meta or {}
        if len(meta) > MAX_METADATA_KEYS:
            raise ValueError("Metadata exceeds key limit (8192 total keys)")
        if any(not isinstance(key, str) for key in meta):
            raise ValueError("Metadata key must be a string")
        for key in sorted(meta):
            value = meta[key]
            if key in {"filename", "lineno"} or key.startswith("__"):
                continue
            self.write({"type": "metadata", "entry_id": entry_id, "posting": ordinal,
                        "key": key, "value": _typed_value(value)})


def export_stream(workspace, destination, entry_file="main.bean"):
    """Export once, returning small counts/digests; raise on any invalid input."""
    root = _absolute(workspace)
    root_fd = _directory_fd(root)
    os.close(root_fd)
    if Path(entry_file).is_absolute():
        raise ValueError("Entry file must be relative")
    entry = validator._confined(root, _absolute(root / entry_file))
    target = _absolute(destination)
    if target.is_relative_to(root):
        raise ValueError("Destination must be outside the ledger root")
    parent_fd = _directory_fd(target.parent)
    owned = None
    try:
        parent = os.fstat(parent_fd)
        if stat.S_IMODE(parent.st_mode) != 0o700 or parent.st_uid != os.getuid():
            raise ValueError("Destination parent must be an owned private 0700 directory")
        fd = os.open(target.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=parent_fd)
        owned = os.fstat(fd)
        with os.fdopen(fd, "wb") as output:
            os.fchmod(output.fileno(), 0o600)
            sources = _source_files(root, entry)
            source_digest = _source_digest(root, sources)
            validator._preflight(root, entry)
            entries, errors, options = validator.loader._uncached_load_file(
                str(entry), None, validator.validation.HARDCORE_VALIDATIONS, None)
            if errors:
                raise ValueError("Canonical validation failed: " + errors[0].message)
            if _source_digest(root, sources) != source_digest:
                raise ValueError("Source changed during canonical load")
            if set(options.get("include", ())) != {str(path) for path in sources[0]}:
                raise ValueError("Canonical source set changed")
            writer = _Writer(output)
            writer.write({"type": "header", "version": 1, "source_digest": source_digest,
                          "entry_file": _wire_path(entry.relative_to(root).as_posix()),
                          "runtime": "beancount/" + beancount.__version__ + " python/" + sys.version.split()[0],
                          "exporter": "bounded-v1"})
            for key, value in options.items():
                if isinstance(value, list) and value and all(isinstance(item, str) for item in value):
                    value = value[-1]
                if isinstance(value, str):
                    if key == "documents":
                        value = _relative(root, entry.parent / value, documents=True)
                    elif key in {"filename", "include"}:
                        value = _relative(root, value)
                    writer.write({"type": "option", "key": key, "value": value})
            for value in sorted(set(options.get("commodities", ())) |
                                set(options.get("operating_currency", ()))):
                writer.write({"type": "commodity", "value": value})
            directive_count = posting_count = 0
            for directive_count, item in enumerate(entries, 1):
                writer.write({"type": "directive", "id": directive_count,
                              "value": _directive(root, item)})
                writer.metadata(directive_count, -1, item.meta)
                if isinstance(item, data.Transaction):
                    for ordinal, posting in enumerate(item.postings):
                        writer.write({"type": "posting", "entry_id": directive_count,
                                      "ordinal": ordinal, "value": _posting(posting)})
                        posting_count += 1
                        writer.metadata(directive_count, ordinal, posting.meta)
            if _source_digest(root, sources) != source_digest:
                raise ValueError("Source changed during export")
            summary = {"records": writer.records, "directives": directive_count,
                       "postings": posting_count, "sha256": writer.digest.hexdigest()}
            writer.write({"type": "footer", **summary}, footer=True)
            output.flush()
            os.fsync(output.fileno())
            current = os.stat(target.name, dir_fd=parent_fd, follow_symlinks=False)
            if (current.st_dev, current.st_ino) != (owned.st_dev, owned.st_ino):
                raise ValueError("Destination replaced during export")
            checked_parent = _directory_fd(target.parent)
            try:
                current_parent = os.fstat(checked_parent)
                if ((current_parent.st_dev, current_parent.st_ino) !=
                        (parent.st_dev, parent.st_ino) or
                        stat.S_IMODE(current_parent.st_mode) != 0o700):
                    raise ValueError("Destination parent changed during export")
            finally:
                os.close(checked_parent)
        return {"source_digest": source_digest, **summary}
    except BaseException:
        if owned is not None:
            try:
                current = os.stat(target.name, dir_fd=parent_fd, follow_symlinks=False)
                if (current.st_dev, current.st_ino) == (owned.st_dev, owned.st_ino):
                    os.unlink(target.name, dir_fd=parent_fd)
            except FileNotFoundError:
                pass
        raise
    finally:
        os.close(parent_fd)
