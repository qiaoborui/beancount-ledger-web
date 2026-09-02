// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LedgerMobileCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(name: "LedgerMobile", targets: ["LedgerMobile"]),
    ],
    targets: [
        .target(
            name: "LedgerMobile",
            path: "Sources",
            exclude: [
                "AccountsView.swift",
                "AnalysisViews.swift",
                "BQLQueryView.swift",
                "CurrencyAnalysisView.swift",
                "DesignSystem.swift",
                "ImportHistoryView.swift",
                "LedgerMobileApp.swift",
                "MoreView.swift",
                "NativeImportFlowView.swift",
                "OverviewView.swift",
                "RootView.swift",
                "SafePreviewLedgerAPI.swift",
                "SettingsView.swift",
                "TimeRangePicker.swift",
                "TransactionViews.swift",
            ],
            sources: ["APIClient.swift", "BQLModels.swift", "BiometricUnlockService.swift", "CurrencyModels.swift", "ImportIndexActivityAttributes.swift", "ImportIndexActivityCoordinator.swift", "LedgerImportHistory.swift", "LedgerImportModels.swift", "LedgerModels.swift", "LedgerSession.swift", "LedgerWidgetSnapshot.swift", "LedgerWidgetSnapshotBuilder.swift", "MoneyText.swift", "PasskeyAuthenticationService.swift"]
        ),
        .testTarget(
            name: "LedgerMobileTests",
            dependencies: ["LedgerMobile"],
            path: "Tests"
        ),
    ]
)
