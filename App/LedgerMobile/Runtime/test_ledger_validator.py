import contextlib
import datetime
import json
import os
import hashlib
import pathlib
import random
import shutil
import tempfile
import unittest
from unittest import mock

import ledger_validator

from ledger_validator import validate_json, validate_only_json


class CanonicalValidationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def validate(self, text):
        (self.root / "main.bean").write_text(text)
        full = json.loads(validate_json(str(self.root)))
        diagnostics = json.loads(validate_only_json(str(self.root)))
        self.assertEqual(diagnostics, {"errors": full["errors"]})
        return full["errors"]

    def test_balanced_and_unbalanced(self):
        ledger = '''2000-01-01 open Assets:Cash CNY
2000-01-01 open Expenses:Food CNY
2026-01-01 * "Lunch"
  Assets:Cash -10 CNY
  Expenses:Food 10 CNY
'''
        self.assertEqual(self.validate(ledger), [])
        errors = self.validate(ledger.replace("Food 10", "Food 9"))
        self.assertTrue(any("balance" in error["message"] for error in errors))

    def test_includes_and_missing_account_and_balance_assertion(self):
        (self.root / "accounts.bean").write_text("2000-01-01 open Assets:Cash CNY\n")
        self.assertEqual(self.validate('include "accounts.bean"\n'), [])
        self.assertTrue(self.validate('2000-01-02 balance Assets:Unknown 0 CNY\n'))
        self.assertTrue(self.validate('include "accounts.bean"\n2000-01-02 balance Assets:Cash 1 CNY\n'))

    def test_cost_booking(self):
        ledger = '''2000-01-01 open Assets:Cash USD
2000-01-01 open Assets:Stock HOOL
2026-01-01 * "Buy"
  Assets:Stock 2 HOOL {10 USD}
  Assets:Cash -20 USD
2026-01-02 * "Sell unavailable lot"
  Assets:Stock -3 HOOL {10 USD}
  Assets:Cash 30 USD
'''
        self.assertTrue(self.validate(ledger))

    def test_plugins_are_checked_in_includes_before_execution(self):
        (self.root / "child.bean").write_text('plugin "os"\n')
        errors = self.validate('include "child.bean"\n')
        self.assertIn("不支持插件", errors[0]["message"])
        self.assertTrue(self.validate('plugin "beancount.plugins.check_commodity" "__import__(\'os\')"\n'))
        self.assertEqual(self.validate('plugin "beancount.plugins.auto_accounts"\n'), [])

    def test_include_escape_symlink_and_pythonpath(self):
        self.assertTrue(self.validate('include "../*.bean"\n'))
        (self.root / "outside").symlink_to(self.root.parent, target_is_directory=True)
        self.assertTrue(self.validate('include "outside/*.bean"\n'))
        self.assertTrue(self.validate('option "insert_pythonpath" "TRUE"\n'))
        self.assertTrue(self.validate('option "documents" "../"\n'))

    def test_preflight_parses_only_files_that_can_carry_policy_directives(self):
        root = self.root.resolve()
        (root / "plain.bean").write_text("2000-01-01 open Assets:Cash CNY\n")
        (root / "transactions.bean").write_text(
            '2026-01-01 * "Shop" "Lunch"\n  Assets:Cash -1 CNY\n  Expenses:Food 1 CNY\n')
        (root / "policy.bean").write_text('plugin "beancount.plugins.auto_accounts"\n')
        (root / "main.bean").write_text('include "*.bean"\n')
        with mock.patch.object(ledger_validator.parser, "parse_file",
                               wraps=ledger_validator.parser.parse_file) as parse:
            ledger_validator._preflight(root, root / "main.bean")
        parsed = sorted(pathlib.Path(call.args[0]).name for call in parse.call_args_list)
        self.assertEqual(parsed, ["main.bean", "policy.bean"])

    def test_preflight_policy_rejections_still_fire_for_directive_files(self):
        cases = [
            ('plugin "os"\n', "不支持插件"),
            ('option "insert_pythonpath" "TRUE"\n', "insert_pythonpath"),
            ('option "documents" "../"\n', "账本引用超出本地目录"),
            ('2026-01-01 document Assets:Cash "../outside.pdf"\n', "账本引用超出本地目录"),
        ]
        for text, message in cases:
            (self.root / "child.bean").write_text(text)
            errors = self.validate('include "child.bean"\n')
            self.assertTrue(errors, text)
            self.assertIn(message, errors[0]["message"])
        (self.root / "child.bean").write_text('include "secret.gpg"\n')
        (self.root / "secret.gpg").write_bytes(b"encrypted ledger")
        self.assertIn("请先解密账本再导入", self.validate('include "child.bean"\n')[0]["message"])

    def test_imported_pickle_is_never_loaded_or_removed(self):
        cache = self.root / ".main.bean.picklecache"
        content = b"untrusted pickle cache"
        cache.write_bytes(content)
        self.assertEqual(self.validate("2000-01-01 open Assets:Cash CNY\n"), [])
        self.assertEqual(cache.read_bytes(), content)

    def test_exports_plugin_transformed_accounts_and_prices(self):
        self.validate('''plugin "beancount.plugins.auto_accounts"
plugin "beancount.plugins.implicit_prices"
2026-01-01 * "Buy"
  Assets:Stock 2 HOOL {10 USD}
  Assets:Cash -20 USD
''')
        result = json.loads(validate_json(str(self.root)))
        self.assertEqual(result["errors"], [])
        canonical = result["canonical"]
        self.assertEqual(canonical["version"], 1)
        entries = canonical["entries"]
        self.assertEqual({e["Account"] for e in entries if e["Kind"] == "open"},
                         {"Assets:Stock", "Assets:Cash"})
        price = next(e for e in entries if e["Kind"] == "price")
        self.assertEqual(price["AmountValue"], {"Number": "10", "Currency": "USD"})
        self.assertEqual(price["Currency"], "HOOL")

    def test_exports_every_operating_currency_without_commodity_declarations(self):
        self.validate('option "operating_currency" "USD"\noption "operating_currency" "EUR"\n')
        result = json.loads(validate_json(str(self.root)))
        self.assertEqual(result["errors"], [])
        self.assertEqual(result["canonical"]["commodities"], ["EUR", "USD"])

    def test_amount_metadata_and_custom_values_keep_scalar_api_contract(self):
        self.validate('''2000-01-01 open Assets:Cash CNY
2000-01-01 open Expenses:Food CNY
2026-01-01 custom "budget" Expenses:Food "monthly" 100 CNY
2026-01-02 * "Lunch"
  limit: 100 CNY
  Assets:Cash -12.50 CNY
  Expenses:Food 12.50 CNY
''')
        result = json.loads(validate_json(str(self.root)))
        self.assertEqual(result["errors"], [])
        entries = result["canonical"]["entries"]
        budget = next(entry for entry in entries if entry["Kind"] == "custom")
        self.assertEqual(budget["CustomValues"], ["Expenses:Food", "monthly", "100 CNY"])
        transaction = next(entry for entry in entries if entry["Kind"] == "transaction")
        self.assertEqual(transaction["Metadata"]["limit"], "100 CNY")
        self.assertEqual(transaction["Postings"][0]["Quantity"], {"Number": "-12.50", "Currency": "CNY"})

    def test_open_currencies_preserve_primary_currency_order(self):
        self.assertEqual(self.validate('2000-01-01 open Assets:Cash USD,CNY\n'), [])
        result = json.loads(validate_json(str(self.root)))
        self.assertEqual(result["canonical"]["entries"][0]["Currencies"], ["USD", "CNY"])

    def test_exports_booked_split_postings_and_generated_pad(self):
        self.validate('''2000-01-01 open Assets:Cash USD
2000-01-01 open Assets:Stock HOOL "FIFO"
2000-01-01 open Equity:Opening USD
2000-01-02 pad Assets:Cash Equity:Opening
2000-01-03 balance Assets:Cash 100 USD
2026-01-01 * "Buy first"
  Assets:Stock 2 HOOL {10 USD}
  Assets:Cash -20 USD
2026-01-02 * "Buy second"
  Assets:Stock 2 HOOL {12 USD}
  Assets:Cash -24 USD
2026-01-03 * "Sell split"
  Assets:Stock -3 HOOL {}
  Assets:Cash
''')
        result = json.loads(validate_json(str(self.root)))
        self.assertEqual(result["errors"], [])
        transactions = [e for e in result["canonical"]["entries"] if e["Kind"] == "transaction"]
        self.assertEqual(len(transactions), 4)
        sell = next(e for e in transactions if e["Narration"] == "Sell split")
        self.assertEqual([(p["account"], p["Quantity"]["Number"], p["Quantity"]["Currency"])
                          for p in sell["Postings"]],
                         [("Assets:Stock", "-2", "HOOL"), ("Assets:Stock", "-1", "HOOL"),
                          ("Assets:Cash", "32", "USD")])
        self.assertEqual(sell["File"], "main.bean")
        self.assertEqual(sell["Line"], 12)

    def test_validation_only_never_exports_entries_but_still_books_and_checks(self):
        (self.root / "main.bean").write_text('''plugin "beancount.plugins.auto_accounts"
2026-01-01 * "Lunch"
  Assets:Cash -10 CNY
  Expenses:Food 10 CNY
''')
        with mock.patch.object(ledger_validator, "_canonical_entry", side_effect=AssertionError("must not export")) as export:
            with mock.patch.object(ledger_validator.loader, "_uncached_load_file",
                                   wraps=ledger_validator.loader._uncached_load_file) as load:
                self.assertEqual(json.loads(validate_only_json(str(self.root))), {"errors": []})
                self.assertEqual(load.call_count, 1)
                self.assertIs(load.call_args.args[2], ledger_validator.validation.HARDCORE_VALIDATIONS)
            export.assert_not_called()
        canonical = json.loads(validate_json(str(self.root)))["canonical"]
        self.assertEqual(len([e for e in canonical["entries"] if e["Kind"] == "open"]), 2)

    def test_validation_only_reloads_mutated_source_and_preserves_diagnostics(self):
        self.assertEqual(self.validate("2000-01-01 open Assets:Cash CNY\n"), [])
        self.assertTrue(self.validate("2000-01-02 balance Assets:Cash 1 CNY\n"))
        self.assertEqual(self.validate("2000-01-01 open Assets:Cash CNY\n"), [])

    def test_both_entrypoints_share_preflight_and_exception_diagnostics(self):
        with mock.patch.object(ledger_validator, "_preflight", side_effect=ValueError("Synthetic preflight failure")):
            (self.root / "main.bean").write_text("")
            expected = {"errors": [{"message": "Synthetic preflight failure"}]}
            self.assertEqual(json.loads(validate_only_json(str(self.root))), expected)
            self.assertEqual(json.loads(validate_json(str(self.root))), expected)

    def test_stream_export_is_identical_for_copies_in_different_directories(self):
        # Content-addressed reuse: a validated stage and the generation it
        # becomes must export the same bytes.
        files = {"main.bean": 'option "operating_currency" "CNY"\ninclude "tx/a.bean"\n2026-01-01 open Assets:Cash\n2026-01-01 open Expenses:Food\n',
                 "tx/a.bean": '2026-01-02 * "Shop" "Lunch"\n  Expenses:Food 12.00 CNY\n  Assets:Cash\n'}
        streams = []
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second, tempfile.TemporaryDirectory() as output_dir:
            for index, root in enumerate((first, second)):
                for name, text in files.items():
                    path = pathlib.Path(root) / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(text)
                output = pathlib.Path(output_dir).resolve() / f"{index}.records"
                reply = json.loads(ledger_validator.export_canonical_json(root, "main.bean", str(output)))
                self.assertEqual(reply["errors"], [])
                streams.append(output.read_bytes())
        self.assertEqual(streams[0], streams[1])
        options = {json.loads(line)["key"]: json.loads(line)["value"] for line in streams[0].splitlines()
                   if json.loads(line)["type"] == "option"}
        self.assertEqual(options["filename"], "main.bean")
        self.assertEqual(options["include"], "tx/a.bean")
        self.assertNotIn("input_hash", options)

    def test_stream_sha256_is_unchanged_for_the_canonical_fixture(self):
        # Golden bytes captured from origin/main @ 150b552 (beancount 3.2.3)
        # before the preflight duplicate parse was skipped. A mismatch means
        # the canonical bytes changed, not merely the speed of producing them.
        files = {
            "main.bean": 'option "operating_currency" "CNY"\ninclude "tx/a.bean"\n'
                         '2026-01-01 open Assets:Cash\n2026-01-01 open Expenses:Food\n',
            "tx/a.bean": '2026-01-02 * "Shop" "Lunch"\n  Expenses:Food 12.00 CNY\n  Assets:Cash\n',
        }
        for name, text in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        with tempfile.TemporaryDirectory() as output_dir:
            output = pathlib.Path(output_dir).resolve() / "model.records"
            reply = json.loads(ledger_validator.export_canonical_json(
                str(self.root), "main.bean", str(output)))
            self.assertEqual(reply["errors"], [])
            self.assertEqual(reply["stream"], {
                "version": 1, "entries": 3, "bytes": 2002,
                "sha256": "d954978294bf74672e5e52541258834e4e36f011be2fa068c846dd27c50c69fd",
            })
            self.assertEqual(
                hashlib.sha256(output.read_bytes()).hexdigest(),
                "378bd0f9f35ae6d20a1318433094f5b5c32844b050e1f50f8108d5ed24330f43")

    def test_stream_export_matches_canonical_without_whole_model_response(self):
        text = '''plugin "beancount.plugins.auto_accounts"
plugin "beancount.plugins.implicit_prices"
2026-01-01 * "Buy"
  Assets:Stock 2 HOOL {10 USD}
  Assets:Cash -20 USD
'''
        self.assertEqual(self.validate(text), [])
        expected = json.loads(validate_json(str(self.root)))["canonical"]
        with tempfile.TemporaryDirectory() as output_dir:
            output = pathlib.Path(output_dir).resolve() / "model.records"
            reply = json.loads(ledger_validator.export_canonical_json(str(self.root), "main.bean", str(output)))
            self.assertEqual(reply["errors"], [])
            self.assertNotIn("canonical", reply)
            lines = output.read_bytes().splitlines(keepends=True)
            footer = json.loads(lines[-1])
            self.assertEqual(footer["sha256"], hashlib.sha256(b"".join(lines[:-1])).hexdigest())
            actual = {"version": 1, "entries": [], "options": {}, "commodities": []}
            current = None
            for line in lines:
                record = json.loads(line)
                if record["type"] == "option": actual["options"][record["key"]] = record["value"]
                elif record["type"] == "commodity": actual["commodities"].append(record["value"])
                elif record["type"] == "entry": current = record["entry"]
                elif record["type"] == "posting": current.setdefault("Postings", []).append(record["posting"])
                elif record["type"] == "end_entry": actual["entries"].append(current)
            self.assertEqual(actual, expected)
            self.assertEqual(reply["stream"]["entries"], len(expected["entries"]))
            self.assertLess(len(json.dumps(reply)), 256)
            original = output.read_bytes()
            second = json.loads(ledger_validator.export_canonical_json(str(self.root), "main.bean", str(output)))
            self.assertTrue(second["errors"])
            self.assertEqual(output.read_bytes(), original)

    def test_stream_failure_never_leaves_partial_or_source_output(self):
        self.assertEqual(self.validate("2000-01-01 open Assets:Cash CNY\n"), [])
        inside = self.root / "stream"
        self.assertTrue(json.loads(ledger_validator.export_canonical_json(str(self.root), "main.bean", str(inside)))["errors"])
        self.assertFalse(inside.exists())
        with tempfile.TemporaryDirectory() as output_dir:
            output = pathlib.Path(output_dir).resolve() / "model.records"
            with mock.patch.object(ledger_validator, "STREAM_RECORD_LIMIT", 40):
                self.assertTrue(json.loads(ledger_validator.export_canonical_json(str(self.root), "main.bean", str(output)))["errors"])
            self.assertFalse(output.exists())
            (self.root / "main.bean").write_text("invalid ledger\n")
            self.assertTrue(json.loads(ledger_validator.export_canonical_json(str(self.root), "main.bean", str(output)))["errors"])
            self.assertFalse(output.exists())

    def test_stream_resolves_export_parent_alias_outside_source(self):
        self.assertEqual(self.validate("2000-01-01 open Assets:Cash CNY\n"), [])
        with tempfile.TemporaryDirectory() as directory:
            parent = pathlib.Path(directory) / "actual"
            parent.mkdir()
            alias = pathlib.Path(directory) / "alias"
            alias.symlink_to(parent, target_is_directory=True)
            output = alias / "model.records"
            reply = json.loads(ledger_validator.export_canonical_json(str(self.root), "main.bean", str(output)))
            self.assertEqual(reply["errors"], [])
            self.assertEqual(reply["stream"]["entries"], 1)
            self.assertTrue((parent / output.name).is_file())
            self.assertTrue(json.loads(ledger_validator.export_canonical_json(
                str(self.root), "main.bean", str(output)))["errors"])
            inside_alias = pathlib.Path(directory) / "inside-alias"
            inside_alias.symlink_to(self.root, target_is_directory=True)
            inside = inside_alias / "forbidden.records"
            self.assertTrue(json.loads(ledger_validator.export_canonical_json(
                str(self.root), "main.bean", str(inside)))["errors"])
            self.assertFalse((self.root / inside.name).exists())

    def test_stream_sha256_is_unchanged_for_the_rich_fixture(self):
        # Golden bytes captured from origin/main @ 150b552 before the export
        # path was specialized (beancount 3.2.3). A mismatch means the
        # canonical wire format changed, not just how fast it is produced.
        files = {
            "main.bean": 'option "operating_currency" "CNY"\n'
                         'option "title" "Rich fixture"\n'
                         'plugin "beancount.plugins.auto_accounts"\n'
                         'plugin "beancount.plugins.implicit_prices"\n'
                         'include "tx/*.bean"\n'
                         '2000-01-01 open Assets:Cash CNY,USD\n'
                         '2000-01-01 open Assets:Stock HOOL "FIFO"\n'
                         '2000-01-01 open Expenses:Food CNY\n'
                         '2000-01-01 open Equity:Opening CNY\n'
                         '2000-01-02 pad Assets:Cash Equity:Opening\n'
                         '2000-01-03 balance Assets:Cash 100.00 CNY\n'
                         '2019-01-01 commodity HOOL\n',
            "tx/a.bean": '2020-01-01 * "Shop" "Lunch & tea" #food ^trip-1\n'
                         '  category: "food"\n'
                         '  note: "escaped \\"quote\\" and 中文"\n'
                         '  count: 3\n'
                         '  ratio: 1.5\n'
                         '  budget: 100.00 CNY\n'
                         '  reviewed: 2020-01-05\n'
                         '  Assets:Cash -12.50 CNY\n'
                         '  Expenses:Food 12.50 CNY\n'
                         '2020-01-02 ! "Shop" "Manual"\n'
                         '  Assets:Cash -3 CNY\n'
                         '  Expenses:Food 3 CNY\n'
                         '2020-02-01 * "Buy"\n'
                         '  Assets:Stock 2 HOOL {10.00 USD}\n'
                         '  Assets:Cash -20.00 USD\n'
                         '2020-02-02 * "Buy more"\n'
                         '  Assets:Stock 2 HOOL {12.00 USD}\n'
                         '  Assets:Cash -24.00 USD\n'
                         '2020-02-03 * "Sell"\n'
                         '  Assets:Stock -3 HOOL {}\n'
                         '  Assets:Cash 32.00 USD\n'
                         '2020-03-01 price HOOL 10.50 USD\n'
                         '2020-03-02 event "location" "Beijing"\n'
                         '2020-03-03 note Assets:Cash "note with 中文"\n'
                         '2020-03-05 custom "budget" Expenses:Food "monthly" 100.00 CNY 2020-03-01 TRUE\n',
        }
        for name, text in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory).resolve() / "stream"
            reply = json.loads(ledger_validator.export_canonical_json(str(self.root), "main.bean", str(output)))
            self.assertEqual(reply["errors"], [])
            self.assertEqual(reply["stream"], {
                "version": 1, "entries": 19, "bytes": 6708,
                "sha256": "23bcce0b054c3f374a7cb90fb2612288914c8b992ea2180e018443ef533642fd",
            })
            self.assertEqual(hashlib.sha256(output.read_bytes()).hexdigest(),
                             "d317aae6bc668a9f4ac71c817a2a0e2bbf257a037c5c633047fc8fe384c5182c")

    def test_stream_rejects_huge_projection_before_canonical_entry_allocation(self):
        from beancount.core import data as bean_data
        from datetime import date
        root = self.root.resolve()
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory).resolve() / "stream"
            for meta, narration in [({}, "x" * ledger_validator.STREAM_RECORD_LIMIT),
                                    ({str(i): "x" * 1000 for i in range(2000)}, "small")]:
                entry = bean_data.Transaction(meta, date(2026, 1, 1), "*", "Synthetic", narration, frozenset(), frozenset(), [])
                with mock.patch.object(ledger_validator, "_canonical_entry", side_effect=AssertionError("projection should not run")) as project:
                    with self.assertRaisesRegex(ValueError, "byte budget"):
                        ledger_validator._write_canonical_stream(root, [entry], {}, output)
                    project.assert_not_called()
                self.assertFalse(output.exists())

    def test_stream_rejects_oversized_posting_before_projection(self):
        from beancount.core import data as bean_data
        from beancount.core.amount import Amount
        from datetime import date
        from decimal import Decimal
        root = self.root.resolve()
        oversized = "Assets:" + "A" * ledger_validator.STREAM_RECORD_LIMIT
        posting = bean_data.Posting(oversized, Amount(Decimal("1"), "CNY"), None, None, None, None)
        entry = bean_data.Transaction({"filename": "main.bean", "lineno": 1}, date(2026, 1, 1),
                                      "*", "Synthetic", "small", frozenset(), frozenset(), [posting])
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory).resolve() / "stream"
            with mock.patch.object(ledger_validator, "_canonical_posting", side_effect=AssertionError("projection should not run")) as project:
                with self.assertRaisesRegex(ValueError, "byte budget"):
                    ledger_validator._write_canonical_stream(root, [entry], {}, output)
                project.assert_not_called()
            self.assertFalse(output.exists())

    def test_stream_rejects_oversized_posting_metadata_before_projection(self):
        from beancount.core import data as bean_data
        from beancount.core.amount import Amount
        from datetime import date
        from decimal import Decimal
        root = self.root.resolve()
        meta = {"filename": "main.bean", "lineno": 2,
                "note": "n" * ledger_validator.STREAM_RECORD_LIMIT}
        posting = bean_data.Posting("Assets:Cash", Amount(Decimal("1"), "CNY"), None, None, None, meta)
        entry = bean_data.Transaction({"filename": "main.bean", "lineno": 1}, date(2026, 1, 1),
                                      "*", "Synthetic", "small", frozenset(), frozenset(), [posting])
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory).resolve() / "stream"
            with mock.patch.object(ledger_validator, "_canonical_posting", side_effect=AssertionError("projection should not run")) as project:
                with self.assertRaisesRegex(ValueError, "byte budget"):
                    ledger_validator._write_canonical_stream(root, [entry], {}, output)
                project.assert_not_called()
            self.assertFalse(output.exists())

    def test_stream_accepts_large_narration_under_budget(self):
        from beancount.core import data as bean_data
        from datetime import date
        root = self.root.resolve()
        narration = "x" * 100000
        entry = bean_data.Transaction({"filename": "main.bean", "lineno": 1}, date(2026, 1, 1),
                                      "*", "Synthetic", narration, frozenset(), frozenset(), [])
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory).resolve() / "stream"
            reply = ledger_validator._write_canonical_stream(root, [entry], {}, output)
            self.assertEqual(reply["entries"], 1)
            records = [json.loads(line) for line in output.read_bytes().splitlines()]
            self.assertEqual(records[1]["entry"]["Narration"], narration)

    def test_posting_bound_agrees_with_generic_walk(self):
        # _check_export_value stays the reference cost model; the specialized
        # posting check must make identical accept/reject decisions.
        from beancount.core import data as bean_data
        from beancount.core.amount import Amount
        from beancount.core.position import Cost
        from datetime import date
        from decimal import Decimal
        limit = ledger_validator.STREAM_RECORD_LIMIT
        huge = "x" * limit
        ordinary = bean_data.Posting("Assets:Cash", Amount(Decimal("-12.50"), "CNY"), None, None, None,
                                     {"filename": "main.bean", "lineno": 2})
        cases = [
            ordinary,
            bean_data.Posting("Assets:Cash", Amount(Decimal("1"), "CNY"), None, None, None, None),
            bean_data.Posting("Assets:Stock", Amount(Decimal("2"), "HOOL"),
                              Cost(Decimal("10.00"), "USD", date(2020, 2, 1), None), None, "*", None),
            bean_data.Posting("Assets:Stock", Amount(Decimal("2"), "HOOL"),
                              Cost(Decimal("10.00"), "USD", date(2020, 2, 1), "lot"),
                              Amount(Decimal("11.00"), "USD"), "!", {}),
            bean_data.Posting("Assets:Cash", Amount(Decimal("1" + "0" * 5000), "CNY"), None, None, None, None),
            bean_data.Posting(huge, Amount(Decimal("1"), "CNY"), None, None, None, None),
            bean_data.Posting("Assets:Cash", Amount(Decimal("1"), huge), None, None, None, None),
            bean_data.Posting("Assets:Cash", Amount(Decimal("1"), "CNY"), None, None, huge, None),
            bean_data.Posting("Assets:Cash", Amount(Decimal("1"), "CNY"), None, None, None,
                              {"filename": "main.bean", "lineno": 1, "note": huge}),
            bean_data.Posting("Assets:Cash", Amount(Decimal("1"), "CNY"),
                              Cost(Decimal("1"), "USD", None, huge), None, None, None),
        ]
        for posting in cases:
            generic = specialized = None
            try:
                ledger_validator._check_export_value(posting, limit - 4096)
            except ValueError as error:
                generic = str(error)
            try:
                ledger_validator._check_export_posting(posting)
            except ValueError as error:
                specialized = str(error)
            self.assertEqual(generic, specialized, posting)

    def test_entry_bound_agrees_with_pre_change_cost_model(self):
        # Reference: the exact pre-specialization entry check. Its metadata
        # loop walked meta.items() and costed each key with _check_export_value
        # directly, so that path has no dict-container offsets. A record with
        # thousands of tiny metadata keys is the edge where a different key
        # cost would show up; the specialized check must land on the same
        # accept/reject boundary and cost container fields identically.
        from beancount.core import data as bean_data
        from beancount.parser.grammar import ValueType
        from datetime import date
        limit = 4096 + 50000
        keys = [chr(0x4E00 + i) for i in range(3300)]

        def reference_budget(entry):
            try:
                budget = limit - 4096
                for name in ("account", "source_account", "currency", "flag", "payee",
                             "narration", "comment", "name", "query_string", "description",
                             "filename", "currencies", "tags", "links", "type", "amount",
                             "tolerance"):
                    if hasattr(entry, name):
                        budget = ledger_validator._check_export_value(getattr(entry, name), budget)
                for key, value in (entry.meta or {}).items():
                    if key not in {"filename", "lineno"} and not key.startswith("__"):
                        budget = ledger_validator._check_export_value(key, budget)
                        budget = ledger_validator._check_export_value(value, budget)
                budget = ledger_validator._check_export_value((entry.meta or {}).get("filename", ""), budget)
                if isinstance(entry, bean_data.Custom):
                    for value in entry.values:
                        budget = ledger_validator._check_export_value(value.value, budget)
                return budget
            except ValueError:
                return -1

        def accepts(entry):
            try:
                with mock.patch.object(ledger_validator, "STREAM_RECORD_LIMIT", limit):
                    ledger_validator._check_export_entry(entry)
                return True
            except ValueError:
                return False

        def many_keys(count):
            return bean_data.Transaction({key: "v" for key in keys[:count]},
                                         date(2026, 1, 1), "*", "Synthetic", "small",
                                         frozenset(), frozenset(), [])

        sweep = [accepts(many_keys(count)) for count in range(3000, 3200)]
        self.assertIn(True, sweep)
        self.assertIn(False, sweep)
        for count in range(3000, 3200):
            entry = many_keys(count)
            self.assertEqual(accepts(entry), reference_budget(entry) >= 0, count)
        # Projected containers and Custom values keep their generic costs too.
        containers = []
        for count in (0, 2, 5):
            tags = frozenset("t{}".format(i) for i in range(count))
            containers.append(bean_data.Transaction({"filename": "main.bean", "lineno": 1},
                                                    date(2026, 1, 1), "*", "Synthetic", "small",
                                                    tags, tags, []))
            containers.append(bean_data.Open({"filename": "main.bean", "lineno": 1},
                                             date(2026, 1, 1), "Assets:Cash",
                                             ["C{}".format(i) for i in range(count)], None))
            containers.append(bean_data.Custom({"filename": "main.bean", "lineno": 1},
                                               date(2026, 1, 1), "kind",
                                               [ValueType("v{}".format(i), None) for i in range(count)]))
        for entry in containers:
            self.assertEqual(accepts(entry), reference_budget(entry) >= 0, entry)

    def test_stream_supports_booking_modes_and_custom_typed_values(self):
        self.assertEqual(self.validate('''2000-01-01 open Assets:Stock HOOL "FIFO"
2026-01-01 custom "budget" Assets:Stock "monthly" 100 USD
'''), [])
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory).resolve() / "stream"
            reply = json.loads(ledger_validator.export_canonical_json(str(self.root), "main.bean", str(output)))
            self.assertEqual(reply["errors"], [])
            self.assertEqual(reply["stream"]["entries"], 2)

    def test_stream_timings_are_opt_in_and_keep_stream_bytes_identical(self):
        import os
        ledger = '''2000-01-01 open Assets:Cash CNY
2000-01-01 open Expenses:Food CNY
2026-01-01 * "Lunch"
  Assets:Cash -10 CNY
  Expenses:Food 10 CNY
'''
        (self.root / "main.bean").write_text(ledger)
        results = {}
        with tempfile.TemporaryDirectory() as directory:
            for enabled in (False, True):
                output = pathlib.Path(directory).resolve() / ("timed.records" if enabled else "plain.records")
                environment = {"LEDGER_VALIDATION_TIMINGS": "1"} if enabled else {"LEDGER_VALIDATION_TIMINGS": ""}
                with mock.patch.dict(os.environ, environment):
                    reply = json.loads(ledger_validator.export_canonical_json(
                        str(self.root), "main.bean", str(output)))
                self.assertEqual(reply["errors"], [])
                results[enabled] = (reply["stream"], output.read_bytes())
        plain, timed = results[False][0], results[True][0]
        # Default export keeps its exact descriptor shape and stream bytes.
        self.assertNotIn("timings", plain)
        timings = timed.pop("timings")
        self.assertEqual(set(timings), {"parse", "booking", "plugins", "validate"})
        self.assertTrue(all(isinstance(value, (int, float)) and value >= 0
                            for value in timings.values()))
        self.assertEqual(timed, plain)
        self.assertEqual(results[True][1], results[False][1])

    def test_timings_do_not_change_validation_payloads(self):
        import os
        ledger = '''2000-01-01 open Assets:Cash CNY
2000-01-01 open Expenses:Food CNY
2026-01-01 * "Lunch"
  Assets:Cash -10 CNY
  Expenses:Food 10 CNY
'''
        (self.root / "main.bean").write_text(ledger)
        with mock.patch.dict(os.environ, {"LEDGER_VALIDATION_TIMINGS": "1"}):
            full = json.loads(validate_json(str(self.root)))
            diagnostics = json.loads(validate_only_json(str(self.root)))
        self.assertEqual(diagnostics, {"errors": full["errors"]})
        self.assertNotIn("timings", full)

    def test_stream_fdopen_failure_closes_descriptor_and_removes_owned_file(self):
        import os
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory).resolve() / "stream"
            descriptors = []
            def fail_open(fd, mode):
                descriptors.append(fd)
                raise OSError("synthetic fdopen failure")
            with mock.patch.object(ledger_validator.os, "fdopen", side_effect=fail_open):
                with self.assertRaises(OSError):
                    ledger_validator._write_canonical_stream(self.root.resolve(), [], {}, output)
            self.assertFalse(output.exists())
            self.assertEqual(len(descriptors), 1)
            with self.assertRaises(OSError): os.fstat(descriptors[0])


