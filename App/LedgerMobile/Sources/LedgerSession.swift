import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

enum LedgerLockInterval: Int, CaseIterable, Equatable, Sendable, Identifiable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .immediately: "立即"
        case .oneMinute: "1 分钟"
        case .fiveMinutes: "5 分钟"
        case .fifteenMinutes: "15 分钟"
        case .thirtyMinutes: "30 分钟"
        }
    }
}

enum LedgerTransactionMutationPhase: Equatable, Sendable {
    case pending
    case confirmed
    case failed(String)

    var blocksFurtherWrites: Bool {
        switch self {
        case .pending, .confirmed: true
        case .failed: false
        }
    }
}

enum LedgerTransactionMutationError: LocalizedError, Equatable {
    case sourceUnavailable
    case alreadyInProgress

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            "找不到这笔交易的最新账本来源，请刷新后重试。"
        case .alreadyInProgress:
            "这笔交易正在由服务器确认，请等待同步完成后再试。"
        }
    }
}

enum LedgerTransactionResolution: Equatable {
    case visible(LedgerTransaction)
    case unavailable
}

private struct LedgerTransactionMutation {
    enum Kind {
        case edit(LedgerTransactionEntry)
        case addTags([String])
        case delete
    }

    let operationID: UUID
    let original: LedgerTransaction
    let projected: LedgerTransaction
    let kind: Kind
    var phase: LedgerTransactionMutationPhase
}

@MainActor
final class LedgerSession: ObservableObject {
    nonisolated static let passkeyRelyingPartyID = "beancount.borry.org"
    nonisolated static var nativePasskeyEnabledForCurrentBuild: Bool {
#if PERSONAL_TEAM_BUILD
        false
#else
        true
#endif
    }

    enum Phase: Equatable {
        case configuration
        case checking
        case locked(authenticated: Bool)
        case ready
    }

    @Published private(set) var phase: Phase
    @Published private(set) var ledger: LedgerBootstrap?
    @Published private(set) var serverURL: URL?
    @Published var serverInput: String
    @Published var password = ""
    @Published var errorMessage: String?
    @Published var amountsVisible = false
    @Published var primaryDestinationID = "overview"
    @Published private(set) var pendingWidgetExpenseDay: String?
    @Published private(set) var compactTabDestinations = LedgerDestination.defaultCompactTabs
    @Published private(set) var selectedRange: LedgerDateRange
    @Published private(set) var draftRange: LedgerDateRange
    @Published private(set) var isRangeLoading = false
    @Published private(set) var isValuationCurrencyLoading = false
    @Published private(set) var accountPeriodBalancesAvailable = false
    @Published var rangePickerPresented = false
    @Published private(set) var passkeyAvailable = false
    @Published private(set) var privacyShielded = true
    @Published private(set) var privacyCoverArmed = false
    @Published private(set) var isAuthenticationBusy = false
    @Published private(set) var isBiometricSettingBusy = false
    @Published private(set) var isWidgetRefreshBusy = false
    @Published private(set) var lockInterval: LedgerLockInterval = .fiveMinutes
    @Published private(set) var importIndexProgress: LedgerImportIndexProgress?
    @Published private(set) var gmailOAuthResult: LedgerGmailOAuthResult?
    @Published private(set) var transactionMutationStates: [String: LedgerTransactionMutationPhase] = [:]
    @Published private(set) var widgetRefreshStatus: LedgerWidgetRefreshStatus

    private let api: any LedgerAPI
    private let biometricStore: any BiometricCredentialStore
    private let passkeyAuthenticator: any PasskeyAuthenticating
    private let widgetSnapshotStore: LedgerWidgetSnapshotStore
    private let widgetCredentialStore: any LedgerWidgetCredentialStoring
    private let widgetRefreshStatusStore: LedgerWidgetRefreshStatusStore
    private var widgetRefreshStatusObserver: LedgerWidgetRefreshStatusObserver?
    private let importIndexActivity: ImportIndexActivityCoordinator
    private let defaults: UserDefaults
    private let ledgerNow: () -> Date
    private var applicationActive = true
    private var automaticUnlockAttempted = false
    private var systemAuthenticationInProgress = false
    private var requestGeneration = 0
    private var sessionEpoch = 0
    private var importIndexTask: Task<Void, Never>?
    private var importIndexGeneration = 0
    private var importIndexRestoreInFlight = false
    private var transactionMutations: [String: LedgerTransactionMutation] = [:]
    private var transactionMutationAliases: [String: String] = [:]
    private var transactionReconciliationTask: Task<Void, Never>?
    private var transactionReconciliationID: UUID?
    private var transactionReconciliationRequested = false
    private var widgetCredentialRegistrationInFlight = false
    private static let serverKey = "ledger.mobile.server-origin"
    private static let locallyLockedOriginsKey = "ledger.mobile.locally-locked-origins"
    private static let lockIntervalsKey = "ledger.mobile.lock-intervals"
    private static let valuationCurrenciesKey = "ledger.mobile.valuation-currencies"
    private static let backgroundDatesKey = "ledger.mobile.background-dates"
    private static let gmailOAuthStatesKey = "ledger.mobile.gmail-oauth-states"
    private static let compactTabsKey = "ledger.mobile.compact-tabs"
    private static let sessionCookieName = "ledger_session"
    private static let sensitiveCookieName = "ledger_sensitive_until"

