"""Host tests for bounded-v1; run with the packaged Beancount 3.2.3 pin."""

import hashlib
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from datetime import date
from decimal import Decimal
from unittest import mock

from beancount.core.amount import Amount

import ledger_stream as stream
import ledger_validator as validator


BASIC = '''2000-01-01 open Assets:Cash CNY
2000-01-01 open Expenses:Food CNY
2026-01-01 * "午餐" #food ^receipt
  Assets:Cash -12.50 CNY
  Expenses:Food 12.50 CNY
'''

GOLDEN = '''option "title" "Exact ledger"
option "operating_currency" "USD"
option "operating_currency" "CNY"
plugin "beancount.plugins.auto_accounts"
plugin "beancount.plugins.implicit_prices"
2000-01-01 open Assets:Cash USD,CNY
2000-01-01 open Assets:Stock HOOL "FIFO"
2000-01-01 open Equity:Opening USD
2000-01-01 commodity HOOL
  name: "Example stock"
2000-01-02 pad Assets:Cash Equity:Opening
2000-01-03 balance Assets:Cash 100 ~ 0.001 USD
2026-01-01 * "Buy first"
  exact: 123456789.123456789123456789
  limit: 100.000000000000000001 USD
  due: 2026-02-03
  approved: TRUE
  memo: "中文 metadata"
  Assets:Stock 2 HOOL {10 USD, 2025-12-31, "first-lot"} @ 10 USD
    broker: "Example broker"
    exact: 0.123456789123456789
  Assets:Cash -20 USD
2026-01-02 * "Buy second"
  Assets:Stock 2 HOOL {12 USD}
  Assets:Cash -24 USD
2026-01-03 * "Sell split"
  Assets:Stock -3 HOOL {}
  Assets:Cash
2026-01-04 * "Currency exchange"
  Assets:Cash -10 USD @ 7 CNY
  Assets:Cash 70 CNY
2026-01-05 * "Auto account"
  Assets:Cash -1 CNY
  Expenses:Food 1 CNY
2026-01-06 custom "budget" Expenses:Food "monthly" 100.000000000000000001 CNY 0.123456789123456789 TRUE 2026-02-01
2026-01-07 note Assets:Cash "A note" #tag ^link
2026-01-08 event "location" "Somewhere"
2026-01-09 query "test" "SELECT account"
2026-01-10 close Expenses:Food
'''


class BoundedStreamTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "ledger"
        self.root.mkdir(mode=0o700)
        self.private = self.base / "private"
        self.private.mkdir(mode=0o700)
        self.destination = self.private / "canonical.jsonl"
        self.source = self.root / "main.bean"
        self.source.write_text(BASIC, encoding="utf-8")

    def export(self, text=None, **kwargs):
        if text is not None:
            self.source.write_text(text, encoding="utf-8")
        summary = stream.export_stream(self.root, self.destination, **kwargs)
        raw = self.destination.read_bytes()
        lines = raw.splitlines(keepends=True)
        records = [json.loads(line) for line in lines]
        self.assertTrue(all(line.endswith(b"\n") for line in lines))
        self.assertTrue(all(len(line) <= 1048576 for line in lines))
        self.assertTrue(all(json.dumps(row, ensure_ascii=False, separators=(",", ":")).encode()
                            + b"\n" == line for row, line in zip(records, lines)))
        self.assertEqual(records[0]["type"], "header")
        self.assertEqual(records[-1]["type"], "footer")
        self.assertEqual(records[-1]["records"], len(records) - 1)
        self.assertEqual(records[-1]["directives"], sum(r["type"] == "directive" for r in records))
        self.assertEqual(records[-1]["postings"], sum(r["type"] == "posting" for r in records))
        self.assertEqual(records[-1]["sha256"], hashlib.sha256(b"".join(lines[:-1])).hexdigest())
        self.assertEqual(summary, {"source_digest": records[0]["source_digest"],
                                   **{k: v for k, v in records[-1].items() if k != "type"}})
        self.assertNotIn(str(self.root), raw.decode())
        return records, summary

    def assert_rejected(self, error=ValueError):
        with self.assertRaises(error):
            stream.export_stream(self.root, self.destination)
        self.assertFalse(self.destination.exists())

    def test_header_footer_order_permissions_and_uncached_validation(self):
        cache = self.root / ".main.bean.picklecache"
        cache.write_bytes(b"Do not open untrusted pickle")
        with mock.patch.object(validator, "_canonical_entry", side_effect=AssertionError("whole entry")), \
                mock.patch.object(validator.loader, "_uncached_load_file",
                                  wraps=validator.loader._uncached_load_file) as load, \
                mock.patch.object(validator, "_preflight", wraps=validator._preflight) as preflight, \
                mock.patch.object(stream.os, "fsync", wraps=os.fsync) as fsync:
            records, _ = self.export()
        load.assert_called_once()
        self.assertIs(load.call_args.args[2], validator.validation.HARDCORE_VALIDATIONS)
        preflight.assert_called_once()
        fsync.assert_called_once()
        self.assertEqual(cache.read_bytes(), b"Do not open untrusted pickle")
        self.assertEqual(stat.S_IMODE(self.destination.stat().st_mode), 0o600)
        header = records[0]
        self.assertEqual(header["version"], 1)
        self.assertEqual(header["entry_file"], "main.bean")
        self.assertEqual(header["exporter"], "bounded-v1")
        self.assertIn("beancount/3.2.3", header["runtime"])
        self.assertRegex(header["source_digest"], r"^[a-f0-9]{64}$")
        started = False
        current, ordinal = 0, -1
        for row in records[1:-1]:
            if row["type"] in {"option", "commodity"}:
                self.assertFalse(started)
            elif row["type"] == "directive":
                started = True
                current += 1
                ordinal = -1
                self.assertEqual(row["id"], current)
                self.assertNotIn("Postings", row["value"])
                self.assertNotIn("Metadata", row["value"])
            elif row["type"] == "posting":
                ordinal += 1
                self.assertEqual((row["entry_id"], row["ordinal"]), (current, ordinal))

    def test_empty_ledger_has_valid_zero_counts(self):
        records, summary = self.export("")
        self.assertEqual(summary["directives"], 0)
        self.assertEqual(summary["postings"], 0)
        self.assertGreater(len(records), 2)

    def test_plugin_cost_multicurrency_booking_and_legacy_semantic_parity(self):
        records, _ = self.export(GOLDEN)
        legacy = json.loads(validator.validate_json(self.root))
        self.assertEqual(legacy["errors"], [])
        old = legacy["canonical"]
        directives = [r for r in records if r["type"] == "directive"]
        self.assertEqual(len(directives), len(old["entries"]))
        for record, entry in zip(directives, old["entries"]):
            expected = {k: v for k, v in entry.items()
                        if k not in {"Metadata", "Postings", "CustomValues"}}
            actual = {k: v for k, v in record["value"].items()
                      if k not in {"Booking", "CustomValues"}}
            self.assertEqual(actual, expected)
            postings = [r["value"] for r in records
                        if r["type"] == "posting" and r["entry_id"] == record["id"]]
            self.assertEqual(postings, entry.get("Postings", []))
        options = {r["key"]: r["value"] for r in records if r["type"] == "option"}
        for key, value in old["options"].items():
            if key in {"filename", "include", "documents"}:
                value = stream._relative(self.root, value)
            self.assertEqual(options[key], value)
        self.assertEqual(options["operating_currency"], "CNY")
        self.assertEqual([r["value"] for r in records if r["type"] == "commodity"], old["commodities"])
        self.assertTrue(any(r["value"].get("Kind") == "price" for r in directives))
        self.assertTrue(any(r["value"].get("Account") == "Expenses:Food" and
                            r["value"]["Kind"] == "open" for r in directives))
        stock = next(r["value"] for r in directives if r["value"].get("Account") == "Assets:Stock")
        self.assertEqual(stock["Booking"], "FIFO")
        pad = next(r["value"] for r in directives if r["value"]["Kind"] == "pad")
        self.assertEqual(pad["Account2"], "Equity:Opening")
        sell = next(r for r in directives if r["value"].get("Narration") == "Sell split")
        split = [r for r in records if r["type"] == "posting" and r["entry_id"] == sell["id"]]
        self.assertEqual([r["value"]["Quantity"]["Number"] for r in split], ["-2", "-1", "32"])
        self.assertEqual([r["ordinal"] for r in split], [0, 1, 2])
        buy = next(r for r in directives if r["value"].get("Narration") == "Buy first")
        first = next(r["value"] for r in records if r["type"] == "posting" and r["entry_id"] == buy["id"])
        self.assertEqual(first["CostDate"], "2025-12-31")
        self.assertEqual(first["CostLabel"], "first-lot")
        self.assertEqual(first["Price"], {"Number": "10", "Currency": "USD"})

    def test_exact_metadata_custom_types_and_metadata_order(self):
        records, _ = self.export(GOLDEN)
        meta = {}
        current, ordinal = 0, -1
        for row in records:
            if row["type"] == "directive":
                current, ordinal = row["id"], -1
            elif row["type"] == "posting":
                ordinal = row["ordinal"]
            elif row["type"] == "metadata":
                self.assertEqual((row["entry_id"], row["posting"]), (current, ordinal))
                self.assertNotIn(row["key"], {"filename", "lineno"})
                self.assertFalse(row["key"].startswith("__"))
                meta[(ordinal, row["key"])] = row["value"]
        self.assertEqual(meta[(-1, "exact")], {"type": "decimal", "value": "123456789.123456789123456789"})
        self.assertEqual(meta[(0, "exact")], {"type": "decimal", "value": "0.123456789123456789"})
        self.assertEqual(meta[(-1, "limit")], {"type": "amount", "value": {"Number": "100.000000000000000001", "Currency": "USD"}})
        self.assertEqual(meta[(-1, "due")], {"type": "date", "value": "2026-02-03"})
        self.assertEqual(meta[(-1, "approved")], {"type": "bool", "value": True})
        self.assertEqual(meta[(0, "broker")], {"type": "str", "value": "Example broker"})
        custom = next(r["value"] for r in records if r["type"] == "directive" and r["value"]["Kind"] == "custom")
        self.assertEqual(custom["CustomValues"], [
            {"type": "account", "value": "Expenses:Food"},
            {"type": "str", "value": "monthly"},
            {"type": "amount", "value": {"Number": "100.000000000000000001", "Currency": "CNY"}},
            {"type": "decimal", "value": "0.123456789123456789"},
            {"type": "bool", "value": True}, {"type": "date", "value": "2026-02-01"}])

    def test_all_typed_values_depth_and_unsupported(self):
        cases = [(None, "none", None), (True, "bool", True), (False, "bool", False),
                 (123, "int", 123), ("x", "str", "x"),
                 (date(2026, 1, 2), "date", "2026-01-02"),
                 (Decimal("1.000000000000000001"), "decimal", "1.000000000000000001"),
                 (Amount(Decimal("2.00"), "CNY"), "amount", {"Number": "2.00", "Currency": "CNY"})]
        for value, kind, expected in cases:
            self.assertEqual(stream._typed_value(value), {"type": kind, "value": expected})
        for value in ([1, "two"], (1, "two")):
            self.assertEqual(stream._typed_value(value), {"type": "list", "value": [
                {"type": "int", "value": 1}, {"type": "str", "value": "two"}]})
        self.assertEqual(stream._typed_value({"b", "a"}), stream._typed_value(frozenset({"a", "b"})))
        nested = None
        for _ in range(16):
            nested = [nested]
        stream._typed_value(nested)
        with self.assertRaisesRegex(ValueError, "depth"):
            stream._typed_value([nested])
        cyclic = []
        cyclic.append(cyclic)
        with self.assertRaisesRegex(ValueError, "depth"):
            stream._typed_value(cyclic)
        for unsupported in (0.1, float("nan"), {"a": 1}, object(), b"bytes", Decimal("NaN"), Decimal("Infinity")):
            with self.subTest(type=type(unsupported).__name__), self.assertRaises(ValueError):
                stream._typed_value(unsupported)

    def test_plugin_metadata_none_list_int_and_internal_filter(self):
        original = validator.loader._uncached_load_file

        def load(*args):
            entries, errors, options = original(*args)
            entries[0].meta.update({"nil": None, "count": 12,
                                    "values": [Decimal("0.000000000000000001"), True],
                                    "__unsupported_internal": object()})
            return entries, errors, options

        with mock.patch.object(validator.loader, "_uncached_load_file", side_effect=load):
            records, _ = self.export()
        meta = {r["key"]: r["value"] for r in records if r["type"] == "metadata"}
        self.assertEqual(meta["nil"], {"type": "none", "value": None})
        self.assertEqual(meta["count"], {"type": "int", "value": 12})
        self.assertEqual(meta["values"]["value"][0]["value"], str(Decimal("0.000000000000000001")))
        self.assertNotIn("__unsupported_internal", meta)

    def test_unsupported_metadata_removes_partial(self):
        original = validator.loader._uncached_load_file

        def load(*args):
            entries, errors, options = original(*args)
            entries[-1].postings[-1].meta["bad"] = 1.1
            return entries, errors, options

        with mock.patch.object(validator.loader, "_uncached_load_file", side_effect=load):
            self.assert_rejected()

    def test_many_postings_are_independent_bounded_records(self):
        # Legacy transaction JSON alone is >1MiB; no transaction-wide allocation.
        count = 14000
        text = '2000-01-01 open Assets:Cash USD\n2026-01-01 * "Large"\n'
        text += ''.join('  Assets:Cash ' + ('1' if i % 2 == 0 else '-1') + ' USD\n' for i in range(count))
        with mock.patch.object(validator, "_canonical_entry", side_effect=AssertionError("whole entry")):
            records, summary = self.export(text)
        self.assertEqual(summary["postings"], count)
        self.assertGreater(self.destination.stat().st_size, stream.MAX_RECORD_BYTES)
        self.assertLess(max(len(json.dumps(r)) for r in records), 1000)

    def test_large_metadata_map_is_split_without_transaction_allocation(self):
        original = validator.loader._uncached_load_file
        count = 5000

        def load(*args):
            entries, errors, options = original(*args)
            for index in range(count):
                entries[-1].meta["field" + str(index)] = "x" * 250
            return entries, errors, options

        with mock.patch.object(validator.loader, "_uncached_load_file", side_effect=load), \
                mock.patch.object(validator, "_canonical_entry", side_effect=AssertionError("whole entry")):
            records, _ = self.export()
        self.assertEqual(sum(r["type"] == "metadata" for r in records), count)
        self.assertGreater(self.destination.stat().st_size, stream.MAX_RECORD_BYTES)

    def test_metadata_limit_counts_internal_keys_before_sorting(self):
        self.assertEqual(stream.MAX_METADATA_KEYS, 8192)
        meta = {"__" + str(i): object() for i in range(stream.MAX_METADATA_KEYS)}
        output = io.BytesIO()
        writer = stream._Writer(output)
        writer.metadata(1, -1, meta)  # Inclusive bound, even for omitted keys.
        self.assertEqual(output.getvalue(), b"")
        meta["filename"] = "main.bean"
        with mock.patch.object(stream, "sorted", create=True,
                               side_effect=AssertionError("sort before limit")):
            with self.assertRaisesRegex(ValueError, "Metadata exceeds key limit"):
                writer.metadata(1, -1, meta)

    def test_metadata_limit_removes_partial_for_both_owners(self):
        original = validator.loader._uncached_load_file
        for posting in (False, True):
            with self.subTest(posting=posting):
                def load(*args):
                    entries, errors, options = original(*args)
                    meta = entries[-1].postings[-1].meta if posting else entries[-1].meta
                    meta.clear()
                    meta.update({"__" + str(i): None
                                 for i in range(stream.MAX_METADATA_KEYS)})
                    meta["public"] = "over limit"
                    return entries, errors, options

                with mock.patch.object(validator.loader, "_uncached_load_file", side_effect=load):
                    with self.assertRaisesRegex(ValueError, "Metadata exceeds key limit"):
                        stream.export_stream(self.root, self.destination)
                self.assertFalse(self.destination.exists())

    def test_metadata_limit_inclusive_public_keys(self):
        output = io.BytesIO()
        writer = stream._Writer(output)
        writer.metadata(1, -1, {"key" + str(i): None
                                for i in range(stream.MAX_METADATA_KEYS)})
        keys = [json.loads(line)["key"] for line in output.getvalue().splitlines()]
        self.assertEqual(len(keys), stream.MAX_METADATA_KEYS)
        self.assertEqual(keys, sorted(keys))

    def test_non_regular_sources_are_rejected_without_blocking(self):
        self.source.unlink()
        os.mkfifo(self.source)
        self.assert_rejected()

    def test_invalid_sources_and_preflight_never_run_untrusted_plugins(self):
        for text in (BASIC.replace("Food 12.50", "Food 11.50"),
                     'include "missing.bean"\n', 'not valid beancount\n',
                     'plugin "os"\n', 'option "insert_pythonpath" "TRUE"\n',
                     'include "../*.bean"\n', 'option "documents" "../outside"\n'):
            with self.subTest(text=text):
                self.source.write_text(text)
                self.assert_rejected()
        self.source.write_text('include "children/**/*.bean"\n')
        (self.root / "children" / "nested").mkdir(parents=True)
        (self.root / "children" / "nested" / "bad.bean").write_text('plugin "os"\n')
        with mock.patch.object(validator.loader, "_uncached_load_file") as load:
            self.assert_rejected()
            load.assert_not_called()

    def test_source_symlink_root_component_and_glob_rejected(self):
        outside = self.base / "outside.bean"
        outside.write_text(BASIC)
        link = self.root / "link.bean"
        link.symlink_to(outside)
        self.source.write_text('include "*.bean"\n')
        self.assert_rejected()
        alias = self.base / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(OSError):
            stream.export_stream(alias, self.destination)
        self.assertFalse(self.destination.exists())

    def test_invalid_entry_file_and_destination_inside_ledger(self):
        for entry in (str(self.source), "../main.bean"):
            with self.assertRaises(ValueError):
                stream.export_stream(self.root, self.destination, entry)
        with self.assertRaises(ValueError):
            stream.export_stream(self.root, self.root / "stream")
        self.assertFalse((self.root / "stream").exists())

    def test_oversized_record_includes_lf_and_utf8_boundary(self):
        output = io.BytesIO()
        writer = stream._Writer(output)
        overhead = len(b'{"s":""}\n')
        writer.write({"s": "a" * (stream.MAX_RECORD_BYTES - overhead)})
        self.assertEqual(len(output.getvalue()), stream.MAX_RECORD_BYTES)
        with self.assertRaisesRegex(ValueError, "byte limit"):
            writer.write({"s": "a" * (stream.MAX_RECORD_BYTES - overhead + 1)})
        with self.assertRaisesRegex(ValueError, "byte limit"):
            writer.write({"s": "中" * (stream.MAX_RECORD_BYTES // 2)})
        with self.assertRaisesRegex(ValueError, "byte limit"):
            stream._typed_value([None] * (stream.MAX_RECORD_BYTES // 8 + 1))
        self.source.write_text(BASIC.replace("午餐", "a" * stream.MAX_RECORD_BYTES))
        self.assert_rejected()

    def test_permissions_parent_missing_symlink_and_existing_destination(self):
        self.private.chmod(0o755)
        self.assert_rejected()
        self.private.chmod(0o700)
        self.destination.write_bytes(b"existing")
        with self.assertRaises(FileExistsError):
            stream.export_stream(self.root, self.destination)
        self.assertEqual(self.destination.read_bytes(), b"existing")
        self.destination.unlink()
        sentinel = self.base / "sentinel"
        sentinel.write_bytes(b"keep")
        self.destination.symlink_to(sentinel)
        with self.assertRaises(FileExistsError):
            stream.export_stream(self.root, self.destination)
        self.assertTrue(self.destination.is_symlink())
        self.assertEqual(sentinel.read_bytes(), b"keep")
        alias = self.base / "alias"
        alias.symlink_to(self.private, target_is_directory=True)
        with self.assertRaises(OSError):
            stream.export_stream(self.root, alias / "other")
        with self.assertRaises(FileNotFoundError):
            stream.export_stream(self.root, self.base / "missing" / "stream")
        self.assertFalse((self.base / "missing").exists())

    def test_nested_destination_parent_symlink_is_rejected(self):
        nested = self.private / "nested"
        nested.mkdir(mode=0o700)
        alias = self.base / "alias"
        alias.symlink_to(self.private, target_is_directory=True)
        with self.assertRaises(OSError):
            stream.export_stream(self.root, alias / "nested" / "stream")
        self.assertEqual(list(nested.iterdir()), [])

    def test_fsync_failure_removes_own_partial_only(self):
        with mock.patch.object(stream.os, "fsync", side_effect=OSError("disk full")):
            self.assert_rejected(OSError)

    def test_replaced_partial_is_not_unlinked(self):

        def fail(*args):
            # Keep the owned inode alive under another name to avoid inode reuse.
            self.destination.rename(self.private / "moved-own-partial")
            self.destination.write_bytes(b"replacement owned by somebody else")
            raise RuntimeError("cancel")

        with mock.patch.object(validator.loader, "_uncached_load_file", side_effect=fail):
            with self.assertRaises(RuntimeError):
                stream.export_stream(self.root, self.destination)
        self.assertEqual(self.destination.read_bytes(), b"replacement owned by somebody else")

    def test_cancellation_removes_partial(self):
        with mock.patch.object(validator.loader, "_uncached_load_file", side_effect=KeyboardInterrupt):
            self.assert_rejected(KeyboardInterrupt)

    def test_source_hash_includes_sorted_paths_and_exact_bytes(self):
        self.source.write_text('include "z.bean"\ninclude "a.bean"\n')
        (self.root / "z.bean").write_text('2000-01-01 open Assets:Z USD\n')
        (self.root / "a.bean").write_text('2000-01-01 open Assets:A USD\n')
        _, summary = self.export()
        expected = hashlib.sha256()
        for name in ("a.bean", "main.bean", "z.bean"):
            raw = (self.root / name).read_bytes()
            encoded = name.encode()
            expected.update(len(encoded).to_bytes(8, "big"))
            expected.update(encoded)
            expected.update(len(raw).to_bytes(8, "big"))
            expected.update(raw)
        self.assertEqual(summary["source_digest"], expected.hexdigest())
        self.destination.unlink()
        child = self.root / "z.bean"
        before = child.stat()
        child.write_text('2000-01-01 open Assets:Y USD\n')
        os.utime(child, ns=(before.st_atime_ns, before.st_mtime_ns))
        _, changed = self.export()
        self.assertNotEqual(summary["source_digest"], changed["source_digest"])

    def test_source_change_same_size_and_mtime_during_load(self):
        original = validator.loader._uncached_load_file

        def changed(*args):
            result = original(*args)
            before = self.source.stat()
            self.source.write_text(BASIC.replace("12.50", "13.50"))
            os.utime(self.source, ns=(before.st_atime_ns, before.st_mtime_ns))
            return result

        with mock.patch.object(validator.loader, "_uncached_load_file", side_effect=changed):
            self.assert_rejected()

    def test_source_change_after_streaming_removes_partial(self):
        original = stream._Writer.write
        mutated = False

        def changed(writer, record, **kwargs):
            nonlocal mutated
            original(writer, record, **kwargs)
            if record["type"] == "posting" and not mutated:
                self.source.write_text(BASIC + "; modified\n")
                mutated = True

        with mock.patch.object(stream._Writer, "write", changed):
            self.assert_rejected()
        self.assertTrue(mutated)

    def test_glob_addition_during_load_is_rejected(self):
        self.source.write_text('include "children/*.bean"\n')
        children = self.root / "children"
        children.mkdir()
        (children / "a.bean").write_text(BASIC)
        original = validator.loader._uncached_load_file

        def changed(*args):
            result = original(*args)
            (children / "b.bean").write_text('; a new source\n')
            return result

        with mock.patch.object(validator.loader, "_uncached_load_file", side_effect=changed):
            self.assert_rejected()

    def test_output_is_private_at_creation_even_with_permissive_umask(self):
        original = validator.loader._uncached_load_file

        def inspect(*args):
            self.assertEqual(stat.S_IMODE(self.destination.stat().st_mode), 0o600)
            return original(*args)

        old_umask = os.umask(0)
        try:
            with mock.patch.object(validator.loader, "_uncached_load_file", side_effect=inspect):
                self.export()
        finally:
            os.umask(old_umask)

    def test_depth_failure_and_oversized_metadata_remove_partial(self):
        original = validator.loader._uncached_load_file
        nested = None
        for _ in range(17):
            nested = [nested]
        for value in (nested, "x" * stream.MAX_RECORD_BYTES):
            def load(*args):
                entries, errors, options = original(*args)
                entries[-1].meta["bad"] = value
                return entries, errors, options

            with mock.patch.object(validator.loader, "_uncached_load_file", side_effect=load):
                self.assert_rejected()

    def test_write_failure_removes_partial(self):
        original = stream._Writer.write

        def fail(writer, record, **kwargs):
            original(writer, record, **kwargs)
            if record["type"] == "posting":
                raise OSError("simulated disk full")

        with mock.patch.object(stream._Writer, "write", fail):
            self.assert_rejected(OSError)

    def test_replaced_destination_cannot_report_success(self):
        def replace(fd):
            self.destination.rename(self.private / "own-completed-stream")
            self.destination.write_bytes(b"not this export")

        with mock.patch.object(stream.os, "fsync", side_effect=replace):
            with self.assertRaisesRegex(ValueError, "replaced"):
                stream.export_stream(self.root, self.destination)
        self.assertEqual(self.destination.read_bytes(), b"not this export")

    def test_unknown_custom_dtype_is_rejected(self):
        original = validator.loader._uncached_load_file
        self.source.write_text('2026-01-01 custom "test" "value"\n')

        def load(*args):
            entries, errors, options = original(*args)
            entries[0].values[0] = entries[0].values[0]._replace(dtype=object)
            return entries, errors, options

        with mock.patch.object(validator.loader, "_uncached_load_file", side_effect=load):
            self.assert_rejected()

    def test_nested_entry_and_document_source_paths_are_relative(self):
        child = self.root / "child"
        child.mkdir()
        document = child / "receipt.pdf"
        document.write_bytes(b"public synthetic fixture")
        text = '2000-01-01 open Assets:Cash USD\n2026-01-01 document Assets:Cash "receipt.pdf"\n'
        (child / "entry.bean").write_text(text)
        records, _ = self.export(entry_file="child/entry.bean")
        self.assertEqual(records[0]["entry_file"], "child/entry.bean")
        row = next(r["value"] for r in records if r["type"] == "directive" and r["value"]["Kind"] == "document")
        self.assertEqual(row["File"], "child/entry.bean")
        self.assertEqual(row["Filename"], "child/receipt.pdf")

    def test_documents_option_resolves_against_nested_entry_parent(self):
        child = self.root / "child"
        (child / "receipts").mkdir(parents=True)
        (child / "entry.bean").write_text('option "documents" "receipts"\n' + BASIC)
        records, _ = self.export(entry_file="child/entry.bean")
        options = {r["key"]: r["value"] for r in records if r["type"] == "option"}
        self.assertEqual(options["documents"], "child/receipts")

    def test_documents_option_root_is_supported(self):
        records, _ = self.export('option "documents" "."\n' + BASIC)
        self.assertEqual(next(r["value"] for r in records
                              if r["type"] == "option" and r["key"] == "documents"), ".")

    def test_unsupported_source_paths_remove_partial(self):
        for name in ("back\\slash.bean", "colon:name.bean", "control\x01.bean", "del\x7f.bean"):
            with self.subTest(name=name):
                (self.root / name).write_text(BASIC)
                with self.assertRaisesRegex(ValueError, "Unsupported wire path"):
                    stream.export_stream(self.root, self.destination, entry_file=name)
                self.assertFalse(self.destination.exists())
                (self.root / name).unlink()

    def test_unsupported_included_source_path_removes_partial(self):
        # Even an empty included file must not enter the source digest with a
        # path outside the wire grammar, despite producing no directive File.
        (self.root / "bad:name.bean").write_text("")
        self.source.write_text('include "bad:name.bean"\n' + BASIC)
        self.assert_rejected()

    def test_unsupported_loaded_paths_remove_partial(self):
        original = validator.loader._uncached_load_file
        (self.root / "receipt.pdf").write_bytes(b"public synthetic fixture")
        self.source.write_text(BASIC + '2026-01-02 document Assets:Cash "receipt.pdf"\n')
        for role in ("File", "Filename", "filename", "documents"):
            for path in ("bad\\path", "bad:path", "bad\x01path", "bad\x7fpath", "../outside"):
                with self.subTest(role=role, path=path):
                    def load(*args):
                        entries, errors, options = original(*args)
                        if role == "File":
                            entries[-1].meta["filename"] = path
                        elif role == "Filename":
                            entries[-1] = entries[-1]._replace(filename=path)
                        else:
                            options[role] = path
                        return entries, errors, options

                    with mock.patch.object(validator.loader, "_uncached_load_file", side_effect=load):
                        self.assert_rejected()


@unittest.skipUnless(os.environ.get("LEDGER_STREAM_CHECK"),
                     "set LEDGER_STREAM_CHECK to the Go verifier binary")
class WirePathInteroperabilityTests(unittest.TestCase):
    setUp = BoundedStreamTests.setUp
    export = BoundedStreamTests.export

    def go_verify(self, records, accepted):
        output = io.BytesIO()
        writer = stream._Writer(output)
        for record in records:
            writer.write(record)
        writer.write({"type": "footer", "records": writer.records,
                      "directives": sum(r["type"] == "directive" for r in records),
                      "postings": 0, "sha256": writer.digest.hexdigest()}, footer=True)
        self.destination.write_bytes(output.getvalue())
        result = subprocess.run([os.environ["LEDGER_STREAM_CHECK"], str(self.destination)],
                                capture_output=True)
        self.assertEqual(result.returncode, 0 if accepted else 1, result.stderr)

    def test_wire_path_grammar_matches_go_in_all_fields(self):
        header = {"type": "header", "version": 1, "source_digest": "a" * 64,
                  "entry_file": "main.bean", "runtime": "beancount/3.2.3 python/3.11.0",
                  "exporter": "bounded-v1"}
        cases = [("main.bean", True), ("child/receipt.pdf", True), ("中文/票据", True),
                 ("back\\slash", False), ("colon:name", False), ("../file", False),
                 ("child/../file", False), ("/absolute", False), ("C:/file", False),
                 ("./file", False), ("child//file", False), ("child/", False),
                 ("control\x00", False), ("control\x1f", False), ("del\x7f", False)]
        for role in ("header", "File", "Filename", "filename", "include", "documents"):
            empty = role in {"File", "filename", "include", "documents"}
            documents = role == "documents"
            for value, accepted in cases + [("", empty), (".", documents)]:
                with self.subTest(role=role, value=value):
                    if accepted:
                        self.assertEqual(stream._wire_path(value, empty=empty,
                                                           documents=documents), value)
                    else:
                        with self.assertRaises(ValueError):
                            stream._wire_path(value, empty=empty, documents=documents)
                    records = [dict(header)]
                    if role == "header":
                        records[0]["entry_file"] = value
                    elif role in {"File", "Filename"}:
                        directive = {"Kind": "document", "Date": "2026-01-01",
                                     "File": "main.bean", "Line": 1,
                                     "Account": "Assets:Cash", "Filename": "receipt.pdf",
                                     "Tags": [], "Links": []}
                        directive[role] = value
                        records.append({"type": "directive", "id": 1, "value": directive})
                    else:
                        records.append({"type": "option", "key": role, "value": value})
                    self.go_verify(records, accepted)

    def test_real_documents_exports_verify_in_go(self):
        for entry_file, documents, expected in (("main.bean", ".", "."),
                                                ("child/entry.bean", "receipts", "child/receipts")):
            with self.subTest(entry_file=entry_file):
                entry = self.root / entry_file
                entry.parent.mkdir(exist_ok=True)
                (entry.parent / documents).mkdir(exist_ok=True)
                entry.write_text('option "documents" "' + documents + '"\n' + BASIC)
                records, _ = self.export(entry_file=entry_file)
                self.assertEqual(next(r["value"] for r in records
                                      if r["type"] == "option" and r["key"] == "documents"), expected)
                result = subprocess.run([os.environ["LEDGER_STREAM_CHECK"], str(self.destination)],
                                        capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.destination.unlink()


if __name__ == "__main__":
    unittest.main()
