# Terminal widget implementation captures

47 native SwiftUI widget-body renders exported from iOS 27 simulator tests, using synthetic placeholder data only. These are not SpringBoard screenshots or physical-device acceptance.

Covers seven widget types, small/medium/large families, light/dark, week/month/year, monochrome Lock Screen accessories, privacy-hidden calendar/heatmap, long amounts/account names and empty states. Existing fixture data is retained; the Open Design sample values are not production data.

Run the LedgerWidgetsTests target in the LedgerMobile scheme. Visual tests attach PNGs to the xcresult; export with `xcrun xcresulttool export attachments`.

Design: near-white/graphite, amber heat/chart marks, monospaced amounts, fine dividers, no nested category cards. Preserve actual year-over-year semantics, account valuation, civil-date links and timeline loading. Updated labels use the saved snapshot timestamp. System widget margins/corners remain WidgetKit-owned.

Validation: 17 widget tests passed. Visually inspected overview, account, calendar, trend, heatmap, imports, Lock Screen rectangle, privacy, long and empty outputs. Fixed the initial large-import clipping before exporting this set.
