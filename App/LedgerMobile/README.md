# LedgerMobile

`LedgerMobile` is a fully local native iOS ledger app. The ledger library offers
creating a ledger, importing a Beancount folder, and downloading a Git workspace.
Settings provides ledger switching and storage configuration.

The app keeps an independent copy in the application's private container
and works without a server. The embedded Go engine handles ledger queries and
staged edits inside the app process. Embedded CPython and the canonical
Beancount parser validate staged changes before an atomic generation switch
publishes them. Local creation, opening, and unlocking use the device's Face ID,
Touch ID, or passcode through LocalAuthentication; a device passcode is required.
The production composition creates only local repositories. Git is an optional
`LogicalLocalStorage` provider: local reads and writes finish on device, while an
explicit synchronization exchanges validated versions with an HTTPS Git remote.

The embedded build currently supports private local builds and tests. Public
IPA redistribution is gated by the unresolved combined dependency licensing
issue documented in [Runtime/THIRD_PARTY.md](Runtime/THIRD_PARTY.md).

## Native interaction design

The iPhone shell owns one navigation stack per tab, including More. Secondary
destinations push in that stack and preserve the system back gesture. The iPad
shell uses a system sidebar and keeps its visibility when changing destinations.
Overview, transactions, accounts, and More use compact, continuous system lists;
settings and editing retain grouped forms. All pages use inline navigation titles.
Range-scoped pages keep the calendar and current period in the navigation bar.
The transactions page carries its own search field above the kind filter bar;
whole-ledger search is its own destination with a native navigation search
field. Period stepping stays in the date picker until confirmation.
Transactions show categories beside notes, with date sections and swipe actions
for tags and confirmed deletion. Accounts show a category filter bar
(全部/资金/信用/理财/应收) over expandable groups; keyword search on that page is
not implemented yet, and `FEATURE_PARITY.md` records it as a known gap.
Editing and import preparation use system forms, searchable account selection,
and navigation-bar confirmation.
See [DESIGN.md](DESIGN.md) for the shared navigation, typography, and privacy rules.

## Current scope

- Create a local ledger with common accounts, import a complete Beancount folder,
  browse and edit `.bean` files, export a copy, and add transactions through a
  preview and confirmation. Imported files retain their original copies.
  Exported ledger snapshots omit imported `.git` metadata; the private workspace
  and original source retain that metadata.
- Validate local writes with canonical Beancount checks. Includes and documents
  stay inside the local workspace; supported plugins are explicitly allowlisted.
  Unsupported plugins and validation failures prevent publication of the change.
  A ledger whose plugin list is not allowlisted therefore cannot be opened at
  all, even read-only; `FEATURE_PARITY.md` tracks that as a known gap.
- Configure HTTPS Git storage with device-only Keychain credentials, pull and
  validate remote changes, and push local revisions with a non-forced ref update.
  Review file conflicts and export both versions before choosing a resolution.
- Automatically synchronize after local saves, on foreground entry/network
  recovery and during iOS-granted background processing opportunities. Disable
  automatic sync per Git workspace or run it immediately. Authentication failures
  and conflicts pause automatic attempts; local saves remain independent.
  Synced local reports update the shared Widget snapshot. Lock-screen work uses
  first-unlock file protection and device-only first-unlock Git credentials;
  actual background and Widget refresh times are controlled by iOS.
- Search and filter transactions by keyword, type, and account, edit safely
  round-trippable entries, and apply tags to up to 200 selected transactions.
- Browse grouped account balances, account details, related transactions, and
  running balances.
- Review Dashboard KPIs, cashflow trends, spending structure, and anomalous
  transactions for the selected date range.
- Track net worth history, browse hierarchical income and expense statements,
  and inspect investment holdings, market values, costs, and returns.
- Run one or more read-only BQL statements, switch numeric results between
  table, bar, pie, and line views. Query history is device-local.
- Inspect direct, inverse, and CNY-bridged exchange rates, review recent price
  history, and switch the valuation currency used across overview and analysis.
- Import CSV, Excel, PDF, ZIP (including encrypted ZIP), and EML/HTML bills through the system file picker,
  review detected providers, duplicate warnings, and candidate entries,
  then commit only the selected transactions. The native screen also shows each
  channel's latest coverage date, update freshness, archived filename, archive
  time, and file size. Local processing uses embedded importers and validates
  the resulting ledger on device.
