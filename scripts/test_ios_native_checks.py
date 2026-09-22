"""Host-independent contract guards, not a substitute for the macOS build.

Stdlib only so these run on a clean runner before any dependency installation.
The deliberately narrow checks complement actionlint rather than parse YAML.
"""
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/ios-native-checks.yml"


def run_blocks(text):
    """Extract literal run blocks from this workflow's fixed step indentation."""
    return re.findall(r"^        run: \|\n((?:          .*\n|\n)+)", text, re.M)


class NativeWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text()

    def test_public_readonly_pr_only(self):
        self.assertIn("\non:\n  pull_request:\n", self.workflow)
        self.assertIn("permissions:\n  contents: read\n", self.workflow)
        self.assertIn("persist-credentials: false", self.workflow)
        self.assertIn("runs-on: macos-15", self.workflow)
        self.assertIn("timeout-minutes: 45", self.workflow)
        self.assertIn("cancel-in-progress: true", self.workflow)
        self.assertIn("github.event.pull_request.number", self.workflow)
        for forbidden in (
            "workflow_dispatch:", "workflow_call:", "pull_request_target:",
            "  push:", "self-hosted", "secrets.", "write-all", "contents: write",
            "actions/upload-artifact", "actions/cache", "build-ios-ipa.sh",
            "-allowProvisioning", "xcodebuild archive", "-exportArchive",
        ):
            self.assertNotIn(forbidden, self.workflow)

    def test_trigger_covers_native_inputs(self):
        paths = self.workflow.split("    paths:\n", 1)[1].split("\npermissions:", 1)[0]
        for path in (
            "App/LedgerMobile/**", "server/mobilecore/**", "server/mobilegit/**",
            "server/mobilereadindex/**", "server/internal/**", "server/go.mod",
            "server/go.sum", "scripts/build-ledgercore-xcframework.sh",
            "scripts/build-beancount-ios.sh", "scripts/build-beancount-ios-resources.sh",
            "scripts/test_ios_native_checks.py", ".github/workflows/ios-native-checks.yml",
        ):
            self.assertIn(f"- '{path}'", paths)

    def test_real_builders_precede_project_and_build(self):
        positions = [self.workflow.index(command) for command in (
            "run: bash scripts/build-ledgercore-xcframework.sh",
            "run: bash scripts/build-beancount-ios.sh",
            "run: xcodegen generate", "          xcodebuild build",
        )]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("go-version: '1.26.x'", self.workflow)
        self.assertIn("cache: false", self.workflow)
        self.assertIn("brew install bison flex xcodegen", self.workflow)
        self.assertIn("DEVELOPER_DIR={developer}", self.workflow)
        self.assertNotIn("/Applications/Xcode-beta.app", self.workflow)
        # Detect drift in the toolchain assumption documented in the workflow.
        builder = (ROOT / "scripts/build-ledgercore-xcframework.sh").read_text()
        self.assertIn("go mod edit -go=1.26.0", builder)

    def test_both_configurations_build_all_products_without_signing(self):
        self.assertIn("configuration: [Debug, BoundedDebug]", self.workflow)
        self.assertIn("fail-fast: false", self.workflow)
        for option in (
            "-scheme LedgerMobile", '-configuration "$CONFIGURATION"',
            "-sdk iphonesimulator", "-destination 'generic/platform=iOS Simulator'",
            "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
            "CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=",
        ):
            self.assertIn(option, self.workflow)
        for product in (
            "$app/LedgerMobile", "$app/PlugIns/LedgerWidgets.appex/LedgerWidgets",
            "$app/PlugIns/LedgerShare.appex/LedgerShare",
            "$app/Frameworks/Python.framework/Python",
            "$app/python/app_packages/ledger_stream_bridge.py",
        ):
            self.assertIn(f'test -s "{product}"', self.workflow)
        project = (ROOT / "App/LedgerMobile/project.yml").read_text()
        app = project.split("  LedgerMobile:\n", 1)[1].split("  LedgerWidgets:\n", 1)[0]
        for extension in ("LedgerWidgets", "LedgerShare"):
            self.assertIn(f"- target: {extension}\n        embed: true", app)

    def test_native_modules_cannot_silently_fall_back(self):
        self.assertIn("import LedgerCore\n", self.workflow)
        self.assertIn("import BeancountRuntime\n", self.workflow)
        self.assertIn("MobilereadindexNewBridge", self.workflow)
        self.assertIn("swiftc -typecheck", self.workflow)
        self.assertNotIn("#if canImport", self.workflow)
        self.assertNotIn("continue-on-error", self.workflow)
        self.assertNotIn("|| true", self.workflow)

    def test_apple_sqlite_runtime_gate_precedes_native_build(self):
        gate = self.workflow.index("- name: Test read index against Apple system SQLite")
        builder = self.workflow.index("run: bash scripts/build-ledgercore-xcframework.sh")
        self.assertLess(gate, builder)
        step = self.workflow[gate:builder].split("\n      # Build", 1)[0]
        self.assertIn("working-directory: server", step)
        self.assertIn('export TMPDIR="$(cd "$RUNNER_TEMP" && pwd -P)"', step)
        self.assertIn(
            "go test -race -p 2 -timeout 120s ./internal/ledger ./internal/readindex/... ./mobilereadindex",
            step,
        )

    def test_embedded_shell_and_python_syntax(self):
        blocks = run_blocks(self.workflow)
        self.assertEqual(len(blocks), 5)
        for block in blocks:
            shell = "\n".join(line[10:] for line in block.splitlines()) + "\n"
            result = subprocess.run(["bash", "-n"], input=shell, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            if "python3 - <<'PY'\n" in shell:
                python = shell.split("python3 - <<'PY'\n", 1)[1].split("\nPY", 1)[0]
                compile(python, str(WORKFLOW), "exec")


if __name__ == "__main__":
    unittest.main()
