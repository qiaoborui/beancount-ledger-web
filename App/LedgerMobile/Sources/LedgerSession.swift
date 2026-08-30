import Foundation

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

@MainActor
final class LedgerSession: ObservableObject {
    nonisolated static let passkeyRelyingPartyID = "beancount.borry.org"

    enum Phase: Equatable {
        case configuration
        case checking
        case locked(authenticated: Bool)
        case loading
        case ready
    }

    @Published private(set) var phase: Phase
    @Published private(set) var ledger: LedgerBootstrap?
    @Published private(set) var serverURL: URL?
    @Published var serverInput: String
    @Published var password = ""
    @Published var errorMessage: String?
    @Published var amountsVisible = true
    @Published var primaryDestinationID = "overview"
    @Published private(set) var selectedRange: LedgerDateRange
    @Published private(set) var draftRange: LedgerDateRange
    @Published private(set) var isRangeLoading = false
    @Published var rangePickerPresented = false
    @Published private(set) var passkeyAvailable = false
    @Published private(set) var privacyShielded = true
    @Published private(set) var isBiometricSettingBusy = false
    @Published private(set) var lockInterval: LedgerLockInterval = .fiveMinutes

    private let api: any LedgerAPI
    private let biometricStore: any BiometricCredentialStore
    private let passkeyAuthenticator: any PasskeyAuthenticating
    private let defaults: UserDefaults
    private var applicationActive = true
    private var requestGeneration = 0
    private static let serverKey = "ledger.mobile.server-origin"
    private static let locallyLockedOriginsKey = "ledger.mobile.locally-locked-origins"
    private static let lockIntervalsKey = "ledger.mobile.lock-intervals"
    private static let backgroundDatesKey = "ledger.mobile.background-dates"
    private static let sessionCookieName = "ledger_session"
    private static let sensitiveCookieName = "ledger_sensitive_until"