- Refresh data, hide amounts, lock sensitive access, and cover App Switcher
  snapshots while the app is inactive.
- Keep financial typography stable by switching constrained amounts to compact
  `w`, `k`, `M`, `B`, and `亿` notation.
- Add Home Screen widgets for configurable weekly/monthly/yearly spending, a monthly expense
  calendar, a user-selected asset or liability account, and per-channel import
  recency. Widget snapshots contain expense analytics, account balances, and
  reduced import metadata only; income, archived document names and paths,
  cookies, passwords, and quick-unlock tokens stay out of the App Group
  container. The app publishes reduced snapshots from local reads. Activating a
  local ledger suspends any previously configured widget network credential.
- Tap a date in the medium or large expense calendar widget to open that day's
  expense transactions in a separate native sheet. The app validates the civil
  date and preserves the request through unlock. The sheet owns its data; the
  global date range, active page, and existing search filters stay unchanged.
  The calendar uses four intensity levels, outlines today,
  and shows daily amounts in the large family. It reuses the existing reduced
  widget snapshot and local repository.
- Add a medium 30-day spending trend and a separate 12-week heatmap. Both use
  the existing daily positive-expense series (before refunds); the trend labels
  this explicitly. Weekly/monthly/yearly overview totals retain the report's
  net-expense calculation. Heatmap dates use the same isolated day sheet.
- Configure weekly/monthly/yearly spending on circular, rectangular, and inline
  Lock Screen widgets. Financial content is privacy-sensitive and uses the
  system accessory rendering treatment. A cached period outside the current
  device date displays a refresh prompt.
- The optional `insights` widget payload carries week, year, and 12-week history
  with its own timestamp, populated from local reports.
- Unlock through Face ID, Touch ID, or the device passcode. Cold launch requests
  authentication automatically; returning after the lock interval does the same.
  Canceling leaves a manual retry available.
- Choose an automatic lock interval per ledger: immediately, 1, 5, 15, or 30
  minutes. App Switcher snapshots remain covered as soon as the app leaves the
  foreground.
- Open More and Settings from the fourth iPhone tab or the bottom of the iPad
  sidebar. The iPad shell supports collapsing and restoring its sidebar.
- Exercise the responsive iPhone and iPad layouts with safe deterministic data
  through the Debug-only visual QA mode.

Financial writes retain preview, validation, and confirmation. Gmail automation,
the hosted agent workspace, remote server authentication, and server
administration are outside this local-only product. The optional natural-language
drafting and Jev account classification call a user-configured HTTPS endpoint
with a key the user supplies; every ledger read, validation, and write still runs
on the device. Snapshot backups to a user-chosen folder (normally in iCloud
Drive) are described below.

## Backup and restore (iCloud Drive)

Settings → 本地账本 → 备份与恢复 writes complete snapshots of the open ledger
to a folder the user picks in the system folder picker, normally one inside
iCloud Drive. The app keeps a security-scoped bookmark to that folder, so no
iCloud entitlement, CloudKit container, or paid Apple Developer team is
required, and Personal Team or SideStore builds work unchanged. iCloud Drive
itself uploads the files and makes them visible on the user's other devices.

