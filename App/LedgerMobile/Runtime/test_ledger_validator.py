import json
import pathlib
import tempfile
import unittest

from ledger_validator import validate_json


class CanonicalValidationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def validate(self, text):
        (self.root / "main.bean").write_text(text)
        return json.loads(validate_json(str(self.root)))["errors"]

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


if __name__ == "__main__":
    unittest.main()
