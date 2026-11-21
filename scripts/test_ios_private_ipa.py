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
VERSION_SCRIPT = ROOT / "scripts/ios-release-version.sh"
TEAM_SCRIPT = ROOT / "scripts/build-ios-team-signed.sh"
PROJECT = ROOT / "App/LedgerMobile/project.yml"


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
        for builder in ("build-ledgercore-xcframework.sh", "build-beancount-ios.sh", "build-linux-ios.sh"):
            self.assertLess(script.index(builder), archive)
        self.assertLess(script.index('"$framework"'), script.index('sign_bundle "$app"'))
        for required in ("Python.framework", "ledger_validator.py", "licenses/Beancount-GPL-2.0.txt"):
            self.assertIn(required, script)

    def test_release_version_comes_from_the_tag_on_head(self):
        """The tag declares the version and the build; project.yml is not involved."""
        script = SCRIPT.read_text()
        self.assertIn('bash "$repo_root/scripts/ios-release-version.sh"', script)
        self.assertIn('"CURRENT_PROJECT_VERSION=$build_number"', script)
        self.assertIn('"MARKETING_VERSION=$marketing_version"', script)
        # Nothing is written back, so there is no bump to commit or roll back.
        self.assertNotIn("sed -i", script)
        uses = [line.strip() for line in script.splitlines()
                if "project.yml" in line and not line.lstrip().startswith("#")]
        self.assertEqual(uses, ["xcodegen generate --spec project.yml --quiet"])
        self.assertNotIn("checkout --", script)
        # The tag is resolved before the slow framework builds.
        self.assertLess(script.index("ios-release-version.sh"),
                        script.index("build-ledgercore-xcframework.sh"))
        # The packaged app must report exactly the tagged numbers.
        self.assertIn("not the tagged $marketing_version ($build_number)", script)
        self.assertNotIn("GITHUB_RUN_NUMBER", script)


