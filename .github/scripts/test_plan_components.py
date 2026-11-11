"""Guards for the path-to-area table in plan-components.sh (stdlib only)."""
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
PLANNER = ROOT / ".github/scripts/plan-components.sh"
AREAS = {"backend", "agent", "web", "ios", "ios_app", "ios_widgets", "ios_runtime", "selfhost", "release"}


def plan(*args, paths=()):
    result = subprocess.run(
        ["bash", str(PLANNER), *args],
        input="".join(f"{path}\n" for path in paths),
        capture_output=True, text=True, check=True,
    )
    return json.loads(result.stdout)


def enabled(*paths):
    return {area for area, on in plan(paths=paths).items() if on}


class PlanComponentsTests(unittest.TestCase):
    def test_reports_every_area(self):
        self.assertEqual(set(plan(paths=[]).keys()), AREAS)

    def test_all_turns_everything_on(self):
        self.assertEqual({area for area, on in plan("--all").items() if on}, AREAS)

    def test_each_path_runs_only_its_area(self):
        cases = {
            "web/src/components/ledger/App.tsx": {"web"},
            "web/package.json": {"web"},
            "agent/src/bub_ledger/plugin.py": {"agent"},
            ".agents/skills/telegram-ledger-agent/SKILL.md": {"agent"},
            "server/internal/app/ledger.go": {"backend", "ios", "ios_app"},
            "examples/minimal-ledger/main.bean": {"backend", "ios", "ios_app"},
            "App/LedgerMobile/Sources/RootView.swift": {"ios", "ios_app"},
            "App/LedgerMobile/Tests/LedgerSessionTests.swift": {"ios", "ios_app"},
            "App/LedgerMobile/UITests/LocalLedgerUITests.swift": {"ios", "ios_app"},
            "App/LedgerMobile/ShareExtension/ShareViewController.swift": {"ios", "ios_app"},
            "App/LedgerMobile/WidgetExtension/QuickRecordWidget.swift": {"ios", "ios_widgets"},
            "App/LedgerMobile/WidgetTests/LedgerWidgetVisualTests.swift": {"ios", "ios_widgets"},
            "App/LedgerMobile/project.yml": {"ios", "ios_app", "ios_widgets"},
            "App/LedgerMobile/Package.swift": {"ios"},
            "App/LedgerMobile/FEATURE_PARITY.md": {"ios"},
            "App/LedgerMobile/Runtime/ledger_validator.py": {"ios", "ios_runtime", "backend", "ios_app"},
            "scripts/build-ledgercore-xcframework.sh": {"ios_app"},
            ".github/scripts/ios-app-check.sh": {"ios_app", "ios_widgets"},
            "docker/docker-compose.selfhost.yml": {"selfhost"},
            "scripts/selfhost/beancount-ledger-deploy-submit": {"selfhost"},
            ".env.selfhost.example": {"selfhost"},
            ".github/scripts/test-deploy-selfhost-submit.sh": {"selfhost"},
            ".github/scripts/select-xcode.sh": {"ios", "ios_app", "ios_widgets"},
            "scripts/build-ios-ipa.sh": {"release"},
            "scripts/ios-release-version.sh": {"release"},
            "scripts/publish-sidestore-release.py": {"release"},
            ".github/workflows/ios-release.yml": {"release"},
        }
        for path, expected in cases.items():
            with self.subTest(path=path):
                self.assertEqual(enabled(path), expected)

    def test_shared_widget_sources_come_from_project_yml(self):
        # MoneyText.swift is listed by the widget target; RootView.swift is not.
        self.assertEqual(enabled("App/LedgerMobile/Sources/MoneyText.swift"),
                         {"ios", "ios_app", "ios_widgets"})
        self.assertEqual(enabled("App/LedgerMobile/Resources/Fonts/IBMPlexSans-Regular.ttf"),
                         {"ios", "ios_app", "ios_widgets"})
        project = (ROOT / "App/LedgerMobile/project.yml").read_text()
        self.assertIn("- path: Sources/MoneyText.swift", project)
        self.assertNotIn("- path: Sources/RootView.swift", project)

    def test_documentation_runs_nothing(self):
        self.assertEqual(enabled("README.md", "docs/self-hosted-compose.md", "AGENTS.md"), set())

    def test_pipeline_changes_run_everything(self):
        for path in (".github/workflows/ci.yml", ".github/scripts/plan-components.sh",
                     ".github/scripts/test_plan_components.py"):
            with self.subTest(path=path):
                self.assertEqual(enabled(path), AREAS)

    def test_areas_accumulate_across_paths(self):
        self.assertEqual(enabled("web/src/main.tsx", "agent/pyproject.toml"), {"web", "agent"})


if __name__ == "__main__":
    unittest.main()
