import json
import hashlib
import pathlib
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
