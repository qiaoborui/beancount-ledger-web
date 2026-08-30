# LedgerMobile

`LedgerMobile` is the native, read-only iOS client for Beancount Ledger Web.
It connects to an existing HTTPS deployment and reuses the server's cookie
authentication and privacy lock.

## Current scope

- Verify a compatible Ledger Web HTTPS origin before accepting a password.
- Restore the Cookie session and read the current month's overview.
- Search and filter transactions by keyword, type, and account, then open the
  transaction detail.
- Browse grouped account balances, account details, related transactions, and
  running balances.
- Review Dashboard KPIs, cashflow trends, spending structure, and anomalous
  transactions for the selected date range.
- Track net worth history, browse hierarchical income and expense statements,
  and inspect investment holdings, market values, costs, and returns.
- Refresh data, hide amounts, lock sensitive access, and cover App Switcher
  snapshots while the app is inactive.
- Keep financial typography stable by switching constrained amounts to compact
  `w`, `k`, `M`, `B`, and `亿` notation.
- Use an existing Ledger passkey as the primary account login on iPhone and
  iPad, with password fallback.
- Enable Face ID or Touch ID from Settings, then unlock with a server-revocable
  device token protected by the system Keychain.
- Choose an automatic lock interval per server: immediately, 1, 5, 15, or 30
  minutes. App Switcher snapshots remain covered as soon as the app leaves the
  foreground.
- Open More and Settings from the fourth iPhone tab or the bottom of the iPad
  sidebar. The iPad shell supports collapsing and restoring its sidebar.
- Exercise the responsive iPhone and iPad layouts with safe deterministic data
  through the Debug-only visual QA mode.

The next read-only milestone adds Agent conversations, BQL queries, and
currency analysis. Ledger writes remain a later phase with a separate
preview-and-confirmation design.

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

## Visual QA

`--safe-preview` is compiled only into Debug builds. It skips account login and
loads deterministic example data containing long account names, large amounts,
all transaction filters, and account history. It cannot activate in a Release
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

The checked-in signing configuration uses Team ID `H92F889YBH`, bundle ID
`com.qiaoborui.ledger.mobile`, and the Associated Domain
`webcredentials:beancount.borry.org`. The production server must meet all of
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
