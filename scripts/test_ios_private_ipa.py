"""Host-independent guards for private-only IPA packaging (stdlib only)."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/build-ios-ipa.sh"
RELEASE_WORKFLOW = ROOT / ".github/workflows/ios-release.yml"


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

    def test_release_workflow_runs_only_for_release_tags_upstream(self):
        """Publishing happens on a pushed release tag, never on a PR or a fork."""
        workflow = RELEASE_WORKFLOW.read_text()
        self.assertIsNotNone(re.search(r"^  push:\n    tags:\n", workflow, re.M))
        self.assertIsNone(re.search(r"^    branches:", workflow, re.M))
        for trigger in ("pull_request", "pull_request_target", "workflow_dispatch",
                        "workflow_call", "schedule"):
            self.assertIsNone(re.search(rf"^  {trigger}:", workflow, re.M))
        self.assertIn("if: github.repository == 'qiaoborui/beancount-ledger-web'", workflow)
        self.assertIn("--private-local", workflow)
        self.assertIn("require-tag-match: true", workflow)
        self.assertIn("release-repo: qiaoborui/beancount-ledger-releases", workflow)
        self.assertNotIn("contents: write", workflow)

    def test_release_workflow_pins_tools_to_the_workflow_ref(self):
        """The shared scripts must come from the same ref as the shared workflow."""
        workflow = RELEASE_WORKFLOW.read_text()
        uses = re.search(
            r"^    uses: Ami0307/tethera-releases/\.github/workflows/ios-release\.yml@(\S+)$",
            workflow, re.M)
        tools = re.search(r"^      tools-ref: (\S+)$", workflow, re.M)
        self.assertIsNotNone(uses)
        self.assertIsNotNone(tools)
        self.assertEqual(uses.group(1), tools.group(1))

    def test_runtime_build_and_signature_order(self):
        script = SCRIPT.read_text()
        archive = script.index("xcodebuild archive")
        for builder in ("build-ledgercore-xcframework.sh", "build-beancount-ios.sh"):
            self.assertLess(script.index(builder), archive)
        self.assertLess(script.index('"$framework"'), script.index('sign_bundle "$app"'))
        for required in ("Python.framework", "ledger_validator.py", "licenses/Beancount-GPL-2.0.txt"):
            self.assertIn(required, script)

    def test_release_version_comes_from_a_tag(self):
        """The marketing version is a declared release, never a per-PR guess."""
        script = SCRIPT.read_text()
        self.assertIn("No release tag found.", script)
        # A tag that disagrees with project.yml must stop the build, not be
        # silently overridden in either direction.
        self.assertIn(
            'Newest release tag v$release_version disagrees with project.yml', script)
        # Tags are compared as versions. `git describe` orders by commit date,
        # so re-tagging an older commit would silently move the shipped version
        # backwards.
        self.assertNotIn("git describe --tags", script)
        self.assertIn("sort -t. -k1,1n -k2,2n -k3,3n", script)
        self.assertIn("git -C \"$repo_root\" tag --list 'v[0-9]*.[0-9]*.[0-9]*'", script)

    def test_release_tag_ordering_backs_off_to_the_newest_version(self):
        """Sorted ordering must survive tags applied out of commit order."""
        tags = ["v0.9.5", "v0.10.0", "v0.2.0", "v0.3.1"]
        ordered = sorted((tag[1:] for tag in tags),
                         key=lambda value: tuple(int(part) for part in value.split(".")))
        self.assertEqual(ordered[-1], "0.10.0")

    def test_every_package_advances_the_build_number(self):
        """Build numbers identify a binary; a reused one never renews on device."""
        script = SCRIPT.read_text()
        self.assertIn('build_number="$(( ${current_build:-0} + 1 ))"', script)
        self.assertIn('"CURRENT_PROJECT_VERSION=$build_number"', script)
        # The bump is written back so the next package starts above it, and the
        # exit trap restores the file only after the write actually happened.
        self.assertIn("CURRENT_PROJECT_VERSION: *", script)
        self.assertIn("Could not advance CURRENT_PROJECT_VERSION", script)
        self.assertIn("version_file_dirty=1", script)
        self.assertLess(
            script.index("version_file_dirty=0"),
            script.index("version_file_dirty=1"),
            "the dirty flag must be armed after the write, not before")
        # A finished IPA carries the new number, so success must disarm the
        # trap; otherwise the bump is rolled back and the next package reuses it.
        self.assertGreater(
            script.rindex("version_file_dirty=0"),
            script.index('unzip -tq "$output_dir/$ipa_name"'),
            "the bump must survive once the IPA is written")
        # CI no longer offsets by the run number: the increment covers every
        # package, local or hosted.
        self.assertNotIn("GITHUB_RUN_NUMBER", script)


if __name__ == "__main__":
    unittest.main()