- Format: one `.ledgerbackup` file per backup (magic header, JSON manifest
  with every file's size and SHA-256, then file bytes). `.git` metadata is
  excluded. Extraction verifies paths, lengths, and hashes before anything
  reaches the ledger, and the restored tree still passes the canonical
  Beancount validation before it is published as a new revision.
- Layout: `<folder>/<ledger ID>/<name>_<UTC time>_<digest>.ledgerbackup`.
  Listings come from file names, so iCloud downloads a backup only when it is
  restored. Every read and write uses `NSFileCoordinator`.
- Conflicts: backups are immutable and uniquely named, so two devices never
  write the same file. A tree whose content digest already exists in the
  ledger's folder is not written again. Retention keeps the newest 30 per
  ledger and only ever deletes files that match the backup naming scheme.
- Restore into the current ledger first backs up the current content, then
  replaces the whole tree as one revision; a save that landed after the user
  confirmed makes the restore fail as stale. For a Git workspace the restored
  tree is an ordinary local change, so a concurrent remote change goes through
  the existing conflict review. "恢复为新账本" and the library's "从备份恢复"
  (any `.ledgerbackup` picked in Files, e.g. on a new device) create a separate
  ledger and never touch existing ones.
- Automatic backup runs at most once a day per ledger while the app is open
  and unlocked, and can be turned off per ledger.

Backups in iCloud Drive are not additionally encrypted by the app; with
Advanced Data Protection enabled Apple encrypts them end to end.

## Multi-device sync (iCloud Drive folder)

Settings → 存储与同步 → 选择 iCloud 云盘文件夹 turns a ledger into a synced
ledger, as an alternative to Git storage. Other devices join it from the
library with "从 iCloud 云盘加入账本" and the same folder. Like backups this
uses a picked folder and a bookmark, not CloudKit or a ubiquity container, so
Personal Team and SideStore builds can use it. The cost is that there is no
push: a device picks up changes when it saves, returns to the foreground, runs
its periodic or background sync, or the user taps 立即同步, and only after
iCloud Drive has downloaded the other device's files.

- Layout: `ledger-sync.json` (name and entry file),
  `snapshots/<content digest>.ledgerbackup` (immutable trees in the backup
  format), and `devices/<configuration ID>.json`, one head per device with the
  digests it has incorporated, newest first.
- Each device only writes its own head, so iCloud never has two writers for
  one file. A head can arrive before its snapshot; that peer is skipped until
  the snapshot is there.
- Merge: every unseen peer head is merged into the local tree with the same
  three-way file merge as Git storage, against the newest digest both sides
  have seen. Conflicting files use the existing review (keep this device's or
  the other device's version). The merge is symmetric, so devices that merge
  each other at the same time publish the same digest and stop.
- Snapshots no head's last 16 entries reference are pruned after three days.

## Generate and build

Build all three native dependencies before generating or building the Xcode
project. Prerequisites are Xcode, XcodeGen, Go (including toolchain download
support), Python 3, Bison 3.8+, and Flex 2.6.4+. On this development machine Xcode
is installed as `Xcode-beta.app`; set `DEVELOPER_DIR` to your installation.
The scripts download pinned build inputs and keep artifacts under ignored
`server/.build/`. Network access is needed to obtain build dependencies.

From the repository root:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
brew install xcodegen bison flex
bash scripts/build-ledgercore-xcframework.sh
bash scripts/build-beancount-ios.sh

cd App/LedgerMobile
xcodegen generate
xcodebuild \
    -project LedgerMobile.xcodeproj \
    -scheme LedgerMobile \
    -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath DerivedData/Local \
    CODE_SIGNING_ALLOWED=NO \
    build-for-testing
```

The resulting dependencies are `LedgerCore.xcframework`,
`BeancountRuntime.xcframework`, and `Python.xcframework`. The project links the
first two statically, embeds Python, and runs
`scripts/build-beancount-ios-resources.sh` to package the standard library,
Python extension frameworks, and license notices before app signing. Rebuild
LedgerCore after Go engine changes and BeancountRuntime after runtime changes.

The current embedded dependency slices support iOS arm64 and iOS Simulator
arm64/x86_64. Mac Catalyst requires additional compatible slices and packaging
work. Use the iOS or simulator destinations for this local build. `project.yml`
retains historical Catalyst settings; local Catalyst support remains pending.

## Local integration and UI tests

After building the three dependencies and generating the project, run the real
Go + CPython integration tests in the app host, alongside workspace, repository,
and session regressions:

```bash
cd App/LedgerMobile
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild test \
    -project LedgerMobile.xcodeproj \
    -scheme LedgerMobile \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0' \
    -derivedDataPath DerivedData/Local \
    -only-testing:LedgerMobileTests/LocalLedgerIntegrationTests \
    -only-testing:LedgerMobileTests/LocalLedgerSessionTests \
    -only-testing:LedgerMobileTests/LocalLedgerRepositoryTests \
    -only-testing:LedgerMobileTests/LocalLedgerWorkspaceTests \
    CODE_SIGNING_ALLOWED=NO

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild test \
    -project LedgerMobile.xcodeproj \
    -scheme LedgerMobile \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0' \
    -derivedDataPath DerivedData/Local \
    -only-testing:LedgerMobileUITests/LocalLedgerUITests \
    CODE_SIGNING_ALLOWED=NO
```

Choose an installed simulator with `xcrun simctl list devices available`.
`LocalLedgerIntegrationTests` uses the production bridges and unique temporary
ledgers for create/read/add/edit/delete/reopen and failed-validation rollback.
`LocalLedgerUITests` drives library creation, a confirmed transaction, and app
restart with an isolated simulator-only authentication fixture. Its
`--local-ui-testing` launch path is Debug/simulator-only; real-device unlock
uses system authentication. Keep these tests separate from the deterministic
`--safe-preview` visual fixtures below.

For a physical app-host integration run, replace the destination with
`platform=iOS,id=<device-identifier>`, use a device-specific derived-data folder,
and allow normal development signing. Test only disposable fixtures and verify
device authentication independently. The simulator-only local UI test skips on
physical devices.

From the repository root, `bash scripts/build-beancount-ios-smoke.sh` builds and
runs a small interpreter smoke app on an already booted simulator. It checks
valid/invalid transactions, balance assertions, and rejected plugin/path input.
`swift test` in `App/LedgerMobile` covers portable code; the embedded runtime
and App Group checks require the corresponding app-host environment.

For UI iteration, build and install on the physical iPhone early for direct
feedback. After the final device-feedback changes, complete regression before
merging the PR: model/session tests, the full iPhone UI suite, and focused small
screen, accessibility, and iPad coverage. Keep automated writes in safe-preview
fixtures and record any independently reproduced baseline failures separately.

## Visual QA

`--safe-preview` is compiled only into Debug builds. It skips account login and
loads deterministic example data containing long account names, large amounts,
all transaction filters, account history, and BQL table/chart results. Add
`--safe-import-flow` to open a simulated bill import with two candidate
transactions and one duplicate. These arguments cannot activate in a Release
build.

Generate the Xcode project, then run the responsive UI suite against an iPhone
and an iPad simulator:

```bash
cd App/LedgerMobile
xcodegen generate

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild test \
    -project LedgerMobile.xcodeproj \
    -scheme LedgerMobile \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0' \
    -only-testing:LedgerMobileUITests

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild test \
    -project LedgerMobile.xcodeproj \
    -scheme LedgerMobile \
    -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5),OS=27.0' \
    -only-testing:LedgerMobileUITests
```

The app requires iOS 17 or later and a device passcode for local ledger access.
Git synchronization supports HTTPS remotes, an explicit branch, and optional
username/token credentials. Adding a Git ledger only reads the remote. Later
synchronization runs automatically when enabled, or immediately from the status
dot. Conflicts require explicit resolution before synchronization resumes.

## iLoader, SideStore and AltStore installation

These notes cover installation and renewal of a private local build. Public
binary distribution remains gated by [the runtime licensing issue](Runtime/THIRD_PARTY.md).
Keep the embedded Python framework and standard-library extension frameworks
when packaging or re-signing; they must receive valid signatures with the app.
### Private GitHub Actions packaging

Open Actions → **iOS SideStore IPA** → **Run workflow**, select `main`, and run
the workflow. The Mac runner builds the embedded Go and Beancount frameworks,
archives the app, and signs Python and all standard-library extension frameworks
before signing the app and its Widget/Share extensions.

The result is uploaded as a private Actions artifact for 7 days and also stays
on the Mac runner at
`~/Downloads/LedgerMobile-PrivateBuilds/<run-id>-<attempt>/`, with owner-only
permissions. Download the artifact from the run summary, extract it, and import
the `.ipa` into SideStore using **+**. It also contains a SHA-256 checksum and
`build-info.txt` with the source commit, app version and actual Xcode/SDK
versions. GitHub retains the private artifact for 7 days. Automatic push builds
remain disabled; the local copy stays until the owner removes it.

For a direct private build, select Xcode through `DEVELOPER_DIR`, then run:

```sh
bash scripts/build-ios-ipa.sh --private-local /absolute/path/to/new-output-directory
```

The parent directory must exist and the output directory must be new. The
explicit private-use flag preserves the public distribution gate.

The workflow uses a dedicated Apple Silicon Mac runner with labels
`self-hosted`, `macOS`, `ARM64`, and `ledger-ios`. It selects the newest Xcode in
`/Applications`, including beta releases, through the job's `DEVELOPER_DIR`.
The Mac's global Xcode selection stays available to other local work. Install
Xcode updates on the runner and complete Apple's first-launch setup before
building. Install XcodeGen, Bison and Flex with Homebrew, plus Go 1.26 or newer
and Python 3 on the runner's PATH (`brew install xcodegen bison flex`).
Register the runner with this repository and the `ledger-ios` label, then run
its bundled `svc.sh install` and `svc.sh start` as the macOS login user. The Mac
must stay awake and the runner service must remain online to accept builds.
Each build uses a separate temporary archive directory and removes it on exit.
IPA packaging accepts manual dispatch only and serializes builds on the Mac;
public pull requests execute through the regular hosted CI workflow.
Before enabling a persistent runner on this public repository, set Actions →
General → Fork pull request workflows to **Require approval for all external
contributors** (`all_external_contributors`). Review workflow changes before
approving those runs: a fork can add a workflow requesting the same runner labels.

Packaging requires no Apple credentials or repository signing secrets. The
Release device archive receives ad-hoc signatures that preserve App Group
entitlements for the installer's discovery step. SideStore supplies the final
Apple ID signature, provisioning profiles and Keychain groups. Keep both
extensions when SideStore asks, and renew with the same Apple ID. Local ledger
access uses Face ID, Touch ID, or the device passcode.

### Shared storage and renewal

Keep the Widget and Share extensions when importing the IPA. The app and both
extensions resolve their shared container from the `ALTAppGroups` mapping added
by SideStore/AltStore. iLoader 2.3.3 omits this metadata for ordinary apps; its
fallback uses the rewritten main bundle ID (`com.qiaoborui.ledger.mobile.TEAMID`),
with the ten-character signing team before the optional `.widgets` or `.share`
suffix. All three bundles resolve `group.<rewritten main bundle ID>`.
Re-signed builds also use that entitled App Group as the
widget credential's Keychain access group, so renewal with the same Apple team
preserves the shared namespace. Direct Xcode installations retain their existing
App Group and Keychain group.

After updating a re-signed build, open Ledger and unlock the local ledger to
republish its reduced widget snapshot. Renew with the same installer and Apple
team to preserve the shared namespace. Changing Apple teams creates a different
shared namespace. A present `ALTAppGroups` value with a missing or ambiguous
Ledger mapping disables widget credential access and takes precedence over the
iLoader fallback.

## Retained remote compatibility code

The production local-only composition rejects remote repositories. Existing
remote authentication code and test fixtures remain in the shared source tree
for compatibility testing. The following deployment notes apply only to a
separately composed remote client; local ledger access uses device-owner auth.

The checked-in Debug and Release configurations support installation with an
Apple Personal Team. They use `Supporting/LedgerMobilePersonal.entitlements`
for the widget App Group and omit Associated Domains, so password login and
Face ID or Touch ID quick unlock remain available while native passkey login
stays hidden.

Enabling native passkeys requires a paid Apple Developer team. Remove the
`PERSONAL_TEAM_BUILD` condition, set `CODE_SIGN_ENTITLEMENTS` to
`Supporting/LedgerMobile.entitlements`, and use Team ID `H92F889YBH` with bundle
ID `com.qiaoborui.ledger.mobile`. The production server must then meet all of
these requirements:

- Serve `/.well-known/apple-app-site-association` over HTTPS with status 200,
  no redirect, and `application/json` content. The Go server exposes this route
  with app ID `H92F889YBH.com.qiaoborui.ledger.mobile`.
- Set `WEBAUTHN_RP_ID=beancount.borry.org`.
- Include `https://beancount.borry.org` in `WEBAUTHN_PUBLIC_ORIGIN` so the
  client data produced by the native Authentication Services ceremony is an
  accepted WebAuthn origin.

Native passkey begin and verify requests run only when the configured API origin
is exactly `https://beancount.borry.org`. This origin binding prevents a
compatible third-party API from relaying a production WebAuthn challenge.
Private mesh origins continue to support password login and device-level
Face ID or Touch ID quick unlock.