if __name__ == "__main__":
    unittest.main()


class LoadCacheTests(unittest.TestCase):
    """The opt-in pickle cache must never change results, only reuse them."""

    LEDGER = '''2000-01-01 open Assets:Cash CNY
2000-01-01 open Expenses:Food CNY
2026-01-01 * "Lunch"
  Assets:Cash -10 CNY
  Expenses:Food 10 CNY
'''

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name) / "ledger"
        self.root.mkdir()
        (self.root / "main.bean").write_text(self.LEDGER)
        self.cache = pathlib.Path(self.temporary.name) / "cache"
        self.cache.mkdir()

    def tearDown(self):
        self.temporary.cleanup()

    def environment(self, value, runtime="build-a"):
        values = {ledger_validator.LOAD_CACHE_ENVIRONMENT: str(value)}
        if runtime is not None:
            values[ledger_validator.LOAD_CACHE_RUNTIME_ENVIRONMENT] = runtime
        return mock.patch.dict("os.environ", values)

    def cached_names(self):
        return {path.name for path in self.cache.iterdir()}

    def test_cache_directory_is_optional(self):
        # Without the variable the loader keeps its uncached binding.
        with mock.patch.dict("os.environ", {}, clear=False):
            os.environ.pop(ledger_validator.LOAD_CACHE_ENVIRONMENT, None)
            payload = json.loads(validate_only_json(str(self.root)))
        self.assertEqual(payload, {"errors": []})
        self.assertEqual(list(self.cache.iterdir()), [])

    def test_enabled_cache_returns_identical_diagnostics(self):
        # beancount only writes a cache when a load costs more than its
        # threshold, so a fixture this small never produces one. Force the write
        # to exercise the path/identity logic that is ours.
        uncached = json.loads(validate_only_json(str(self.root)))
        with mock.patch.object(ledger_validator.loader, "PICKLE_CACHE_THRESHOLD", 0.0):
            with self.environment(self.cache):
                first = json.loads(validate_only_json(str(self.root)))
                second = json.loads(validate_only_json(str(self.root)))
        self.assertEqual(first, uncached)
        self.assertEqual(second, uncached)
        entries = list(self.cache.iterdir())
        self.assertEqual(len(entries), 1, entries)
        self.assertTrue(entries[0].name.endswith(".picklecache"))

    def test_editing_the_ledger_uses_a_different_cache_file(self):
        with mock.patch.object(ledger_validator.loader, "PICKLE_CACHE_THRESHOLD", 0.0):
          with self.environment(self.cache):
              validate_only_json(str(self.root))
              first = {path.name for path in self.cache.iterdir()}
              (self.root / "main.bean").write_text(self.LEDGER.replace("10 CNY\n  Expenses:Food", "11 CNY\n  Expenses:Food"))
              validate_only_json(str(self.root))
              second = {path.name for path in self.cache.iterdir()}
          self.assertNotEqual(first, second)
          # A stale cache must not survive as the only entry.
          self.assertEqual(len(second), 2)

    def test_invalid_ledger_is_never_cached_as_valid(self):
        (self.root / "main.bean").write_text(self.LEDGER.replace("Food 10", "Food 9"))
        with self.environment(self.cache):
            first = json.loads(validate_only_json(str(self.root)))
            second = json.loads(validate_only_json(str(self.root)))
        self.assertTrue(first["errors"])
        self.assertEqual(first, second)

    def test_symlinked_cache_directory_is_refused(self):
        target = pathlib.Path(self.temporary.name) / "elsewhere"
        target.mkdir()
        link = pathlib.Path(self.temporary.name) / "link"
        link.symlink_to(target)
        with self.environment(link):
            payload = json.loads(validate_only_json(str(self.root)))
        self.assertEqual(payload, {"errors": []})
        self.assertEqual(list(target.iterdir()), [])

    def test_cache_without_runtime_fingerprint_stays_off(self):
        with mock.patch.object(ledger_validator.loader, "PICKLE_CACHE_THRESHOLD", 0.0):
            with self.environment(self.cache, runtime=None):
                os.environ.pop(ledger_validator.LOAD_CACHE_RUNTIME_ENVIRONMENT, None)
                payload = json.loads(validate_only_json(str(self.root)))
        self.assertEqual(payload, {"errors": []})
        self.assertEqual(self.cached_names(), set())

    def test_another_build_uses_a_different_cache_file(self):
        with mock.patch.object(ledger_validator.loader, "PICKLE_CACHE_THRESHOLD", 0.0):
            with self.environment(self.cache, runtime="build-a"):
                validate_only_json(str(self.root))
            first = self.cached_names()
            with self.environment(self.cache, runtime="build-b"):
                validate_only_json(str(self.root))
            second = self.cached_names()
        self.assertEqual(len(first), 1)
        self.assertEqual(len(second), 2, "a pickle from another build must never be read back")

    def test_editing_an_included_file_uses_a_different_cache_file(self):
        # Includes resolve against the including file's directory, not the
        # ledger root; the cache key must cover the file the loader reads.
        (self.root / "books").mkdir()
        (self.root / "books" / "index.bean").write_text('include "2026.bean"\n')
        (self.root / "books" / "2026.bean").write_text(
            '2026-01-02 * "Dinner"\n  Assets:Cash -5 CNY\n  Expenses:Food 5 CNY\n')
        (self.root / "main.bean").write_text(self.LEDGER + 'include "books/index.bean"\n')
        with mock.patch.object(ledger_validator.loader, "PICKLE_CACHE_THRESHOLD", 0.0):
            with self.environment(self.cache):
                self.assertEqual(json.loads(validate_only_json(str(self.root))), {"errors": []})
                first = self.cached_names()
                # Same size and mtime, so beancount's own staleness check cannot
                # notice the edit; only the content digest can.
                included = self.root / "books" / "2026.bean"
                stat = included.stat()
                included.write_text(
                    '2026-01-02 * "Dinner"\n  Assets:Cash -5 CNY\n  Expenses:Food 4 CNY\n')
                os.utime(included, ns=(stat.st_atime_ns, stat.st_mtime_ns))
                edited = json.loads(validate_only_json(str(self.root)))
                second = self.cached_names()
        self.assertTrue(edited["errors"], "the edited include must be re-validated, not served from cache")
        self.assertEqual(len(first), 1)
        self.assertLessEqual(first, second)

    def test_missing_cache_directory_still_validates(self):
        with self.environment(pathlib.Path(self.temporary.name) / "absent"):
            payload = json.loads(validate_only_json(str(self.root)))
        self.assertEqual(payload, {"errors": []})