class TeamSigningTests(unittest.TestCase):
    """The paid team signs from project.yml; SideStore keeps the unsuffixed IDs."""

    def test_project_signs_every_target_with_the_team_settings(self):
        project = PROJECT.read_text()
        team = re.search(r"^    LEDGER_TEAM_ID: ([A-Z0-9]{10})$", project, re.M)
        self.assertIsNotNone(team)
        self.assertNotIn("PERSONAL_TEAM_BUILD", project)
        self.assertEqual(project.count("DEVELOPMENT_TEAM: $(LEDGER_TEAM_ID)"), 3)
        for suffix in ("", ".widgets", ".share"):
            self.assertIn(f"PRODUCT_BUNDLE_IDENTIFIER: $(LEDGER_BUNDLE_ID){suffix}\n", project)
        for entitlements in ("Supporting/LedgerMobile.entitlements",
                             "WidgetExtension/LedgerWidgets.entitlements",
                             "ShareExtension/LedgerShare.entitlements"):
            text = (ROOT / "App/LedgerMobile" / entitlements).read_text()
            self.assertIn("<string>$(LEDGER_APP_GROUP)</string>", text, entitlements)
            self.assertNotIn("associated-domains", text, entitlements)

    def test_project_uses_the_paid_team_identifiers(self):
        project = PROJECT.read_text()
        self.assertIn("    LEDGER_BUNDLE_ID: com.qiaoborui.ledger\n", project)
        self.assertIn("    LEDGER_APP_GROUP: group.com.qiaoborui.ledger\n", project)
        # The app and both extensions tell LedgerSharedAccess their group.
        self.assertEqual(project.count("LedgerAppGroupIdentifier: $(LEDGER_APP_GROUP)"), 3)
        for plist in ("Supporting/Info.plist", "WidgetExtension/Info.plist", "ShareExtension/Info.plist"):
            text = (ROOT / "App/LedgerMobile" / plist).read_text()
            self.assertIn("<key>LedgerAppGroupIdentifier</key>\n\t<string>$(LEDGER_APP_GROUP)</string>", text, plist)

    def test_sidestore_package_keeps_the_mobile_identifiers(self):
        script = SCRIPT.read_text()
        self.assertIn("readonly sidestore_bundle_id=com.qiaoborui.ledger.mobile", script)
        self.assertIn("readonly sidestore_app_group=group.com.qiaoborui.ledger.mobile", script)
        self.assertIn('"LEDGER_BUNDLE_ID=$sidestore_bundle_id" "LEDGER_APP_GROUP=$sidestore_app_group"', script)
        self.assertIn('"$(LEDGER_APP_GROUP)"', script)

    def test_icloud_container_is_main_app_only_and_team_independent(self):
        project = PROJECT.read_text()
        # The container is where users' iCloud data lives: it must not move
        # with the team suffix or an App Store transfer.
        self.assertIn("    LEDGER_ICLOUD_CONTAINER: iCloud.com.qiaoborui.ledger\n", project)
        app = (ROOT / "App/LedgerMobile/Supporting/LedgerMobile.entitlements").read_text()
        self.assertEqual(app.count("<string>$(LEDGER_ICLOUD_CONTAINER)</string>"), 2)
        self.assertIn("<string>CloudDocuments</string>", app)
        for extension in ("WidgetExtension/LedgerWidgets.entitlements",
                          "ShareExtension/LedgerShare.entitlements"):
            self.assertNotIn("icloud", (ROOT / "App/LedgerMobile" / extension).read_text().lower())
        # SideStore cannot provision iCloud, so its ad-hoc signature drops it.
        script = SCRIPT.read_text()
        for key in ("com.apple.developer.icloud-container-identifiers",
                    "com.apple.developer.ubiquity-container-identifiers",
                    "com.apple.developer.icloud-services"):
            self.assertIn(f'"{key}"', script)

    def test_testflight_needs_the_api_key_before_building(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith("ASC_")}
        result = subprocess.run(["bash", str(TEAM_SCRIPT), "--testflight"],
                                capture_output=True, text=True, env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ASC_KEY_ID", result.stderr)

    def test_testflight_job_is_opt_in_and_read_only(self):
        workflow = RELEASE_WORKFLOW.read_text()
        job = workflow[workflow.index("\n  testflight:"):]
        self.assertIn("vars.TESTFLIGHT_UPLOAD == 'true'", job)
        self.assertIn("github.repository == 'qiaoborui/beancount-ledger-web'", job)
        self.assertIn("build-ios-team-signed.sh --testflight", job)
        self.assertNotIn("write", job)
        # The runner's login keychain is locked without a console login, so
        # the job signs from its own keychain and always removes it.
        create = job.index("signing-keychain.sh create")
        self.assertLess(create, job.index("build-ios-team-signed.sh --testflight"))
        self.assertIn("if: always()\n        run: bash .github/scripts/signing-keychain.sh delete", job)


class ReleaseVersionTests(unittest.TestCase):
    """Runs scripts/ios-release-version.sh against throwaway repositories."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name)
        self.git("init", "-q")
        self.commit()

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args):
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
               "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
        subprocess.run(["git", "-C", str(self.repo), *args], check=True, env=env,
                       capture_output=True, text=True)

    def commit(self):
        self.git("commit", "-q", "--allow-empty", "-m", "c")

    def tag(self, name):
        self.git("tag", "-a", name, "-m", name)

    def resolve(self):
        return subprocess.run(["bash", str(VERSION_SCRIPT), str(self.repo)],
                              capture_output=True, text=True)

    def test_build_number_is_derived_from_the_version(self):
        for tag, expected in (("v1.4.3", "1.4.3 10403"), ("v1.5.0", "1.5.0 10500"),
                              ("v2.0.0", "2.0.0 20000"), ("v10.99.99", "10.99.99 109999")):
            with self.subTest(tag=tag):
                self.commit()
                self.tag(tag)
                result = self.resolve()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)

    def test_a_newer_release_always_has_a_higher_build(self):
        versions = ["0.4.1", "0.10.0", "1.0.0", "1.4.2", "1.4.3", "1.5.0", "1.10.0", "2.0.0"]
        builds = [int(a) * 10000 + int(b) * 100 + int(c)
                  for a, b, c in (v.split(".") for v in versions)]
        self.assertEqual(builds, sorted(builds))
        # Above build 62, the last number counted up by hand (1.4.1).
        self.assertGreater(builds[versions.index("1.4.3")], 62)

    def test_untagged_head_is_refused(self):
        self.tag("v1.4.2")
        self.commit()
        result = self.resolve()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HEAD has no release tag", result.stderr)

    def test_only_the_newest_release_can_be_packaged(self):
        self.tag("v1.4.2")
        self.commit()
        self.tag("v1.10.0")
        self.git("checkout", "-q", "HEAD~1")
        result = self.resolve()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("v1.4.2 is not the newest release tag in this generation (v1.10.0)", result.stderr)

    def test_the_highest_of_several_tags_on_head_wins(self):
        self.tag("v1.4.2")
        self.tag("v1.4.3")
        self.assertEqual(self.resolve().stdout.strip(), "1.4.3 10403")

    def test_tags_that_are_not_plain_releases_are_ignored(self):
        for name in ("v1.4.3-rc1", "v1.04.3", "1.4.3", "v1.4"):
            self.tag(name)
        result = self.resolve()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HEAD has no release tag", result.stderr)

    def test_minor_and_patch_stay_below_one_hundred(self):
        self.tag("v1.100.0")
        result = self.resolve()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("below 100", result.stderr)

    def test_a_generation_marker_restarts_the_numbering(self):
        self.tag("v1.4.31")
        marker = self.repo / "scripts" / "ios-release-generation"
        marker.parent.mkdir()
        marker.write_text("restart at 0.1.1\n")
        self.git("add", "scripts/ios-release-generation")
        self.commit()
        self.tag("v0.1.1")
        result = self.resolve()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "0.1.1 101")

        self.commit()
        self.tag("v0.1.2")
        self.assertEqual(self.resolve().stdout.strip(), "0.1.2 102")

    def test_a_legacy_tag_before_the_marker_is_not_the_newest(self):
        self.tag("v1.4.31")
        marker = self.repo / "scripts" / "ios-release-generation"
        marker.parent.mkdir()
        marker.write_text("restart at 0.1.1\n")
        self.git("add", "scripts/ios-release-generation")
        self.commit()
        self.tag("v0.1.1")
        self.commit()
        self.tag("v0.1.2")
        self.git("checkout", "-q", "HEAD~1")
        result = self.resolve()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("v0.1.1 is not the newest release tag in this generation (v0.1.2)", result.stderr)


if __name__ == "__main__":
    unittest.main()
