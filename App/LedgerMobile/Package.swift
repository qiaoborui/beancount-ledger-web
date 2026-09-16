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
                "GlobalSearchView.swift",
                "LedgerAppIntents.swift",
                "AnalysisViews.swift",
                "BQLQueryView.swift",
                "CurrencyAnalysisView.swift",
                "DesignSystem.swift",
                "ImportHistoryView.swift",
                "LedgerMobileApp.swift",
                "LocalLedgerViews.swift",
                "LocalLedgerStorageView.swift",
                "MoreView.swift",
                "NativeImportFlowView.swift",
                "OverviewView.swift",
                "RootView.swift",
                "SafePreviewLedgerAPI.swift",
                "SettingsView.swift",
                "TimeRangePicker.swift",
                "TransactionViews.swift",
                "TransactionVisualCategory.swift",
            ],
            sources: ["LocalLedgerAutoSyncCoordinator.swift", "LocalLedgerWidgetPublisher.swift", "LocalLedgerBackgroundProtection.swift", "LocalLedgerBackgroundSyncService.swift", "LogicalLocalStorage.swift", "DeviceLocalStorage.swift", "GitLocalStorage.swift", "LocalGitTransport.swift", "LocalGitCredentialStore.swift", "LedgerSharedAccess.swift", "LedgerExternalRoute.swift", "LedgerSharedImportInbox.swift", "LedgerSharedImportApp.swift", "GlobalSearchModels.swift", "APIClient.swift", "BQLModels.swift", "BiometricUnlockService.swift", "CurrencyModels.swift", "ImportIndexActivityAttributes.swift", "ImportIndexActivityCoordinator.swift", "LedgerImportHistory.swift", "LedgerImportModels.swift", "LedgerModels.swift", "LedgerSession.swift", "LedgerWidgetCredentialStore.swift", "LedgerWidgetRefreshClient.swift", "LedgerWidgetSnapshot.swift", "LedgerWidgetSnapshotBuilder.swift", "LocalLedgerWorkspace.swift", "LocalLedgerAuthentication.swift", "LocalLedgerCatalog.swift", "LocalLedgerEngine.swift", "LocalLedgerRepository.swift", "EmbeddedBeancountValidator.swift", "MoneyText.swift", "PasskeyAuthenticationService.swift"]
        ),
        .testTarget(
            name: "LedgerMobileTests",
            dependencies: ["LedgerMobile"],
            path: "Tests"
        ),
    ]
)
