import Foundation
import Combine
#if canImport(WidgetKit)
import WidgetKit
#endif
#if canImport(UIKit)
import UIKit
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
    @Published private(set) var localOverviewCategories: LedgerOverviewCategories?
    @Published private(set) var isLocalOverviewCategoriesLoading = false
    @Published private(set) var localOverviewCategoriesError: String?
    var overviewTransactionStats: OverviewTransactionStats? {
        guard let ledger else { return nil }
        return OverviewTransactionStats(isLocal: isLocal, aggregate: localOverviewCategories,
            transactions: ledger.transactions)
    }

    private var overviewCategoriesGeneration = 0
    private var overviewSaveObserver: AnyCancellable?
    @Published private(set) var location: LedgerLocation?
    @Published private(set) var localSyncStatus: LocalStorageSyncStatus?
    @Published private(set) var localAutomaticSyncEnabled = true
    private let automaticLocalSyncServicesEnabled: Bool
    private var localSyncCoordinator: LocalLedgerAutoSyncCoordinator?
    private var localSaveObserver: AnyCancellable?
    private var localNetworkAvailable = true
    private var backgroundLocalSyncTask: Task<Bool, Never>?
    private static let backgroundGitAuthorizationKey = "ledger.mobile.background-git-authorization"
    private static let automaticSyncDisabledPrefix = "ledger.mobile.auto-sync-disabled."
    private static let automaticSyncPausedPrefix = "ledger.mobile.auto-sync-paused."
    var serverURL: URL? {
        guard case let .remote(url) = location else { return nil }
        return url
    }
    /// Identity for per-ledger preferences and request lifetime checks. Local
    /// identities never enter URLSession; repository dispatch uses the typed UUID.
    private var contextURL: URL? {
        switch location {
        case let .remote(url): url
        case let .local(id): URL(string: "ledger-local://\(id.uuidString.lowercased())")
        case nil: nil
        }
    }
    var isLocal: Bool {
        if case .local = location { return true }
        return false
    }
    var currentLocalLedgerDescriptor: LocalLedgerDescriptor? {
        guard case let .local(id) = location else { return nil }
        return localLedgers.first(where: { $0.id == id })
    }
    @Published private(set) var localLedgers: [LocalLedgerDescriptor] = []
    @Published private(set) var localLedgerName = "本地账本"
    @Published private(set) var isLocalOperationBusy = false
    @Published var serverInput: String
    @Published var password = ""
    @Published var errorMessage: String?
    @Published var amountsVisible = false
    @Published var primaryDestinationID = "overview"
    @Published var pendingTransactionFilter: LedgerTransactionFilter?
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

    private let repositoryFactory: LedgerRepositoryFactory
    private let localCatalog: LocalLedgerCatalog?
    private let localAuthenticator: any LocalLedgerAuthenticating
    let localOnly: Bool
    @Published private(set) var isStorageSyncBusy = false
    private var repositories: [LedgerLocation: any LedgerRepository] = [:]
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
    private var applicationBackground = false
    private var localAuthenticationForegroundWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var automaticUnlockAttempted = false
    private var systemAuthenticationInProgress = false
    private var requestGeneration = 0
    private var sessionEpoch = 0
    private struct LocalPresentation {
        let ledgerID: UUID
        let revisionID: UUID?
        let today: String
    }
    private var localPresentation: LocalPresentation?
    private var localResumeTask: Task<Void, Never>?
    private var localResumeID: UUID?
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
    private static let activeLocalLedgerKey = "ledger.mobile.active-local-ledger"
    private static let storageModeKey = "ledger.mobile.storage-mode"
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
        repositoryFactory: LedgerRepositoryFactory? = nil,
        showsStorageChoice: Bool = false,
        localOnly: Bool = false,
        automaticLocalSyncServicesEnabled: Bool = false,
        localCatalog: LocalLedgerCatalog? = nil,
        localAuthenticator: (any LocalLedgerAuthenticating)? = nil,
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
        self.localOnly = localOnly
        self.automaticLocalSyncServicesEnabled = automaticLocalSyncServicesEnabled
        self.localCatalog = localCatalog ?? (api == nil && repositoryFactory == nil ? try? LocalLedgerCatalog.appManaged() : nil)
        self.localAuthenticator = localAuthenticator ?? SystemLocalLedgerAuthenticator()
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

        if let initialTab = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--initial-tab=") })?.replacingOccurrences(of: "--initial-tab=", with: "") {
            primaryDestinationID = initialTab
        }

        if localOnly {
            // Production local-only composition has no HTTP client or remote
            // repository factory. Providers own their own explicit sync transport.
            self.repositoryFactory = { location in
                throw LedgerRepositoryError.unsupportedLocation(location)
            }
        } else if let repositoryFactory {
            self.repositoryFactory = repositoryFactory
        } else {
            let resolvedAPI: any LedgerAPI
            if let api {
                resolvedAPI = api
            } else {
                let configuration = URLSessionConfiguration.default
                configuration.httpCookieStorage = .shared
                configuration.httpShouldSetCookies = true
                configuration.timeoutIntervalForRequest = 20
                configuration.timeoutIntervalForResource = 40
                resolvedAPI = LedgerAPIClient(session: URLSession(configuration: configuration))
            }
            self.repositoryFactory = { location in
                guard case let .remote(baseURL) = location else {
                    throw LedgerRepositoryError.unsupportedLocation(location)
                }
                return RemoteLedgerRepository(api: resolvedAPI, baseURL: baseURL)
            }
        }

        let stored = defaults.string(forKey: Self.serverKey) ?? ""
        if showsStorageChoice, defaults.string(forKey: Self.storageModeKey) == nil,
           defaults.string(forKey: Self.activeLocalLedgerKey) == nil {
            defaults.set("library", forKey: Self.storageModeKey)
        }
        compactTabDestinations = Self.storedCompactTabs(in: defaults)
        let normalized = try? ServerConfiguration.normalize(stored)
        serverInput = stored
        location = localOnly ? nil : normalized.map(LedgerLocation.remote)
        phase = localOnly || normalized == nil ? .configuration : .checking
        if let storedID = defaults.string(forKey: Self.activeLocalLedgerKey), let id = UUID(uuidString: storedID) {
            location = .local(id)
            phase = .checking
        } else if defaults.string(forKey: Self.storageModeKey) == "library" {
            location = nil
            phase = .configuration
        }
        privacyShielded = false
        if case .remote = location, let normalized {
            lockInterval = storedLockInterval(for: normalized)
            if isLocallyLocked(normalized) || shouldLockAfterBackground(for: normalized) {
                setLocallyLocked(true, for: normalized)
                clearBackgroundDate(for: normalized)
                phase = .locked(authenticated: true)
            }
        }
        // Aggregate invalidation is independent of optional automatic Git sync.
        overviewSaveObserver = NotificationCenter.default.publisher(for: LocalLedgerRepository.didSaveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let id = notification.object as? UUID else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.location == .local(id), let repository = self.localRepository else { return }
                    let epoch = self.sessionEpoch
                    let revision = try? await repository.workspace.currentRevision()
                    guard self.sessionEpoch == epoch, self.location == .local(id),
                          self.phase == .ready,
                          revision?.id != self.localPresentation?.revisionID else { return }
                    self.invalidateOverviewCategories()
                    self.localOverviewCategoriesError = "账本已更新，请刷新概览汇总"
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
        if isLocal, biometricKind == .unavailable { return "设备密码" }
        return biometricKind.title
    }

    var biometricSystemImage: String {
        if isLocal, biometricKind == .unavailable { return "lock.shield" }
        return biometricKind == .touchID ? "touchid" : "faceid"
    }

    var hasBiometricUnlock: Bool {
        if isLocal { return localAuthenticator.isAvailable }
        guard let contextURL else { return false }
        return biometricKind != .unavailable && biometricStore.containsCredential(for: contextURL)
    }

    var canUseBiometricUnlock: Bool {
        if isLocal { return localAuthenticator.isAvailable }
        guard let contextURL else { return false }
        return hasBiometricUnlock && isLocallyLocked(contextURL)
    }

    func start() async {
        if isLocal {
            guard phase == .checking else { return }
            let epoch = sessionEpoch
            let expectedLocation = location
            await refreshLocalLedgers()
            guard !Task.isCancelled, sessionEpoch == epoch, location == expectedLocation else { return }
            // Keep the startup surface mounted during automatic authentication.
            // A rejected attempt exposes the manual unlock screen in the catch path.
            await automaticallyUnlockIfNeeded()
            return
        }
        await refreshLocalLedgers()
        if phase == .checking, hasBiometricUnlock, let contextURL {
            lockLocally(for: contextURL)
        }
        await resume()
        await automaticallyUnlockIfNeeded()
    }

    func resume() async {
        if isLocal {
            await unlockLocalLedger()
            return
        }
        guard phase == .checking, let contextURL else { return }
        lockInterval = storedLockInterval(for: contextURL)
        if isLocallyLocked(contextURL) || shouldLockAfterBackground(for: contextURL) {
            setLocallyLocked(true, for: contextURL)
            clearBackgroundDate(for: contextURL)
            amountsVisible = false
            privacyShielded = !applicationActive
            phase = .locked(authenticated: true)
            return
        }
        await checkSession(at: contextURL, generation: requestGeneration)
    }

    func saveServer() async {
        guard !localOnly else {
            errorMessage = "此版本使用本地账本，请选择本地目录或 Git 存储。"
            return
        }
        guard case .configuration = phase else { return }
        do {
            let normalized = try ServerConfiguration.normalize(serverInput)
            if contextURL != normalized { resetGlobalSearch() }
            location = .remote(normalized)
            defaults.removeObject(forKey: Self.activeLocalLedgerKey)
            defaults.set("remote", forKey: Self.storageModeKey)
            serverInput = normalized.absoluteString
            errorMessage = nil
            phase = .checking
            let generation = invalidateSession()
            await checkSession(at: normalized, generation: generation, persistOrigin: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshLocalLedgers() async {
        guard let localCatalog else { return }
        do {
            localLedgers = try await localCatalog.list()
            if case let .local(id) = location, let descriptor = localLedgers.first(where: { $0.id == id }) {
                localLedgerName = descriptor.name
            }
            localAutomaticSyncEnabled = localGitConfiguration.map {
                !defaults.bool(forKey: Self.automaticSyncDisabledPrefix + $0.id.uuidString)
            } ?? true
            updateLocalSyncEligibility()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createLocalLedger(name: String, currency: String) async {
        await createCustomLocalLedger(name: name, currency: currency, accounts: [], categories: [])
    }

    func createCustomLocalLedger(
        name: String,
        currency: String,
        accounts: [OnboardingAccountSelection],
        categories: [OnboardingCategorySelection]
    ) async {
        guard !isLocalOperationBusy, !isAuthenticationBusy, let localCatalog else { return }
        isLocalOperationBusy = true
        errorMessage = nil
        let epoch = sessionEpoch
        let expectedLocation = location
        defer { isLocalOperationBusy = false }
        do {
            try await authenticateLocalLedger(epoch: epoch, location: expectedLocation)
            try requireCurrentLocalOperation(epoch: epoch, location: expectedLocation)
            let descriptor = try await localCatalog.createCustom(
                name: name,
                currency: currency,
                accounts: accounts,
                categories: categories
            )
            try requireCurrentLocalOperation(epoch: epoch, location: expectedLocation)
            await refreshLocalLedgers()
            try requireCurrentLocalOperation(epoch: epoch, location: expectedLocation)
            try await activateLocalLedger(descriptor)
        } catch is CancellationError { } catch { errorMessage = error.localizedDescription }
    }

    func importLocalLedger(from directory: URL, name: String, entrypoint: String) async {
        guard !isLocalOperationBusy, !isAuthenticationBusy, let localCatalog else { return }
        isLocalOperationBusy = true
        errorMessage = nil
        let epoch = sessionEpoch
        let expectedLocation = location
        defer { isLocalOperationBusy = false }
        let granted = directory.startAccessingSecurityScopedResource()
        defer { if granted { directory.stopAccessingSecurityScopedResource() } }
        do {
            try await authenticateLocalLedger(epoch: epoch, location: expectedLocation)
            try requireCurrentLocalOperation(epoch: epoch, location: expectedLocation)
            let descriptor = try await localCatalog.importLedger(from: directory, name: name, entrypoint: entrypoint)
            try requireCurrentLocalOperation(epoch: epoch, location: expectedLocation)
            await refreshLocalLedgers()
            try requireCurrentLocalOperation(epoch: epoch, location: expectedLocation)
            try await activateLocalLedger(descriptor)
        } catch is CancellationError { } catch { errorMessage = error.localizedDescription }
    }

    func openLocalLedger(_ descriptor: LocalLedgerDescriptor) async {
        guard !isLocalOperationBusy, !isAuthenticationBusy else { return }
        isLocalOperationBusy = true
        errorMessage = nil
        let epoch = sessionEpoch
        let expectedLocation = location
        defer { isLocalOperationBusy = false }
        do {
            try await authenticateLocalLedger(epoch: epoch, location: expectedLocation)
            try requireCurrentLocalOperation(epoch: epoch, location: expectedLocation)
            try await activateLocalLedger(descriptor)
        } catch is CancellationError { } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func updateLocalLedger(_ descriptor: LocalLedgerDescriptor, name: String, entrypoint: String? = nil) async throws -> LocalLedgerDescriptor {
        guard let localCatalog else { throw LedgerRepositoryError.capabilityUnavailable("local storage") }
        isLocalOperationBusy = true
        errorMessage = nil
        defer { isLocalOperationBusy = false }
        do {
            let updated = try await localCatalog.update(ledgerID: descriptor.id, name: name, entrypoint: entrypoint)
            if case let .local(id) = location, id == descriptor.id {
                localLedgerName = updated.name
                repositories[.local(descriptor.id)] = localCatalog.repository(for: updated)
            }
            await refreshLocalLedgers()
            return updated
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func deleteLocalLedger(_ descriptor: LocalLedgerDescriptor) async throws {
        guard let localCatalog else { throw LedgerRepositoryError.capabilityUnavailable("local storage") }
        isLocalOperationBusy = true
        errorMessage = nil
        defer { isLocalOperationBusy = false }
        do {
            try await localCatalog.delete(ledgerID: descriptor.id)
            repositories.removeValue(forKey: .local(descriptor.id))
            if defaults.string(forKey: Self.activeLocalLedgerKey) == descriptor.id.uuidString {
                defaults.removeObject(forKey: Self.activeLocalLedgerKey)
            }
            if case let .local(id) = location, id == descriptor.id {
                chooseLedger()
            }
            await refreshLocalLedgers()
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func authenticateLocalLedger(epoch: Int, location expectedLocation: LedgerLocation?) async throws {
        let previousAuthenticationBusy = isAuthenticationBusy
        let previousSystemAuthentication = systemAuthenticationInProgress
        isAuthenticationBusy = true
        systemAuthenticationInProgress = true
        defer {
            isAuthenticationBusy = previousAuthenticationBusy
            systemAuthenticationInProgress = previousSystemAuthentication
        }
        try await localAuthenticator.authenticate()
        guard sessionEpoch == epoch, location == expectedLocation, !applicationBackground else { throw CancellationError() }
        // LocalAuthentication may finish before SwiftUI delivers the active scene
        // event. Keep the operation pending until that event, without opening data
        // while inactive. A background visit or context change cancels the waiter.
        if !applicationActive {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { localAuthenticationForegroundWaiters[id] = continuation }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.localAuthenticationForegroundWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
                }
            }
        }
        try requireCurrentLocalOperation(epoch: epoch, location: expectedLocation)
    }

    private func finishLocalAuthenticationForegroundWaiters(cancelled: Bool) {
        let waiters = localAuthenticationForegroundWaiters.values
        localAuthenticationForegroundWaiters.removeAll()
        for waiter in waiters {
            if cancelled { waiter.resume(throwing: CancellationError()) }
            else { waiter.resume() }
        }
    }

    private func requireCurrentLocalOperation(epoch: Int, location expectedLocation: LedgerLocation?) throws {
        try Task.checkCancellation()
        guard applicationActive, sessionEpoch == epoch, location == expectedLocation else { throw CancellationError() }
    }

    private func activateLocalLedger(_ descriptor: LocalLedgerDescriptor) async throws {
        guard let localCatalog else { throw LedgerRepositoryError.capabilityUnavailable("local storage") }
        let generation = invalidateSession()
        stopImportIndexTracking()
        clearTransactionMutations()
        suspendWidgetCredential(allowRemoteRevocation: false)
        clearWidgetSnapshot()
        ledger = nil
        localPresentation = nil
        location = .local(descriptor.id)
        localLedgerName = descriptor.name
        repositories[.local(descriptor.id)] = localCatalog.repository(for: descriptor)
        defaults.set(descriptor.id.uuidString, forKey: Self.activeLocalLedgerKey)
        defaults.set("local", forKey: Self.storageModeKey)
        passkeyAvailable = false
        accountPeriodBalancesAvailable = true
        phase = .checking
        guard let contextURL else { return }
        lockInterval = storedLockInterval(for: contextURL)
        setLocallyLocked(false, for: contextURL)
        clearBackgroundDate(for: contextURL)
        do {
            try await loadLedger(from: contextURL, generation: generation)
            await prepareLocalAutomaticSync()
        } catch {
            guard generation == requestGeneration else { throw error }
            phase = .locked(authenticated: true)
            throw error
        }
    }

    func unlockLocalLedger() async {
        guard isLocal, !isAuthenticationBusy, applicationActive else { return }
        isAuthenticationBusy = true
        systemAuthenticationInProgress = true
        errorMessage = nil
        let epoch = sessionEpoch
        let expectedLocation = location
        defer {
            isAuthenticationBusy = false
            systemAuthenticationInProgress = false
        }
        do {
            try await authenticateLocalLedger(epoch: epoch, location: expectedLocation)
            try requireCurrentLocalOperation(epoch: epoch, location: expectedLocation)
            if restoreRetainedLocalLedger() { return }
            await refreshLocalLedgers()
            try requireCurrentLocalOperation(epoch: epoch, location: expectedLocation)
            guard case let .local(id) = location,
                  let descriptor = localLedgers.first(where: { $0.id == id }) else {
                throw LedgerRepositoryError.capabilityUnavailable("找不到本地账本，请重新选择")
            }
            try await activateLocalLedger(descriptor)
        } catch {
            if expectedLocation == location {
                phase = .locked(authenticated: true)
                errorMessage = error.localizedDescription
            }
        }
    }

    /// A locked local session retains its current presentation only in memory.
    /// This path is reached after successful device authentication and the epoch check.
    private func restoreRetainedLocalLedger() -> Bool {
        guard case let .local(id) = location, localPresentation?.ledgerID == id,
              let ledger, ledger.sensitiveUnlocked, let contextURL else { return false }
        _ = invalidateRequests()
        setLocallyLocked(false, for: contextURL)
        clearBackgroundDate(for: contextURL)
        // Authentication just succeeded; the scene is returning to active even if
        // `applicationActive` hasn't been updated yet by the parallel scenePhase task.
        // Unconditionally show amounts and drop the privacy shield so the app reveals
        // content without a flash on Face ID / Touch ID unlock.
        amountsVisible = true
        privacyShielded = false
        phase = .ready
        scheduleLocalResumeRefresh(prepareAutomaticSync: true)
        return true
    }

    private func scheduleLocalResumeRefresh(prepareAutomaticSync: Bool = false) {
        guard let repository = localRepository, let presentation = localPresentation,
              presentation.ledgerID == repository.descriptor.id else { return }
        localResumeTask?.cancel()
        let id = UUID(), epoch = sessionEpoch, expectedLocation = location
        localResumeID = id
        localResumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.localResumeID == id { self.localResumeTask = nil; self.localResumeID = nil }
            }
            do {
                let revision = try await repository.workspace.currentRevision()
                guard !Task.isCancelled, self.sessionEpoch == epoch, self.location == expectedLocation,
                      self.applicationActive, self.phase == .ready else { return }
                if presentation.revisionID == nil || presentation.revisionID != revision?.id
                    || presentation.today != LedgerDateRange.today(now: self.ledgerNow()) {
                    await self.refresh()
                } else {
                    await self.refreshLocalOverviewCategories()
                }
                guard !Task.isCancelled, self.sessionEpoch == epoch, self.location == expectedLocation,
                      self.applicationActive, self.phase == .ready else { return }
                if prepareAutomaticSync { await self.prepareLocalAutomaticSync() }
            } catch {
                guard !Task.isCancelled, self.sessionEpoch == epoch, self.location == expectedLocation,
                      self.phase == .ready else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Leaves files, history and remote login credentials intact while changing
    /// the active context. This is also the local-mode equivalent of logout.
    func chooseLedger() {
        defaults.removeObject(forKey: Self.backgroundGitAuthorizationKey)
        LocalLedgerBackgroundSyncService.shared.setEnabled(false)
        _ = invalidateSession()
        stopImportIndexTracking()
        clearTransactionMutations()
        resetGlobalSearch()
        suspendWidgetCredential()
        clearWidgetSnapshot()
        pendingWidgetExpenseDay = nil
        pendingExternalRoute = nil
        externalAccount = nil
        ledger = nil
        localPresentation = nil
        location = nil
        amountsVisible = false
        password = ""
        errorMessage = nil
        defaults.removeObject(forKey: Self.activeLocalLedgerKey)
        defaults.set("library", forKey: Self.storageModeKey)
        phase = .configuration
    }

    var localRepository: LocalLedgerRepository? {
        guard isLocal else { return nil }
        return (try? activeRepository) as? LocalLedgerRepository
    }

    var localGitConfiguration: LocalGitConfiguration? {
        guard case let .local(id) = location else { return nil }
        return localLedgers.first(where: { $0.id == id })?.git
    }

    func importGitLedger(repositoryURL: String, branch: String, name: String,
                         entrypoint: String, credential: LocalGitCredential?) async {
        guard !isLocalOperationBusy, !isAuthenticationBusy, let localCatalog else { return }
        isLocalOperationBusy = true
        errorMessage = nil
        let epoch = sessionEpoch
        let expectedLocation = location
        defer { isLocalOperationBusy = false }
        do {
            try await authenticateLocalLedger(epoch: epoch, location: expectedLocation)
            let descriptor = try await localCatalog.importGit(repositoryURL: repositoryURL, branch: branch,
                name: name, entrypoint: entrypoint, credential: credential)
            try requireCurrentLocalOperation(epoch: epoch, location: expectedLocation)
            await refreshLocalLedgers()
            try requireCurrentLocalOperation(epoch: epoch, location: expectedLocation)
            try await activateLocalLedger(descriptor)
        } catch is CancellationError { } catch { errorMessage = error.localizedDescription }
    }

    func configureLocalGit(repositoryURL: String, branch: String, credential: LocalGitCredential?) async throws {
        guard phase == .ready, applicationActive, !isStorageSyncBusy, case let .local(id) = location, let localCatalog else {
            throw LocalLedgerError.operationFailed("请先解锁本地账本，等待当前同步结束。")
        }
        isStorageSyncBusy = true
        defer { isStorageSyncBusy = false }
        let epoch = sessionEpoch
        let descriptor = try await localCatalog.configureGit(ledgerID: id, repositoryURL: repositoryURL,
            branch: branch, credential: credential)
        try requireCurrentLocalOperation(epoch: epoch, location: .local(id))
        repositories[.local(id)] = localCatalog.repository(for: descriptor)
        await refreshLocalLedgers()
        defaults.removeObject(forKey: Self.automaticSyncPausedPrefix + (descriptor.git?.id.uuidString ?? ""))
        localSyncCoordinator?.resume()
        await prepareLocalAutomaticSync()
    }

    func disconnectLocalGit() async throws {
        guard phase == .ready, applicationActive, !isStorageSyncBusy, case let .local(id) = location, let localCatalog else {
            throw LocalLedgerError.operationFailed("请先解锁本地账本，等待当前同步结束。")
        }
        isStorageSyncBusy = true
        defer { isStorageSyncBusy = false }
        let epoch = sessionEpoch
        let descriptor = try await localCatalog.disconnectGit(ledgerID: id)
        try requireCurrentLocalOperation(epoch: epoch, location: .local(id))
        repositories[.local(id)] = localCatalog.repository(for: descriptor)
        defaults.removeObject(forKey: Self.backgroundGitAuthorizationKey)
        localSyncCoordinator?.setEligible(false)
        LocalLedgerBackgroundSyncService.shared.setEnabled(false)
        localSyncStatus = nil
        await refreshLocalLedgers()
    }

    func synchronizeLocalStorage() async throws -> LocalStorageSyncStatus {
        guard phase == .ready, applicationActive, !isStorageSyncBusy, let repository = localRepository else {
            throw LocalLedgerError.operationFailed("请先解锁本地账本，等待当前同步结束。")
        }
        isStorageSyncBusy = true
        let epoch = sessionEpoch
        let expectedLocation = location
        var succeeded = false
        defer {
            isStorageSyncBusy = false
            if succeeded, epoch == sessionEpoch, location == expectedLocation {
                updateLocalSyncEligibility()
                localSyncCoordinator?.resume()
            }
        }
        let previousRevisionID = await repository.presentedRevisionID
        let status: LocalStorageSyncStatus
        do {
            status = try await repository.synchronize()
        } catch {
            guard epoch == sessionEpoch, location == expectedLocation else { throw error }
            let latest = try? await repository.storageStatus()
            guard epoch == sessionEpoch, location == expectedLocation else { throw error }
            if latest?.phase == .conflicted {
                localSyncStatus = latest
            } else {
                localSyncStatus = .init(mode: latest?.mode ?? (repository.descriptor.git == nil ? .device : .git),
                    phase: .failed, lastSyncedAt: latest?.lastSyncedAt, baseCommit: latest?.baseCommit,
                    message: latest?.message ?? error.localizedDescription)
            }
            throw error
        }
        guard epoch == sessionEpoch, location == expectedLocation else { throw CancellationError() }
        localSyncStatus = status
        if let config = localGitConfiguration {
            defaults.removeObject(forKey: Self.automaticSyncPausedPrefix + config.id.uuidString)
        }
        succeeded = true
        let currentRevisionID = try? await repository.workspace.currentRevision()?.id
        if epoch == sessionEpoch, location == expectedLocation, phase == .ready, applicationActive {
            if previousRevisionID == nil || previousRevisionID != currentRevisionID {
                await refresh()
            }
        }
        return status
    }

    func resolveLocalStorageConflicts(keepingLocal: Bool) async throws -> LocalStorageSyncStatus {
        guard phase == .ready, applicationActive, !isStorageSyncBusy, let repository = localRepository else {
            throw LocalLedgerError.operationFailed("请先解锁本地账本，等待当前同步结束。")
        }
        isStorageSyncBusy = true
        let epoch = sessionEpoch
        let expectedLocation = location
        var succeeded = false
        defer {
            isStorageSyncBusy = false
            if succeeded, epoch == sessionEpoch, location == expectedLocation {
                updateLocalSyncEligibility()
                localSyncCoordinator?.resume()
            }
        }
        let status = try await repository.resolveSyncConflicts(keepingLocal: keepingLocal)
        guard epoch == sessionEpoch, location == expectedLocation else { throw CancellationError() }
        localSyncStatus = status
        if let config = localGitConfiguration {
            defaults.removeObject(forKey: Self.automaticSyncPausedPrefix + config.id.uuidString)
        }
        succeeded = true
        if epoch == sessionEpoch, location == expectedLocation, phase == .ready, applicationActive {
            await refresh()
        }
        return status
    }

    /// Production opts in explicitly; fixture sessions never start network work.
    func startLocalAutomaticSyncServices() {
        guard automaticLocalSyncServicesEnabled, localSyncCoordinator == nil else { return }
        localSyncCoordinator = LocalLedgerAutoSyncCoordinator { [weak self] in
            guard let self else { return .paused }
            return await self.runAutomaticLocalSync(background: false)
        }
        localSaveObserver = NotificationCenter.default.publisher(for: LocalLedgerRepository.didSaveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let id = notification.object as? UUID else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.location == .local(id) else { return }
                    let epoch = self.sessionEpoch
                    let status = try? await self.localRepository?.storageStatus()
                    guard self.sessionEpoch == epoch, self.location == .local(id) else { return }
                    self.localSyncStatus = status
                    self.localSyncCoordinator?.localChangesSaved()
                }
            }
        updateLocalSyncEligibility()
    }

    /// Platform connectivity is supplied by the app entry point. Fixture sessions
    /// can drive this boundary without depending on the simulator host's network.
    func updateLocalSyncNetworkAvailability(_ reachable: Bool) {
        guard automaticLocalSyncServicesEnabled else { return }
        let restored = reachable && !localNetworkAvailable
        localNetworkAvailable = reachable
        updateLocalSyncEligibility()
        if restored { localSyncCoordinator?.networkRestored() }
    }

    func setLocalAutomaticSyncEnabled(_ enabled: Bool) async {
        guard let config = localGitConfiguration else { return }
        defaults.set(!enabled, forKey: Self.automaticSyncDisabledPrefix + config.id.uuidString)
        localAutomaticSyncEnabled = enabled
        if enabled {
            defaults.removeObject(forKey: Self.automaticSyncPausedPrefix + config.id.uuidString)
            await prepareLocalAutomaticSync()
            localSyncCoordinator?.resume()
        } else {
            backgroundLocalSyncTask?.cancel()
        }
        updateLocalSyncEligibility()
    }

    private func prepareLocalAutomaticSync() async {
        guard automaticLocalSyncServicesEnabled, let repository = localRepository,
              let config = repository.descriptor.git, phase == .ready else { return }
        startLocalAutomaticSyncServices()
        let epoch = sessionEpoch
        let authorization = backgroundAuthorization(for: repository.descriptor)
        do {
            if defaults.string(forKey: Self.backgroundGitAuthorizationKey) != authorization {
                try await LocalLedgerBackgroundProtection.prepareForBackgroundSync(
                    rootDirectory: repository.workspace.rootDirectory, configurationID: config.id)
            }
            let status = try await repository.storageStatus()
            guard epoch == sessionEpoch, location == .local(repository.descriptor.id), phase == .ready else { return }
            defaults.set(authorization, forKey: Self.backgroundGitAuthorizationKey)
            localSyncStatus = status
            localSyncCoordinator?.resume()
            updateLocalSyncEligibility()
        } catch {
            guard epoch == sessionEpoch else { return }
            localSyncStatus = .init(mode: .git, phase: .failed,
                message: "后台同步准备失败：\(error.localizedDescription)")
        }
    }

    private func backgroundAuthorization(for descriptor: LocalLedgerDescriptor) -> String {
        descriptor.id.uuidString + ":" + (descriptor.git?.id.uuidString ?? "")
    }

    private func allowsAutomaticSync(_ descriptor: LocalLedgerDescriptor) -> Bool {
        guard automaticLocalSyncServicesEnabled, let config = descriptor.git else { return false }
        return defaults.string(forKey: Self.activeLocalLedgerKey) == descriptor.id.uuidString
            && defaults.string(forKey: Self.backgroundGitAuthorizationKey) == backgroundAuthorization(for: descriptor)
            && !defaults.bool(forKey: Self.automaticSyncDisabledPrefix + config.id.uuidString)
            && !defaults.bool(forKey: Self.automaticSyncPausedPrefix + config.id.uuidString)
    }

    private func updateLocalSyncEligibility() {
        guard automaticLocalSyncServicesEnabled else { return }
        let descriptor = localLedgers.first { location == .local($0.id) }
        let authorized = descriptor.map(allowsAutomaticSync) ?? false
        localSyncCoordinator?.setEligible(authorized && applicationActive && phase == .ready && localNetworkAvailable)
        LocalLedgerBackgroundSyncService.shared.setEnabled(authorized)
    }

    /// Called by BGTaskScheduler on warm and cold launches; never unlocks the UI.
    func performBackgroundLocalSync() async -> Bool {
        guard automaticLocalSyncServicesEnabled, backgroundLocalSyncTask == nil else { return false }
        let work = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.runAutomaticLocalSync(background: true) == .success
        }
        backgroundLocalSyncTask = work
        defer { backgroundLocalSyncTask = nil }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    #if os(iOS)
    /// Flushes any pending sync right as the app transitions to the background.
    /// Obtains a short background execution assertion from iOS so writes and pushes finish.
    func flushBackgroundLocalSyncIfNeeded() async {
        guard automaticLocalSyncServicesEnabled, isLocal else { return }
        let descriptor = localLedgers.first { location == .local($0.id) }
        guard let descriptor, allowsAutomaticSync(descriptor) else { return }

        var backgroundTaskID = UIBackgroundTaskIdentifier.invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "ledger.flush-local-sync") {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }

        let success = await performBackgroundLocalSync()
        LocalLedgerBackgroundSyncService.shared.recordExecution(kind: .sceneFlush, success: success)

        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
    #endif

    private func runAutomaticLocalSync(background: Bool) async -> LocalLedgerAutoSyncCoordinator.Outcome {
        if isStorageSyncBusy && background {
            // Give any concurrent foreground save/sync up to 2 seconds to finish yielding.
            for _ in 0..<20 {
                if !isStorageSyncBusy { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        guard !Task.isCancelled, !isStorageSyncBusy, let localCatalog else { return .retryableFailure }
        if !background, (!applicationActive || phase != .ready) { return .retryableFailure }
        isStorageSyncBusy = true
        defer { isStorageSyncBusy = false }
        let epoch = sessionEpoch
        var descriptor: LocalLedgerDescriptor?
        var repository: LocalLedgerRepository?
        do {
            let ledgers = try await localCatalog.list()
            guard !Task.isCancelled, epoch == sessionEpoch else { return .retryableFailure }
            localLedgers = ledgers
            guard let active = ledgers.first(where: { allowsAutomaticSync($0) }) else {
                LocalLedgerBackgroundSyncService.shared.setEnabled(false)
                return .paused
            }
            descriptor = active
            LocalLedgerBackgroundSyncService.shared.setEnabled(true)
            let current = localCatalog.repository(for: active)
            repository = current
            let previous = try await current.storageStatus()
            if previous.phase == .conflicted { throw LocalStorageError.conflicts(previous.conflictPaths) }
            try Task.checkCancellation()
            guard epoch == sessionEpoch, allowsAutomaticSync(active) else { return .paused }
            if location == .local(active.id) {
                localSyncStatus = .init(mode: .git, phase: .synchronizing,
                    lastSyncedAt: previous.lastSyncedAt, baseCommit: previous.baseCommit)
            }
            let status = try await current.synchronize()
            try Task.checkCancellation()
            guard epoch == sessionEpoch, allowsAutomaticSync(active) else { return .paused }
            if location == .local(active.id) { localSyncStatus = status }
            let origin = URL(string: "ledger-local://" + active.id.uuidString.lowercased())!
            let published = try await LocalLedgerWidgetPublisher.refresh(repository: current,
                valuationCurrency: storedValuationCurrency(for: origin), store: widgetSnapshotStore, now: ledgerNow()) {
                    !Task.isCancelled && self.sessionEpoch == epoch && self.allowsAutomaticSync(active)
                }
            if published {
                #if canImport(WidgetKit)
                WidgetCenter.shared.reloadAllTimelines()
                #endif
            }
            if !background, epoch == sessionEpoch, phase == .ready, applicationActive {
                await refresh()
            }
            guard !Task.isCancelled, epoch == sessionEpoch else { return .retryableFailure }
            LocalLedgerBackgroundSyncService.shared.setEnabled(allowsAutomaticSync(active))
            // Writes made during fetch/push remain pending and get another attempt.
            return status.phase == .pending || !published ? .retryableFailure : .success
        } catch {
            guard !Task.isCancelled, epoch == sessionEpoch else { return .retryableFailure }
            let status = try? await repository?.storageStatus()
            guard !Task.isCancelled, epoch == sessionEpoch else { return .retryableFailure }
            if repository != nil { localSyncStatus = status }
            let pause = Self.automaticSyncRequiresAttention(error)
            if let config = descriptor?.git, pause {
                defaults.set(true, forKey: Self.automaticSyncPausedPrefix + config.id.uuidString)
                LocalLedgerBackgroundSyncService.shared.setEnabled(false)
            }
            if let descriptor, location == .local(descriptor.id), localSyncStatus?.phase != .conflicted {
                localSyncStatus = .init(mode: .git, phase: .failed,
                    lastSyncedAt: localSyncStatus?.lastSyncedAt, baseCommit: localSyncStatus?.baseCommit,
                    message: error.localizedDescription)
            }
            return pause ? .paused : .retryableFailure
        }
    }

    static func automaticSyncRequiresAttention(_ error: Error) -> Bool {
        if let error = error as? LocalStorageError {
            switch error {
            case .conflicts, .invalidGitConfiguration, .unsafeFile, .treeLimitExceeded,
                 .corruptSyncState, .emptyRepository, .gitUnavailable: return true
            case .synchronizationInProgress: return false
            case .gitFailure: break
            }
        }
        if let failure = error as? LocalGitTransportFailure { return failure.requiresAttention }
        if error is EmbeddedBeancountValidator.ValidationError { return true }
        return false
    }

    func addLocalTransaction(_ entry: LedgerTransactionEntry) async throws {
        guard phase == .ready, let localRepository else {
            throw LedgerRepositoryError.capabilityUnavailable("local writes")
        }
        let epoch = sessionEpoch
        try await localRepository.addTransaction(entry: entry)
        guard epoch == sessionEpoch else { throw CancellationError() }
        await refresh()
    }

    func addAccount(
        account: String,
        alias: String,
        currency: String,
        date: String,
        openingBalance: String? = nil
    ) async throws {
        guard phase == .ready else {
            throw LedgerAPIError.incompatibleServer("当前账本会话不可用")
        }
        let input = LedgerAccountInput(date: date, account: account, alias: alias, currency: currency)
        let epoch = sessionEpoch
        if let localRepository {
            try await localRepository.addAccount(input: input)
            guard epoch == sessionEpoch else { throw CancellationError() }

            if let openingBalance = openingBalance?.trimmingCharacters(in: .whitespacesAndNewlines),
               !openingBalance.isEmpty,
               let balanceDecimal = Decimal(string: openingBalance),
               balanceDecimal != 0 {
                let isLiability = account.hasPrefix("Liabilities:")
                let isPositive = balanceDecimal > 0
                let accountAmount = isLiability ? (isPositive ? "-\(balanceDecimal)" : "\(abs(balanceDecimal))") : "\(balanceDecimal)"
                let equityAmount = isLiability ? "\(balanceDecimal)" : (isPositive ? "-\(balanceDecimal)" : "\(abs(balanceDecimal))")
                let entry = LedgerTransactionEntry(
                    date: date,
                    flag: "*",
                    payee: "",
                    narration: "期初余额",
                    tags: [],
                    links: [],
                    postings: [
                        LedgerTransactionEntryPosting(account: account, amount: accountAmount, currency: currency),
                        LedgerTransactionEntryPosting(account: "Equity:Opening-Balances", amount: equityAmount, currency: currency)
                    ]
                )
                try await localRepository.addTransaction(entry: entry)
                guard epoch == sessionEpoch else { throw CancellationError() }
            }
        } else {
            _ = try await performSensitiveRequest { repository in
                try await repository.addAccount(input: input)
            }
        }
        await refresh()
    }

    func reconcileAccount(
        account: String,
        actualAmount: String,
        balanceDate: String,
        adjustmentDate: String
    ) async throws -> LedgerReconciliationResult {
        guard phase == .ready else {
            throw LedgerAPIError.incompatibleServer("当前账本会话不可用")
        }
        let request = LedgerReconcileRequest(
            account: account,
            actualAmount: actualAmount,
            balanceDate: balanceDate,
            adjustmentDate: adjustmentDate
        )
        let result = try await performSensitiveRequest { repository in
            try await repository.reconcile(request: request)
        }
        await refresh()
        return result
    }

    func fetchReconciliationRows(start: String, end: String) async throws -> [LedgerReconciliationRow] {
        guard phase == .ready else {
            throw LedgerAPIError.incompatibleServer("当前账本会话不可用")
        }
        let response = try await performSensitiveRequest { repository in
            try await repository.reconciliation(start: start, end: end)
        }
        return response.rows
    }

    func accountStatus(for account: String) -> LedgerAccountStatus? {
        ledger?.accountStatuses.first { $0.account == account }
    }

    func reconciliationRow(for account: String) -> LedgerReconciliationRow? {
        ledger?.reconciliationRows.first { $0.account == account }
    }

    func login() async {
        guard case let .locked(authenticated) = phase,
              let contextURL,
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
            try await remoteRepository(at: contextURL).login(password: candidate)
            guard generation == requestGeneration else {
                clearAuthenticationCookies(for: contextURL)
                return
            }
            password = ""
            try await loadLedger(from: contextURL, generation: generation)
            guard generation == requestGeneration, phase == .ready else { return }
            setLocallyLocked(false, for: contextURL)
            if let ledger {
                await ensureWidgetCredential(for: contextURL, valuationCurrency: ledger.valuationCurrency)
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
              let contextURL,
              passkeyAvailable,
              isTrustedNativePasskeyOrigin(contextURL),
              !isAuthenticationBusy else { return }
        let generation = invalidateSession()
        isAuthenticationBusy = true
        defer { isAuthenticationBusy = false }
        errorMessage = nil
        do {
            let repository = try remoteRepository(at: contextURL)
            let options = try await repository.passkeyLoginOptions()
            let assertion: PasskeyAssertion
            systemAuthenticationInProgress = true
            do {
                defer { systemAuthenticationInProgress = false }
                assertion = try await passkeyAuthenticator.authenticate(
                    options: options,
                    relyingPartyID: Self.passkeyRelyingPartyID
                )
            }
            try await repository.verifyPasskey(assertion: assertion)
            guard generation == requestGeneration else {
                clearAuthenticationCookies(for: contextURL)
                return
            }
            try await loadLedger(from: contextURL, generation: generation)
            guard generation == requestGeneration, phase == .ready else { return }
            setLocallyLocked(false, for: contextURL)
            if let ledger {
                await ensureWidgetCredential(for: contextURL, valuationCurrency: ledger.valuationCurrency)
            }
        } catch {
            guard generation == requestGeneration else { return }
            errorMessage = error.localizedDescription
            phase = .locked(authenticated: authenticated)
        }
    }

    func automaticallyUnlockIfNeeded() async {
        let localStartup = isLocal && phase == .checking
        let awaitsAutomaticUnlock = phase == .locked(authenticated: true)
            || phase == .locked(authenticated: false) || localStartup
        guard applicationActive, awaitsAutomaticUnlock, canUseBiometricUnlock || localStartup,
              !automaticUnlockAttempted, !isAuthenticationBusy,
              !systemAuthenticationInProgress else { return }
        automaticUnlockAttempted = true
        await unlockWithBiometrics()
    }

    func unlockWithBiometrics() async {
        if isLocal {
            await unlockLocalLedger()
            return
        }
        guard case let .locked(authenticated) = phase,
              let contextURL,
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
                    for: contextURL,
                    reason: "使用 \(biometricTitle) 解锁账本金额"
                )
            }
            guard generation == requestGeneration else { return }
            let usesLocalMarker = credential.deviceID == "local-biometric"
            if ledger != nil {
                setLocallyLocked(false, for: contextURL)
                // Authentication just succeeded; unconditionally reveal content even if
                // applicationActive hasn't updated yet from the parallel scenePhase task.
                amountsVisible = true
                privacyShielded = false
                phase = .ready
            }

            var requiresCredentialMigration = usesLocalMarker
            var quickUnlockFailed = false
            if !usesLocalMarker {
                do {
                    try await remoteRepository(at: contextURL).verifyQuickUnlock(credential: credential)
                    guard generation == requestGeneration else {
                        clearAuthenticationCookies(for: contextURL)
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
                try await loadLedger(from: contextURL, generation: generation)
                serverAccessConfirmed = phase == .ready
                if serverAccessConfirmed {
                    setLocallyLocked(false, for: contextURL)
                }
            }
            if case .locked = phase {
                setLocallyLocked(true, for: contextURL)
                if quickUnlockFailed {
                    errorMessage = "Face ID 已通过，但服务器会话已过期，请输入密码重新连接"
                }
            } else {
                if requiresCredentialMigration, serverAccessConfirmed {
                    await migrateLocalBiometricCredential(
                        for: contextURL,
                        replacingDeviceID: usesLocalMarker ? nil : credential.deviceID
                    )
                } else if quickUnlockFailed {
                    errorMessage = "Face ID 已解锁本机数据；服务器暂未同步，刷新后可使用密码重新连接"
                }
                if serverAccessConfirmed, phase == .ready, let ledger {
                    await ensureWidgetCredential(for: contextURL, valuationCurrency: ledger.valuationCurrency)
                }
            }
        } catch {
            guard generation == requestGeneration else { return }
            setLocallyLocked(true, for: contextURL)
            errorMessage = error.localizedDescription
            phase = .locked(authenticated: authenticated)
        }
    }

    func setBiometricUnlockEnabled(_ enabled: Bool) async {
        guard phase == .ready, let contextURL, !isBiometricSettingBusy else { return }
        guard enabled != hasBiometricUnlock else { return }
        isBiometricSettingBusy = true
        errorMessage = nil
        defer { isBiometricSettingBusy = false }

        if enabled {
            do {
                let repository = try remoteRepository(at: contextURL)
                let credential = try await repository.registerQuickUnlock(
                    deviceName: "Ledger iOS · \(biometricTitle)",
                    mode: "text"
                )
                guard phase == .ready, self.contextURL == contextURL else {
                    try? await repository.revokeQuickUnlock(deviceID: credential.deviceID)
                    return
                }
                do {
                    try biometricStore.save(credential, for: contextURL)
                } catch {
                    try? await repository.revokeQuickUnlock(deviceID: credential.deviceID)
                    throw error
                }
                if let ledger {
                    await ensureWidgetCredential(for: contextURL, valuationCurrency: ledger.valuationCurrency)
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
                    for: contextURL,
                    reason: "验证后停用 \(biometricTitle) 快速解锁"
                )
            }
            guard phase == .ready, self.contextURL == contextURL else { return }
            if widgetCredentialStore.isAvailable,
               let widgetCredential = try widgetCredentialStore.load(),
               widgetCredential.serverOrigin == contextURL.absoluteString {
                try await remoteRepository(at: contextURL).revokeQuickUnlock(deviceID: widgetCredential.deviceID)
                try widgetCredentialStore.suspend()
                try widgetCredentialStore.completeRevocation(deviceID: widgetCredential.deviceID)
                clearWidgetSnapshot()
            }
            if credential.deviceID != "local-biometric" {
                try await remoteRepository(at: contextURL).revokeQuickUnlock(deviceID: credential.deviceID)
                guard phase == .ready, self.contextURL == contextURL else { return }
            }
            biometricStore.deleteCredential(for: contextURL)
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
              let contextURL,
              let ledger,
              !isWidgetRefreshBusy else { return }
        isWidgetRefreshBusy = true
        defer { isWidgetRefreshBusy = false }

        await ensureWidgetCredential(for: contextURL, valuationCurrency: ledger.valuationCurrency)
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
        guard let contextURL else { return }
        lockInterval = interval
        var intervals = defaults.dictionary(forKey: Self.lockIntervalsKey) as? [String: Int] ?? [:]
        intervals[contextURL.absoluteString] = interval.rawValue
        defaults.set(intervals, forKey: Self.lockIntervalsKey)
    }

    func refresh() async {
        _ = await refreshWithResult()
    }

    private func refreshWithResult() async -> Bool {
        guard phase == .ready, let contextURL, !isRangeLoading, !isValuationCurrencyLoading else { return false }
        let generation = invalidateRequests()
        do {
            try await loadLedger(from: contextURL, generation: generation)
            guard generation == requestGeneration else { return false }
            errorMessage = nil
            return true
        } catch {
            guard generation == requestGeneration else { return false }
            errorMessage = error.localizedDescription
            handleBootstrapSessionError(error, contextURL: contextURL)
            return false
        }
    }

    private func refreshAfterBiometricUnlock() async -> Bool {
        guard phase == .ready, let contextURL, !isRangeLoading, !isValuationCurrencyLoading else { return false }
        let generation = invalidateRequests()
        do {
            try await loadLedger(
                from: contextURL,
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
        guard let contextURL, phase == .ready, !isRangeLoading else { return }
        let currency = rawCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !currency.isEmpty, currency != ledger?.valuationCurrency else { return }

        let generation = invalidateRequests()
        isValuationCurrencyLoading = true
        errorMessage = nil
        do {
            try await loadLedger(
                from: contextURL,
                generation: generation,
                valuationCurrency: currency
            )
            guard generation == requestGeneration else { return }
            isValuationCurrencyLoading = false
            startTransactionReconciliationIfNeeded()
        } catch {
            guard generation == requestGeneration else { return }
            isValuationCurrencyLoading = false
            handleBootstrapSessionError(error, contextURL: contextURL)
            startTransactionReconciliationIfNeeded()
        }
    }

    func accountDetail(for account: String, currency: String) async throws -> LedgerAccountDetail {
        guard phase == .ready, let contextURL else {
            throw LedgerAPIError.incompatibleServer("当前账本会话不可用")
        }
        let generation = requestGeneration
        let range = selectedRange
        do {
            let detail = try await repository(at: contextURL).accountDetail(
                account: account,
                currency: currency,
                start: range.start,
                end: range.queryEndExclusive
            )
            guard generation == requestGeneration,
                  self.contextURL == contextURL,
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
               self.contextURL == contextURL,
               phase == .ready {
                clearSensitiveCookie(for: contextURL)
                ledger = nil
                amountsVisible = false
                phase = .locked(authenticated: true)
            }
            throw error
        }
    }

    func analysisResource(_ kind: LedgerAnalysisResourceKind) async throws -> LedgerAnalysisResource {
        guard phase == .ready, let contextURL else {
            throw LedgerAPIError.incompatibleServer("当前账本会话不可用")
        }
        let generation = requestGeneration
        let range = selectedRange
        let valuationCurrency = ledger?.valuationCurrency ?? storedValuationCurrency(for: contextURL)
        do {
            let repository = try repository(at: contextURL)
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
                async let dashboard = repository.dashboard(
                    start: range.start,
                    end: range.queryEndExclusive,
                    valuationCurrency: valuationCurrency
                )
                async let statement = repository.incomeStatement(
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
                resource = .investments(try await repository.investments())
            }
            guard generation == requestGeneration,
                  self.contextURL == contextURL,
                  phase == .ready else {
                throw CancellationError()
            }
            return resource
        } catch let error as LedgerAPIError {
            if case let .server(status, _) = error,
               status == 423,
               generation == requestGeneration,
               self.contextURL == contextURL,
               phase == .ready {
                clearSensitiveCookie(for: contextURL)
                ledger = nil
                amountsVisible = false
                phase = .locked(authenticated: true)
            }
            throw error
        }
    }

    func importDocuments() async throws -> [LedgerImportDocument] {
        try await performSensitiveRequest { repository in
            try await repository.importDocuments()
        }
    }

    func importProviders() async throws -> [LedgerImportProviderInfo] {
        try await performSensitiveRequest { repository in
            try await repository.importProviders()
        }
    }

    func gmailAutomation() async throws -> (LedgerGmailStatus, [LedgerGmailPendingImport]) {
        try await performGmailRequest { repository in
            async let status = repository.gmailStatus()
            async let pending = repository.gmailPendingImports()
            return try await (status, pending)
        }
    }

    func connectGmail() async throws -> URL {
        let url = try await performGmailRequest { repository in
            let response = try await repository.gmailConnect()
            return response.url
        }
        guard let contextURL,
              let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
              .first(where: { $0.name == "state" })?.value,
              !state.isEmpty else {
            throw LedgerAPIError.invalidResponse
        }
        storePendingGmailOAuthState(state, for: contextURL)
        gmailOAuthResult = nil
        return url
    }

    func syncGmail(pendingID: String? = nil) async throws -> LedgerGmailSyncResult {
        try await performGmailRequest { repository in
            try await repository.gmailSync(pendingID: pendingID)
        }
    }

    func disconnectGmail() async throws {
        try await performGmailRequest { repository in
            try await repository.gmailDisconnect()
        }
        if let contextURL { clearPendingGmailOAuthState(for: contextURL) }
        gmailOAuthResult = nil
    }

    func gmailPendingImport(id: String) async throws -> LedgerGmailPendingDetail {
        try await performGmailRequest { repository in
            try await repository.gmailPendingImport(id: id)
        }
    }

    func dismissGmailPendingImport(id: String) async throws {
        try await performGmailRequest { repository in
            try await repository.dismissGmailPendingImport(id: id)
        }
    }

    func gmailPendingEvents() throws -> AsyncThrowingStream<Void, Error> {
        guard phase == .ready, let contextURL else {
            throw LedgerAPIError.incompatibleServer("当前账本会话不可用")
        }
        return try remoteRepository(at: contextURL).gmailPendingEvents()
    }

    func previewImport(
        file: LedgerImportSelectedFile,
        provider: String?,
        alipayFundRounding: Bool,
        archivePassword: String
    ) async throws -> LedgerImportPreview {
        try await performSensitiveRequest { repository in
            try await repository.previewImport(
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
        try await performSensitiveRequest { repository in
            try await repository.commitImport(
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
        guard phase == .ready, contextURL != nil else {
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
            try await performSensitiveRequest(validatesRequestGeneration: false) { repository in
                try await repository.updateTransaction(source: source, entry: entry)
            }
            confirmTransactionMutations(keys: [key], operationID: operationID)
            scheduleTransactionReconciliation()
        } catch {
            failTransactionMutations(keys: [key], operationID: operationID, error: error)
            throw error
        }
    }

    func deleteTransaction(source: TransactionSource, reason: String) async throws {
        guard phase == .ready, contextURL != nil else {
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
            try await performSensitiveRequest(validatesRequestGeneration: false) { repository in
                try await repository.deleteTransaction(source: source, reason: reason)
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
        guard phase == .ready, contextURL != nil else {
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
            try await performSensitiveRequest(validatesRequestGeneration: false) { repository in
                try await repository.addTransactionTags(sources: sources, tags: tags)
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

    /// Consume bounded pages without publishing or retaining an all-history list.
    /// performSensitiveRequest rejects late results on lock/ledger/write changes;
    /// the native cursor rejects any revision change between pages.
    func classificationEvidence(for entry: LedgerImportEntry) async throws -> ImportClassificationContext.Evidence {
        let epoch = sessionEpoch, generation = requestGeneration
        return try await performSensitiveRequest { repository in
            var accumulator = ImportClassificationContext.Accumulator(entry: entry)
            var cursor: String?
            var revision: String?
            repeat {
                try Task.checkCancellation()
                try await self.validateHistoryRead(epoch: epoch, generation: generation)
                let page = try await repository.classificationHistoryPage(cursor: cursor)
                guard page.sensitiveUnlocked, revision == nil || revision == page.revision else {
                    throw LedgerAPIError.server(status: 409, message: "历史记录已变化，请重试")
                }
                try await self.validateHistoryRead(epoch: epoch, generation: generation)
                revision = page.revision
                accumulator.consume(page.transactions)
                cursor = page.nextCursor
            } while cursor != nil
            return accumulator.evidence
        }
    }

    func bookkeepingHistory(for entry: LedgerTransactionEntry) async throws -> [LedgerTransaction] {
        guard !entry.payee.isEmpty else { return [] }
        let epoch = sessionEpoch, generation = requestGeneration
        return try await performSensitiveRequest { repository in
            var related: [LedgerTransaction] = []
            var cursor: String?
            var revision: String?
            repeat {
                try Task.checkCancellation()
                try await self.validateHistoryRead(epoch: epoch, generation: generation)
                let page = try await repository.classificationHistoryPage(cursor: cursor)
                guard page.sensitiveUnlocked, revision == nil || revision == page.revision else {
                    throw LedgerAPIError.server(status: 409, message: "历史记录已变化，请重试")
                }
                try await self.validateHistoryRead(epoch: epoch, generation: generation)
                revision = page.revision
                related = Array((related + page.transactions.filter { $0.date <= entry.date && $0.payee == entry.payee })
                    .sorted { $0.date > $1.date }.prefix(5))
                cursor = page.nextCursor
            } while cursor != nil
            return related
        }
    }

    private func validateHistoryRead(epoch: Int, generation: Int) throws {
        guard sessionEpoch == epoch, requestGeneration == generation, phase == .ready, !privacyShielded else {
            throw CancellationError()
        }
    }

    func loadGlobalTransactions(forceRefresh: Bool = false) async throws {
        if !forceRefresh, phase == .ready,
           let loadedAt = globalTransactionsLoadedAt,
           Date().timeIntervalSince(loadedAt) < 60 { return }
        let payload = try await performSensitiveRequest(validatesRequestGeneration: false) { repository in
            let payload = try await repository.globalTransactions()
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
        if isLocal { invalidateOverviewCategories() }
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
              contextURL != nil,
              !isRangeLoading,
              !isValuationCurrencyLoading else { return }
        let reconciliationID = UUID()
        transactionReconciliationID = reconciliationID
        transactionReconciliationTask = Task { [weak self] in
            guard let self else { return }
            while self.transactionReconciliationID == reconciliationID,
                  self.transactionReconciliationRequested,
                  self.phase == .ready,
                  self.contextURL != nil,
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
        for contextURL: URL,
        replacingDeviceID: String? = nil
    ) async {
        do {
            let repository = try remoteRepository(at: contextURL)
            let credential = try await repository.registerQuickUnlock(
                deviceName: "Ledger iOS · \(biometricTitle)",
                mode: "text"
            )
            guard phase == .ready, self.contextURL == contextURL else {
                try? await repository.revokeQuickUnlock(deviceID: credential.deviceID)
                return
            }
            do {
                try biometricStore.save(credential, for: contextURL)
            } catch {
                try? await repository.revokeQuickUnlock(deviceID: credential.deviceID)
                throw error
            }
            if let replacingDeviceID, replacingDeviceID != credential.deviceID {
                try? await repository.revokeQuickUnlock(deviceID: replacingDeviceID)
            }
        } catch {
            guard phase == .ready, self.contextURL == contextURL else { return }
            errorMessage = "\(biometricTitle) 快速解锁升级失败，请保持登录后重试"
        }
    }

    private func ensureWidgetCredential(for contextURL: URL, valuationCurrency: String) async {
        guard contextURL.scheme == "https", !isLocal else { return }
        guard phase == .ready,
              self.contextURL == contextURL,
              !widgetCredentialRegistrationInFlight else { return }
        guard hasBiometricUnlock else {
            recordWidgetRefreshStatus(.waitingForBiometrics)
            return
        }
        guard widgetCredentialStore.isAvailable else {
            recordWidgetRefreshStatus(.storageUnavailable)
            return
        }

        await Self.revokePendingWidgetCredential(
            using: { try self.repository(at: $0) },
            store: widgetCredentialStore
        )
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
                if existing.serverOrigin == contextURL.absoluteString,
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
                await Self.revokePendingWidgetCredential(
                    using: { try self.repository(at: $0) },
                    store: widgetCredentialStore
                )
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
            let repository = try remoteRepository(at: contextURL)
            let credential = try await repository.registerQuickUnlock(
                deviceName: "Ledger Widget",
                mode: "widget"
            )
            guard phase == .ready, self.contextURL == contextURL else {
                try? await repository.revokeQuickUnlock(deviceID: credential.deviceID)
                return
            }
            do {
                try widgetCredentialStore.save(
                    LedgerWidgetCredential(
                        serverOrigin: contextURL.absoluteString,
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
                try? await repository.revokeQuickUnlock(deviceID: credential.deviceID)
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

    private func suspendWidgetCredential(allowRemoteRevocation: Bool = true) {
        let shouldRevoke = allowRemoteRevocation && !isLocal
        let repositoryFactory: LedgerRepositoryFactory = { try self.repository(at: $0) }
        let store = widgetCredentialStore
        let currentCredential = try? store.load()
        do {
            try store.suspend()
        } catch {
            guard shouldRevoke else {
                recordWidgetRefreshStatus(.storageUnavailable)
                return
            }
            guard let currentCredential,
                  let contextURL = URL(string: currentCredential.serverOrigin) else { return }
            guard let repository = try? remoteRepository(at: contextURL) else { return }
            Task {
                await Self.revokeWidgetCredential(
                    using: repository,
                    store: store,
                    credential: currentCredential
                )
            }
            return
        }
        guard shouldRevoke else { return }
        Task {
            await Self.revokePendingWidgetCredential(using: repositoryFactory, store: store)
        }
    }

    private static func revokeWidgetCredential(
        using repository: any LedgerRemoteQuickUnlock,
        store: any LedgerWidgetCredentialStoring,
        credential: LedgerWidgetCredential
    ) async {
        do {
            try await repository.revokeWidgetQuickUnlock(credential: credential)
        } catch let error as LedgerAPIError {
            guard case let .server(status, _) = error, status == 401 else { return }
        } catch {
            return
        }
        try? store.completeRevocation(deviceID: credential.deviceID)
    }

    private static func revokePendingWidgetCredential(
        using repositoryFactory: LedgerRepositoryFactory,
        store: any LedgerWidgetCredentialStoring
    ) async {
        let credential: LedgerWidgetCredential
        do {
            guard let pending = try store.pendingRevocation() else { return }
            credential = pending
        } catch {
            return
        }
        guard let contextURL = URL(string: credential.serverOrigin) else { return }
        do {
            guard let repository = try repositoryFactory(.remote(contextURL)) as? any LedgerRemoteQuickUnlock else {
                return
            }
            try await repository.revokeWidgetQuickUnlock(credential: credential)
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
        try await performSensitiveRequest { repository in
            try await repository.indexInfo(targetGitSHA: targetGitSHA)
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
        return try await performSensitiveRequest { repository in
            try await repository.runBQL(
                query: query,
                valuationCurrency: currency
            )
        }
    }

    func loadBQLHistory() async throws -> [BQLHistoryRecord] {
        try await performSensitiveRequest { repository in
            try await repository.bqlHistory()
        }
    }

    func saveBQLHistory(query: String) async throws -> BQLHistoryRecord {
        try await performSensitiveRequest { repository in
            try await repository.saveBQLHistory(query: query)
        }
    }

    func generateBQLHistoryTitle(id: String) async throws -> BQLHistoryRecord {
        try await performSensitiveRequest { repository in
            try await repository.generateBQLHistoryTitle(id: id)
        }
    }

    func renameBQLHistory(id: String, title: String) async throws -> BQLHistoryRecord {
        try await performSensitiveRequest { repository in
            try await repository.renameBQLHistory(id: id, title: title)
        }
    }

    func deleteBQLHistory(id: String) async throws {
        try await performSensitiveRequest { repository in
            try await repository.deleteBQLHistory(id: id)
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

    func setDraftRange(_ range: LedgerDateRange) {
        draftRange = range
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
        guard let contextURL, phase == .ready, !isRangeLoading, !isValuationCurrencyLoading else { return }
        let generation = invalidateRequests()
        isRangeLoading = true
        errorMessage = nil
        do {
            try await loadLedger(
                from: contextURL,
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
        guard let contextURL else { return }
        if isLocal {
            defaults.removeObject(forKey: Self.backgroundGitAuthorizationKey)
            LocalLedgerBackgroundSyncService.shared.setEnabled(false)
        }
        clearBackgroundDate(for: contextURL)
        lockLocally(for: contextURL)
    }

    func logout() {
        if isLocal { chooseLedger(); return }
        guard let contextURL else { return }
        pendingWidgetExpenseDay = nil
        pendingExternalRoute = nil
        externalAccount = nil
        resetGlobalSearch()
        _ = invalidateSession()
        stopImportIndexTracking()
        suspendWidgetCredential()
        clearWidgetSnapshot()
        clearAuthenticationCookies(for: contextURL)
        setLocallyLocked(false, for: contextURL)
        clearBackgroundDate(for: contextURL)
        clearPendingGmailOAuthState(for: contextURL)
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
        let previousServerURL = contextURL
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
        defaults.removeObject(forKey: Self.activeLocalLedgerKey)
        ledger = nil
        location = nil
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
        defer { updateLocalSyncEligibility() }
        let wasActive = applicationActive
        applicationActive = isActive
        applicationBackground = isBackground
        if isBackground {
            if isLocalOperationBusy || (isLocal && isAuthenticationBusy) { _ = invalidateSession() }
            finishLocalAuthenticationForegroundWaiters(cancelled: true)
        } else if isActive {
            finishLocalAuthenticationForegroundWaiters(cancelled: false)
        }
        if !isActive {
            // System authentication (Face ID / Touch ID / device passcode) briefly deactivates
            // the scene while the sheet is presented. Skip shielding during that transient
            // inactive period so the privacy cover does not flash in and back out on unlock.
            if (privacyCoverArmed || isBackground) && !systemAuthenticationInProgress {
                privacyShielded = true
                privacyCoverArmed = true
                amountsVisible = false
            }
            guard isBackground, let contextURL else { return }
            automaticUnlockAttempted = false
            recordBackgroundDate(for: contextURL)
            if lockInterval == .immediately {
                lockLocally(for: contextURL)
            }
            return
        }

        refreshWidgetRefreshStatus()

        guard let contextURL else {
            privacyShielded = false
            return
        }
        if shouldLockAfterBackground(for: contextURL) {
            lockLocally(for: contextURL)
        }
        clearBackgroundDate(for: contextURL)
        amountsVisible = phase == .ready
        privacyShielded = false
        privacyCoverArmed = true
        guard !wasActive, phase == .ready, !systemAuthenticationInProgress else { return }
        Task { await restoreImportIndexTrackingIfNeeded() }
        if isLocal { scheduleLocalResumeRefresh() }
        else { await refresh() }
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
            pendingExternalRoute = nil
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
            guard let contextURL,
                  let returnedState = query.first(where: { $0.name == "state" })?.value,
                  consumePendingGmailOAuthState(returnedState, for: contextURL) else { return }
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

    func navigateToTransactions(
        kind: TransactionKindFilter = .all,
        account: String? = nil,
        tag: String? = nil,
        query: String = ""
    ) {
        var filter = LedgerTransactionFilter()
        filter.kind = kind
        filter.account = account
        if let tag, !tag.isEmpty { filter.tags = [tag] }
        filter.query = query
        self.pendingTransactionFilter = filter
        self.primaryDestinationID = LedgerDestination.transactions.rawValue
    }

    /// A day drill-down owns its payload and never replaces the global range or ledger.
    func widgetDayLedger(_ day: String) async throws -> LedgerBootstrap {
        guard LedgerWidgetLink.isValidDay(day) else {
            throw LedgerAPIError.incompatibleServer("无效的消费日期")
        }
        let range = LedgerDateRange(start: day, end: day, preset: .custom)
        let today = LedgerDateRange.today(now: ledgerNow())
        let currency = ledger?.valuationCurrency ?? "CNY"
        return try await performSensitiveRequest(validatesRequestGeneration: false) { repository in
            let payload = try await repository.bootstrap(
                start: range.start, end: range.queryEndExclusive,
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

    private func checkSession(at contextURL: URL, generation: Int, persistOrigin: Bool = false) async {
        errorMessage = nil
        do {
            let repository = try remoteRepository(at: contextURL)
            let health = try await repository.health()
            try health.validateForMobileClient()
            let auth = try await repository.authStatus()
            let passkeyStatus = isTrustedNativePasskeyOrigin(contextURL)
                ? try? await repository.passkeyStatus()
                : nil
            guard generation == requestGeneration else { return }
            accountPeriodBalancesAvailable = health.supportsAccountPeriodBalances
            privacyShielded = !applicationActive
            if persistOrigin {
                defaults.set(contextURL.absoluteString, forKey: Self.serverKey)
            }
            passkeyAvailable = passkeyStatus?.registered == true
            lockInterval = storedLockInterval(for: contextURL)
            clearBackgroundDate(for: contextURL)
            if isLocallyLocked(contextURL) {
                ledger = nil
                amountsVisible = false
                phase = .locked(authenticated: true)
            } else if auth.authDisabled {
                setLocallyLocked(false, for: contextURL)
                try await loadLedger(from: contextURL, generation: generation)
            } else if auth.authenticated && auth.sensitiveUnlocked {
                try await loadLedger(from: contextURL, generation: generation)
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
        from contextURL: URL,
        generation: Int,
        range: LedgerDateRange? = nil,
        valuationCurrency: String? = nil,
        preserveCachedLedgerOnSensitiveLock: Bool = false
    ) async throws {
        let targetRange = range ?? selectedRange
        let targetCurrency = valuationCurrency ?? storedValuationCurrency(for: contextURL)
        let source = try repository(at: contextURL)
        let local = source as? LocalLedgerRepository
        let today = LedgerDateRange.today(now: ledgerNow())
        let payload: LedgerBootstrap
        let presentationRevision: UUID?
        if let local {
            let snapshot = try await local.bootstrapSnapshot(start: targetRange.start,
                end: targetRange.queryEndExclusive, today: today, valuationCurrency: targetCurrency)
            payload = snapshot.payload
            presentationRevision = snapshot.revisionID
        } else {
            payload = try await source.bootstrap(start: targetRange.start,
                end: targetRange.queryEndExclusive, today: today, valuationCurrency: targetCurrency)
            presentationRevision = nil
        }
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
        localPresentation = local.map {
            LocalPresentation(ledgerID: $0.descriptor.id,
                revisionID: presentationRevision, today: today)
        }
        storeValuationCurrency(payload.valuationCurrency, for: contextURL)
        selectedRange = targetRange
        amountsVisible = applicationActive
        privacyShielded = !applicationActive
        if let route = pendingExternalRoute?.route, case let .search(query) = route {
            prepareExternalSearch(query)
        }
        phase = .ready
        Task { await restoreImportIndexTrackingIfNeeded() }
        if local != nil { await refreshLocalOverviewCategories() }
        guard generation == requestGeneration else { return }
        await publishWidgetSnapshot(
            ledger: payload,
            contextURL: contextURL,
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
        contextURL: URL,
        valuationCurrency: String,
        generation: Int
    ) async {
        let widgetRefreshAttemptAt = ledgerNow()
        let month = LedgerDateRange.current(.month, now: widgetRefreshAttemptAt)
        let today = LedgerDateRange.today(now: widgetRefreshAttemptAt)
        let weekStart = LedgerWidgetDates.weekStart(today)
        guard let repository = try? repository(at: contextURL) else { return }
        async let weekRequest: LedgerHomeReport? = try? await repository.homeReport(
            start: weekStart, end: LedgerWidgetDates.adding(7, to: weekStart),
            valuationCurrency: valuationCurrency
        )
        async let yearRequest: LedgerHomeReport? = try? await repository.homeReport(
            start: String(today.prefix(4)) + "-01-01",
            end: String((Int(today.prefix(4)) ?? 2026) + 1) + "-01-01", valuationCurrency: valuationCurrency
        )
        async let historyRequest: LedgerHomeReport? = try? await repository.homeReport(
            start: LedgerWidgetDates.adding(-77, to: weekStart),
            end: LedgerWidgetDates.adding(1, to: today), valuationCurrency: valuationCurrency
        )
        async let reportRequest: LedgerHomeReport? = try? await repository.homeReport(
            start: month.start,
            end: month.queryEndExclusive,
            valuationCurrency: valuationCurrency
        )
        async let importDocumentsRequest: [LedgerImportDocument]? = try? await repository.importDocuments()
        let (report, importDocuments, week, year, history) = await (reportRequest, importDocumentsRequest, weekRequest, yearRequest, historyRequest)
        guard generation == requestGeneration, self.contextURL == contextURL else {
            return
        }
        await ensureWidgetCredential(for: contextURL, valuationCurrency: valuationCurrency)
        // Credential registration can suspend while the user ends or locks this session.
        guard generation == requestGeneration, self.contextURL == contextURL, phase == .ready else {
            return
        }
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

    private func handleBootstrapSessionError(_ error: Error, contextURL: URL) {
        errorMessage = error.localizedDescription
        guard let apiError = error as? LedgerAPIError,
              case let .server(status, _) = apiError,
              status == 401 || status == 423 else { return }
        _ = invalidateSession()
        clearTransactionMutations()
        ledger = nil
        amountsVisible = false
        if status == 401 {
            clearAuthenticationCookies(for: contextURL)
            setLocallyLocked(false, for: contextURL)
            phase = .locked(authenticated: false)
        } else {
            clearSensitiveCookie(for: contextURL)
            phase = .locked(authenticated: true)
        }
    }

    private func storedValuationCurrency(for contextURL: URL) -> String {
        let currencies = defaults.dictionary(forKey: Self.valuationCurrenciesKey) as? [String: String]
        let stored = currencies?[contextURL.absoluteString]?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let stored, !stored.isEmpty { return stored }
        return "CNY"
    }

    private func storeValuationCurrency(_ currency: String, for contextURL: URL) {
        let normalized = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return }
        var currencies = defaults.dictionary(forKey: Self.valuationCurrenciesKey) as? [String: String] ?? [:]
        currencies[contextURL.absoluteString] = normalized
        defaults.set(currencies, forKey: Self.valuationCurrenciesKey)
    }

    private func storePendingGmailOAuthState(_ state: String, for contextURL: URL) {
        var states = pendingGmailOAuthStates()
        var values = states[contextURL.absoluteString] ?? []
        values.removeAll { $0 == state }
        values.append(state)
        states[contextURL.absoluteString] = Array(values.suffix(8))
        savePendingGmailOAuthStates(states)
    }

    private func consumePendingGmailOAuthState(_ state: String, for contextURL: URL) -> Bool {
        var states = pendingGmailOAuthStates()
        guard var values = states[contextURL.absoluteString],
              let index = values.firstIndex(of: state) else { return false }
        values.remove(at: index)
        if values.isEmpty {
            states.removeValue(forKey: contextURL.absoluteString)
        } else {
            states[contextURL.absoluteString] = values
        }
        savePendingGmailOAuthStates(states)
        return true
    }

    private func clearPendingGmailOAuthState(for contextURL: URL) {
        var states = pendingGmailOAuthStates()
        states.removeValue(forKey: contextURL.absoluteString)
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

    /// Each location retains one repository for this session's lifetime.
    func repository(at location: LedgerLocation) throws -> any LedgerRepository {
        if localOnly, case .remote = location {
            throw LedgerRepositoryError.unsupportedLocation(location)
        }
        if let cached = repositories[location] { return cached }
        let repository = try repositoryFactory(location)
        repositories[location] = repository
        return repository
    }

    var activeRepository: (any LedgerRepository)? {
        get throws {
            guard let location else { return nil }
            return try repository(at: location)
        }
    }

    private func repository(at contextURL: URL) throws -> any LedgerRepository {
        if contextURL.scheme == "ledger-local", let host = contextURL.host, let id = UUID(uuidString: host) {
            return try repository(at: .local(id))
        }
        return try repository(at: .remote(contextURL))
    }

    private func remoteRepository(at contextURL: URL) throws -> any RemoteLedgerCapabilities {
        guard let remote = try repository(at: contextURL) as? any RemoteLedgerCapabilities else {
            throw LedgerRepositoryError.capabilityUnavailable("remote services")
        }
        return remote
    }

    private func performGmailRequest<Value: Sendable>(
        _ operation: @Sendable (any LedgerRemoteGmail) async throws -> Value
    ) async throws -> Value {
        try await performSensitiveRequest { repository in
            guard let gmail = repository as? any LedgerRemoteGmail else {
                throw LedgerRepositoryError.capabilityUnavailable("Gmail")
            }
            return try await operation(gmail)
        }
    }

    private func performSensitiveRequest<Value: Sendable>(
        validatesRequestGeneration: Bool = true,
        _ operation: @Sendable (any LedgerRepository) async throws -> Value
    ) async throws -> Value {
        guard phase == .ready, let contextURL else {
            throw LedgerAPIError.incompatibleServer("当前账本会话不可用")
        }
        let generation = requestGeneration
        let epoch = sessionEpoch
        do {
            let value = try await operation(repository(at: contextURL))
            guard (!validatesRequestGeneration || generation == requestGeneration),
                  epoch == sessionEpoch,
                  self.contextURL == contextURL,
                  phase == .ready else {
                throw CancellationError()
            }
            return value
        } catch let error as LedgerAPIError {
            if case let .server(status, _) = error,
               status == 401 || status == 423,
               (!validatesRequestGeneration || generation == requestGeneration),
               epoch == sessionEpoch,
                self.contextURL == contextURL,
                phase == .ready {
                _ = invalidateSession()
                clearTransactionMutations()
                ledger = nil
                amountsVisible = false
                if status == 401 {
                    clearAuthenticationCookies(for: contextURL)
                    setLocallyLocked(false, for: contextURL)
                    phase = .locked(authenticated: false)
                } else {
                    clearSensitiveCookie(for: contextURL)
                    phase = .locked(authenticated: true)
                }
            }
            throw error
        }
    }

    private func invalidateOverviewCategories() {
        overviewCategoriesGeneration &+= 1
        localOverviewCategories = nil
        localOverviewCategoriesError = nil
        isLocalOverviewCategoriesLoading = false
    }

    /// Never substitute bootstrap/global transaction arrays for a failed local
    /// aggregate: those arrays will eventually be independently bounded.
    func refreshLocalOverviewCategories() async {
        guard phase == .ready, let repository = localRepository,
              let presentation = localPresentation,
              presentation.ledgerID == repository.descriptor.id,
              let revisionID = presentation.revisionID else { return }
        invalidateOverviewCategories()
        let token = overviewCategoriesGeneration, generation = requestGeneration
        let epoch = sessionEpoch, expectedLocation = location, range = selectedRange
        isLocalOverviewCategoriesLoading = true
        func isCurrent() -> Bool {
            token == overviewCategoriesGeneration && generation == requestGeneration
                && epoch == sessionEpoch && location == expectedLocation && phase == .ready
                && selectedRange == range && localPresentation?.revisionID == revisionID
        }
        defer { if isCurrent() { isLocalOverviewCategoriesLoading = false } }
        do {
            let result = try await repository.overviewCategories(start: range.start,
                end: range.queryEndExclusive, expectedRevisionID: revisionID)
            // A writer may have published while the pinned engine read was suspended.
            let current = try await repository.workspace.currentRevision()
            guard isCurrent(), !Task.isCancelled else { return }
            guard current?.id == revisionID else { throw LocalLedgerWorkspace.WorkspaceError.staleRevision }
            localOverviewCategories = result
        } catch {
            guard isCurrent(), !Task.isCancelled else { return }
            localOverviewCategoriesError = error.localizedDescription
        }
    }

    @discardableResult
    private func invalidateRequests() -> Int {
        invalidateOverviewCategories()
        requestGeneration &+= 1
        return requestGeneration
    }

    @discardableResult
    private func invalidateSession() -> Int {
        localResumeTask?.cancel()
        localResumeTask = nil
        localResumeID = nil
        localSyncCoordinator?.setEligible(false)
        backgroundLocalSyncTask?.cancel()
        localSyncStatus = nil
        finishLocalAuthenticationForegroundWaiters(cancelled: true)
        globalTransactions = []
        globalTransactionsLoadedAt = nil
        sessionEpoch &+= 1
        return invalidateRequests()
    }

    private func clearAuthenticationCookies(for contextURL: URL) {
        clearCookies(named: [Self.sessionCookieName, Self.sensitiveCookieName], for: contextURL)
    }

    private func clearSensitiveCookie(for contextURL: URL) {
        clearCookies(named: [Self.sensitiveCookieName], for: contextURL)
    }

    private func clearCookies(named names: Set<String>, for contextURL: URL) {
        guard contextURL.scheme == "https" else { return }
        guard let host = contextURL.host else { return }
        for cookie in HTTPCookieStorage.shared.cookies ?? [] {
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if names.contains(cookie.name), host == domain || host.hasSuffix(".\(domain)") {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
    }

    private func isLocallyLocked(_ contextURL: URL) -> Bool {
        Set(defaults.stringArray(forKey: Self.locallyLockedOriginsKey) ?? []).contains(contextURL.absoluteString)
    }

    private func setLocallyLocked(_ locked: Bool, for contextURL: URL) {
        var origins = Set(defaults.stringArray(forKey: Self.locallyLockedOriginsKey) ?? [])
        if locked {
            origins.insert(contextURL.absoluteString)
        } else {
            origins.remove(contextURL.absoluteString)
        }
        defaults.set(origins.sorted(), forKey: Self.locallyLockedOriginsKey)
    }

    private func storedLockInterval(for contextURL: URL) -> LedgerLockInterval {
        let intervals = defaults.dictionary(forKey: Self.lockIntervalsKey) as? [String: Int]
        guard let rawValue = intervals?[contextURL.absoluteString],
              let interval = LedgerLockInterval(rawValue: rawValue) else {
            return .fiveMinutes
        }
        return interval
    }

    private func isTrustedNativePasskeyOrigin(_ contextURL: URL) -> Bool {
        nativePasskeyEnabled
            && contextURL.scheme?.lowercased() == "https"
            && contextURL.host?.lowercased() == Self.passkeyRelyingPartyID
            && contextURL.port == nil
    }

    private var nativePasskeyEnabled: Bool {
        Self.nativePasskeyEnabledForCurrentBuild
    }

    private func recordBackgroundDate(for contextURL: URL, now: Date? = nil) {
        var dates = defaults.dictionary(forKey: Self.backgroundDatesKey) as? [String: Double] ?? [:]
        guard dates[contextURL.absoluteString] == nil else { return }
        dates[contextURL.absoluteString] = (now ?? ledgerNow()).timeIntervalSince1970
        defaults.set(dates, forKey: Self.backgroundDatesKey)
    }

    private func clearBackgroundDate(for contextURL: URL) {
        var dates = defaults.dictionary(forKey: Self.backgroundDatesKey) as? [String: Double] ?? [:]
        dates.removeValue(forKey: contextURL.absoluteString)
        defaults.set(dates, forKey: Self.backgroundDatesKey)
    }

    private func shouldLockAfterBackground(for contextURL: URL, now: Date? = nil) -> Bool {
        let dates = defaults.dictionary(forKey: Self.backgroundDatesKey) as? [String: Double]
        guard let timestamp = dates?[contextURL.absoluteString] else { return false }
        let elapsed = max(0, (now ?? ledgerNow()).timeIntervalSince1970 - timestamp)
        return elapsed >= TimeInterval(storedLockInterval(for: contextURL).rawValue)
    }

    private func lockLocally(for contextURL: URL) {
        guard self.contextURL == contextURL else { return }
        if case .locked = phase { return }
        _ = invalidateSession()
        stopImportIndexTracking()
        setLocallyLocked(true, for: contextURL)
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
            reconciliationRows: reconciliationRows,
            accounts: accounts,
            commodities: commodities,
            prices: prices,
            valuationCurrency: valuationCurrency,
            accountStatuses: accountStatuses,
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