    init(
        api: (any LedgerAPI)? = nil,
        defaults: UserDefaults = .standard,
        biometricStore: (any BiometricCredentialStore)? = nil,
        passkeyAuthenticator: (any PasskeyAuthenticating)? = nil,
        widgetSnapshotStore: LedgerWidgetSnapshotStore = .shared,
        widgetCredentialStore: (any LedgerWidgetCredentialStoring)? = nil,
        widgetRefreshStatusStore: LedgerWidgetRefreshStatusStore? = nil,
        importIndexActivity: ImportIndexActivityCoordinator = ImportIndexActivityCoordinator(),
        ledgerNow: @escaping () -> Date = Date.init
    ) {
        let initialRange = LedgerDateRange.current(.month, now: ledgerNow())
        selectedRange = initialRange
        draftRange = initialRange
        self.defaults = defaults
        self.ledgerNow = ledgerNow
        self.biometricStore = biometricStore ?? SystemBiometricCredentialStore()
        self.passkeyAuthenticator = passkeyAuthenticator ?? SystemPasskeyAuthenticationService()
        self.widgetSnapshotStore = widgetSnapshotStore
        self.widgetCredentialStore = widgetCredentialStore ?? SystemLedgerWidgetCredentialStore()
        let resolvedWidgetRefreshStatusStore = widgetRefreshStatusStore
            ?? LedgerWidgetRefreshStatusStore(suiteName: widgetSnapshotStore.suiteName)
        self.widgetRefreshStatusStore = resolvedWidgetRefreshStatusStore
        widgetRefreshStatus = resolvedWidgetRefreshStatusStore.load()
            ?? LedgerWidgetRefreshStatus(phase: .waitingForBiometrics)
        self.importIndexActivity = importIndexActivity

        if let api {
            self.api = api
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.httpCookieStorage = .shared
            configuration.httpShouldSetCookies = true
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 40
            self.api = LedgerAPIClient(session: URLSession(configuration: configuration))
        }

        let stored = defaults.string(forKey: Self.serverKey) ?? ""
        compactTabDestinations = Self.storedCompactTabs(in: defaults)
        let normalized = try? ServerConfiguration.normalize(stored)
        serverInput = stored
        serverURL = normalized
        phase = normalized == nil ? .configuration : .checking
        privacyShielded = false
        if let normalized {
            lockInterval = storedLockInterval(for: normalized)
            if isLocallyLocked(normalized) || shouldLockAfterBackground(for: normalized) {
                setLocallyLocked(true, for: normalized)
                clearBackgroundDate(for: normalized)
                phase = .locked(authenticated: true)
            }
        }
        widgetRefreshStatusObserver = LedgerWidgetRefreshStatusObserver(
            store: resolvedWidgetRefreshStatusStore
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.applicationActive else { return }
                self.refreshWidgetRefreshStatus()
            }
        }
    }

    var biometricKind: LedgerBiometricKind {
        biometricStore.biometricKind
    }

    var biometricTitle: String {
        biometricKind.title
    }

    var biometricSystemImage: String {
        biometricKind == .touchID ? "touchid" : "faceid"
    }

    var hasBiometricUnlock: Bool {
        guard let serverURL else { return false }
        return biometricKind != .unavailable && biometricStore.containsCredential(for: serverURL)
    }

    var canUseBiometricUnlock: Bool {
        guard let serverURL else { return false }
        return hasBiometricUnlock && isLocallyLocked(serverURL)
    }

    func start() async {
        if phase == .checking, hasBiometricUnlock, let serverURL {
            lockLocally(for: serverURL)
        }
        await resume()
        await automaticallyUnlockIfNeeded()
    }

    func resume() async {
        guard phase == .checking, let serverURL else { return }
        lockInterval = storedLockInterval(for: serverURL)
        if isLocallyLocked(serverURL) || shouldLockAfterBackground(for: serverURL) {
            setLocallyLocked(true, for: serverURL)
            clearBackgroundDate(for: serverURL)
            amountsVisible = false
            privacyShielded = !applicationActive
            phase = .locked(authenticated: true)
            return
        }
        await checkSession(at: serverURL, generation: requestGeneration)
    }

    func saveServer() async {
        guard case .configuration = phase else { return }
        do {
            let normalized = try ServerConfiguration.normalize(serverInput)
            if serverURL != normalized { resetGlobalSearch() }
            serverURL = normalized
            serverInput = normalized.absoluteString
            errorMessage = nil
            phase = .checking
            let generation = invalidateSession()
            await checkSession(at: normalized, generation: generation, persistOrigin: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func login() async {
        guard case let .locked(authenticated) = phase,
              let serverURL,
              !isAuthenticationBusy else { return }
        let candidate = password
        guard !candidate.isEmpty else {
            errorMessage = "请输入账本密码"
            return
        }

        let generation = invalidateSession()
        isAuthenticationBusy = true
        defer { isAuthenticationBusy = false }
        errorMessage = nil
        do {
            try await api.login(baseURL: serverURL, password: candidate)
            guard generation == requestGeneration else {
                clearAuthenticationCookies(for: serverURL)
                return
            }
            password = ""
            try await loadLedger(from: serverURL, generation: generation)
            guard generation == requestGeneration, phase == .ready else { return }
            setLocallyLocked(false, for: serverURL)
            if let ledger {
                await ensureWidgetCredential(for: serverURL, valuationCurrency: ledger.valuationCurrency)
            }
        } catch {
            guard generation == requestGeneration else { return }
            password = ""
            errorMessage = error.localizedDescription
            phase = .locked(authenticated: authenticated)
        }
    }

    func loginWithPasskey() async {
        guard case let .locked(authenticated) = phase,
              let serverURL,
              passkeyAvailable,
              isTrustedNativePasskeyOrigin(serverURL),
              !isAuthenticationBusy else { return }
        let generation = invalidateSession()
        isAuthenticationBusy = true
        defer { isAuthenticationBusy = false }
        errorMessage = nil
        do {
            let options = try await api.passkeyLoginOptions(baseURL: serverURL)
            let assertion: PasskeyAssertion
            systemAuthenticationInProgress = true
            do {
                defer { systemAuthenticationInProgress = false }
                assertion = try await passkeyAuthenticator.authenticate(
                    options: options,
                    relyingPartyID: Self.passkeyRelyingPartyID
                )
            }
            try await api.verifyPasskey(baseURL: serverURL, assertion: assertion)
            guard generation == requestGeneration else {
                clearAuthenticationCookies(for: serverURL)
                return
            }
            try await loadLedger(from: serverURL, generation: generation)
            guard generation == requestGeneration, phase == .ready else { return }
            setLocallyLocked(false, for: serverURL)
            if let ledger {
                await ensureWidgetCredential(for: serverURL, valuationCurrency: ledger.valuationCurrency)
            }
        } catch {
            guard generation == requestGeneration else { return }
            errorMessage = error.localizedDescription
            phase = .locked(authenticated: authenticated)
        }
    }

    func automaticallyUnlockIfNeeded() async {
        guard applicationActive, case .locked = phase, canUseBiometricUnlock,
              !automaticUnlockAttempted, !isAuthenticationBusy,
              !systemAuthenticationInProgress else { return }
        automaticUnlockAttempted = true
        await unlockWithBiometrics()
    }

    func unlockWithBiometrics() async {
        guard case let .locked(authenticated) = phase,
              let serverURL,
              canUseBiometricUnlock,
              !isAuthenticationBusy else { return }
        automaticUnlockAttempted = true
        let generation = invalidateSession()
        isAuthenticationBusy = true
        defer { isAuthenticationBusy = false }
        errorMessage = nil
        do {
            let credential: QuickUnlockCredential
            systemAuthenticationInProgress = true
            do {
                defer { systemAuthenticationInProgress = false }
                credential = try await biometricStore.readCredential(
                    for: serverURL,
                    reason: "使用 \(biometricTitle) 解锁账本金额"
                )
            }
            guard generation == requestGeneration else { return }
            let usesLocalMarker = credential.deviceID == "local-biometric"
            if ledger != nil {
                setLocallyLocked(false, for: serverURL)
                amountsVisible = applicationActive
                privacyShielded = !applicationActive
                phase = .ready
            }

            var requiresCredentialMigration = usesLocalMarker
            var quickUnlockFailed = false
            if !usesLocalMarker {
                do {
                    try await api.verifyQuickUnlock(baseURL: serverURL, credential: credential)
                    guard generation == requestGeneration else {
                        clearAuthenticationCookies(for: serverURL)
                        return
                    }
                } catch {
                    guard generation == requestGeneration else { return }
                    quickUnlockFailed = true
                    requiresCredentialMigration = true
                }
            }

            var serverAccessConfirmed = false
            if ledger != nil {
                if applicationActive {
                    serverAccessConfirmed = await refreshAfterBiometricUnlock()
                }
            } else {
                try await loadLedger(from: serverURL, generation: generation)
                serverAccessConfirmed = phase == .ready
                if serverAccessConfirmed {
                    setLocallyLocked(false, for: serverURL)
                }
            }
            if case .locked = phase {
                setLocallyLocked(true, for: serverURL)
                if quickUnlockFailed {
                    errorMessage = "Face ID 已通过，但服务器会话已过期，请输入密码重新连接"
                }
            } else {
                if requiresCredentialMigration, serverAccessConfirmed {
                    await migrateLocalBiometricCredential(
                        for: serverURL,
                        replacingDeviceID: usesLocalMarker ? nil : credential.deviceID
                    )
                } else if quickUnlockFailed {
                    errorMessage = "Face ID 已解锁本机数据；服务器暂未同步，刷新后可使用密码重新连接"
                }
                if serverAccessConfirmed, phase == .ready, let ledger {
                    await ensureWidgetCredential(for: serverURL, valuationCurrency: ledger.valuationCurrency)
                }
            }
        } catch {
            guard generation == requestGeneration else { return }
            setLocallyLocked(true, for: serverURL)
            errorMessage = error.localizedDescription
            phase = .locked(authenticated: authenticated)
        }
    }

    func setBiometricUnlockEnabled(_ enabled: Bool) async {
        guard phase == .ready, let serverURL, !isBiometricSettingBusy else { return }
        guard enabled != hasBiometricUnlock else { return }
        isBiometricSettingBusy = true
        errorMessage = nil
        defer { isBiometricSettingBusy = false }

        if enabled {
            do {
                let credential = try await api.registerQuickUnlock(
                    baseURL: serverURL,
                    deviceName: "Ledger iOS · \(biometricTitle)",
                    mode: "text"
                )
                guard phase == .ready, self.serverURL == serverURL else {
                    try? await api.revokeQuickUnlock(baseURL: serverURL, deviceID: credential.deviceID)
                    return
                }
                do {
                    try biometricStore.save(credential, for: serverURL)
                } catch {
                    try? await api.revokeQuickUnlock(baseURL: serverURL, deviceID: credential.deviceID)
                    throw error
                }
                if let ledger {
                    await ensureWidgetCredential(for: serverURL, valuationCurrency: ledger.valuationCurrency)
                }
            } catch {
                errorMessage = "\(biometricTitle) 启用失败：\(error.localizedDescription)"
            }
            return
        }

        do {
            systemAuthenticationInProgress = true
            let credential: QuickUnlockCredential
            do {
                defer { systemAuthenticationInProgress = false }
                credential = try await biometricStore.readCredential(
                    for: serverURL,
                    reason: "验证后停用 \(biometricTitle) 快速解锁"
                )
            }
            guard phase == .ready, self.serverURL == serverURL else { return }
            if widgetCredentialStore.isAvailable,
               let widgetCredential = try widgetCredentialStore.load(),
               widgetCredential.serverOrigin == serverURL.absoluteString {
                try await api.revokeQuickUnlock(baseURL: serverURL, deviceID: widgetCredential.deviceID)
                try widgetCredentialStore.suspend()
                try widgetCredentialStore.completeRevocation(deviceID: widgetCredential.deviceID)
                clearWidgetSnapshot()
            }
            if credential.deviceID != "local-biometric" {
                try await api.revokeQuickUnlock(baseURL: serverURL, deviceID: credential.deviceID)
                guard phase == .ready, self.serverURL == serverURL else { return }
            }
            biometricStore.deleteCredential(for: serverURL)
            recordWidgetRefreshStatus(.waitingForBiometrics)
        } catch {
            errorMessage = "\(biometricTitle) 停用失败：\(error.localizedDescription)"
        }
    }

    func refreshWidgetRefreshStatus() {
        if !hasBiometricUnlock {
            widgetRefreshStatus = LedgerWidgetRefreshStatus(
                phase: .waitingForBiometrics,
                lastAttemptAt: widgetRefreshStatus.lastAttemptAt,
                lastSuccessAt: widgetRefreshStatus.lastSuccessAt
            )
            return
        }
        if let stored = widgetRefreshStatusStore.load() {
            widgetRefreshStatus = stored
        }
    }

    func retryWidgetBackgroundRefresh() async {
        guard phase == .ready,
              let serverURL,
              let ledger,
              !isWidgetRefreshBusy else { return }
        isWidgetRefreshBusy = true
        defer { isWidgetRefreshBusy = false }

        await ensureWidgetCredential(for: serverURL, valuationCurrency: ledger.valuationCurrency)
        refreshWidgetRefreshStatus()
        guard (try? widgetCredentialStore.load()) != nil else { return }

        let loader = LedgerWidgetTimelineLoader(
            credentialStore: widgetCredentialStore,
            snapshotStore: widgetSnapshotStore,
            statusStore: widgetRefreshStatusStore
        )
        _ = await loader.load(now: ledgerNow(), forceRefresh: true)
        refreshWidgetRefreshStatus()
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    func setLockInterval(_ interval: LedgerLockInterval) {
        guard let serverURL else { return }
        lockInterval = interval
        var intervals = defaults.dictionary(forKey: Self.lockIntervalsKey) as? [String: Int] ?? [:]
        intervals[serverURL.absoluteString] = interval.rawValue
        defaults.set(intervals, forKey: Self.lockIntervalsKey)
    }

    func refresh() async {
        _ = await refreshWithResult()
    }

    private func refreshWithResult() async -> Bool {
        guard phase == .ready, let serverURL, !isRangeLoading, !isValuationCurrencyLoading else { return false }
        let generation = invalidateRequests()
        do {
            try await loadLedger(from: serverURL, generation: generation)
            guard generation == requestGeneration else { return false }
            errorMessage = nil
            return true
        } catch {
            guard generation == requestGeneration else { return false }
            errorMessage = error.localizedDescription
            handleBootstrapSessionError(error, serverURL: serverURL)
            return false
        }
    }

    private func refreshAfterBiometricUnlock() async -> Bool {
        guard phase == .ready, let serverURL, !isRangeLoading, !isValuationCurrencyLoading else { return false }
        let generation = invalidateRequests()
        do {
            try await loadLedger(
                from: serverURL,
                generation: generation,
                preserveCachedLedgerOnSensitiveLock: true
            )
            guard generation == requestGeneration else { return false }
            errorMessage = nil
            return true
        } catch {
            guard generation == requestGeneration else { return false }
            errorMessage = "Face ID 已解锁本机数据；服务器同步失败：\(error.localizedDescription)"
            return false
        }
    }

    func setValuationCurrency(_ rawCurrency: String) async {
        guard let serverURL, phase == .ready, !isRangeLoading else { return }
        let currency = rawCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !currency.isEmpty, currency != ledger?.valuationCurrency else { return }

        let generation = invalidateRequests()
        isValuationCurrencyLoading = true
        errorMessage = nil
        do {
            try await loadLedger(
                from: serverURL,
                generation: generation,
                valuationCurrency: currency
            )
            guard generation == requestGeneration else { return }
            isValuationCurrencyLoading = false
            startTransactionReconciliationIfNeeded()
        } catch {
            guard generation == requestGeneration else { return }
            isValuationCurrencyLoading = false
            handleBootstrapSessionError(error, serverURL: serverURL)
            startTransactionReconciliationIfNeeded()
        }
    }

    func accountDetail(for account: String, currency: String) async throws -> LedgerAccountDetail {
        guard phase == .ready, let serverURL else {
            throw LedgerAPIError.incompatibleServer("当前账本会话不可用")
        }
        let generation = requestGeneration
        let range = selectedRange
        do {
            let detail = try await api.accountDetail(
                baseURL: serverURL,
                account: account,
                currency: currency,
                start: range.start,
                end: range.queryEndExclusive
            )
            guard generation == requestGeneration,
                  self.serverURL == serverURL,
                  phase == .ready else {
                throw CancellationError()
            }
            if accountPeriodBalancesAvailable && detail.hasPeriodBalances(start: range.start, end: range.queryEndExclusive) {
                return detail
            }
            return detail.filteredForLegacyServer(
                start: range.start,
                endExclusive: range.queryEndExclusive
            )
        } catch let error as LedgerAPIError {
            if case let .server(status, _) = error,
               status == 423,
               generation == requestGeneration,
               self.serverURL == serverURL,
               phase == .ready {
                clearSensitiveCookie(for: serverURL)
                ledger = nil
                amountsVisible = false
                phase = .locked(authenticated: true)
            }
            throw error
        }
    }

    func analysisResource(_ kind: LedgerAnalysisResourceKind) async throws -> LedgerAnalysisResource {
        guard phase == .ready, let serverURL else {
            throw LedgerAPIError.incompatibleServer("当前账本会话不可用")
        }
        let generation = requestGeneration
        let range = selectedRange
        let valuationCurrency = ledger?.valuationCurrency ?? storedValuationCurrency(for: serverURL)
        do {
            let resource: LedgerAnalysisResource
            switch kind {
            case .assets:
                guard let ledger else {
                    throw LedgerAPIError.incompatibleServer("当前账本数据不可用")
                }
                resource = .assets(
                    LedgerAssetsAnalysis(
                        accountBalances: ledger.accountBalances,
                        accounts: ledger.accounts,
                        netWorthHistory: ledger.netWorthHistory,
                        monthEndNetWorth: ledger.monthEndNetWorth,
                        netWorthWindows: ledger.netWorthWindows,
                        comparisons: ledger.comparisons,
                        valuationCurrency: ledger.valuationCurrency
                    )
                )
            case .incomeExpense:
                async let dashboard = api.dashboard(
                    baseURL: serverURL,
                    start: range.start,
                    end: range.queryEndExclusive,
                    valuationCurrency: valuationCurrency
                )
                async let statement = api.incomeStatement(
                    baseURL: serverURL,
                    start: range.start,
                    end: range.queryEndExclusive,
                    valuationCurrency: valuationCurrency
                )
                let (dashboardValue, statementValue) = try await (dashboard, statement)
                resource = .incomeExpense(
                    LedgerIncomeExpenseAnalysis(
                        dashboard: dashboardValue,
                        statement: statementValue
                    )
                )
            case .investments:
                resource = .investments(try await api.investments(baseURL: serverURL))
            }
            guard generation == requestGeneration,
                  self.serverURL == serverURL,
                  phase == .ready else {
                throw CancellationError()
            }
            return resource
        } catch let error as LedgerAPIError {
            if case let .server(status, _) = error,
               status == 423,
               generation == requestGeneration,
               self.serverURL == serverURL,
               phase == .ready {
                clearSensitiveCookie(for: serverURL)
                ledger = nil
                amountsVisible = false
                phase = .locked(authenticated: true)
            }
            throw error
        }
    }

    func importDocuments() async throws -> [LedgerImportDocument] {
        try await performSensitiveRequest { api, serverURL in
            try await api.importDocuments(baseURL: serverURL)
        }
    }

    func importProviders() async throws -> [LedgerImportProviderInfo] {
        try await performSensitiveRequest { api, serverURL in
            try await api.importProviders(baseURL: serverURL)
        }
    }

    func gmailAutomation() async throws -> (LedgerGmailStatus, [LedgerGmailPendingImport]) {
        try await performSensitiveRequest { api, serverURL in
            async let status = api.gmailStatus(baseURL: serverURL)
            async let pending = api.gmailPendingImports(baseURL: serverURL)
            return try await (status, pending)
        }
    }

    func connectGmail() async throws -> URL {
        let url = try await performSensitiveRequest { api, serverURL in
            let response = try await api.gmailConnect(baseURL: serverURL)
            return response.url
        }
        guard let serverURL,
              let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
              .first(where: { $0.name == "state" })?.value,
              !state.isEmpty else {
            throw LedgerAPIError.invalidResponse
        }
        storePendingGmailOAuthState(state, for: serverURL)
        gmailOAuthResult = nil
        return url
    }

    func syncGmail(pendingID: String? = nil) async throws -> LedgerGmailSyncResult {
        try await performSensitiveRequest { api, serverURL in
            try await api.gmailSync(baseURL: serverURL, pendingID: pendingID)
        }
    }

    func disconnectGmail() async throws {
        try await performSensitiveRequest { api, serverURL in
            try await api.gmailDisconnect(baseURL: serverURL)
        }
        if let serverURL { clearPendingGmailOAuthState(for: serverURL) }
        gmailOAuthResult = nil
    }

    func gmailPendingImport(id: String) async throws -> LedgerGmailPendingDetail {
        try await performSensitiveRequest { api, serverURL in
            try await api.gmailPendingImport(baseURL: serverURL, id: id)
        }
    }

    func dismissGmailPendingImport(id: String) async throws {
        try await performSensitiveRequest { api, serverURL in
            try await api.dismissGmailPendingImport(baseURL: serverURL, id: id)
        }
    }

    func gmailPendingEvents() throws -> AsyncThrowingStream<Void, Error> {
        guard phase == .ready, let serverURL else {
            throw LedgerAPIError.incompatibleServer("当前账本会话不可用")
        }
        return api.gmailPendingEvents(baseURL: serverURL)
    }

    func previewImport(
        file: LedgerImportSelectedFile,
        provider: String?,
        alipayFundRounding: Bool,
        archivePassword: String
    ) async throws -> LedgerImportPreview {
        try await performSensitiveRequest { api, serverURL in
            try await api.previewImport(
                baseURL: serverURL,
                file: file,
                provider: provider,
                alipayFundRounding: alipayFundRounding,
                archivePassword: archivePassword
            )
        }
    }

    func commitImport(
        preview: LedgerImportPreview,
        entries: [LedgerImportEntry]
    ) async throws -> LedgerImportCommitResult {
        try await performSensitiveRequest { api, serverURL in
            try await api.commitImport(
                baseURL: serverURL,
                request: LedgerImportCommitRequest(
                    importID: preview.importID,
                    provider: preview.provider,
                    entries: entries
                )
            )
        }
    }

    func updateTransaction(
        source: TransactionSource,
        entry: LedgerTransactionEntry
    ) async throws {
        guard phase == .ready, serverURL != nil else {
            throw LedgerAPIError.incompatibleServer("当前账本会话不可用")
        }
        guard let original = knownTransaction(source) else {
            throw LedgerTransactionMutationError.sourceUnavailable
        }
        let operationID = UUID()
        let key = Self.transactionMutationKey(source)
        try beginTransactionMutation(
            key: key,
            mutation: LedgerTransactionMutation(
                operationID: operationID,
                original: original,
                projected: original.projecting(entry: entry),
                kind: .edit(entry),
                phase: .pending
            )
        )

        do {
            try await performSensitiveRequest(validatesRequestGeneration: false) { api, baseURL in
                try await api.updateTransaction(baseURL: baseURL, source: source, entry: entry)
            }
            confirmTransactionMutations(keys: [key], operationID: operationID)
            scheduleTransactionReconciliation()
        } catch {
            failTransactionMutations(keys: [key], operationID: operationID, error: error)
            throw error
        }
    }

    func deleteTransaction(source: TransactionSource, reason: String) async throws {
        guard phase == .ready, serverURL != nil else {
            throw LedgerAPIError.incompatibleServer("当前账本会话不可用")
        }
        guard source.hash?.isEmpty == false,
              let original = knownTransaction(source) else {
            throw LedgerTransactionMutationError.sourceUnavailable
        }
        let operationID = UUID()
        let key = Self.transactionMutationKey(source)
        try beginTransactionMutation(key: key, mutation: LedgerTransactionMutation(
            operationID: operationID, original: original, projected: original,
            kind: .delete, phase: .pending
        ))
        do {
            try await performSensitiveRequest(validatesRequestGeneration: false) { api, baseURL in
                try await api.deleteTransaction(baseURL: baseURL, source: source, reason: reason)
            }
            confirmTransactionMutations(keys: [key], operationID: operationID)
            scheduleTransactionReconciliation()
        } catch {
            failTransactionMutations(keys: [key], operationID: operationID, error: error)
            throw error
        }
    }

    private func isConfirmedDeletion(_ source: TransactionSource) -> Bool {
        guard let mutation = transactionMutations[Self.transactionMutationKey(source)],
              case .delete = mutation.kind, mutation.phase == .confirmed else { return false }
        return true
    }

    func addTransactionTags(
        sources: [TransactionSource],
        tags: [String]
    ) async throws {
        guard phase == .ready, serverURL != nil else {
            throw LedgerAPIError.incompatibleServer("当前账本会话不可用")
        }
        let originals = sources.compactMap { source in
            knownTransaction(source)
        }
        guard originals.count == sources.count else {
            throw LedgerTransactionMutationError.sourceUnavailable
        }
        let operationID = UUID()
        let keys = sources.map(Self.transactionMutationKey)
        guard Set(keys).count == keys.count else {
            throw LedgerTransactionMutationError.sourceUnavailable
        }
        guard !keys.contains(where: { transactionMutations[$0]?.phase.blocksFurtherWrites == true }) else {
            throw LedgerTransactionMutationError.alreadyInProgress
        }
        for original in originals {
            let key = Self.transactionMutationKey(original.source)
            try beginTransactionMutation(
                key: key,
                mutation: LedgerTransactionMutation(
                    operationID: operationID,
                    original: original,
                    projected: original.projecting(addingTags: tags),
                    kind: .addTags(tags),
                    phase: .pending
                )
            )
        }

        do {
            try await performSensitiveRequest(validatesRequestGeneration: false) { api, baseURL in
                try await api.addTransactionTags(baseURL: baseURL, sources: sources, tags: tags)
            }
            confirmTransactionMutations(keys: keys, operationID: operationID)
            scheduleTransactionReconciliation()
        } catch {
            failTransactionMutations(keys: keys, operationID: operationID, error: error)
            throw error
        }
    }

    func transactionMutationPhase(for transaction: LedgerTransaction) -> LedgerTransactionMutationPhase? {
        let key = Self.transactionMutationKey(transaction.source)
        let mutationKey = transactionMutationAliases[key] ?? key
        return transactionMutationStates[mutationKey]
    }

    @Published private(set) var globalTransactions: [LedgerTransaction] = []
    private var globalTransactionsLoadedAt: Date?
    var hasCachedGlobalTransactions: Bool { globalTransactionsLoadedAt != nil }

    func loadGlobalTransactions(forceRefresh: Bool = false) async throws {
        if !forceRefresh, phase == .ready,
           let loadedAt = globalTransactionsLoadedAt,
           Date().timeIntervalSince(loadedAt) < 60 { return }
        let payload = try await performSensitiveRequest(validatesRequestGeneration: false) { api, url in
            let payload = try await api.globalTransactions(baseURL: url)
            guard payload.sensitiveUnlocked else {
                throw LedgerAPIError.server(status: 423, message: "服务器敏感数据已锁定")
            }
            return payload
        }
        try Task.checkCancellation()
        reconcileTransactionMutations(in: payload.transactions)
        globalTransactions = payload.transactions
        globalTransactionsLoadedAt = Date()
        if let ledger {
            self.ledger = ledger.replacingTransactions(with: payload.transactions.filter {
                $0.date >= selectedRange.start && $0.date < selectedRange.queryEndExclusive
            })
        }
    }

    var visibleGlobalTransactions: [LedgerTransaction] {
        globalTransactions.filter { !isConfirmedDeletion($0.source) }.map(projectedTransaction)
    }

    private func knownTransaction(_ source: TransactionSource) -> LedgerTransaction? {
        ledger?.transactions.first(where: { $0.source == source })
            ?? globalTransactions.first(where: { $0.source == source })
    }

    var visibleTransactions: [LedgerTransaction] {
        (ledger?.transactions ?? []).filter { !isConfirmedDeletion($0.source) }.map(projectedTransaction)
    }

    func visibleTransaction(matching source: TransactionSource) -> LedgerTransaction? {
        guard case let .visible(transaction) = transactionResolution(for: source) else { return nil }
        return transaction
    }

    func transactionResolution(for source: TransactionSource) -> LedgerTransactionResolution {
        if isConfirmedDeletion(source) { return .unavailable }
        if let transaction = knownTransaction(source) {
            return .visible(projectedTransaction(transaction))
        }
        let key = Self.transactionMutationKey(source)
        guard let mutation = transactionMutations[key] else { return .unavailable }
        switch mutation.phase {
        case .pending, .confirmed:
            return .visible(mutation.projected)
        case .failed:
            return .unavailable
        }
    }

    private func beginTransactionMutation(
        key: String,
        mutation: LedgerTransactionMutation
    ) throws {
        if transactionMutations[key]?.phase.blocksFurtherWrites == true {
            throw LedgerTransactionMutationError.alreadyInProgress
        }
        transactionMutations[key] = mutation
        transactionMutationStates[key] = .pending
    }

    private func confirmTransactionMutations(keys: [String], operationID: UUID) {
        for key in keys {
            guard var mutation = transactionMutations[key], mutation.operationID == operationID else { continue }
            mutation.phase = .confirmed
            transactionMutations[key] = mutation
            transactionMutationStates[key] = .confirmed
        }
    }

    private func failTransactionMutations(keys: [String], operationID: UUID, error: Error) {
        let message = error.localizedDescription
        for key in keys {
            guard var mutation = transactionMutations[key], mutation.operationID == operationID else { continue }
            mutation.phase = .failed(message)
            transactionMutations[key] = mutation
            transactionMutationStates[key] = .failed(message)
        }
    }

    private func projectedTransaction(_ transaction: LedgerTransaction) -> LedgerTransaction {
        let key = Self.transactionMutationKey(transaction.source)
        let mutationKey = transactionMutationAliases[key] ?? key
        guard let mutation = transactionMutations[mutationKey] else { return transaction }
        switch mutation.phase {
        case .pending, .confirmed:
            return mutation.projected
        case .failed:
            return transaction
        }
    }

    private func reconcileTransactionMutations(in serverTransactions: [LedgerTransaction], start: String = "0001-01-01", end: String = "9999-12-31") {
        var reconciledKeys: [String] = []

        for (key, mutation) in transactionMutations {
            guard mutation.original.date >= start, mutation.original.date < end,
                  mutation.projected.date >= start, mutation.projected.date < end else { continue }
            switch mutation.phase {
            case .failed:
                if !serverTransactions.contains(where: { $0.source == mutation.original.source }) {
                    reconciledKeys.append(key)
                }
                continue
            case .confirmed:
                if let satisfied = mutation.uniqueSatisfiedTransaction(in: serverTransactions) {
                    transactionMutationAliases[Self.transactionMutationKey(satisfied.source)] = key
                    reconciledKeys.append(key)
                    continue
                }
                guard serverTransactions.contains(where: { $0.source == mutation.original.source }) else {
                    reconciledKeys.append(key)
                    continue
                }
            case .pending:
                if let satisfied = mutation.uniqueSatisfiedTransaction(in: serverTransactions) {
                    transactionMutationAliases[Self.transactionMutationKey(satisfied.source)] = key
                }
                continue
            }
        }

        for key in reconciledKeys {
            transactionMutations.removeValue(forKey: key)
            transactionMutationStates.removeValue(forKey: key)
            transactionMutationAliases = transactionMutationAliases.filter { $0.value != key }
        }
    }

    private func scheduleTransactionReconciliation() {
        transactionReconciliationRequested = true
        startTransactionReconciliationIfNeeded()
    }

    private func startTransactionReconciliationIfNeeded() {
        guard transactionReconciliationRequested,
              transactionReconciliationTask == nil,
              phase == .ready,
              serverURL != nil,
              !isRangeLoading,
              !isValuationCurrencyLoading else { return }
        let reconciliationID = UUID()
        transactionReconciliationID = reconciliationID
        transactionReconciliationTask = Task { [weak self] in
            guard let self else { return }
            while self.transactionReconciliationID == reconciliationID,
                  self.transactionReconciliationRequested,
                  self.phase == .ready,
                  self.serverURL != nil,
                  !self.isRangeLoading,
                  !self.isValuationCurrencyLoading {
                self.transactionReconciliationRequested = false
                await self.refresh()
            }
            if self.transactionReconciliationID == reconciliationID {
                self.transactionReconciliationTask = nil
                self.transactionReconciliationID = nil
                self.startTransactionReconciliationIfNeeded()
            }
        }
    }

    private func clearTransactionMutations() {
        transactionReconciliationTask?.cancel()
        transactionReconciliationTask = nil
        transactionReconciliationID = nil
        transactionReconciliationRequested = false
        transactionMutations.removeAll()
        transactionMutationStates.removeAll()
        transactionMutationAliases.removeAll()
    }

    private static func transactionMutationKey(_ source: TransactionSource) -> String {
        "\(source.gitSHA ?? "local"):\(source.file):\(source.line):\(source.hash ?? "")"
    }

    private func migrateLocalBiometricCredential(
        for serverURL: URL,
        replacingDeviceID: String? = nil
    ) async {
        do {
            let credential = try await api.registerQuickUnlock(
                baseURL: serverURL,
                deviceName: "Ledger iOS · \(biometricTitle)",
                mode: "text"
            )
            guard phase == .ready, self.serverURL == serverURL else {
                try? await api.revokeQuickUnlock(baseURL: serverURL, deviceID: credential.deviceID)
                return
            }
            do {
                try biometricStore.save(credential, for: serverURL)
            } catch {
                try? await api.revokeQuickUnlock(baseURL: serverURL, deviceID: credential.deviceID)
                throw error
            }
            if let replacingDeviceID, replacingDeviceID != credential.deviceID {
                try? await api.revokeQuickUnlock(baseURL: serverURL, deviceID: replacingDeviceID)
            }
        } catch {
            guard phase == .ready, self.serverURL == serverURL else { return }
            errorMessage = "\(biometricTitle) 快速解锁升级失败，请保持登录后重试"
        }
    }

    private func ensureWidgetCredential(for serverURL: URL, valuationCurrency: String) async {
        guard phase == .ready,
              self.serverURL == serverURL,
              !widgetCredentialRegistrationInFlight else { return }
        guard hasBiometricUnlock else {
            recordWidgetRefreshStatus(.waitingForBiometrics)
            return
        }
        guard widgetCredentialStore.isAvailable else {
            recordWidgetRefreshStatus(.storageUnavailable)
            return
        }

        await Self.revokePendingWidgetCredential(using: api, store: widgetCredentialStore)
        do {
            if try widgetCredentialStore.pendingRevocation() != nil {
                recordWidgetRefreshStatus(.authorizationRejected)
                return
            }
        } catch {
            recordWidgetRefreshStatus(.storageUnavailable)
            return
        }

        do {
            if let existing = try widgetCredentialStore.load() {
                if existing.serverOrigin == serverURL.absoluteString,
                   !Self.widgetCredentialNeedsRotation(existing, now: ledgerNow()) {
                    let updated = existing.updating(valuationCurrency: valuationCurrency, enabled: true)
                    if updated != existing {
                        try widgetCredentialStore.save(updated)
                    }
                    let currentPhase = widgetRefreshStatusStore.load()?.phase
                    if currentPhase == nil
                        || currentPhase == .waitingForBiometrics
                        || currentPhase == .provisioning
                        || currentPhase == .credentialUnavailable
                        || currentPhase == .authorizationRejected
                        || currentPhase == .storageUnavailable {
                        recordWidgetRefreshStatus(.ready)
                    } else {
                        refreshWidgetRefreshStatus()
                    }
                    return
                }
                try widgetCredentialStore.suspend()
                await Self.revokePendingWidgetCredential(using: api, store: widgetCredentialStore)
                if try widgetCredentialStore.pendingRevocation() != nil {
                    recordWidgetRefreshStatus(.authorizationRejected)
                    return
                }
            }
        } catch {
            recordWidgetRefreshStatus(.storageUnavailable)
            return
        }

        widgetCredentialRegistrationInFlight = true
        defer { widgetCredentialRegistrationInFlight = false }
        recordWidgetRefreshStatus(.provisioning)
        do {
            let credential = try await api.registerQuickUnlock(
                baseURL: serverURL,
                deviceName: "Ledger Widget",
                mode: "widget"
            )
            guard phase == .ready, self.serverURL == serverURL else {
                try? await api.revokeQuickUnlock(baseURL: serverURL, deviceID: credential.deviceID)
                return
            }
            do {
                try widgetCredentialStore.save(
                    LedgerWidgetCredential(
                        serverOrigin: serverURL.absoluteString,
                        deviceID: credential.deviceID,
                        token: credential.token,
                        valuationCurrency: valuationCurrency,
                        enabled: true,
                        expiresAt: credential.expiresAt ?? Self.widgetCredentialFallbackExpiration(now: ledgerNow())
                    )
                )
                recordWidgetRefreshStatus(.ready)
                #if canImport(WidgetKit)
                WidgetCenter.shared.reloadAllTimelines()
                #endif
            } catch {
                try? await api.revokeQuickUnlock(baseURL: serverURL, deviceID: credential.deviceID)
                recordWidgetRefreshStatus(.storageUnavailable)
            }
        } catch {
            let failure = Self.widgetRefreshFailure(for: error)
            recordWidgetRefreshStatus(failure.phase, httpStatus: failure.httpStatus)
        }
    }

    private func recordWidgetRefreshStatus(
        _ phase: LedgerWidgetRefreshPhase,
        attemptedAt: Date? = nil,
        succeededAt: Date? = nil,
        httpStatus: Int? = nil
    ) {
        do {
            try widgetRefreshStatusStore.record(
                phase,
                attemptedAt: attemptedAt,
                succeededAt: succeededAt,
                httpStatus: httpStatus
            )
            widgetRefreshStatus = widgetRefreshStatusStore.load()
                ?? LedgerWidgetRefreshStatus(phase: phase, httpStatus: httpStatus)
        } catch {
            widgetRefreshStatus = LedgerWidgetRefreshStatus(
                phase: .storageUnavailable,
                lastAttemptAt: attemptedAt ?? widgetRefreshStatus.lastAttemptAt,
                lastSuccessAt: succeededAt ?? widgetRefreshStatus.lastSuccessAt
            )
        }
    }

    private static func widgetRefreshFailure(
        for error: Error
    ) -> (phase: LedgerWidgetRefreshPhase, httpStatus: Int?) {
        guard let apiError = error as? LedgerAPIError else {
            return (.networkUnavailable, nil)
        }
        switch apiError {
        case let .server(status, _):
            return (.httpFailure(status), status)
        case .incompatibleServer:
            return (.serverOutdated, nil)
        case .transport:
            return (.networkUnavailable, nil)
        case .invalidResponse, .decoding:
            return (.invalidResponse, nil)
        }
    }

    private func suspendWidgetCredential() {
        let api = self.api
        let store = widgetCredentialStore
        let currentCredential = try? store.load()
        do {
            try store.suspend()
        } catch {
            guard let currentCredential else { return }
            Task {
                await Self.revokeWidgetCredential(
                    using: api,
                    store: store,
                    credential: currentCredential
                )
            }
            return
        }
        Task {
            await Self.revokePendingWidgetCredential(using: api, store: store)
        }
    }

    private static func revokeWidgetCredential(
        using api: any LedgerAPI,
        store: any LedgerWidgetCredentialStoring,
        credential: LedgerWidgetCredential
    ) async {
        guard let serverURL = URL(string: credential.serverOrigin) else { return }
        do {
            try await api.revokeWidgetQuickUnlock(baseURL: serverURL, credential: credential)
        } catch let error as LedgerAPIError {
            guard case let .server(status, _) = error, status == 401 else { return }
        } catch {
            return
        }
        try? store.completeRevocation(deviceID: credential.deviceID)
    }

    private static func revokePendingWidgetCredential(
        using api: any LedgerAPI,
        store: any LedgerWidgetCredentialStoring
    ) async {
        let credential: LedgerWidgetCredential
        do {
            guard let pending = try store.pendingRevocation() else { return }
            credential = pending
        } catch {
            return
        }
        guard let serverURL = URL(string: credential.serverOrigin) else { return }
        do {
            try await api.revokeWidgetQuickUnlock(baseURL: serverURL, credential: credential)
        } catch let error as LedgerAPIError {
            guard case let .server(status, _) = error, status == 401 else { return }
        } catch {
            return
        }
        try? store.completeRevocation(deviceID: credential.deviceID)
    }

    private static func widgetCredentialNeedsRotation(_ credential: LedgerWidgetCredential, now: Date) -> Bool {
        guard let rawExpiration = credential.expiresAt,
              let expiration = ISO8601DateFormatter().date(from: rawExpiration) else {
            return true
        }
        return expiration.timeIntervalSince(now) <= 14 * 24 * 60 * 60
    }

    private static func widgetCredentialFallbackExpiration(now: Date) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(90 * 24 * 60 * 60))
    }

    func indexInfo(targetGitSHA: String? = nil) async throws -> LedgerIndexInfo {
        try await performSensitiveRequest { api, serverURL in
            try await api.indexInfo(baseURL: serverURL, targetGitSHA: targetGitSHA)
        }
    }

    func startImportIndexTracking(
        result: LedgerImportCommitResult,
        providerLabel: String,
        baselineGitSHA: String?
    ) {
        importIndexGeneration &+= 1
        let trackingGeneration = importIndexGeneration
        importIndexTask?.cancel()
        importIndexTask = nil
        let targetGitSHA = normalizedGitSHA(result.indexGitSHA)
        let baseline = normalizedGitSHA(baselineGitSHA)
        if result.readModelPending == true, targetGitSHA == nil, baseline == nil {
            importIndexProgress = nil
            Task { await importIndexActivity.end(immediately: true) }
            return
        }
        importIndexProgress = LedgerImportIndexProgress(
            providerLabel: providerLabel,
            entryCount: result.count,
            phase: result.readModelPending == true ? .indexing : .indexed
        )

        guard result.readModelPending == true else {
            Task { await importIndexActivity.end(immediately: true) }
            return
        }

        beginImportIndexPolling(
            providerLabel: providerLabel,
            entryCount: result.count,
            targetGitSHA: targetGitSHA,
            baselineGitSHA: baseline,
            startsActivity: true,
            trackingGeneration: trackingGeneration
        )
    }

    func runBQL(query: String) async throws -> BQLResult {
        let currency = ledger?.valuationCurrency ?? "CNY"
        return try await performSensitiveRequest { api, serverURL in
            try await api.runBQL(
                baseURL: serverURL,
                query: query,
                valuationCurrency: currency
            )
        }
    }

    func loadBQLHistory() async throws -> [BQLHistoryRecord] {
        try await performSensitiveRequest { api, serverURL in
            try await api.bqlHistory(baseURL: serverURL)
        }
    }

    func saveBQLHistory(query: String) async throws -> BQLHistoryRecord {
        try await performSensitiveRequest { api, serverURL in
            try await api.saveBQLHistory(baseURL: serverURL, query: query)
        }
    }

    func generateBQLHistoryTitle(id: String) async throws -> BQLHistoryRecord {
        try await performSensitiveRequest { api, serverURL in
            try await api.generateBQLHistoryTitle(baseURL: serverURL, id: id)
        }
    }

    func renameBQLHistory(id: String, title: String) async throws -> BQLHistoryRecord {
        try await performSensitiveRequest { api, serverURL in
            try await api.renameBQLHistory(baseURL: serverURL, id: id, title: title)
        }
    }

    func deleteBQLHistory(id: String) async throws {
        try await performSensitiveRequest { api, serverURL in
            try await api.deleteBQLHistory(baseURL: serverURL, id: id)
        }
    }

    func presentRangePicker() {
        draftRange = selectedRange
        rangePickerPresented = true
    }

    func dismissRangePicker() {
        rangePickerPresented = false
    }

    func selectDraftPreset(_ preset: LedgerDateRangePreset) {
        guard preset != .custom else { return }
        draftRange = LedgerDateRange.current(preset, now: ledgerNow())
    }

    func moveDraftRange(by delta: Int) {
        draftRange = draftRange.shifted(by: delta)
    }

    func updateDraftStart(_ date: Date) {
        draftRange = LedgerDateRange.custom(start: date, end: max(date, draftRange.endDate))
    }

    func updateDraftEnd(_ date: Date) {
        draftRange = LedgerDateRange.custom(start: min(date, draftRange.startDate), end: date)
    }

    func applyDraftRange() async {
        let range = draftRange
        rangePickerPresented = false
        await applyRange(range)
    }

    func moveRange(by delta: Int) async {
        guard selectedRange.preset != .custom else { return }
        await applyRange(selectedRange.shifted(by: delta))
    }

    func applyRange(_ range: LedgerDateRange) async {
        guard let serverURL, phase == .ready, !isRangeLoading, !isValuationCurrencyLoading else { return }
        let generation = invalidateRequests()
        isRangeLoading = true
        errorMessage = nil
        do {
            try await loadLedger(
                from: serverURL,
                generation: generation,
                range: range
            )
            guard generation == requestGeneration else { return }
            isRangeLoading = false
            startTransactionReconciliationIfNeeded()
        } catch {
            guard generation == requestGeneration else { return }
            isRangeLoading = false
            errorMessage = error.localizedDescription
            startTransactionReconciliationIfNeeded()
        }
    }

    func lock() async {
        guard let serverURL else { return }
        clearBackgroundDate(for: serverURL)
        lockLocally(for: serverURL)
    }

    func logout() {
        guard let serverURL else { return }
        pendingWidgetExpenseDay = nil
        pendingExternalRoute = nil
        externalAccount = nil
        resetGlobalSearch()
        _ = invalidateSession()
        stopImportIndexTracking()
        suspendWidgetCredential()
        clearWidgetSnapshot()
        clearAuthenticationCookies(for: serverURL)
        setLocallyLocked(false, for: serverURL)
        clearBackgroundDate(for: serverURL)
        clearPendingGmailOAuthState(for: serverURL)
        gmailOAuthResult = nil
        clearTransactionMutations()
        ledger = nil
        password = ""
        amountsVisible = false
        isRangeLoading = false
        isValuationCurrencyLoading = false
        rangePickerPresented = false
        privacyShielded = false
        phase = .locked(authenticated: false)
    }

    func changeServer() {
        pendingWidgetExpenseDay = nil
        resetGlobalSearch()
        pendingExternalRoute = nil
        externalAccount = nil
        let previousServerURL = serverURL
        _ = invalidateSession()
        stopImportIndexTracking()
        suspendWidgetCredential()
        clearWidgetSnapshot()
        if let previousServerURL {
            biometricStore.deleteCredential(for: previousServerURL)
            clearAuthenticationCookies(for: previousServerURL)
            setLocallyLocked(false, for: previousServerURL)
            clearBackgroundDate(for: previousServerURL)
            clearPendingGmailOAuthState(for: previousServerURL)
        }
        gmailOAuthResult = nil
        clearTransactionMutations()
        defaults.removeObject(forKey: Self.serverKey)
        ledger = nil
        self.serverURL = nil
        serverInput = ""
        password = ""
        errorMessage = nil
        amountsVisible = false
        let initialRange = LedgerDateRange.current(.month, now: ledgerNow())
        selectedRange = initialRange
        draftRange = initialRange
        isRangeLoading = false
        isValuationCurrencyLoading = false
        rangePickerPresented = false
        passkeyAvailable = false
        accountPeriodBalancesAvailable = false
        lockInterval = .fiveMinutes
        privacyShielded = false
        phase = .configuration
    }

    func updateActivity(isActive: Bool, isBackground: Bool) async {
        let wasActive = applicationActive
        applicationActive = isActive
        if !isActive {
            if privacyCoverArmed || isBackground {
                privacyShielded = true
                privacyCoverArmed = true
                amountsVisible = false
            }
            guard isBackground, let serverURL else { return }
            automaticUnlockAttempted = false
            recordBackgroundDate(for: serverURL)
            if lockInterval == .immediately {
                lockLocally(for: serverURL)
            }
            return
        }

        refreshWidgetRefreshStatus()

        guard let serverURL else {
            privacyShielded = false
            return
        }
        if shouldLockAfterBackground(for: serverURL) {
            lockLocally(for: serverURL)
        }
        clearBackgroundDate(for: serverURL)
        amountsVisible = phase == .ready
        privacyShielded = false
        privacyCoverArmed = true
        guard !wasActive, phase == .ready, !systemAuthenticationInProgress else { return }
        Task { await restoreImportIndexTrackingIfNeeded() }
        await refresh()
    }

    func presentsPrivacyCover(sceneIsActive: Bool) -> Bool {
        privacyCoverArmed && (!sceneIsActive || privacyShielded)
    }

    func toggleAmounts() {
        amountsVisible.toggle()
    }

    func setCompactTabDestinations(_ destinations: [LedgerDestination]) {
        let normalized = LedgerDestination.normalizedCompactTabs(destinations)
        compactTabDestinations = normalized
        defaults.set(normalized.map(\.rawValue), forKey: Self.compactTabsKey)
    }

    private static func storedCompactTabs(in defaults: UserDefaults) -> [LedgerDestination] {
        guard let rawValues = defaults.stringArray(forKey: compactTabsKey) else {
            return LedgerDestination.defaultCompactTabs
        }
        return LedgerDestination.normalizedCompactTabs(rawValues.compactMap(LedgerDestination.init(rawValue:)))
    }

    @Published private(set) var sharedImportRevision = 0

    func receiveSharedFile(_ url: URL) async {
        do {
            try await Task.detached(priority: .userInitiated) {
                _ = try LedgerSharedImportInbox.appInbox().enqueue(fileURL: url)
            }.value
            sharedImportRevision += 1
            primaryDestinationID = LedgerDestination.imports.rawValue
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @Published private(set) var pendingExternalRoute: LedgerExternalRouteRequest?
    @Published var externalAccount: LedgerExternalAccount?
    @Published var globalSearchQuery = ""
    @Published var globalSearchScope: LedgerGlobalSearchScope = .all
    @Published var globalSearchFilters = LedgerGlobalSearchFilters()
    @Published private(set) var recentGlobalSearches: [String] = []

    func recordGlobalSearch(_ query: String) {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 500 else { return }
        let locale = Locale(identifier: "en_US_POSIX")
        let key = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
        recentGlobalSearches.removeAll {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale) == key
        }
        recentGlobalSearches.insert(value, at: 0)
        recentGlobalSearches = Array(recentGlobalSearches.prefix(10))
    }

    func clearRecentGlobalSearches() { recentGlobalSearches = [] }

    private func resetGlobalSearch() {
        globalSearchQuery = ""
        globalSearchScope = .all
        globalSearchFilters = LedgerGlobalSearchFilters()
        clearRecentGlobalSearches()
    }

    private func prepareExternalSearch(_ query: String) {
        globalSearchScope = .all
        globalSearchFilters = LedgerGlobalSearchFilters()
        if globalSearchQuery != query { globalSearchQuery = query }
    }

    func applyPendingExternalRoute() async {
        guard phase == .ready, !isRangeLoading, !isValuationCurrencyLoading,
              let request = pendingExternalRoute else { return }
        switch request.route {
        case .page: break
        case let .account(path, currency):
            if let account = ledger?.accounts.first(where: { $0.account == path }) {
                externalAccount = LedgerExternalAccount(account: path, currency: currency.isEmpty ? account.currency : currency)
            } else {
                errorMessage = "当前账本中找不到这个账户"
            }
        case let .transactions(day):
            if let date = LedgerExternalRoute.date(day) {
                await applyRange(.custom(start: date, end: date))
            }
        case let .search(query):
            prepareExternalSearch(query)
        }
        if pendingExternalRoute?.id == request.id { pendingExternalRoute = nil }
    }

    func openWidgetURL(_ url: URL) {
        guard url.scheme?.lowercased() == "ledger" else { return }
        if url.host?.lowercased() == "transactions",
           let day = LedgerWidgetLink.expenseDay(from: url) {
            pendingWidgetExpenseDay = day
            return
        }
        if url.host?.lowercased() != "gmail-import" {
            guard let route = LedgerExternalRoute.parse(url) else { return }
            if case let .search(query) = route, phase == .ready { prepareExternalSearch(query) }
            pendingWidgetExpenseDay = nil
            primaryDestinationID = route.destination.rawValue
            pendingExternalRoute = LedgerExternalRouteRequest(route: route)
            return
        }
        switch url.host?.lowercased() {
        case "gmail-import":
            primaryDestinationID = "imports"
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let serverURL,
                  let returnedState = query.first(where: { $0.name == "state" })?.value,
                  consumePendingGmailOAuthState(returnedState, for: serverURL) else { return }
            let statusValue = query.first(where: { $0.name == "gmail" })?.value ?? ""
            let status = LedgerGmailOAuthResult.Status(rawValue: statusValue) ?? .error
            let reasonValue = query.first(where: { $0.name == "reason" })?.value
            let reason = ["cancelled", "callback_failed"].contains(reasonValue ?? "") ? reasonValue : nil
            gmailOAuthResult = LedgerGmailOAuthResult(
                id: UUID(),
                status: status,
                reason: reason
            )
        case "overview":
            pendingWidgetExpenseDay = nil
            primaryDestinationID = "overview"
        default:
            break
        }
    }

    var canPresentWidgetDay: Bool {
        pendingWidgetExpenseDay != nil && phase == .ready
            && !isAuthenticationBusy
    }

    func dismissWidgetDay() {
        pendingWidgetExpenseDay = nil
    }

    /// A day drill-down owns its payload and never replaces the global range or ledger.
    func widgetDayLedger(_ day: String) async throws -> LedgerBootstrap {
        guard LedgerWidgetLink.isValidDay(day) else {
            throw LedgerAPIError.incompatibleServer("无效的消费日期")
        }
        let range = LedgerDateRange(start: day, end: day, preset: .custom)
        let today = LedgerDateRange.today(now: ledgerNow())
        let currency = ledger?.valuationCurrency ?? "CNY"
        return try await performSensitiveRequest(validatesRequestGeneration: false) { api, serverURL in
            let payload = try await api.bootstrap(
                baseURL: serverURL, start: range.start, end: range.queryEndExclusive,
                today: today, valuationCurrency: currency
            )
            guard payload.sensitiveUnlocked else {
                throw LedgerAPIError.server(status: 423, message: "服务器敏感数据已锁定")
            }
            return payload
        }
    }

    func consumeGmailOAuthResult(id: UUID) {
        guard gmailOAuthResult?.id == id else { return }
        gmailOAuthResult = nil
    }

    func dismissError() {
        errorMessage = nil
    }

    private func checkSession(at serverURL: URL, generation: Int, persistOrigin: Bool = false) async {
        errorMessage = nil
        do {
            let health = try await api.health(baseURL: serverURL)
            try health.validateForMobileClient()
            let auth = try await api.authStatus(baseURL: serverURL)
            let passkeyStatus = isTrustedNativePasskeyOrigin(serverURL)
                ? try? await api.passkeyStatus(baseURL: serverURL)
                : nil
            guard generation == requestGeneration else { return }
            accountPeriodBalancesAvailable = health.supportsAccountPeriodBalances
            privacyShielded = !applicationActive
            if persistOrigin {
                defaults.set(serverURL.absoluteString, forKey: Self.serverKey)
            }
            passkeyAvailable = passkeyStatus?.registered == true
            lockInterval = storedLockInterval(for: serverURL)
            clearBackgroundDate(for: serverURL)
            if isLocallyLocked(serverURL) {
                ledger = nil
                amountsVisible = false
                phase = .locked(authenticated: true)
            } else if auth.authDisabled {
                setLocallyLocked(false, for: serverURL)
                try await loadLedger(from: serverURL, generation: generation)
            } else if auth.authenticated && auth.sensitiveUnlocked {
                try await loadLedger(from: serverURL, generation: generation)
            } else {
                phase = .locked(authenticated: auth.authenticated)
            }
        } catch {
            guard generation == requestGeneration else { return }
            errorMessage = error.localizedDescription
            ledger = nil
            amountsVisible = false
            privacyShielded = false
            phase = .configuration
        }
    }

    private func loadLedger(
        from serverURL: URL,
        generation: Int,
        range: LedgerDateRange? = nil,
        valuationCurrency: String? = nil,
        preserveCachedLedgerOnSensitiveLock: Bool = false
    ) async throws {
        let targetRange = range ?? selectedRange
        let targetCurrency = valuationCurrency ?? storedValuationCurrency(for: serverURL)
        let payload = try await api.bootstrap(
            baseURL: serverURL,
            start: targetRange.start,
            end: targetRange.queryEndExclusive,
            today: LedgerDateRange.today(now: ledgerNow()),
            valuationCurrency: targetCurrency
        )
        guard generation == requestGeneration else { return }
        guard payload.sensitiveUnlocked else {
            if preserveCachedLedgerOnSensitiveLock, ledger != nil {
                throw LedgerAPIError.server(status: 423, message: "服务器敏感数据已锁定")
            }
            _ = invalidateSession()
            clearTransactionMutations()
            ledger = nil
            amountsVisible = false
            phase = .locked(authenticated: true)
            return
        }
        if !globalTransactions.isEmpty {
            globalTransactions.removeAll { transaction in
                if payload.transactions.contains(where: { $0.source == transaction.source }) { return true }
                let key = Self.transactionMutationKey(transaction.source)
                if let mutation = transactionMutations[transactionMutationAliases[key] ?? key],
                   mutation.phase.blocksFurtherWrites {
                    if case .delete = mutation.kind, mutation.phase == .confirmed {
                        return transaction.date >= targetRange.start && transaction.date < targetRange.queryEndExclusive
                    }
                    return mutation.uniqueSatisfiedTransaction(in: payload.transactions) != nil
                }
                return transaction.date >= targetRange.start && transaction.date < targetRange.queryEndExclusive
            }
            globalTransactions.append(contentsOf: payload.transactions)
        }
        reconcileTransactionMutations(in: payload.transactions, start: targetRange.start, end: targetRange.queryEndExclusive)
        ledger = payload
        storeValuationCurrency(payload.valuationCurrency, for: serverURL)
        selectedRange = targetRange
        amountsVisible = applicationActive
        privacyShielded = !applicationActive
        if let route = pendingExternalRoute?.route, case let .search(query) = route {
            prepareExternalSearch(query)
        }
        phase = .ready
        Task { await restoreImportIndexTrackingIfNeeded() }
        await publishWidgetSnapshot(
            ledger: payload,
            serverURL: serverURL,
            valuationCurrency: payload.valuationCurrency,
            generation: generation
        )
    }

    private func beginImportIndexPolling(
        providerLabel: String,
        entryCount: Int,
        targetGitSHA: String?,
        baselineGitSHA: String?,
        startsActivity: Bool,
        trackingGeneration: Int
    ) {
        importIndexTask = Task { [weak self] in
            guard let self else { return }
            if startsActivity {
                await self.importIndexActivity.start(
                    providerLabel: providerLabel,
                    entryCount: entryCount,
                    targetGitSHA: targetGitSHA,
                    baselineGitSHA: baselineGitSHA
                )
            }
            guard !Task.isCancelled, self.importIndexGeneration == trackingGeneration else { return }
            var attempts = 0
            while !Task.isCancelled, attempts < 600 {
                attempts += 1
                let info = try? await self.indexInfo(targetGitSHA: targetGitSHA)
                guard !Task.isCancelled, self.importIndexGeneration == trackingGeneration else { return }
                if let info,
                   self.indexHasAdvanced(
                       info,
                       targetGitSHA: targetGitSHA,
                       baselineGitSHA: baselineGitSHA
                   ) {
                    self.importIndexProgress = LedgerImportIndexProgress(
                        providerLabel: providerLabel,
                        entryCount: entryCount,
                        phase: .indexed
                    )
                    await self.importIndexActivity.complete()
                    if self.importIndexGeneration == trackingGeneration {
                        self.importIndexTask = nil
                    }
                    return
                }
                if attempts.isMultiple(of: 20) {
                    await self.importIndexActivity.updateIndexing()
                }
                try? await Task.sleep(for: .seconds(1))
            }
            if self.importIndexGeneration == trackingGeneration {
                self.importIndexTask = nil
            }
        }
    }

    private func restoreImportIndexTrackingIfNeeded() async {
        guard applicationActive, phase == .ready, importIndexTask == nil,
              !importIndexRestoreInFlight else { return }
        importIndexRestoreInFlight = true
        let trackingGeneration = importIndexGeneration
        defer { importIndexRestoreInFlight = false }
        guard let pending = await importIndexActivity.restorePending(),
              trackingGeneration == importIndexGeneration else { return }
        if pending.phase == "indexed" {
            await importIndexActivity.complete()
            return
        }
        let targetGitSHA = normalizedGitSHA(pending.targetGitSHA)
        let baselineGitSHA = normalizedGitSHA(pending.baselineGitSHA)
        guard targetGitSHA != nil || baselineGitSHA != nil else {
            await importIndexActivity.end(immediately: true)
            return
        }
        importIndexProgress = LedgerImportIndexProgress(
            providerLabel: pending.providerLabel,
            entryCount: pending.entryCount,
            phase: .indexing
        )
        beginImportIndexPolling(
            providerLabel: pending.providerLabel,
            entryCount: pending.entryCount,
            targetGitSHA: targetGitSHA,
            baselineGitSHA: baselineGitSHA,
            startsActivity: false,
            trackingGeneration: trackingGeneration
        )
    }

    private func indexHasAdvanced(
        _ info: LedgerIndexInfo,
        targetGitSHA: String?,
        baselineGitSHA: String?
    ) -> Bool {
        guard info.enabled, info.active == true else { return false }
        if info.requestCompleted == true {
            return true
        }
        guard let current = normalizedGitSHA(info.gitSHA) else { return false }
        if let targetGitSHA {
            return current.caseInsensitiveCompare(targetGitSHA) == .orderedSame
        }
        if let baselineGitSHA {
            return current.caseInsensitiveCompare(baselineGitSHA) != .orderedSame
        }
        return false
    }

    private func normalizedGitSHA(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else { return nil }
        return normalized
    }

    private func stopImportIndexTracking() {
        importIndexGeneration &+= 1
        importIndexTask?.cancel()
        importIndexTask = nil
        importIndexProgress = nil
        Task { await importIndexActivity.end(immediately: true) }
    }

    private func publishWidgetSnapshot(
        ledger: LedgerBootstrap,
        serverURL: URL,
        valuationCurrency: String,
        generation: Int
    ) async {
        let widgetRefreshAttemptAt = ledgerNow()
        let month = LedgerDateRange.current(.month, now: widgetRefreshAttemptAt)
        let today = LedgerDateRange.today(now: widgetRefreshAttemptAt)
        let weekStart = LedgerWidgetDates.weekStart(today)
        async let weekRequest: LedgerHomeReport? = try? await api.homeReport(
            baseURL: serverURL, start: weekStart, end: LedgerWidgetDates.adding(7, to: weekStart),
            valuationCurrency: valuationCurrency
        )
        async let yearRequest: LedgerHomeReport? = try? await api.homeReport(
            baseURL: serverURL, start: String(today.prefix(4)) + "-01-01",
            end: String((Int(today.prefix(4)) ?? 2026) + 1) + "-01-01", valuationCurrency: valuationCurrency
        )
        async let historyRequest: LedgerHomeReport? = try? await api.homeReport(
            baseURL: serverURL, start: LedgerWidgetDates.adding(-77, to: weekStart),
            end: LedgerWidgetDates.adding(1, to: today), valuationCurrency: valuationCurrency
        )
        async let reportRequest: LedgerHomeReport? = try? await api.homeReport(
            baseURL: serverURL,
            start: month.start,
            end: month.queryEndExclusive,
            valuationCurrency: valuationCurrency
        )
        async let importDocumentsRequest: [LedgerImportDocument]? = try? await api.importDocuments(
            baseURL: serverURL
        )
        let (report, importDocuments, week, year, history) = await (reportRequest, importDocumentsRequest, weekRequest, yearRequest, historyRequest)
        guard generation == requestGeneration, self.serverURL == serverURL else {
            return
        }
        await ensureWidgetCredential(for: serverURL, valuationCurrency: valuationCurrency)
        guard let report else {
            return
        }
        let freshSnapshot = LedgerWidgetSnapshotBuilder.make(
            report: report,
            ledger: ledger,
            importDocuments: importDocuments ?? [],
            importsUpdatedAt: importDocuments == nil ? nil : Date()
        )
        var snapshot: LedgerWidgetSnapshot
        if importDocuments == nil, let previous = widgetSnapshotStore.load() {
            snapshot = LedgerWidgetSnapshot(
                updatedAt: freshSnapshot.updatedAt,
                expense: freshSnapshot.expense,
                accounts: freshSnapshot.accounts,
                imports: previous.imports,
                importsUpdatedAt: previous.importsUpdatedAt
            )
        } else {
            snapshot = freshSnapshot
        }
        if let week, let year, let history {
            snapshot.insights = LedgerWidgetExpenseInsights(
                updatedAt: ISO8601DateFormatter().string(from: widgetRefreshAttemptAt),
                week: LedgerWidgetSnapshotBuilder.make(report: week, ledger: ledger).expense,
                year: LedgerWidgetSnapshotBuilder.make(report: year, ledger: ledger).expense,
                history: LedgerWidgetSnapshotBuilder.make(report: history, ledger: ledger).expense
            )
        } else if let previous = widgetSnapshotStore.load()?.insights, previous.history.currency == report.currency {
            snapshot.insights = previous
        }
        guard (try? widgetSnapshotStore.saveIfNewer(
            snapshot,
            attemptedAt: widgetRefreshAttemptAt
        )) != nil else { return }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    private func clearWidgetSnapshot() {
        widgetSnapshotStore.clear()
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    private func handleBootstrapSessionError(_ error: Error, serverURL: URL) {
        errorMessage = error.localizedDescription
        guard let apiError = error as? LedgerAPIError,
              case let .server(status, _) = apiError,
              status == 401 || status == 423 else { return }
        _ = invalidateSession()
        clearTransactionMutations()
        ledger = nil
        amountsVisible = false
        if status == 401 {
            clearAuthenticationCookies(for: serverURL)
            setLocallyLocked(false, for: serverURL)
            phase = .locked(authenticated: false)
        } else {
            clearSensitiveCookie(for: serverURL)
            phase = .locked(authenticated: true)
        }
    }

    private func storedValuationCurrency(for serverURL: URL) -> String {
        let currencies = defaults.dictionary(forKey: Self.valuationCurrenciesKey) as? [String: String]
        let stored = currencies?[serverURL.absoluteString]?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let stored, !stored.isEmpty { return stored }
        return "CNY"
    }

    private func storeValuationCurrency(_ currency: String, for serverURL: URL) {
        let normalized = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return }
        var currencies = defaults.dictionary(forKey: Self.valuationCurrenciesKey) as? [String: String] ?? [:]
        currencies[serverURL.absoluteString] = normalized
        defaults.set(currencies, forKey: Self.valuationCurrenciesKey)
    }

    private func storePendingGmailOAuthState(_ state: String, for serverURL: URL) {
        var states = pendingGmailOAuthStates()
        var values = states[serverURL.absoluteString] ?? []
        values.removeAll { $0 == state }
        values.append(state)
        states[serverURL.absoluteString] = Array(values.suffix(8))
        savePendingGmailOAuthStates(states)
    }

    private func consumePendingGmailOAuthState(_ state: String, for serverURL: URL) -> Bool {
        var states = pendingGmailOAuthStates()
        guard var values = states[serverURL.absoluteString],
              let index = values.firstIndex(of: state) else { return false }
        values.remove(at: index)
        if values.isEmpty {
            states.removeValue(forKey: serverURL.absoluteString)
        } else {
            states[serverURL.absoluteString] = values
        }
        savePendingGmailOAuthStates(states)
        return true
    }

    private func clearPendingGmailOAuthState(for serverURL: URL) {
        var states = pendingGmailOAuthStates()
        states.removeValue(forKey: serverURL.absoluteString)
        savePendingGmailOAuthStates(states)
    }

    private func pendingGmailOAuthStates() -> [String: [String]] {
        guard let data = defaults.data(forKey: Self.gmailOAuthStatesKey),
              let states = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return states
    }

    private func savePendingGmailOAuthStates(_ states: [String: [String]]) {
        if states.isEmpty {
            defaults.removeObject(forKey: Self.gmailOAuthStatesKey)
        } else if let data = try? JSONEncoder().encode(states) {
            defaults.set(data, forKey: Self.gmailOAuthStatesKey)
        }
    }

    private func performSensitiveRequest<Value: Sendable>(
        validatesRequestGeneration: Bool = true,
        _ operation: @Sendable (any LedgerAPI, URL) async throws -> Value
    ) async throws -> Value {
        guard phase == .ready, let serverURL else {
            throw LedgerAPIError.incompatibleServer("当前账本会话不可用")
        }
        let generation = requestGeneration
        let epoch = sessionEpoch
        do {
            let value = try await operation(api, serverURL)
            guard (!validatesRequestGeneration || generation == requestGeneration),
                  epoch == sessionEpoch,
                  self.serverURL == serverURL,
                  phase == .ready else {
                throw CancellationError()
            }
            return value
        } catch let error as LedgerAPIError {
            if case let .server(status, _) = error,
               status == 401 || status == 423,
               (!validatesRequestGeneration || generation == requestGeneration),
               epoch == sessionEpoch,
                self.serverURL == serverURL,
                phase == .ready {
                _ = invalidateSession()
                clearTransactionMutations()
                ledger = nil
                amountsVisible = false
                if status == 401 {
                    clearAuthenticationCookies(for: serverURL)
                    setLocallyLocked(false, for: serverURL)
                    phase = .locked(authenticated: false)
                } else {
                    clearSensitiveCookie(for: serverURL)
                    phase = .locked(authenticated: true)
                }
            }
            throw error
        }
    }

    @discardableResult
    private func invalidateRequests() -> Int {
        requestGeneration &+= 1
        return requestGeneration
    }

    @discardableResult
    private func invalidateSession() -> Int {
        globalTransactions = []
        globalTransactionsLoadedAt = nil
        sessionEpoch &+= 1
        return invalidateRequests()
    }

    private func clearAuthenticationCookies(for serverURL: URL) {
        clearCookies(named: [Self.sessionCookieName, Self.sensitiveCookieName], for: serverURL)
    }

    private func clearSensitiveCookie(for serverURL: URL) {
        clearCookies(named: [Self.sensitiveCookieName], for: serverURL)
    }

    private func clearCookies(named names: Set<String>, for serverURL: URL) {
        guard let host = serverURL.host else { return }
        for cookie in HTTPCookieStorage.shared.cookies ?? [] {
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if names.contains(cookie.name), host == domain || host.hasSuffix(".\(domain)") {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
    }

    private func isLocallyLocked(_ serverURL: URL) -> Bool {
        Set(defaults.stringArray(forKey: Self.locallyLockedOriginsKey) ?? []).contains(serverURL.absoluteString)
    }

    private func setLocallyLocked(_ locked: Bool, for serverURL: URL) {
        var origins = Set(defaults.stringArray(forKey: Self.locallyLockedOriginsKey) ?? [])
        if locked {
            origins.insert(serverURL.absoluteString)
        } else {
            origins.remove(serverURL.absoluteString)
        }
        defaults.set(origins.sorted(), forKey: Self.locallyLockedOriginsKey)
    }

    private func storedLockInterval(for serverURL: URL) -> LedgerLockInterval {
        let intervals = defaults.dictionary(forKey: Self.lockIntervalsKey) as? [String: Int]
        guard let rawValue = intervals?[serverURL.absoluteString],
              let interval = LedgerLockInterval(rawValue: rawValue) else {
            return .fiveMinutes
        }
        return interval
    }

    private func isTrustedNativePasskeyOrigin(_ serverURL: URL) -> Bool {
        nativePasskeyEnabled
            && serverURL.scheme?.lowercased() == "https"
            && serverURL.host?.lowercased() == Self.passkeyRelyingPartyID
            && serverURL.port == nil
    }

    private var nativePasskeyEnabled: Bool {
        Self.nativePasskeyEnabledForCurrentBuild
    }

    private func recordBackgroundDate(for serverURL: URL, now: Date? = nil) {
        var dates = defaults.dictionary(forKey: Self.backgroundDatesKey) as? [String: Double] ?? [:]
        guard dates[serverURL.absoluteString] == nil else { return }
        dates[serverURL.absoluteString] = (now ?? ledgerNow()).timeIntervalSince1970
        defaults.set(dates, forKey: Self.backgroundDatesKey)
    }

    private func clearBackgroundDate(for serverURL: URL) {
        var dates = defaults.dictionary(forKey: Self.backgroundDatesKey) as? [String: Double] ?? [:]
        dates.removeValue(forKey: serverURL.absoluteString)
        defaults.set(dates, forKey: Self.backgroundDatesKey)
    }

    private func shouldLockAfterBackground(for serverURL: URL, now: Date? = nil) -> Bool {
        let dates = defaults.dictionary(forKey: Self.backgroundDatesKey) as? [String: Double]
        guard let timestamp = dates?[serverURL.absoluteString] else { return false }
        let elapsed = max(0, (now ?? ledgerNow()).timeIntervalSince1970 - timestamp)
        return elapsed >= TimeInterval(storedLockInterval(for: serverURL).rawValue)
    }

    private func lockLocally(for serverURL: URL) {
        guard self.serverURL == serverURL else { return }
        if case .locked = phase { return }
        _ = invalidateSession()
        stopImportIndexTracking()
        setLocallyLocked(true, for: serverURL)
        clearTransactionMutations()
        amountsVisible = false
        isRangeLoading = false
        isValuationCurrencyLoading = false
        rangePickerPresented = false
        phase = .locked(authenticated: true)
    }

}

private extension LedgerTransactionMutation {
    func uniqueSatisfiedTransaction(in transactions: [LedgerTransaction]) -> LedgerTransaction? {
        let matches = transactions.filter { isSatisfied(by: $0) }
        return matches.count == 1 ? matches[0] : nil
    }

    private func isSatisfied(by transaction: LedgerTransaction) -> Bool {
        guard transaction.source.file == original.source.file else { return false }
        switch kind {
        case let .edit(entry):
            return transaction.represents(entry)
        case .addTags:
            return transaction.hasSameVisibleContent(as: projected)
        case .delete:
            return false
        }
    }
}

extension LedgerBootstrap {
    func replacingTransactions(with transactions: [LedgerTransaction]) -> LedgerBootstrap {
        LedgerBootstrap(
            start: start,
            end: end,
            summary: summary,
            comparisons: comparisons,
            accountBalances: accountBalances,
            netWorthHistory: netWorthHistory,
            monthEndNetWorth: monthEndNetWorth,
            netWorthWindows: netWorthWindows,
            transactions: transactions,
            accounts: accounts,
            commodities: commodities,
            prices: prices,
            valuationCurrency: valuationCurrency,
            sensitiveUnlocked: sensitiveUnlocked
        )
    }
}

extension LedgerTransaction {
    fileprivate func hasSameVisibleContent(as other: LedgerTransaction) -> Bool {
        date == other.date
            && payee == other.payee
            && narration == other.narration
            && metadata == other.metadata
            && tags == other.tags
            && postings == other.postings
            && editableEntry == other.editableEntry
    }

    func projecting(entry: LedgerTransactionEntry) -> LedgerTransaction {
        LedgerTransaction(
            date: entry.date,
            payee: entry.payee,
            narration: entry.narration,
            metadata: entry.metadata.isEmpty ? nil : entry.metadata,
            tags: entry.tags.isEmpty ? nil : entry.tags,
            postings: entry.postings.map { posting in
                LedgerPosting(
                    account: posting.account,
                    amount: Self.minorUnits(posting.amount) ?? 0,
                    currency: posting.currency.isEmpty ? nil : posting.currency
                )
            },
            editableEntry: entry,
            source: source
        )
    }

    func projecting(addingTags tags: [String]) -> LedgerTransaction {
        var mergedTags = self.tags ?? []
        for tag in tags where !mergedTags.contains(tag) {
            mergedTags.append(tag)
        }
        return LedgerTransaction(
            date: date,
            payee: payee,
            narration: narration,
            metadata: metadata,
            tags: mergedTags.isEmpty ? nil : mergedTags,
            postings: postings,
            editableEntry: editableEntry.map { entry in
                LedgerTransactionEntry(
                    date: entry.date,
                    flag: entry.flag,
                    payee: entry.payee,
                    narration: entry.narration,
                    metadata: entry.metadata,
                    tags: mergedTags,
                    links: entry.links,
                    postings: entry.postings
                )
            },
            source: source
        )
    }

    func represents(_ entry: LedgerTransactionEntry) -> Bool {
        if editableEntry == entry { return true }
        guard date == entry.date,
              payee == entry.payee,
              narration == entry.narration,
              metadata ?? [:] == entry.metadata,
              tags ?? [] == entry.tags,
              postings.count == entry.postings.count else { return false }

        return zip(postings, entry.postings).allSatisfy { posting, edited in
            posting.account == edited.account
                && posting.amount == Self.minorUnits(edited.amount)
                && (posting.currency ?? "CNY") == edited.currency
        }
    }

    static func minorUnits(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 128,
              trimmed.range(of: "^[+-]?\\d+(\\.\\d*)?$", options: .regularExpression) != nil,
              let decimal = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let number = NSDecimalNumber(decimal: decimal * 100)
        guard number != .notANumber else { return nil }
        return number.rounding(accordingToBehavior: NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )).intValue
    }
}
