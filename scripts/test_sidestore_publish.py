"""Host-independent tests for scripts/publish-sidestore-release.py (stdlib only)."""
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/publish-sidestore-release.py"
spec = importlib.util.spec_from_file_location("publish_sidestore_release", SCRIPT)
publish = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publish)

BUNDLE = publish.BUNDLE_ID


def source(versions):
    return {
        "name": "Ledger",
        "apps": [{"name": "Ledger", "bundleIdentifier": BUNDLE, "versions": versions}],
        "news": [],
    }


def entry(version, build):
    return {
        "version": version,
        "buildVersion": str(build),
        "date": "2026-11-08T00:00:00Z",
        "localizedDescription": f"notes {version}",
        "downloadURL": f"https://example.invalid/{version}.ipa",
        "size": 100 + build,
        "sha256": "0" * 64,
    }


class ReadMetadataTests(unittest.TestCase):
    def write_ipa(self, directory, app_info, extension_info=None):
        path = Path(directory) / "app.ipa"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("Payload/LedgerMobile.app/Info.plist", plistlib.dumps(app_info))
            if extension_info is not None:
                archive.writestr("Payload/LedgerMobile.app/PlugIns/LedgerWidgets.appex/Info.plist",
                                 plistlib.dumps(extension_info))
        return path

    def test_reads_the_app_plist_not_an_extension(self):
        with tempfile.TemporaryDirectory() as temp:
            ipa = self.write_ipa(temp, {
                "CFBundleIdentifier": BUNDLE, "CFBundleShortVersionString": "0.5.0",
                "CFBundleVersion": "55", "MinimumOSVersion": "17.0",
            }, {"CFBundleIdentifier": BUNDLE + ".widgets", "CFBundleShortVersionString": "9.9.9",
                "CFBundleVersion": "1"})
            self.assertEqual(publish.read_ipa_metadata(ipa), {
                "bundleIdentifier": BUNDLE, "version": "0.5.0",
                "buildVersion": "55", "minOSVersion": "17.0",
            })

    def test_rejects_a_file_that_is_not_an_ipa(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "app.ipa"
            path.write_text("not a zip")
            with self.assertRaises(publish.PublishError):
                publish.read_ipa_metadata(path)


class AddVersionTests(unittest.TestCase):
    def test_first_version_fills_empty_source_and_legacy_fields(self):
        original = source([])
        updated = publish.add_version(original, BUNDLE, entry("0.5.0", 55))
        app = updated["apps"][0]
        self.assertEqual([v["version"] for v in app["versions"]], ["0.5.0"])
        self.assertEqual(app["version"], "0.5.0")
        self.assertEqual(app["versionDate"], "2026-11-08T00:00:00Z")
        self.assertEqual(app["versionDescription"], "notes 0.5.0")
        self.assertEqual(app["downloadURL"], "https://example.invalid/0.5.0.ipa")
        self.assertEqual(app["size"], 155)
        self.assertEqual(original["apps"][0]["versions"], [], "input must not be mutated")

    def test_newest_version_goes_first(self):
        updated = publish.add_version(source([entry("0.5.0", 55)]), BUNDLE, entry("0.5.1", 56))
        self.assertEqual([v["version"] for v in updated["apps"][0]["versions"]], ["0.5.1", "0.5.0"])

    def test_versions_compare_numerically(self):
        updated = publish.add_version(source([entry("0.9.0", 60)]), BUNDLE, entry("0.10.0", 61))
        self.assertEqual(updated["apps"][0]["version"], "0.10.0")

    def test_refuses_a_listed_version(self):
        with self.assertRaisesRegex(publish.PublishError, "already in the source"):
            publish.add_version(source([entry("0.5.0", 55)]), BUNDLE, entry("0.5.0", 56))

    def test_refuses_a_build_number_that_is_not_higher(self):
        with self.assertRaisesRegex(publish.PublishError, "not above the newest listed build"):
            publish.add_version(source([entry("0.5.0", 55)]), BUNDLE, entry("0.5.1", 55))

    def test_refuses_an_older_version(self):
        with self.assertRaisesRegex(publish.PublishError, "not above the newest listed version"):
            publish.add_version(source([entry("0.5.0", 55)]), BUNDLE, entry("0.4.9", 56))

    def test_refuses_a_source_without_the_app_and_no_template(self):
        with self.assertRaises(publish.PublishError):
            publish.add_version({"apps": []}, BUNDLE, entry("0.5.0", 55))

    def test_first_publish_inserts_the_app_from_the_template_and_features_it(self):
        empty = {"name": "Ledger", "featuredApps": [], "apps": [], "news": []}
        template = {"name": "Ledger", "bundleIdentifier": BUNDLE, "category": "utilities"}
        updated = publish.add_version(empty, BUNDLE, entry("0.5.0", 55), template)
        app = updated["apps"][0]
        self.assertEqual(app["category"], "utilities")
        self.assertEqual([v["version"] for v in app["versions"]], ["0.5.0"])
        self.assertEqual(updated["featuredApps"], [BUNDLE])
        self.assertNotIn("versions", template, "template must not be mutated")

    def test_template_for_another_app_is_refused(self):
        with self.assertRaises(publish.PublishError):
            publish.add_version({"apps": []}, BUNDLE, entry("0.5.0", 55), {"bundleIdentifier": "other"})


class AssetTests(unittest.TestCase):
    def release(self, **asset):
        return {"tagName": "v0.5.0", "assets": [{"name": "a.ipa", "state": "uploaded",
                                                 "digest": "sha256:" + "a" * 64, **asset}]}

    def test_accepts_an_uploaded_asset_with_the_same_digest(self):
        publish.verify_asset(self.release(), "a.ipa", "a" * 64)

    def test_refuses_same_name_with_other_bytes(self):
        with self.assertRaisesRegex(publish.PublishError, "digest"):
            publish.verify_asset(self.release(), "a.ipa", "b" * 64)

    def test_refuses_an_asset_that_is_not_uploaded(self):
        with self.assertRaisesRegex(publish.PublishError, "not uploaded"):
            publish.verify_asset(self.release(state="starter"), "a.ipa", "a" * 64)

    def test_refuses_a_missing_asset(self):
        with self.assertRaisesRegex(publish.PublishError, "no asset"):
            publish.verify_asset(self.release(), "b.ipa", "a" * 64)


class BuildInfoTests(unittest.TestCase):
    SHA = "0123456789abcdef0123456789abcdef01234567"

    def test_reads_source_and_clean_worktree(self):
        info = publish.parse_build_info(f"Xcode 27.2\nSource: {self.SHA}\nWorktree: clean\nApp: 0.5.0 (55)\n")
        self.assertEqual(info["Source"], self.SHA)

    def test_refuses_a_dirty_or_unrecorded_worktree(self):
        for text in (f"Source: {self.SHA}\nWorktree: dirty\n", f"Source: {self.SHA}\n"):
            with self.assertRaisesRegex(publish.PublishError, "clean worktree"):
                publish.parse_build_info(text)

    def test_refuses_missing_source(self):
        with self.assertRaisesRegex(publish.PublishError, "Source"):
            publish.parse_build_info("Worktree: clean\n")

    def test_remote_tag_prefers_the_peeled_commit(self):
        listing = f"{'1' * 40}\trefs/tags/v0.5.0\n{self.SHA}\trefs/tags/v0.5.0^{{}}\n"
        self.assertEqual(publish.remote_tag_commit(listing, "v0.5.0"), self.SHA)
        self.assertEqual(publish.remote_tag_commit(f"{self.SHA}\trefs/tags/v0.5.0\n", "v0.5.0"), self.SHA)
        self.assertIsNone(publish.remote_tag_commit("", "v0.5.0"))

    def test_rendered_source_keeps_chinese_text_readable(self):
        rendered = publish.render_source({"name": "账本"})
        self.assertIn("账本", rendered)
        self.assertTrue(rendered.endswith("\n"))


class CommandLineTests(unittest.TestCase):
    def test_publishing_requires_explicit_public_flag(self):
        with tempfile.TemporaryDirectory() as temp:
            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(Path(temp) / "missing.ipa"), "--notes", str(Path(temp) / "n.md")],
                capture_output=True, text=True,
            )
        self.assertEqual(result.returncode, 2)
        self.assertIn("--public", result.stderr)
        self.assertIn("THIRD_PARTY.md", result.stderr)


if __name__ == "__main__":
    unittest.main()
