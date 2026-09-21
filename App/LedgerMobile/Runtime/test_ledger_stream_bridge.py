"""Host tests for the native export's Python boundary (Beancount 3.2.3)."""

import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest import mock

import ledger_stream_bridge as bridge
import ledger_validator as validator

BASIC = '''2000-01-01 open Assets:Cash CNY
2000-01-01 open Expenses:Food CNY
2026-01-01 * "Synthetic lunch"
  Assets:Cash -12.50 CNY
  Expenses:Food 12.50 CNY
'''


class StreamBridgeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.root = self.base / "ledger"
        self.root.mkdir(mode=0o700)
        self.derived = self.base / "derived"
        self.derived.mkdir(mode=0o700)
        self.source = self.root / "main.bean"
        self.source.write_text(BASIC, encoding="utf-8")
        self.spool = self.derived / "stream.jsonl"

    def call(self, **overrides):
        args = dict(workspace_path=str(self.root), entry_file="main.bean",
                    derived_directory=str(self.derived), spool_name=self.spool.name)
        args.update(overrides)
        response = bridge.export_stream_json(**args)
        self.assertLessEqual(len(response.encode("utf-8")), bridge.MAX_RESPONSE_BYTES)
        self.assertNotIn(str(self.base), response)
        self.assertNotIn("Synthetic lunch", response)
        return json.loads(response)

    def test_success_is_only_counts_and_digests_and_spool_matches(self):
        # Explicitly guard against accidentally calling a legacy snapshot API.
        with mock.patch.object(validator, "validate_json", side_effect=AssertionError), \
                mock.patch.object(validator, "_canonical_entry", side_effect=AssertionError):
            response = self.call()
        self.assertTrue(response["ok"])
        self.assertEqual(set(response), {"ok", "summary"})
        summary = response["summary"]
        self.assertEqual(set(summary), {"records", "directives", "postings", "source_digest", "sha256"})
        lines = self.spool.read_bytes().splitlines(keepends=True)
        header, footer = json.loads(lines[0]), json.loads(lines[-1])
        self.assertEqual(summary["source_digest"], header["source_digest"])
        self.assertEqual(summary["sha256"], hashlib.sha256(b"".join(lines[:-1])).hexdigest())
        self.assertEqual(summary["records"], len(lines) - 1)
        for key in ("records", "directives", "postings", "sha256"):
            self.assertEqual(summary[key], footer[key])
        self.assertEqual(summary["directives"], 3)
        self.assertEqual(summary["postings"], 2)
        self.assertEqual(stat.S_IMODE(self.spool.stat().st_mode), 0o600)

    @unittest.skipUnless(os.environ.get("LEDGER_STREAM_CHECK"), "requires Go stream verifier")
    def test_bridge_spool_passes_go_verifier(self):
        response = self.call()
        self.assertTrue(response["ok"])
        result = subprocess.run([os.environ["LEDGER_STREAM_CHECK"], str(self.spool)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_relative_entry_file_in_subdirectory(self):
        sub = self.root / "nested"
        sub.mkdir()
        self.source.rename(sub / "entry.bean")
        self.assertTrue(self.call(entry_file="nested/entry.bean")["ok"])

    def test_arguments_rejected_before_export(self):
        for key, values in {
            "workspace_path": [None, "", "relative", "bad\0path"],
            "entry_file": [None, "", 123, "bad\0file"],
            "derived_directory": [None, "", "relative", "bad\0dir"],
            "spool_name": [None, "", ".", "..", "../escape", "/tmp/spool", "sub/file",
                           "bad\\file", "bad:name", "bad\nname", "bad\0name", "x" * 129],
        }.items():
            for value in values:
                with self.subTest(key=key, value=value), \
                        mock.patch.object(bridge.ledger_stream, "export_stream") as export:
                    result = self.call(**{key: value})
                    self.assertFalse(result["ok"])
                    self.assertEqual(result["error"]["code"], "invalid_arguments")
                    export.assert_not_called()

    def test_entry_escape_is_rejected(self):
        for entry in (str(self.source), "../main.bean"):
            with self.subTest(entry=entry):
                self.assertFalse(self.call(entry_file=entry)["ok"])
                self.assertFalse(self.spool.exists())

    def test_existing_spool_and_symlink_are_preserved(self):
        self.spool.write_bytes(b"existing owner")
        self.assertFalse(self.call()["ok"])
        self.assertEqual(self.spool.read_bytes(), b"existing owner")
        self.spool.unlink()
        self.spool.symlink_to(self.source)
        self.assertFalse(self.call()["ok"])
        self.assertTrue(self.spool.is_symlink())
        self.assertEqual(self.source.read_text(), BASIC)

    def test_unsafe_or_missing_derived_directory_fails_closed(self):
        self.derived.chmod(0o755)
        self.assertFalse(self.call()["ok"])
        self.assertFalse(self.spool.exists())
        self.derived.chmod(0o700)
        link = self.base / "linked"
        link.symlink_to(self.derived, target_is_directory=True)
        for directory in (self.root, self.base / "missing", link):
            with self.subTest(directory=directory):
                self.assertFalse(self.call(derived_directory=str(directory))["ok"])
                self.assertFalse((directory / self.spool.name).exists())
        self.assertFalse((self.base / "missing").exists())

    def test_validation_failure_is_private_and_partial_spool_removed(self):
        self.source.write_text('2026-01-01 * "PRIVATE-ERROR-TOKEN"\n  Assets:Missing -1 CNY\n')
        response = self.call()
        self.assertEqual(response, json.loads(bridge._EXPORT_FAILED))
        self.assertNotIn("PRIVATE-ERROR-TOKEN", json.dumps(response))
        self.assertFalse(self.spool.exists())

    def test_write_failure_is_private_and_partial_spool_removed(self):
        with mock.patch.object(bridge.ledger_stream.os, "fsync",
                               side_effect=OSError("PRIVATE-ERROR-TOKEN " + str(self.spool))):
            self.assertEqual(self.call(), json.loads(bridge._EXPORT_FAILED))
        self.assertFalse(self.spool.exists())

    def test_exception_text_is_never_stringified(self):
        class SecretError(Exception):
            def __str__(self):
                raise AssertionError("must not stringify")
        for error in (SecretError(), SystemExit("secret"), KeyboardInterrupt(), MemoryError(),
                      ValueError("private" * 100000)):
            with self.subTest(error=type(error).__name__), \
                    mock.patch.object(bridge.ledger_stream, "export_stream", side_effect=error):
                self.assertEqual(self.call(), json.loads(bridge._EXPORT_FAILED))

    def test_summary_is_projected_and_bounded(self):
        summary = dict(records=2**63 - 1, directives=2**63 - 1, postings=2**63 - 1,
                       source_digest="a" * 64, sha256="b" * 64, private="SECRET" * 100000)
        with mock.patch.object(bridge.ledger_stream, "export_stream", return_value=summary):
            result = self.call()
            self.assertTrue(result["ok"])
            self.assertNotIn("private", result["summary"])
        for key, value in (("records", True), ("records", -1), ("records", 2**63),
                           ("postings", 1.1), ("sha256", "a" * 100000),
                           ("source_digest", str(self.source))):
            with self.subTest(key=key, value=type(value).__name__), \
                    mock.patch.object(bridge.ledger_stream, "export_stream",
                                      return_value={**summary, key: value}):
                self.assertEqual(self.call(), json.loads(bridge._EXPORT_FAILED))

    def test_repeated_success_failure_success(self):
        self.assertTrue(self.call()["ok"])
        self.assertFalse(self.call()["ok"])
        self.spool.unlink()
        self.assertTrue(self.call()["ok"])


if __name__ == "__main__":
    unittest.main()
