# LedgerMobile

`LedgerMobile` is the native iOS client for Beancount Ledger Web. Financial
review, safe transaction editing, and bill imports reuse the server's existing
validation, confirmation, and rollback boundaries.
The app connects to an existing HTTPS deployment and reuses the server's cookie
authentication and privacy lock.

## Current scope

- Verify a compatible Ledger Web HTTPS origin before accepting a password.
- Restore the Cookie session and read the current month's overview.
- Search and filter transactions by keyword, type, and account, edit safely
  round-trippable entries, and apply tags to up to 200 selected transactions.
- Browse grouped account balances, account details, related transactions, and
  running balances.
- Review Dashboard KPIs, cashflow trends, spending structure, and anomalous
  transactions for the selected date range.
- Track net worth history, browse hierarchical income and expense statements,
  and inspect investment holdings, market values, costs, and returns.
- Run one or more read-only BQL statements, switch numeric results between
  table, bar, pie, and line views, and manage server-synced query history.
- Inspect direct, inverse, and CNY-bridged exchange rates, review recent price
  history, and switch the valuation currency used across overview and analysis.
- Import CSV, Excel, PDF, EML/HTML, and ZIP bills through the system file picker,
  review server-detected providers, duplicate warnings, and candidate entries,
  then commit only the selected transactions. The native screen also shows each
  channel's latest coverage date, update freshness, archived filename, archive
  time, and file size.
- Refresh data, hide amounts, lock sensitive access, and cover App Switcher
  snapshots while the app is inactive.
- Keep financial typography stable by switching constrained amounts to compact
  `w`, `k`, `M`, `B`, and `亿` notation.
- Add Home Screen widgets for current-month spending, a monthly expense
  calendar, a user-selected asset or liability account, and per-channel import
  recency. Widget snapshots contain expense analytics, account balances, and
  reduced import metadata only; income, archived document names and paths,
  cookies, passwords, and quick-unlock tokens stay out of the App Group
  container.
- Keep native Ledger passkey login ready for paid-team signing; Personal Team
  builds use password login and device-level biometric quick unlock.
- Enable Face ID or Touch ID from Settings, then unlock with a server-revocable
  device token protected by the system Keychain.
- Choose an automatic lock interval per server: immediately, 1, 5, 15, or 30
  minutes. App Switcher snapshots remain covered as soon as the app leaves the
  foreground.
- Open More and Settings from the fourth iPhone tab or the bottom of the iPad
  sidebar. The iPad shell supports collapsing and restoring its sidebar.
- Exercise the responsive iPhone and iPad layouts with safe deterministic data
  through the Debug-only visual QA mode.

The next milestones continue mobile web parity for financial review screens.
Additional ledger writes retain a separate preview-and-confirmation design.

## Generate and build

```bash
cd App/LedgerMobile
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild \
    -project LedgerMobile.xcodeproj \
    -scheme LedgerMobile \
    -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath /tmp/ledger-mobile-derived-data \
    CODE_SIGNING_ALLOWED=NO \
    build-for-testing
```

Run the portable model and session tests with `swift test` from this directory.

Apple Silicon Mac can run the same iPad build through Designed for iPad. After
`xcodegen generate`, choose `My Mac (Designed for iPad)` as the run destination
in Xcode. Regenerating the project restores the intended iOS platform settings
if Xcode's recommended-settings migration added a native macOS target locally.

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

The app requires iOS 17 or later and an HTTPS Beancount Ledger Web origin.
Enter the origin only, for example `https://ledger.example.com`. The password
is sent to `/api/auth/login` and is never stored by the app. Biometric quick
unlock stores only the server-issued device token under
`biometryCurrentSet` and `WhenUnlockedThisDeviceOnly` Keychain protection.

## Native passkey deployment

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
