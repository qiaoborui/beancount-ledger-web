"""Small, path-free JSON boundary for BRExportStream; never builds a snapshot.

The caller freezes the source generation and supplies an existing owned 0700
*derived* directory outside the ledger, with iOS data protection already applied.
POSIX permissions alone do not establish iOS protection. spool_name is a fresh
basename, not a path. ledger_stream owns exclusive creation (0600), fsync and
inode-safe failure cleanup. Success transfers spool lifecycle to the caller;
existing files are never replaced. No directories are created by this bridge.

The response is at most MAX_RESPONSE_BYTES UTF-8 bytes, containing only counts
and digests on success, or a fixed public error. No exception text, source values,
paths, or canonical JSON snapshot crosses this boundary. The canonical loader
still retains its O(N) AST; this API bounds transport, not loader memory.
"""

import json
from pathlib import Path
import re

import ledger_stream

MAX_RESPONSE_BYTES = 1024  # Keep in sync with BR_EXPORT_STREAM_MAX_RESPONSE_BYTES.
_INVALID_ARGUMENTS = '{"ok":false,"error":{"code":"invalid_arguments","message":"Invalid stream export arguments"}}'
_EXPORT_FAILED = '{"ok":false,"error":{"code":"export_failed","message":"Bounded stream export failed"}}'
_COUNTS = ("records", "directives", "postings")
_DIGESTS = ("source_digest", "sha256")


def export_stream_json(workspace_path, entry_file, derived_directory, spool_name):
    """Return bounded JSON; contain even SystemExit/KeyboardInterrupt at the ABI.

    Detailed validation diagnostics remain the responsibility of BRValidateOnly.
    A failed call must not be interpreted as a usable spool or retried using a
    legacy snapshot. On success, the caller consumes/deletes its named spool.
    """
    try:
        if (any(not isinstance(value, str) or not value or "\0" in value
                for value in (workspace_path, entry_file, derived_directory, spool_name))
                or not Path(workspace_path).is_absolute()
                or not Path(derived_directory).is_absolute()
                or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", spool_name)):
            return _INVALID_ARGUMENTS
        summary = ledger_stream.export_stream(
            workspace_path, Path(derived_directory) / spool_name, entry_file)
        # Project a fixed schema; never serialize an arbitrary runtime object or
        # stringify an exception. Bound even a regressed exporter's return value.
        public = {}
        for key in _COUNTS:
            value = summary[key]
            if type(value) is not int or not 0 <= value <= 2**63 - 1:
                return _EXPORT_FAILED
            public[key] = value
        for key in _DIGESTS:
            value = summary[key]
            if type(value) is not str or not re.fullmatch(r"[0-9a-f]{64}", value):
                return _EXPORT_FAILED
            public[key] = value
        response = json.dumps({"ok": True, "summary": public}, separators=(",", ":"))
        return response if len(response.encode("utf-8")) <= MAX_RESPONSE_BYTES else _EXPORT_FAILED
    except BaseException:
        # Never expose Python's exception message/traceback (it may contain
        # financial data, private source paths or loader diagnostics).
        return _EXPORT_FAILED
