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
                "LedgerGlass.swift",
                "ImportHistoryView.swift",
                "LedgerMobileApp.swift",
                "LocalLedgerViews.swift",
                "LocalLedgerStorageView.swift",
                "LedgerLaunchView.swift",
                "TerminalAnalysisViews.swift",
                "LocalLedgerBackupView.swift",
                "MoreView.swift",
                "NativeImportFlowView.swift",
                "OverviewView.swift",
                "TerminalDesignSystem.swift",
                "BalancedDesignSystem.swift",
                "RootView.swift",
                "SafePreviewLedgerAPI.swift",
                "SettingsView.swift",
                "TimeRangePicker.swift",
                "TransactionViews.swift",
                "TransactionVisualCategory.swift",
                "TransactionShareView.swift",
                "PendingInboxView.swift",
                "EventTagViews.swift",
                "ReconciliationView.swift",
                "AddAccountView.swift",
                "AddCategoryView.swift",
                "CategoriesManagementView.swift",
                "OnboardingWizardView.swift",
                "InstitutionPickerSheet.swift",
                "BeanTransactionImport.swift",
                "BookkeepingPreviewView.swift",
                "NaturalLanguageBookkeepingView.swift",
                "BookkeepingSettingsView.swift",
                "ImportClassificationSettingsView.swift",
                "LedgerIslandEntryView.swift",
                "LedgerAgentView.swift",
                // App-target only: `LocalLedgerPerformanceRecording` drives the
                // opt-in recording from `UserDefaults`/`Bundle` and the view is
                // SwiftUI, so neither belongs to the portable test build. The
                // recorder they talk to (`LocalLedgerPerformanceRecorder`) is
                // portable and listed below.
                "LocalLedgerPerformanceRecording.swift",
                "LocalLedgerPerformanceRecordingView.swift",
            ],
            sources: ["LedgerLocale.swift", "BalancedBucketAxis.swift", "LedgerIslandMotion.swift", "LedgerIslandTypography.swift", "LocalPendingScan.swift", "LocalEventReportExport.swift", "EventReportMarkdownStream.swift", "LocalEventTagReportScan.swift", "LocalEventTagSummaryScan.swift", "LocalAccountTrendScan.swift", "LocalGlobalSearchScan.swift", "LocalTransactionSelectionScan.swift", "LocalTransactionShareExport.swift", "TransactionShareFile.swift", "TransactionShareTextFormatter.swift", "LocalTransactionWindow.swift", "LocalTransactionScan.swift", "AccountPresetModels.swift", "LocalLedgerAutoSyncCoordinator.swift", "LocalCanonicalStreamCache.swift", "LocalModelRequestGate.swift", "LocalLedgerPerformance.swift", "LocalLedgerPerformanceRecorder.swift", "LocalLedgerWidgetPublisher.swift", "LocalLedgerBackgroundProtection.swift", "LocalLedgerBackgroundSyncService.swift", "LogicalLocalStorage.swift", "DeviceLocalStorage.swift", "GitLocalStorage.swift", "FolderLocalStorage.swift", "LocalGitTransport.swift", "LocalGitCredentialStore.swift", "LedgerSharedAccess.swift", "LedgerExternalRoute.swift", "LedgerSharedImportInbox.swift", "LedgerSharedImportApp.swift", "GlobalSearchModels.swift", "APIClient.swift", "BQLModels.swift", "BiometricUnlockService.swift", "CurrencyModels.swift", "ImportIndexActivityAttributes.swift", "ImportIndexActivityCoordinator.swift", "LedgerImportHistory.swift", "LedgerImportModels.swift", "LedgerModels.swift", "LedgerSession.swift", "LedgerWidgetCredentialStore.swift", "LedgerWidgetRefreshClient.swift", "LedgerWidgetSnapshot.swift", "LedgerWidgetSnapshotBuilder.swift", "LocalLedgerWorkspace.swift", "LocalLedgerBackup.swift", "LedgerSession+Backup.swift", "LocalLedgerAuthentication.swift", "LocalLedgerCatalog.swift", "LocalLedgerEngine.swift", "LocalLedgerRepository.swift", "EmbeddedBeancountValidator.swift", "MoneyText.swift", "PasskeyAuthenticationService.swift", "BookkeepingPipeline.swift", "BookkeepingSemanticParser.swift", "BookkeepingSettings.swift", "ImportClassification.swift", "ImportClassificationContext.swift", "ImportClassificationSettings.swift", "LedgerAgent.swift", "LedgerAgentSettings.swift", "BeanTransactionParser.swift", "LedgerImportDraftStore.swift", "ImportReviewQueue.swift", "BookkeepingTextAnalysis.swift", "BookkeepingAccountMatcher.swift", "LocalBookkeepingParser.swift"]
        ),
        .testTarget(
            name: "LedgerMobileTests",
            dependencies: ["LedgerMobile"],
            path: "Tests",
            // These render SwiftUI, load the app bundle or need UIKit, so they
            // stay in the Xcode app-host target instead of the portable package.
            exclude: [
                "CookieFastTransactionEditorTests.swift",
                "LaunchResourceTests.swift",
                "PerfProbeTests.swift",
                "TransactionReceiptRenderingTests.swift",
            ]
        ),
    ]
)