class BookingCheckpointTests(unittest.TestCase):
    """The checkpointed load must be indistinguishable from beancount's own."""

    TODAY = datetime.date(2026, 10, 15)  # closing date 2026-08-01

    MAIN = '''option "operating_currency" "CNY"
option "booking_method" "FIFO"
plugin "beancount.plugins.implicit_prices"
plugin "beancount.plugins.sellgains"
include "accounts.bean"
include "tx/*.bean"
'''
    ACCOUNTS = '''2025-01-01 open Assets:Cash CNY
2025-01-01 open Assets:Savings CNY
2025-01-01 open Assets:Broker:Cash CNY
2025-01-01 open Assets:Broker:Stock STK
2025-01-01 open Assets:Broker:Fund FND "LIFO"
2025-01-01 open Equity:Opening CNY
2025-01-01 open Expenses:Food CNY
2025-01-01 open Expenses:Fees CNY
2025-01-01 open Income:Gains CNY
'''
    CLOSED = '''2025-01-02 pad Assets:Savings Equity:Opening
2025-01-03 balance Assets:Savings 1000.00 CNY
2025-02-01 * "Broker" "Buy" #invest ^lot-a
  memo: "first lot"
  Assets:Broker:Stock 10 STK {10.00 CNY}
  Assets:Broker:Cash
2025-03-01 * "Broker" "Buy again"
  Assets:Broker:Stock 5 STK {12.00 CNY, "late"}
  Assets:Broker:Cash -60.00 CNY
2025-03-02 * "Broker" "Fund"
  Assets:Broker:Fund 3 FND {100 CNY}
  Assets:Broker:Fund 2 FND {110 CNY}
  Assets:Broker:Cash
2025-04-01 * "Broker" "Sell part of the first lot"
  Assets:Broker:Stock -4 STK {} @ 15.00 CNY
  Assets:Broker:Cash 60.00 CNY
  Income:Gains
2025-05-01 * "Lunch"
  Expenses:Food 12.50 CNY
  Assets:Cash
2025-06-01 price STK 14.00 CNY
2025-07-31 * "Fee"
  Expenses:Fees 1.00 CNY
  Assets:Broker:Cash
'''
    OPEN = '''2026-08-03 * "Broker" "Sell across lots"
  Assets:Broker:Stock -8 STK {} @ 16.00 CNY
  Assets:Broker:Cash 128.00 CNY
  Income:Gains
2026-08-04 * "Broker" "Fund sell"
  Assets:Broker:Fund -1 FND {}
  Assets:Broker:Cash 120 CNY
  Income:Gains
2026-09-01 balance Assets:Broker:Stock 3 STK
2026-10-01 * "Coffee"
  Expenses:Food 3.00 CNY
  Assets:Cash
'''

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        base = pathlib.Path(self.temporary.name).resolve()
        self.root = base / "generations" / "a" / "workspace"
        self.checkpoints = base / "checkpoints"
        self.checkpoints.mkdir()
        self.write(self.root, {"main.bean": self.MAIN, "accounts.bean": self.ACCOUNTS,
                               "tx/2025.bean": self.CLOSED, "tx/2026.bean": self.OPEN})
        patcher = mock.patch.object(ledger_validator, "_today", lambda: self.TODAY)
        patcher.start()
        self.addCleanup(patcher.stop)

    def tearDown(self):
        self.temporary.cleanup()

    @staticmethod
    def write(root, files):
        for name, text in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)

    def checkpoint_path(self, root=None):
        root = root or self.root
        with mock.patch.dict("os.environ", {ledger_validator.BOOKING_CHECKPOINT_ENVIRONMENT: str(self.checkpoints)}):
            return ledger_validator._booking_checkpoint_path(root, root / "main.bean")

    def load(self, root=None, *, checkpoint=True):
        root = root or self.root
        path = self.checkpoint_path(root) if checkpoint else None
        return ledger_validator._checkpointed_load(
            root, path, str(root / "main.bean"), None, ledger_validator.validation.HARDCORE_VALIDATIONS, None)

    def assert_same_as_beancount(self, root=None):
        root = root or self.root
        expected = ledger_validator.loader._uncached_load_file(
            str(root / "main.bean"), None, ledger_validator.validation.HARDCORE_VALIDATIONS, None)
        actual = self.load(root)
        self.assertEqual(actual[0], expected[0])
        self.assertEqual([(type(e), e.message, e.source) for e in actual[1]],
                         [(type(e), e.message, e.source) for e in expected[1]])
        # Metadata order is part of the exported model.
        for left, right in zip(actual[0], expected[0]):
            self.assertEqual(list((left.meta or {}).keys()), list((right.meta or {}).keys()))
            for a, b in zip(getattr(left, "postings", ()), getattr(right, "postings", ())):
                self.assertEqual(list((a.meta or {}).keys()), list((b.meta or {}).keys()))
        actual[2].pop("dcontext"), expected[2].pop("dcontext")
        self.assertEqual(actual[2], expected[2])
        return actual

    def stored(self, root=None):
        return ledger_validator._read_checkpoint(self.checkpoint_path(root))

    @contextlib.contextmanager
    def count_reuse(self):
        """Yield a mock whose calls are the loads that reused a checkpoint."""
        reused = mock.Mock()
        original = ledger_validator._checkpoint_prefix

        def spy(*args):
            end = original(*args)
            if end is not None:
                reused(end)
            return end

        with mock.patch.object(ledger_validator, "_checkpoint_prefix", spy):
            yield reused

    def test_first_load_writes_a_checkpoint_and_later_loads_reuse_it(self):
        self.assertIsNone(self.stored())
        entries, errors, _ = self.assert_same_as_beancount()
        self.assertEqual(errors, [])
        stored = self.stored()
        self.assertEqual(stored["closing"], datetime.date(2026, 8, 1))
        self.assertEqual(stored["order"], ["tx/2025.bean"])
        self.assertEqual(len(stored["transactions"][1]), 6)
        self.assertEqual(stored["files"]["tx/2025.bean"][2], 6)
        with self.count_reuse() as decode:
            self.assert_same_as_beancount()
        decode.assert_called_once()

    def test_open_period_writes_reuse_the_checkpoint(self):
        self.load()
        (self.root / "tx/2026.bean").write_text(self.OPEN + '''2026-10-01 * "Dinner"
  Expenses:Food 30.00 CNY
  Assets:Cash
''')
        with self.count_reuse() as decode:
            self.assert_same_as_beancount()
        decode.assert_called_once()

    def test_open_period_errors_against_closed_lots_match_beancount(self):
        self.load()
        # Only 3 STK remain after the closed and open sales.
        (self.root / "tx/2026.bean").write_text(self.OPEN + '''2026-10-02 * "Broker" "Oversell"
  Assets:Broker:Stock -5 STK {}
  Assets:Broker:Cash 80.00 CNY
  Income:Gains
2026-10-03 balance Assets:Broker:Cash 1 CNY
''')
        with self.count_reuse() as decode:
            _, errors, _ = self.assert_same_as_beancount()
        decode.assert_called_once()
        self.assertTrue(errors)

    def test_closed_period_edits_fall_back_to_full_booking(self):
        self.load()
        for closed in (self.CLOSED.replace("12.50", "13.50"),
                       self.CLOSED.replace('  memo: "first lot"\n', ""),
                       self.CLOSED.replace("#invest", "#invest #more"),
                       "\n" + self.CLOSED,
                       self.CLOSED.replace("-4 STK", "-40 STK")):
            with self.subTest(closed=closed[:40]):
                (self.root / "tx/2025.bean").write_text(closed)
                with self.count_reuse() as decode:
                    self.assert_same_as_beancount()
                decode.assert_not_called()

    def test_closed_non_transactions_are_still_checked_in_full(self):
        self.load()
        # Balances, pads and prices are not part of the checkpoint key: they are
        # never stored and always come from the fresh parse.
        (self.root / "tx/2025.bean").write_text(self.CLOSED + "2025-07-31 balance Assets:Savings 999.00 CNY\n")
        with self.count_reuse() as decode:
            _, errors, _ = self.assert_same_as_beancount()
        decode.assert_called_once()
        self.assertEqual(len(errors), 1)
        self.assertIn("Balance failed", errors[0].message)

    def test_booking_options_and_methods_are_part_of_the_key(self):
        self.load()
        for name, text in (("main.bean", self.MAIN.replace('"FIFO"', '"LIFO"')),
                           ("main.bean", self.MAIN + 'option "inferred_tolerance_default" "CNY:0.1"\n'),
                           ("accounts.bean", self.ACCOUNTS.replace('FND "LIFO"', 'FND "FIFO"'))):
            with self.subTest(name=name, text=text[-40:]):
                original = (self.root / name).read_text()
                (self.root / name).write_text(text)
                with self.count_reuse() as decode:
                    self.assert_same_as_beancount()
                decode.assert_not_called()
                (self.root / name).write_text(original)
                self.load()

    def test_a_new_generation_directory_reuses_the_checkpoint(self):
        self.load()
        other = self.root.parents[1] / "b" / "workspace"
        shutil.copytree(self.root, other)
        with self.count_reuse() as decode:
            self.assert_same_as_beancount(other)
        decode.assert_called_once()
        # The exported stream of the new directory is byte-identical to the
        # one beancount's own pipeline produces for it.
        output = pathlib.Path(self.temporary.name).resolve() / "out"
        output.mkdir()
        streams = []
        for index, environment in enumerate(({}, {ledger_validator.BOOKING_CHECKPOINT_ENVIRONMENT: str(self.checkpoints)})):
            with mock.patch.dict("os.environ", environment):
                if not environment:
                    os.environ.pop(ledger_validator.BOOKING_CHECKPOINT_ENVIRONMENT, None)
                target = output / f"{index}.records"
                reply = json.loads(ledger_validator.export_canonical_json(str(other), "main.bean", str(target)))
                self.assertEqual(reply["errors"], [])
                streams.append(target.read_bytes())
        self.assertEqual(streams[0], streams[1])

    def test_new_open_period_files_do_not_invalidate(self):
        self.load()
        (self.root / "tx/2026-10.bean").write_text('2026-10-05 * "Lunch"\n  Expenses:Food 8 CNY\n  Assets:Cash\n')
        with self.count_reuse() as decode:
            self.assert_same_as_beancount()
        decode.assert_called_once()

    def test_closing_date_moves_forward_from_the_previous_checkpoint(self):
        self.load()
        (self.root / "tx/2026.bean").write_text(self.OPEN + '2026-11-02 * "Lunch"\n  Expenses:Food 8 CNY\n  Assets:Cash\n')
        with mock.patch.object(ledger_validator, "_today", lambda: datetime.date(2026, 11, 20)):
            with self.count_reuse() as decode:
                self.assert_same_as_beancount()
            decode.assert_called_once()
            stored = self.stored()
            self.assertEqual(stored["closing"], datetime.date(2026, 9, 1))
            # Parse order follows the include glob, which the filesystem orders.
            self.assertEqual(sorted(stored["order"]), ["tx/2025.bean", "tx/2026.bean"])
            with self.count_reuse() as decode:
                self.assert_same_as_beancount()
            decode.assert_called_once()

    def test_a_stale_ledger_keeps_its_last_months_open(self):
        with mock.patch.object(ledger_validator, "_today", lambda: datetime.date(2030, 1, 1)):
            self.load()
        self.assertEqual(self.stored()["closing"], datetime.date(2026, 8, 1))

    def test_closed_period_errors_are_never_checkpointed(self):
        (self.root / "tx/2025.bean").write_text(self.CLOSED.replace("-4 STK", "-40 STK"))
        _, errors, _ = self.assert_same_as_beancount()
        self.assertTrue(errors)
        self.assertIsNone(self.stored())

    def test_transactions_naming_another_source_file_are_booked_in_full(self):
        # `filename:` is ordinary metadata to the parser and overrides the
        # source path the checkpoint keys its files by.
        (self.root / "tx/2025.bean").write_text(self.CLOSED.replace(
            '  memo: "first lot"\n', '  memo: "first lot"\n  filename: "elsewhere.bean"\n'))
        for _ in range(2):
            _, errors, _ = self.assert_same_as_beancount()
            self.assertEqual(errors, [])
            self.assertIsNone(self.stored())

    def test_an_invalid_ledger_never_replaces_the_checkpoint(self):
        self.load()
        before = self.checkpoint_path().read_bytes()
        (self.root / "tx/2025.bean").write_text(self.CLOSED.replace("12.50", "13.50") + "2025-07-31 balance Assets:Cash 1 CNY\n")
        _, errors, _ = self.assert_same_as_beancount()
        self.assertTrue(errors)
        self.assertEqual(self.checkpoint_path().read_bytes(), before)

    def test_unreadable_or_foreign_checkpoints_are_ignored(self):
        self.load()
        path = self.checkpoint_path()
        for content in (b"", b"not a pickle", __import__("pickle").dumps({"runtime": "other"}),
                        __import__("pickle").dumps({"runtime": ledger_validator._checkpoint_runtime_identity()})):
            with self.subTest(content=content[:20]):
                path.write_bytes(content)
                self.assert_same_as_beancount()

    def test_checkpoint_is_off_without_an_owned_directory(self):
        with mock.patch.dict("os.environ", {}, clear=False):
            os.environ.pop(ledger_validator.BOOKING_CHECKPOINT_ENVIRONMENT, None)
            self.assertIsNone(ledger_validator._booking_checkpoint_path(self.root, self.root / "main.bean"))
        link = pathlib.Path(self.temporary.name) / "link"
        link.symlink_to(self.checkpoints)
        with mock.patch.dict("os.environ", {ledger_validator.BOOKING_CHECKPOINT_ENVIRONMENT: str(link)}):
            self.assertIsNone(ledger_validator._booking_checkpoint_path(self.root, self.root / "main.bean"))
        with mock.patch.object(ledger_validator.beancount, "__version__", "3.3.0"):
            self.assertIsNone(self.checkpoint_path())

    def test_validation_entrypoints_use_the_checkpoint_directory(self):
        with mock.patch.dict("os.environ", {ledger_validator.BOOKING_CHECKPOINT_ENVIRONMENT: str(self.checkpoints)}):
            first = json.loads(validate_json(str(self.root)))
            with self.count_reuse() as decode:
                second = json.loads(validate_json(str(self.root)))
            decode.assert_called_once()
        os.environ.pop(ledger_validator.BOOKING_CHECKPOINT_ENVIRONMENT, None)
        self.assertEqual(first, json.loads(validate_json(str(self.root))))
        self.assertEqual(first, second)

    def test_booking_reads_only_the_options_in_the_key(self):
        # If a beancount upgrade makes booking read another option, the
        # checkpoint key has to grow with it.
        read = set()

        class Recording(dict):
            def __getitem__(self, key):
                read.add(key)
                return super().__getitem__(key)

            def get(self, key, default=None):
                read.add(key)
                return super().get(key, default)

        for precise in ("FALSE", "TRUE"):
            text = (self.MAIN + f'option "use_precise_interpolation" "{precise}"\n'
                    + 'option "infer_tolerance_from_cost" "TRUE"\n' + self.ACCOUNTS + self.CLOSED + self.OPEN)
            text = text.replace('include "accounts.bean"\ninclude "tx/*.bean"\n', "")
            entries, _, options = ledger_validator.parser.parse_string(text)
            entries.sort(key=ledger_validator.data.entry_sortkey)
            ledger_validator.booking.book(entries, Recording(options))
        self.assertLessEqual(read, set(ledger_validator._BOOKING_OPTIONS))
        self.assertIn("booking_method", read)

    def test_random_ledgers_and_edits_match_beancount(self):
        rng = random.Random(20261026)
        with self.count_reuse() as reused:
            for ledger in range(12):
                with self.subTest(ledger=ledger):
                    self.run_random_ledger(rng, ledger)
        # The comparison is only meaningful if many loads took the checkpoint.
        self.assertGreater(reused.call_count, 30)

    def run_random_ledger(self, rng, ledger):
        """Grow a mostly valid ledger, then apply random edits; compare each load."""
        root = pathlib.Path(self.temporary.name).resolve() / "random" / str(ledger) / "workspace"
        months = [(2025 + m // 12, m % 12 + 1) for m in range(22)]  # 2025-01 .. 2026-10
        files = {"main.bean": self.MAIN.replace('"FIFO"', rng.choice(['"FIFO"', '"LIFO"', '"HIFO"'])),
                 "accounts.bean": self.ACCOUNTS}
        body = {month: [] for month in months}
        held = {"STK": 0, "FND": 0}

        def expense(stamp):
            return f'{stamp} * "Shop" "Food"\n  Expenses:Food {rng.randint(1, 900)}.{rng.randint(0, 99):02d} CNY\n  Assets:Cash\n'

        def transaction(stamp):
            kind = rng.random()
            if kind < 0.3:
                return expense(stamp)
            if kind < 0.5:
                units = rng.randint(1, 9)
                held["STK"] += units
                return (f'{stamp} * "Broker" "Buy" #lot\n  lot: "{rng.randint(1, 99)}"\n'
                        f'  Assets:Broker:Stock {units} STK {{{rng.randint(5, 30)}.{rng.randint(0, 99):02d} CNY}}\n'
                        f'  Assets:Broker:Cash\n')
            if kind < 0.7 and held["STK"]:
                units, price = rng.randint(1, held["STK"]), rng.randint(5, 40)
                held["STK"] -= units
                return (f'{stamp} * "Broker" "Sell"\n  Assets:Broker:Stock -{units} STK {{}} @ {price}.00 CNY\n'
                        f'  Assets:Broker:Cash {units * price}.00 CNY\n  Income:Gains\n')
            if kind < 0.8:
                held["FND"] += 2
                return (f'{stamp} * "Broker" "Fund"\n  Assets:Broker:Fund 1 FND {{{rng.randint(90, 110)} CNY}}\n'
                        f'  Assets:Broker:Fund 1 FND {{{rng.randint(90, 110)} CNY}}\n  Assets:Broker:Cash\n')
            if kind < 0.88 and held["FND"]:
                held["FND"] -= 1
                return (f'{stamp} * "Broker" "Fund sell"\n  Assets:Broker:Fund -1 FND {{}}\n'
                        f'  Assets:Broker:Cash {rng.randint(90, 120)} CNY\n  Income:Gains\n')
            if kind < 0.94:
                return f'{stamp} balance Assets:Broker:Stock {held["STK"]} STK\n'
            return f'{stamp} price STK {rng.randint(5, 40)}.00 CNY\n'

        for year, month in months:
            for day in sorted(rng.sample(range(1, 29), rng.randint(0, 5))):
                body[(year, month)].append(transaction(f"{year}-{month:02d}-{day:02d}"))

        def sync():
            shutil.rmtree(root, ignore_errors=True)
            rendered = dict(files)
            for (year, month), items in body.items():
                if items:
                    rendered[f"tx/{year}-{month:02d}.bean"] = "".join(items)
            self.write(root, rendered)

        sync()
        self.assert_same_as_beancount(root)
        for step in range(10):
            action = rng.random()
            year, month = rng.choice(months[-2:] if action < 0.5 else months)
            items = body[(year, month)]
            stamp = f"{year}-{month:02d}-28"
            if action < 0.4 or not items:
                items.append(expense(stamp) if rng.random() < 0.6 else transaction(stamp))
            elif action < 0.5:
                # Selling more than is held is an error wherever it lands.
                items.append(f'{stamp} * "Broker" "Oversell"\n  Assets:Broker:Stock -1000 STK {{}}\n'
                             f'  Assets:Broker:Cash 1 CNY\n  Income:Gains\n')
            elif action < 0.65:
                items.insert(rng.randrange(len(items) + 1), expense(f"{year}-{month:02d}-01"))
            elif action < 0.75:
                index = rng.randrange(len(items))
                if '"Food"' in items[index]:
                    items.pop(index)
            elif action < 0.9:
                index = rng.randrange(len(items))
                items[index] = items[index].replace("\n", '\n  note: "edited"\n', 1)
            else:
                files["main.bean"] = files["main.bean"].replace('"FIFO"', '"LIFO"', 1)
            sync()
            with mock.patch.object(ledger_validator, "_today",
                                   lambda: rng.choice([self.TODAY, datetime.date(2026, 11, 3)])):
                self.assert_same_as_beancount(root)


def strict(value):
    """A comparable form that also tells apart what == conflates.

    Namedtuples compare equal to plain tuples of other types, Decimal("1.0")
    equals Decimal("1.00"), True equals 1, and dicts ignore key order; the
    parse cache has to reproduce all of those exactly.
    """
    from decimal import Decimal
    kind = type(value)
    if isinstance(value, dict):
        return (kind.__qualname__, tuple((strict(key), strict(item)) for key, item in value.items()),
                strict(getattr(value, "default", None)))
    if isinstance(value, list):
        return (kind.__qualname__, tuple(strict(item) for item in value))
    if kind is frozenset or kind is set:
        return (kind.__name__, frozenset(strict(item) for item in value))
    if kind is Decimal:
        return ("Decimal", str(value))
    if isinstance(value, tuple):
        return (kind.__module__, kind.__qualname__, tuple(strict(item) for item in value))
    if isinstance(value, (str, int, float, type(None), datetime.date)):
        return (kind.__name__, value)
    if isinstance(value, type) or value is ledger_validator.data.Booking or isinstance(value, ledger_validator.data.Booking):
        return ("object", id(value))
    if kind.__module__ == "beancount.core.number" or value.__class__.__name__ == "MISSING":
        return ("object", id(value))
    if hasattr(value, "__dict__"):
        return (kind.__qualname__, strict(vars(value)))
    raise AssertionError(f"unexpected value in a parse: {kind!r}")


class ParseCacheTests(unittest.TestCase):
    """A cached parse must be indistinguishable from beancount's own."""

    MAIN = '''option "title" "Parse cache"
option "operating_currency" "CNY"
option "booking_method" "FIFO"
option "inferred_tolerance_default" "CNY:0.005"
plugin "beancount.plugins.implicit_prices"
include "accounts.bean"
include "tx/*.bean"
'''
    ACCOUNTS = '''option "operating_currency" "USD"
2000-01-01 open Assets:Cash CNY,USD
2000-01-01 open Assets:Bank CNY
  bank: "branch"
2000-01-01 open Assets:Stock HOOL "FIFO"
2000-01-01 open Assets:Fund FND "LIFO"
2000-01-01 open Assets:Mixed
2000-01-01 open Expenses:Food CNY
2000-01-01 open Expenses:Misc
2000-01-01 open Equity:Opening CNY
2000-01-01 open Income:Gains
2000-01-02 pad Assets:Bank Equity:Opening
2000-01-03 balance Assets:Bank 100.00 CNY
2000-01-04 balance Assets:Bank 100.0 ~ 0.5 CNY
2019-01-01 commodity HOOL
  name: "Hooli"
  precision: 2
2019-01-02 commodity FND
2030-01-01 close Assets:Mixed
'''
    TX = '''pushtag #trip
pushmeta where: "Beijing"
2020-01-01 * "Shop" "Lunch & tea" #food ^trip-1
  category: "food"
  note: "escaped \\"quote\\" and 中文"
  count: 3
  ratio: 1.50
  budget: 100.00 CNY
  reviewed: 2020-01-05
  flagged: TRUE
  other: Assets:Cash
  label: #tagged
  Assets:Cash -12.50 CNY
    posting-note: "split"
  ! Expenses:Food 12.5 CNY
2020-01-02 ! "Manual"
  Assets:Cash -3 CNY
  Expenses:Food
popmeta where:
2020-02-01 * "Buy" ^lot
  Assets:Stock 2 HOOL {10.00 USD}
  Assets:Cash -20.00 USD
2020-02-02 * "Buy more"
  Assets:Stock 2 HOOL {{24.00 USD}}
  Assets:Cash -24.00 USD
2020-02-03 * "Buy dated"
  Assets:Stock 1 HOOL {11 USD, 2020-02-01, "label"}
  Assets:Cash -11 USD
2020-02-04 * "Sell"
  Assets:Stock -3 HOOL {} @ 13 USD
  Assets:Cash 39.00 USD
  Income:Gains
2020-02-05 * "Sell total price"
  Assets:Stock -1 HOOL {} @@ 14.00 USD
  Assets:Cash 14.00 USD
  Income:Gains
2020-02-06 * "Fund"
  Assets:Fund 1 FND {100 CNY}
  Assets:Fund 1 FND {# 5 CNY}
  Assets:Bank -105 CNY
2020-02-07 * "Arithmetic"
  Expenses:Misc (10 / 3) CNY
  Expenses:Misc 2 * 1.5 CNY
  Assets:Cash
poptag #trip
2020-03-01 price HOOL 10.50 USD
2020-03-02 event "location" "Beijing"
2020-03-03 note Assets:Cash "note with 中文" #n ^m
2020-03-04 query "cash" "SELECT account WHERE account ~ 'Cash'"
2020-03-05 custom "budget" Expenses:Food "monthly" 100.00 CNY 2020-03-01 TRUE 7
2020-03-06 txn "No flag"
  Assets:Cash -1 CNY
  Expenses:Food 1 CNY
2020-03-07 *
  Assets:Cash 0 CNY
2020-03-08 * "Overridden source"
  filename: "elsewhere.bean"
  Assets:Cash -1 CNY
  Expenses:Food
'''

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = pathlib.Path(self.temporary.name).resolve()
        self.root = self.base / "generations" / "a" / "workspace"
        self.cache_directory = self.base / "parse-cache"
        self.cache_directory.mkdir()
        self.write(self.root, {"main.bean": self.MAIN, "accounts.bean": self.ACCOUNTS, "tx/2020.bean": self.TX})

    def tearDown(self):
        self.temporary.cleanup()

    @staticmethod
    def write(root, files):
        for name, text in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)

    def cache(self, root=None):
        return ledger_validator._ParseCache(root or self.root, self.cache_directory)

    counting = False

    def load(self, root=None, checkpoint=None):
        root = root or self.root
        self.counting = True
        try:
            return ledger_validator._checkpointed_load(
                root, checkpoint, str(root / "main.bean"), None, ledger_validator.validation.HARDCORE_VALIDATIONS,
                None, parse_cache=self.cache(root))
        finally:
            self.counting = False

    @staticmethod
    def comparable(result):
        entries, errors, options = result
        return (strict(entries), [(type(e), e.message, strict(e.source)) for e in errors], strict(options))

    def assert_same_as_beancount(self, root=None, checkpoint=None):
        root = root or self.root
        expected = ledger_validator.loader._uncached_load_file(
            str(root / "main.bean"), None, ledger_validator.validation.HARDCORE_VALIDATIONS, None)
        actual = self.load(root, checkpoint)
        self.assertEqual(self.comparable(actual), self.comparable(expected))
        return actual

    @contextlib.contextmanager
    def count_parses(self):
        """Yield a mock whose calls are the files that were actually parsed."""
        parsed = mock.Mock()
        original = ledger_validator.parser.parse_file

        def spy(filename, *args, **kwargs):
            # beancount's own load, the reference, is not counted.
            if self.counting:
                parsed(str(filename))
            return original(filename, *args, **kwargs)

        with mock.patch.object(ledger_validator.parser, "parse_file", spy):
            yield parsed

    def parsed_names(self, parsed, root=None):
        root = root or self.root
        return sorted(pathlib.Path(call.args[0]).relative_to(root).as_posix() for call in parsed.call_args_list)

    def stored(self):
        return sorted(path.name for path in self.cache_directory.iterdir())

    def test_second_load_parses_nothing_and_matches_beancount(self):
        _, errors, _ = self.assert_same_as_beancount()
        self.assertEqual(errors, [])
        self.assertEqual(len(self.stored()), 3)
        with self.count_parses() as parsed:
            self.assert_same_as_beancount()
        parsed.assert_not_called()

    def test_every_file_decodes_to_its_parse_exactly(self):
        self.load()
        for name in ("main.bean", "accounts.bean", "tx/2020.bean"):
            with self.subTest(name=name):
                filename = str(self.root / name)
                with self.count_parses() as parsed:
                    self.counting = True
                    cached = self.cache().parse_file(filename)
                    self.counting = False
                parsed.assert_not_called()
                fresh = ledger_validator.parser.parse_file(filename)
                self.assertEqual(strict(cached[0]), strict(fresh[0]))
                self.assertEqual(cached[1], fresh[1])
                self.assertEqual(strict(cached[2]), strict(fresh[2]))
                # Booking writes into metadata, so no two directives or
                # postings may share a metadata dict or a postings list.
                metas = [id(entry.meta) for entry in cached[0]]
                metas += [id(posting.meta) for entry in cached[0] for posting in getattr(entry, "postings", ())]
                self.assertEqual(len(metas), len(set(metas)))

    def test_a_new_directory_reuses_the_cache_with_its_own_paths(self):
        self.load()
        other = self.base / "staging" / "b" / "workspace"
        shutil.copytree(self.root, other)
        with self.count_parses() as parsed:
            entries, _, options = self.assert_same_as_beancount(other)
        parsed.assert_not_called()
        sources = {entry.meta["filename"] for entry in entries}
        self.assertEqual({name for name in sources if not name.startswith(str(other))},
                         {"elsewhere.bean", "<auto_insert_open>"} & sources)
        self.assertTrue(all(name.startswith(str(other)) for name in options["include"]))
        # The exported stream is byte-identical to the uncached one.
        streams = []
        for environment in ({}, {ledger_validator.PARSE_CACHE_ENVIRONMENT: str(self.cache_directory)}):
            with mock.patch.dict("os.environ", environment):
                if not environment:
                    os.environ.pop(ledger_validator.PARSE_CACHE_ENVIRONMENT, None)
                target = self.base / f"{len(streams)}.records"
                reply = json.loads(ledger_validator.export_canonical_json(str(other), "main.bean", str(target)))
                self.assertEqual(reply["errors"], [])
                streams.append(target.read_bytes())
        self.assertEqual(streams[0], streams[1])

    def test_a_source_typed_as_the_file_itself_is_never_stored(self):
        # Metadata may set "filename" itself; set to this very path, it would
        # be indistinguishable from the parser's own and rebound on reuse.
        (self.root / "tx/2020.bean").write_text(
            self.TX + f'2020-04-01 * "Typed"\n  filename: "{self.root}/tx/2020.bean"\n'
            '  Assets:Cash -1 CNY\n  Expenses:Food\n')
        self.assert_same_as_beancount()
        self.assertNotIn(self.cache_name("tx/2020.bean"), self.stored())
        other = self.base / "generations" / "b" / "workspace"
        shutil.copytree(self.root, other)
        self.assert_same_as_beancount(other)

    def test_an_edit_reparses_only_the_edited_file(self):
        self.load()
        for text in (self.TX + '2020-04-01 * "More"\n  Assets:Cash -1 CNY\n  Expenses:Food\n',
                     self.TX.replace("12.50", "12.51"), self.TX.replace("ratio: 1.50", "ratio: 1.5"),
                     self.TX.replace("12.5 CNY", "12.50 CNY"), "\n" + self.TX, self.TX + "; comment\n"):
            with self.subTest(text=text[-30:]):
                (self.root / "tx/2020.bean").write_text(text)
                with self.count_parses() as parsed:
                    self.assert_same_as_beancount()
                self.assertEqual(self.parsed_names(parsed), ["tx/2020.bean"])
                with self.count_parses() as parsed:
                    self.assert_same_as_beancount()
                parsed.assert_not_called()

    def test_includes_follow_the_current_files(self):
        self.load()
        cases = [
            # A new file matching the glob is parsed; the others still hit.
            ("add", {"tx/2021.bean": '2021-01-01 * "New"\n  Assets:Cash -1 CNY\n  Expenses:Food\n'}),
            # Include order changes only main.bean.
            ("order", {"main.bean": self.MAIN.replace('include "accounts.bean"\ninclude "tx/*.bean"\n',
                                                      'include "tx/*.bean"\ninclude "accounts.bean"\n')}),
            # The same file reached twice reports beancount's duplicate error.
            ("duplicate", {"main.bean": self.MAIN + 'include "accounts.bean"\n'}),
            ("missing", {"main.bean": self.MAIN + 'include "nothing/*.bean"\ninclude "gone.bean"\n'}),
            ("nested", {"accounts.bean": self.ACCOUNTS + 'include "more/*.bean"\n',
                        "more/x.bean": '2001-01-01 open Assets:More\n'}),
        ]
        for label, files in cases:
            with self.subTest(label=label):
                self.write(self.root, files)
                with self.count_parses() as parsed:
                    self.assert_same_as_beancount()
                self.assertEqual(self.parsed_names(parsed), sorted(files))
                with self.count_parses() as parsed:
                    self.assert_same_as_beancount()
                parsed.assert_not_called()
        (self.root / "tx/2021.bean").unlink()
        (self.root / "more/x.bean").rename(self.root / "more/y.bean")
        with self.count_parses() as parsed:
            self.assert_same_as_beancount()
        self.assertEqual(self.parsed_names(parsed), ["more/y.bean"])

    def test_option_changes_apply_to_the_file_that_declares_them(self):
        self.load()
        for name, text in (("main.bean", self.MAIN.replace('"FIFO"', '"LIFO"')),
                           ("main.bean", self.MAIN + 'option "render_commas" "TRUE"\n'),
                           ("main.bean", self.MAIN + 'option "name_assets" "Activa"\n'),
                           ("accounts.bean", self.ACCOUNTS.replace('"USD"', '"HOOL"', 1)),
                           ("main.bean", 'option "display_precision" "CNY:0.001"\n' + self.MAIN)):
            with self.subTest(name=name, text=text[-40:]):
                original = (self.root / name).read_text()
                (self.root / name).write_text(text)
                with self.count_parses() as parsed:
                    self.assert_same_as_beancount()
                self.assertEqual(self.parsed_names(parsed), [name])
                with self.count_parses() as parsed:
                    self.assert_same_as_beancount()
                parsed.assert_not_called()
                # One parse is kept per file, so going back parses it again.
                (self.root / name).write_text(original)
                with self.count_parses() as parsed:
                    self.assert_same_as_beancount()
                self.assertEqual(self.parsed_names(parsed), [name])

    def test_files_that_name_their_directory_are_never_stored(self):
        cases = {
            # A Document's path is resolved against the file's directory.
            "documents": '2020-01-01 document Assets:Cash "receipt.pdf"\n',
            # A path written into the file has to stay what was written.
            "typed path": f'2020-01-01 note Assets:Cash "{self.root}/tx/typed.bean"\n',
            # Parse errors quote nothing to rebind, but are never stored either.
            "errors": '2020-01-01 open Assets:Cash\n2020-13-01 * "Bad date"\n',
        }
        (self.root / "tx/receipt.pdf").write_bytes(b"%PDF")
        for label, text in cases.items():
            with self.subTest(label=label):
                (self.root / "tx/typed.bean").write_text(text)
                before = self.stored()
                for _ in range(2):
                    with self.count_parses() as parsed:
                        self.assert_same_as_beancount()
                    self.assertIn("tx/typed.bean", self.parsed_names(parsed))
                self.assertEqual(self.stored(), sorted(set(before) | set(self.stored()) - {self.cache_name("tx/typed.bean")}))
                self.assertNotIn(self.cache_name("tx/typed.bean"), self.stored())

    def cache_name(self, relative):
        return hashlib.sha256(relative.encode("utf-8")).hexdigest()[:32] + ".parse"

    def test_a_changed_file_replaces_a_stored_parse_that_no_longer_applies(self):
        self.load()
        name = self.cache_name("tx/2020.bean")
        before = (self.cache_directory / name).read_bytes()
        (self.root / "tx/2020.bean").write_text('2020-01-01 document Assets:Cash "x.pdf"\n')
        self.assert_same_as_beancount()
        # The stale entry is left alone and simply never matches.
        self.assertEqual((self.cache_directory / name).read_bytes(), before)
        (self.root / "tx/2020.bean").write_text(self.TX)
        with self.count_parses() as parsed:
            self.assert_same_as_beancount()
        parsed.assert_not_called()

    def test_unreadable_or_foreign_cache_files_are_ignored(self):
        import pickle
        self.load()
        path = self.cache_directory / self.cache_name("tx/2020.bean")
        good = pickle.loads(path.read_bytes())
        for content in (b"", b"not a pickle", pickle.dumps(["list"]), pickle.dumps({"key": "other"}),
                        pickle.dumps(dict(good, entries=b"garbage")), pickle.dumps(dict(good, options=b"x")),
                        pickle.dumps(dict(good, entries=__import__("marshal").dumps(([("Z", 1)], []))))):
            with self.subTest(content=content[:20]):
                path.write_bytes(content)
                with self.count_parses() as parsed:
                    self.assert_same_as_beancount()
                self.assertEqual(self.parsed_names(parsed), ["tx/2020.bean"])

    def test_the_key_covers_the_runtime_and_decimal_context(self):
        import decimal
        self.load()
        with mock.patch.object(ledger_validator, "PARSE_CACHE_FORMAT", 2):
            with self.count_parses() as parsed:
                self.assert_same_as_beancount()
            self.assertEqual(len(parsed.call_args_list), 3)
        with decimal.localcontext() as context:
            context.prec = 5
            with self.count_parses() as parsed:
                self.assert_same_as_beancount()
            self.assertEqual(len(parsed.call_args_list), 3)

    def test_parse_cache_is_off_without_an_owned_directory(self):
        with mock.patch.dict("os.environ", {}, clear=False):
            os.environ.pop(ledger_validator.PARSE_CACHE_ENVIRONMENT, None)
            self.assertIsNone(ledger_validator._parse_cache_directory())
        link = self.base / "link"
        link.symlink_to(self.cache_directory)
        with mock.patch.dict("os.environ", {ledger_validator.PARSE_CACHE_ENVIRONMENT: str(link)}):
            self.assertIsNone(ledger_validator._parse_cache_directory())
        with mock.patch.dict("os.environ", {ledger_validator.PARSE_CACHE_ENVIRONMENT: str(self.cache_directory)}):
            self.assertEqual(ledger_validator._parse_cache_directory(), self.cache_directory)
            with mock.patch.object(ledger_validator.beancount, "__version__", "3.3.0"):
                self.assertIsNone(ledger_validator._parse_cache_directory())

    def test_validation_entrypoints_use_the_parse_cache_directory(self):
        with mock.patch.dict("os.environ", {ledger_validator.PARSE_CACHE_ENVIRONMENT: str(self.cache_directory)}):
            first = json.loads(validate_json(str(self.root)))
            self.assertEqual(len(self.stored()), 3)
            with mock.patch.object(ledger_validator, "_decode_parsed",
                                   wraps=ledger_validator._decode_parsed) as decoded:
                second = json.loads(validate_json(str(self.root)))
            self.assertEqual(decoded.call_count, 3)
        os.environ.pop(ledger_validator.PARSE_CACHE_ENVIRONMENT, None)
        self.assertEqual(first, json.loads(validate_json(str(self.root))))
        self.assertEqual(first, second)

    def test_parse_cache_and_booking_checkpoint_together_match_beancount(self):
        # A checkpoint is only written without the overridden source file.
        (self.root / "tx/2020.bean").write_text(self.TX.split('2020-03-08 * "Overridden source"')[0])
        checkpoints = self.base / "checkpoints"
        checkpoints.mkdir()
        with mock.patch.dict("os.environ", {ledger_validator.BOOKING_CHECKPOINT_ENVIRONMENT: str(checkpoints)}):
            path = ledger_validator._booking_checkpoint_path(self.root, self.root / "main.bean")
        with mock.patch.object(ledger_validator, "_today", lambda: datetime.date(2020, 6, 15)):
            self.assert_same_as_beancount(checkpoint=path)
            self.assertTrue(path.exists())
            with self.count_parses() as parsed:
                self.assert_same_as_beancount(checkpoint=path)
            parsed.assert_not_called()

    def test_random_ledgers_and_edits_match_beancount(self):
        rng = random.Random(20261026)
        hits = 0
        for ledger in range(10):
            with self.subTest(ledger=ledger):
                hits += self.run_random_ledger(rng, ledger)
        # The comparison is only meaningful if most files came from the cache.
        self.assertGreater(hits, 300)

    def run_random_ledger(self, rng, ledger):
        """Random multi-file ledgers and random edits; compare every load."""
        root = self.base / "random" / str(ledger) / "workspace"
        accounts = ["Assets:Cash", "Assets:Bank", "Expenses:Food", "Expenses:Rent", "Income:Salary"]
        currencies = ["CNY", "USD"]

        def amount():
            exponent = rng.choice([0, 1, 2, 3])
            number = rng.randint(1, 99999)
            text = str(number) if not exponent else f"{number // 10 ** exponent}.{number % 10 ** exponent:0{exponent}d}"
            return text

        def directive(stamp):
            kind = rng.random()
            meta = "".join(rng.choice(['  k: "v"\n', "  n: 1.0\n", "  d: 2020-01-01\n", "  a: 5 CNY\n",
                                       "  b: TRUE\n", "  acct: Assets:Cash\n"]) for _ in range(rng.randint(0, 2)))
            if kind < 0.55:
                account = rng.choice(accounts[2:])
                currency = rng.choice(currencies)
                tags = rng.choice(["", " #t", " #t ^l", " ^l2"])
                posting_meta = rng.choice(["", '    pm: "x"\n'])
                return (f'{stamp} {rng.choice(["*", "!", "txn"])} "P{rng.randint(1, 30)}" "N{rng.randint(1, 30)}"{tags}\n'
                        f'{meta}  {account} {amount()} {currency}\n{posting_meta}  Assets:Cash\n')
            if kind < 0.65:
                return f'{stamp} price USD {amount()} CNY\n'
            if kind < 0.72:
                return f'{stamp} note Assets:Cash "note {rng.randint(1, 9)}"\n{meta}'
            if kind < 0.78:
                return f'{stamp} event "e" "v{rng.randint(1, 3)}"\n'
            if kind < 0.84:
                return f'{stamp} custom "c" "s" {amount()} CNY TRUE {stamp}\n'
            if kind < 0.9:
                return f'pushtag #p\n{stamp} * "Tagged"\n  Expenses:Food 1 CNY\n  Assets:Cash\npoptag #p\n'
            if kind < 0.95:
                return f'{stamp} balance Assets:Bank 0 CNY\n'
            return f'{stamp} commodity C{rng.randint(1, 5)}X\n{meta}'

        main_lines = ['option "operating_currency" "CNY"', 'include "accounts.bean"', 'include "tx/*.bean"']
        files = {"accounts.bean": "".join(f"2000-01-01 open {name}\n" for name in accounts)}
        months = [f"2020-{month:02d}" for month in range(1, 13)]
        body = {month: [directive(f"{month}-{rng.randint(1, 28):02d}") for _ in range(rng.randint(0, 6))]
                for month in months}

        def sync():
            shutil.rmtree(root, ignore_errors=True)
            rendered = dict(files, **{"main.bean": "\n".join(main_lines) + "\n"})
            for month, items in body.items():
                if items:
                    rendered[f"tx/{month}.bean"] = "".join(items)
            self.write(root, rendered)
            return len(rendered)

        hits = 0
        count = sync()
        self.assert_same_as_beancount(root)
        for step in range(12):
            action = rng.random()
            month = rng.choice(months)
            items = body[month]
            if action < 0.35:
                items.append(directive(f"{month}-{rng.randint(1, 28):02d}"))
            elif action < 0.5 and items:
                items.pop(rng.randrange(len(items)))
            elif action < 0.6 and items:
                index = rng.randrange(len(items))
                items[index] = items[index].replace(" CNY", " USD", 1)
            elif action < 0.67:
                items.append(f"{month}-02 * \"Broken\"\n  Assets:Nowhere 1 CNY\n  Assets:Cash\n")
            elif action < 0.72:
                items.append(f"{month}-03 * \"Syntax\" \n  Assets:Cash 1 CNY CNY\n")
            elif action < 0.8:
                main_lines.append(rng.choice(['option "operating_currency" "USD"', 'option "render_commas" "TRUE"',
                                              'option "booking_method" "LIFO"', 'option "title" "T"']))
            elif action < 0.87:
                main_lines[1:3] = main_lines[2:0:-1]
            elif action < 0.93:
                files["accounts.bean"] += f"2000-01-01 open Assets:New{step}\n"
            else:
                body[month] = []
            count = sync()
            with self.count_parses() as parsed:
                self.assert_same_as_beancount(root)
            hits += count - len(parsed.call_args_list)
        return hits
