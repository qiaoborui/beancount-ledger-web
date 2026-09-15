"""Host-independent guards for private-only IPA packaging (stdlib only)."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/build-ios-ipa.sh"


class PrivateIPATests(unittest.TestCase):
    def test_packaging_requires_explicit_private_mode(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "output"
            result = subprocess.run(
                ["bash", str(SCRIPT), str(output)], capture_output=True, text=True
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("--private-local", result.stderr)
            self.assertFalse(output.exists())

    def test_existing_output_is_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            marker = Path(temp) / "keep"
            marker.write_text("existing user file")
            result = subprocess.run(
                ["bash", str(SCRIPT), "--private-local", temp],
                capture_output=True, text=True,
                env={**os.environ, "PATH": "/usr/bin:/bin"},
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("fresh output directory", result.stderr)
            self.assertEqual(marker.read_text(), "existing user file")

    def test_workflow_is_manual_and_runner_local(self):
        workflow = (ROOT / ".github/workflows/ios-ipa.yml").read_text()
        self.assertIn("workflow_dispatch:", workflow)
        for trigger in ("push", "pull_request", "pull_request_target", "workflow_call"):
            self.assertIsNone(re.search(rf"^  {trigger}:", workflow, re.M))
        self.assertNotIn("${{ false }}", workflow)
        self.assertIn("actions/upload-artifact", workflow)
        self.assertIn("retention-days: 7", workflow)
        self.assertNotIn("actions/cache", workflow)
        self.assertIn("--private-local", workflow)
        self.assertIn("Downloads/LedgerMobile-PrivateBuilds", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertIn("group: ios-private-ipa", workflow)
        self.assertIn("cancel-in-progress: false", workflow)

    def test_runtime_build_and_signature_order(self):
        script = SCRIPT.read_text()
        archive = script.index("xcodebuild archive")
        for builder in ("build-ledgercore-xcframework.sh", "build-beancount-ios.sh"):
            self.assertLess(script.index(builder), archive)
        self.assertLess(script.index('"$framework"'), script.index('sign_bundle "$app"'))
        for required in ("Python.framework", "ledger_validator.py", "licenses/Beancount-GPL-2.0.txt"):
            self.assertIn(required, script)


if __name__ == "__main__":
    unittest.main()
