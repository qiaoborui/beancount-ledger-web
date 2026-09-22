"""Host-independent guards for private-only IPA packaging (stdlib only)."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/build-ios-ipa.sh"


class PrivateIPATests(unittest.TestCase):
    def test_configuration_defaults_to_release_and_accepts_explicit_modes(self):
        preamble = SCRIPT.read_text().split("umask 077", 1)[0]
        for arguments, expected in [([], "Release"), (["--configuration", "Release"], "Release"),
                                    (["--configuration", "BoundedRelease"], "BoundedRelease")]:
            with self.subTest(arguments=arguments):
                result = subprocess.run(["bash", "-c", preamble + '\nprintf "%s" "$configuration"',
                                         str(SCRIPT), "--private-local", "unused", *arguments],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)

    def test_invalid_configuration_fails_before_creating_output(self):
        for arguments in (["--configuration", "Debug"], ["--configuration", "BoundedDebug"],
                          ["--configuration", "Release;false"], ["--configuration"],
                          ["--other", "BoundedRelease"]):
            with self.subTest(arguments=arguments), tempfile.TemporaryDirectory() as temp:
                output = Path(temp) / "output"
                result = subprocess.run(["bash", str(SCRIPT), "--private-local", str(output), *arguments],
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output.exists())

    def test_configuration_guard_requires_matching_app_and_extension_flags(self):
        script = SCRIPT.read_text()
        block = script.split('python3 - "$build_dir/settings.json" "$configuration"', 1)[1]
        program = block.split("<<'PY'\n", 1)[1].split("\nPY", 1)[0]
        names = ("LedgerMobile", "LedgerWidgets", "LedgerShare")
        for configuration in ("Release", "BoundedRelease"):
            for mismatch in (None, *names, "missing"):
                with self.subTest(configuration=configuration, mismatch=mismatch), tempfile.TemporaryDirectory() as temp:
                    settings = []
                    for name in names:
                        enabled = (configuration == "BoundedRelease") != (name == mismatch)
                        settings.append({"target": name, "buildSettings": {
                            "CONFIGURATION": configuration,
                            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "PERSONAL_TEAM_BUILD" +
                                (" LEDGER_BOUNDED_READ_INDEX" if enabled else ""),
                        }})
                    if mismatch == "missing":
                        settings.pop()
                    path = Path(temp) / "settings.json"
                    path.write_text(json.dumps(settings))
                    result = subprocess.run([os.sys.executable, "-c", program, str(path), configuration],
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, mismatch is None, result.stderr)
        self.assertIn('-configuration "$configuration"', script)
        self.assertIn('echo "Configuration: $configuration"', script)
        self.assertIn('ipa_name="com.qiaoborui.ledger.mobile.ipa"', script)

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
        for required in ("Python.framework", "ledger_validator.py", "ledger_stream.py", "ledger_stream_bridge.py", "licenses/Beancount-GPL-2.0.txt"):
            self.assertIn(required, script)


class PythonRuntimePackagingTests(unittest.TestCase):
    MODULES = ("ledger_validator", "ledger_stream", "ledger_stream_bridge")

    def test_builder_stages_all_application_modules(self):
        script = (ROOT / "scripts/build-beancount-ios.sh").read_text()
        start = script.index("for module in ")
        block = script[start:script.index("\ndone", start) + len("\ndone")]
        with tempfile.TemporaryDirectory() as temp:
            build = Path(temp)
            (build / "packages").mkdir()
            subprocess.run(["bash", "-eu", "-c", block], check=True,
                           env={**os.environ, "ROOT": str(ROOT), "BUILD": str(build)})
            for module in self.MODULES:
                self.assertEqual((build / "packages" / (module + ".py")).read_bytes(),
                                 (ROOT / "App/LedgerMobile/Runtime" / (module + ".py")).read_bytes())

    @unittest.skipUnless(shutil.which("rsync"), "requires rsync")
    def test_incremental_resource_packaging_refreshes_all_modules(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            scripts = root / "scripts"
            scripts.mkdir()
            script = scripts / "build-beancount-ios-resources.sh"
            shutil.copyfile(ROOT / "scripts" / script.name, script)
            runtime = root / "App/LedgerMobile/Runtime"
            runtime.mkdir(parents=True)
            build = root / "server/.build/beancount-ios"
            packages = build / "packages"
            packages.mkdir(parents=True)
            for module in self.MODULES:
                shutil.copyfile(ROOT / "App/LedgerMobile/Runtime" / (module + ".py"),
                                runtime / (module + ".py"))
                (packages / (module + ".py")).write_text("stale staged bridge")
            upstream = build / "upstream/Python.xcframework/build"
            upstream.mkdir(parents=True)
            # Replace Apple-only stdlib install/signing, not resource packaging.
            (upstream / "utils.sh").write_text(
                'install_python() { mkdir -p "$CODESIGNING_FOLDER_PATH/python/lib/python3.14/test"; }\n')
            app = root / "LedgerMobile.app"
            env = {**os.environ, "CODESIGNING_FOLDER_PATH": str(app)}
            for iteration in range(2):
                subprocess.run(["bash", str(script)], env=env, check=True, capture_output=True)
                for module in self.MODULES:
                    self.assertEqual((app / "python/app_packages" / (module + ".py")).read_bytes(),
                                     (runtime / (module + ".py")).read_bytes())
                self.assertFalse((app / "python/lib/python3.14/test").exists())
                # The next pass must copy current sources, not stale build cache.
                for module in self.MODULES:
                    with (runtime / (module + ".py")).open("a") as output:
                        output.write("\n# incremental update\n")

    def test_ipa_checks_current_sources_for_all_modules(self):
        script = SCRIPT.read_text()
        self.assertIn("for module in " + " ".join(self.MODULES) + "; do", script)
        self.assertIn('cmp "$repo_root/App/LedgerMobile/Runtime/$module.py" '
                      '"$app/python/app_packages/$module.py"', script)


if __name__ == "__main__":
    unittest.main()
