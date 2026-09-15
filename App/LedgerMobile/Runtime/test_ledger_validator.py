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


if __name__ == "__main__":
    unittest.main()
