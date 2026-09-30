# 20260928-ios-all-pages-screenshots

- Status: partial. Updated: 2026-09-28 11:38 +08:00.
- User goal: capture every iOS app page using an iOS simulator and synthetic ledger, and save screenshots in the code directory.
- Acceptance: actual simulator PNGs for every reachable page and distinct functional sheet, extra frames for long pages, a file-to-page index, and visual verification. Do not substitute web screenshots or generated mockups.
- Branch/revision inspected: main / 94c07e6968ccc1224f8a06cdab06dbfd36bf181c. No branch or PR created; this task has only local documentation artifacts so far.
- Completed: inspected native routes, navigation titles, existing UI tests and documented synthetic launch modes. Created App/LedgerMobile/Screenshots/20260928-all-pages/README.md with pending coverage.
- Actual screenshot count: 52 PNG files in App/LedgerMobile/Screenshots/20260928-all-pages/png, plus the partial current-test-page.png. No app code changed; no private ledger opened.
- Previous simulator blocker is resolved. iPhone 17 Pro / iOS 27.0 booted successfully. Full UI run completed; xcodebuild returned exit 65 due to 9 failing tests, while many screenshot-producing tests passed.
- Completed: built and ran the current Debug UI suite, exported the available PNG attachments with xcresulttool, copied 52 PNGs into App/LedgerMobile/Screenshots/20260928-all-pages/png, and wrote INDEX.md. Remaining: separately repair/re-run failed coverage and manually cover pages not touched by the suite.
- Validation: simulator boot, current Debug build, and UI suite executed. Result bundle: /private/tmp/ledger-ui.xcresult. 52 PNGs exported. Failed tests are listed in README/command output. Existing screenshots from older revisions are not accepted as current evidence.
- Files are uncommitted and unpushed, local-only. Preserve unrelated pre-existing work. Local checkpoint could not be created because Git metadata is read-only in this session.

- User explicitly authorized access in the follow-up. Retried simctl at 11:37:58 +08:00; the same Operation not permitted / Connection refused remains. Authorization is granted, but execution permissions have not changed. Screenshot count is now 52 PNGs; full page coverage is not yet complete.