    init(
        api: (any LedgerAPI)? = nil,
        defaults: UserDefaults = .standard,
        biometricStore: (any BiometricCredentialStore)? = nil,
        passkeyAuthenticator: (any PasskeyAuthenticating)? = nil
    ) {
        let initialRange = LedgerDateRange.current(.month)
        selectedRange = initialRange
        draftRange = initialRange
        self.defaults = defaults
        self.biometricStore = biometricStore ?? SystemBiometricCredentialStore()
        self.passkeyAuthenticator = passkeyAuthenticator ?? SystemPasskeyAuthenticationService()

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
        let normalized = try? ServerConfiguration.normalize(stored)
        serverInput = stored
        serverURL = normalized
        phase = normalized == nil ? .configuration : .checking
        privacyShielded = normalized != nil
        if let normalized {
            lockInterval = storedLockInterval(for: normalized)
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

    func resume() async {
        guard phase == .checking, let serverURL else { return }
        await checkSession(at: serverURL, generation: requestGeneration)
    }

    func saveServer() async {
        guard case .configuration = phase else { return }
        do {
            let normalized = try ServerConfiguration.normalize(serverInput)
            serverURL = normalized
            serverInput = normalized.absoluteString
            errorMessage = nil
            phase = .checking
            let generation = invalidateRequests()
            await checkSession(at: normalized, generation: generation, persistOrigin: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func login() async {
        guard case let .locked(authenticated) = phase, let serverURL else { return }
        let candidate = password
        guard !candidate.isEmpty else {
            errorMessage = "请输入账本密码"
            return
        }

        let generation = invalidateRequests()
        phase = .loading
        errorMessage = nil
        do {
            try await api.login(baseURL: serverURL, password: candidate)
            guard generation == requestGeneration else {
                clearAuthenticationCookies(for: serverURL)
                return
            }
            setLocallyLocked(false, for: serverURL)
            password = ""
            try await loadLedger(from: serverURL, generation: generation)
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
              isTrustedNativePasskeyOrigin(serverURL) else { return }
        let generation = invalidateRequests()
        phase = .loading
        errorMessage = nil
        do {
            let options = try await api.passkeyLoginOptions(baseURL: serverURL)
            let assertion = try await passkeyAuthenticator.authenticate(
                options: options,
                relyingPartyID: Self.passkeyRelyingPartyID
            )
            try await api.verifyPasskey(baseURL: serverURL, assertion: assertion)
            guard generation == requestGeneration else {
                clearAuthenticationCookies(for: serverURL)
                return
            }
            setLocallyLocked(false, for: serverURL)
            try await loadLedger(from: serverURL, generation: generation)
        } catch {
            guard generation == requestGeneration else { return }
            errorMessage = error.localizedDescription
            phase = .locked(authenticated: authenticated)
        }
    }

    func unlockWithBiometrics() async {
        guard case let .locked(authenticated) = phase, let serverURL, hasBiometricUnlock else { return }
        let generation = invalidateRequests()
        phase = .loading
        errorMessage = nil
        do {
            let credential = try await biometricStore.readCredential(
                for: serverURL,
                reason: "使用 \(biometricTitle) 解锁账本金额"
            )
            try await api.verifyQuickUnlock(baseURL: serverURL, credential: credential)
            guard generation == requestGeneration else {
                clearAuthenticationCookies(for: serverURL)
                return
            }
            setLocallyLocked(false, for: serverURL)
            try await loadLedger(from: serverURL, generation: generation)
        } catch {
            guard generation == requestGeneration else { return }
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
                    deviceName: "Ledger iOS · \(biometricTitle)"
                )
                do {
                    try biometricStore.save(credential, for: serverURL)
                } catch {
                    try? await api.revokeQuickUnlock(baseURL: serverURL, deviceID: credential.deviceID)
                    throw error
                }
            } catch {
                errorMessage = "\(biometricTitle) 启用失败：\(error.localizedDescription)"
            }
            return
        }

        do {
            let credential = try await biometricStore.readCredential(
                for: serverURL,
                reason: "验证后停用 \(biometricTitle) 快速解锁"
            )
            try await api.revokeQuickUnlock(baseURL: serverURL, deviceID: credential.deviceID)
            biometricStore.deleteCredential(for: serverURL)
        } catch {
            errorMessage = "\(biometricTitle) 停用失败：\(error.localizedDescription)"
        }
    }

    func setLockInterval(_ interval: LedgerLockInterval) {
        guard let serverURL else { return }
        lockInterval = interval
        var intervals = defaults.dictionary(forKey: Self.lockIntervalsKey) as? [String: Int] ?? [:]
        intervals[serverURL.absoluteString] = interval.rawValue
        defaults.set(intervals, forKey: Self.lockIntervalsKey)
    }

    func refresh() async {
        guard let serverURL, !isRangeLoading else { return }
        let generation = invalidateRequests()
        do {
            try await loadLedger(from: serverURL, showLoadingState: false, generation: generation)
            guard generation == requestGeneration else { return }
            errorMessage = nil
        } catch {
            guard generation == requestGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func accountDetail(for account: String) async throws -> LedgerAccountDetail {
        guard phase == .ready, let serverURL else {
            throw LedgerAPIError.incompatibleServer("当前账本会话不可用")
        }
        let generation = requestGeneration
        do {
            let detail = try await api.accountDetail(baseURL: serverURL, account: account)
            guard generation == requestGeneration,
                  self.serverURL == serverURL,
                  phase == .ready else {
                throw CancellationError()
            }
            return detail
        } catch let error as LedgerAPIError {
            if case let .server(status, _) = error,
               status == 423,
               generation == requestGeneration,
               self.serverURL == serverURL,
               phase == .ready {
                setLocallyLocked(true, for: serverURL)
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
        do {
            let resource: LedgerAnalysisResource
            switch kind {
            case .dashboard:
                resource = .dashboard(
                    try await api.dashboard(
                        baseURL: serverURL,
                        start: range.start,
                        end: range.queryEndExclusive
                    )
                )
            case .incomeStatement:
                resource = .incomeStatement(
                    try await api.incomeStatement(
                        baseURL: serverURL,
                        start: range.start,
                        end: range.queryEndExclusive
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
                setLocallyLocked(true, for: serverURL)
                clearSensitiveCookie(for: serverURL)
                ledger = nil
                amountsVisible = false
                phase = .locked(authenticated: true)
            }
            throw error
        }
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
        draftRange = LedgerDateRange.current(preset)
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
        guard let serverURL, phase == .ready, !isRangeLoading else { return }
        let generation = invalidateRequests()
        isRangeLoading = true
        errorMessage = nil
        do {
            try await loadLedger(
                from: serverURL,
                showLoadingState: false,
                generation: generation,
                range: range
            )
            guard generation == requestGeneration else { return }
            isRangeLoading = false
        } catch {
            guard generation == requestGeneration else { return }
            isRangeLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func lock() async {
        guard let serverURL else { return }
        let generation = invalidateRequests()
        isRangeLoading = false
        rangePickerPresented = false
        setLocallyLocked(true, for: serverURL)
        clearBackgroundDate(for: serverURL)
        clearSensitiveCookie(for: serverURL)
        ledger = nil
        amountsVisible = false
        privacyShielded = false
        phase = .loading
        do {
            try await api.lock(baseURL: serverURL)
            guard generation == requestGeneration else { return }
        } catch {
            guard generation == requestGeneration else { return }
            errorMessage = error.localizedDescription
        }
        phase = .locked(authenticated: true)
    }

    func logout() {
        guard let serverURL else { return }
        _ = invalidateRequests()
        clearAuthenticationCookies(for: serverURL)
        setLocallyLocked(false, for: serverURL)
        clearBackgroundDate(for: serverURL)
        ledger = nil
        password = ""
        amountsVisible = false
        isRangeLoading = false
        rangePickerPresented = false
        privacyShielded = false
        phase = .locked(authenticated: false)
    }

    func changeServer() {
        let previousServerURL = serverURL
        _ = invalidateRequests()
        if let previousServerURL {
            biometricStore.deleteCredential(for: previousServerURL)
            clearAuthenticationCookies(for: previousServerURL)
            setLocallyLocked(false, for: previousServerURL)
            clearBackgroundDate(for: previousServerURL)
        }
        defaults.removeObject(forKey: Self.serverKey)
        ledger = nil
        self.serverURL = nil
        serverInput = ""
        password = ""
        errorMessage = nil
        amountsVisible = false
        let initialRange = LedgerDateRange.current(.month)
        selectedRange = initialRange
        draftRange = initialRange
        isRangeLoading = false
        rangePickerPresented = false
        passkeyAvailable = false
        lockInterval = .fiveMinutes
        privacyShielded = false
        phase = .configuration
    }

    func updateActivity(isActive: Bool) {
        applicationActive = isActive
        if !isActive {
            privacyShielded = true
            amountsVisible = false
            guard phase == .ready, let serverURL else { return }
            recordBackgroundDate(for: serverURL)
            if lockInterval == .immediately {
                lockLocallyAfterBackground(for: serverURL)
            }
            return
        }

        guard let serverURL else {
            privacyShielded = false
            return
        }
        if shouldLockAfterBackground(for: serverURL) {
            lockLocallyAfterBackground(for: serverURL)
        }
        clearBackgroundDate(for: serverURL)
        amountsVisible = phase == .ready
        privacyShielded = false
    }

    func toggleAmounts() {
        amountsVisible.toggle()
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
            privacyShielded = !applicationActive
            if persistOrigin {
                defaults.set(serverURL.absoluteString, forKey: Self.serverKey)
            }
            passkeyAvailable = passkeyStatus?.registered == true
            lockInterval = storedLockInterval(for: serverURL)
            if shouldLockAfterBackground(for: serverURL) {
                setLocallyLocked(true, for: serverURL)
                clearSensitiveCookie(for: serverURL)
            }
            clearBackgroundDate(for: serverURL)
            if auth.authDisabled {
                setLocallyLocked(false, for: serverURL)
                try await loadLedger(from: serverURL, generation: generation)
            } else if isLocallyLocked(serverURL) {
                ledger = nil
                amountsVisible = false
                phase = .locked(authenticated: auth.authenticated)
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
        showLoadingState: Bool = true,
        generation: Int,
        range: LedgerDateRange? = nil
    ) async throws {
        if showLoadingState { phase = .loading }
        let targetRange = range ?? selectedRange
        let payload = try await api.bootstrap(
            baseURL: serverURL,
            start: targetRange.start,
            end: targetRange.queryEndExclusive,
            today: LedgerDateRange.today()
        )
        guard generation == requestGeneration else { return }
        guard payload.sensitiveUnlocked else {
            ledger = nil
            amountsVisible = false
            phase = .locked(authenticated: true)
            return
        }
        ledger = payload
        selectedRange = targetRange
        amountsVisible = applicationActive
        privacyShielded = !applicationActive
        phase = .ready
    }

    private func performSensitiveRequest<Value: Sendable>(
        _ operation: @Sendable (any LedgerAPI, URL) async throws -> Value
    ) async throws -> Value {
        guard phase == .ready, let serverURL else {
            throw LedgerAPIError.incompatibleServer("当前账本会话不可用")
        }
        let generation = requestGeneration
        do {
            let value = try await operation(api, serverURL)
            guard generation == requestGeneration,
                  self.serverURL == serverURL,
                  phase == .ready else {
                throw CancellationError()
            }
            return value
        } catch let error as LedgerAPIError {
            if case let .server(status, _) = error,
               status == 401 || status == 423,
               generation == requestGeneration,
               self.serverURL == serverURL,
               phase == .ready {
                ledger = nil
                amountsVisible = false
                if status == 401 {
                    clearAuthenticationCookies(for: serverURL)
                    setLocallyLocked(false, for: serverURL)
                    phase = .locked(authenticated: false)
                } else {
                    clearSensitiveCookie(for: serverURL)
                    setLocallyLocked(true, for: serverURL)
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
        serverURL.scheme?.lowercased() == "https"
            && serverURL.host?.lowercased() == Self.passkeyRelyingPartyID
            && serverURL.port == nil
    }

    private func recordBackgroundDate(for serverURL: URL, now: Date = Date()) {
        var dates = defaults.dictionary(forKey: Self.backgroundDatesKey) as? [String: Double] ?? [:]
        dates[serverURL.absoluteString] = now.timeIntervalSince1970
        defaults.set(dates, forKey: Self.backgroundDatesKey)
    }

    private func clearBackgroundDate(for serverURL: URL) {
        var dates = defaults.dictionary(forKey: Self.backgroundDatesKey) as? [String: Double] ?? [:]
        dates.removeValue(forKey: serverURL.absoluteString)
        defaults.set(dates, forKey: Self.backgroundDatesKey)
    }

    private func shouldLockAfterBackground(for serverURL: URL, now: Date = Date()) -> Bool {
        let dates = defaults.dictionary(forKey: Self.backgroundDatesKey) as? [String: Double]
        guard let timestamp = dates?[serverURL.absoluteString] else { return false }
        let elapsed = max(0, now.timeIntervalSince1970 - timestamp)
        return elapsed >= TimeInterval(storedLockInterval(for: serverURL).rawValue)
    }

    private func lockLocallyAfterBackground(for serverURL: URL) {
        guard phase == .ready else { return }
        _ = invalidateRequests()
        setLocallyLocked(true, for: serverURL)
        clearSensitiveCookie(for: serverURL)
        ledger = nil
        amountsVisible = false
        isRangeLoading = false
        rangePickerPresented = false
        phase = .locked(authenticated: true)
    }

}
