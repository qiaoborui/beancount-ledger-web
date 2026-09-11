import Foundation
import CoreFoundation
import Darwin
import Security

private final class LedgerWidgetProcessLockRegistry: @unchecked Sendable {
    static let shared = LedgerWidgetProcessLockRegistry()

    private let registryLock = NSLock()
    private var locks: [String: NSLock] = [:]

    func lock(for suiteName: String) -> NSLock {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locks[suiteName] { return existing }
        let lock = NSLock()
        locks[suiteName] = lock
        return lock
    }
}

struct LedgerWidgetSharedStoreCoordinator: Sendable {
    let suiteName: String

    func withLock<T>(_ operation: () throws -> T) throws -> T {
        let processLock = LedgerWidgetProcessLockRegistry.shared.lock(for: suiteName)
        processLock.lock()
        defer { processLock.unlock() }

        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: suiteName
        ) else {
            return try operation()
        }
        let lockURL = containerURL.appendingPathComponent(".ledger-widget-store.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LedgerWidgetCredentialStoreError.unavailable }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw LedgerWidgetCredentialStoreError.unavailable
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}

final class LedgerWidgetRefreshStatusObserver: @unchecked Sendable {
    private let handler: @Sendable () -> Void
    private let notificationName: CFNotificationName
    private var localObserver: NSObjectProtocol?

    init(store: LedgerWidgetRefreshStatusStore, handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        notificationName = store.changeNotificationName
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let statusObserver = Unmanaged<LedgerWidgetRefreshStatusObserver>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                statusObserver.handler()
            },
            notificationName.rawValue,
            nil,
            .deliverImmediately
        )
        localObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name(store.changeNotificationNameValue),
            object: nil,
            queue: nil
        ) { [handler] _ in
            handler()
        }
    }

    deinit {
        if let localObserver {
            NotificationCenter.default.removeObserver(localObserver)
        }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            notificationName,
            nil
        )
    }
}

struct LedgerWidgetCredential: Codable, Equatable, Sendable {
    let serverOrigin: String
    let deviceID: String
    let token: String
    let valuationCurrency: String
    let enabled: Bool
    let expiresAt: String?

    init(
        serverOrigin: String,
        deviceID: String,
        token: String,
        valuationCurrency: String,
        enabled: Bool,
        expiresAt: String? = nil
    ) {
        self.serverOrigin = serverOrigin
        self.deviceID = deviceID
        self.token = token
        self.valuationCurrency = valuationCurrency
        self.enabled = enabled
        self.expiresAt = expiresAt
    }

    func updating(valuationCurrency: String? = nil, enabled: Bool? = nil) -> LedgerWidgetCredential {
        LedgerWidgetCredential(
            serverOrigin: serverOrigin,
            deviceID: deviceID,
            token: token,
            valuationCurrency: valuationCurrency ?? self.valuationCurrency,
            enabled: enabled ?? self.enabled,
            expiresAt: expiresAt
        )
    }
}

enum LedgerWidgetRefreshPhase: String, Codable, Equatable, Sendable {
    case waitingForBiometrics
    case provisioning
    case ready
    case refreshing
    case success
    case credentialUnavailable
    case authorizationRejected
    case serverOutdated
    case serverUnavailable
    case invalidConfiguration
    case invalidResponse
    case networkUnavailable
    case storageUnavailable
}

struct LedgerWidgetRefreshStatus: Codable, Equatable, Sendable {
    let phase: LedgerWidgetRefreshPhase
    let lastAttemptAt: Date?
    let lastSuccessAt: Date?
    let httpStatus: Int?

    init(
        phase: LedgerWidgetRefreshPhase,
        lastAttemptAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        httpStatus: Int? = nil
    ) {
        self.phase = phase
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.httpStatus = httpStatus
    }
}

struct LedgerWidgetRefreshStatusStore: Sendable {
    static let statusKey = "ledger.widgets.refresh-status.v1"
    static let notificationNonceKey = "ledger.widgets.refresh-notification-nonce.v1"
    static let shared = LedgerWidgetRefreshStatusStore()

    let suiteName: String
    let changeNotificationNameValue: String

    init(suiteName: String = LedgerWidgetSnapshotStore.appGroupIdentifier) {
        self.suiteName = suiteName
        let coordinator = LedgerWidgetSharedStoreCoordinator(suiteName: suiteName)
        let nonce = try? coordinator.withLock {
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                throw LedgerWidgetCredentialStoreError.unavailable
            }
            _ = defaults.synchronize()
            if let existing = defaults.string(forKey: Self.notificationNonceKey) {
                return existing
            }
            let generated = UUID().uuidString.lowercased()
            defaults.set(generated, forKey: Self.notificationNonceKey)
            _ = defaults.synchronize()
            return generated
        }
        changeNotificationNameValue = "com.qiaoborui.ledger.widget-refresh-status.\(nonce ?? UUID().uuidString.lowercased())"
    }

    func load() -> LedgerWidgetRefreshStatus? {
        try? coordinator.withLock {
            guard let defaults else { return nil }
            _ = defaults.synchronize()
            return load(from: defaults)
        }
    }

    func record(
        _ phase: LedgerWidgetRefreshPhase,
        attemptedAt: Date? = nil,
        succeededAt: Date? = nil,
        httpStatus: Int? = nil
    ) throws {
        try coordinator.withLock {
            guard let defaults else { throw LedgerWidgetCredentialStoreError.unavailable }
            _ = defaults.synchronize()
            let previous = load(from: defaults)
            if let attemptedAt,
               let previousAttempt = previous?.lastAttemptAt,
               attemptedAt < previousAttempt {
                return
            }
            let status = LedgerWidgetRefreshStatus(
                phase: phase,
                lastAttemptAt: attemptedAt ?? previous?.lastAttemptAt,
                lastSuccessAt: succeededAt ?? previous?.lastSuccessAt,
                httpStatus: httpStatus
            )
            defaults.set(try JSONEncoder().encode(status), forKey: Self.statusKey)
            _ = defaults.synchronize()
        }
        postChange()
    }

    func clear() {
        try? coordinator.withLock {
            defaults?.removeObject(forKey: Self.statusKey)
            _ = defaults?.synchronize()
        }
        postChange()
    }

    var changeNotificationName: CFNotificationName {
        CFNotificationName(rawValue: changeNotificationNameValue as CFString)
    }

    private var coordinator: LedgerWidgetSharedStoreCoordinator {
        LedgerWidgetSharedStoreCoordinator(suiteName: suiteName)
    }

    private func load(from defaults: UserDefaults) -> LedgerWidgetRefreshStatus? {
        guard let data = defaults.data(forKey: Self.statusKey) else { return nil }
        return try? JSONDecoder().decode(LedgerWidgetRefreshStatus.self, from: data)
    }

    private func postChange() {
        NotificationCenter.default.post(
            name: Notification.Name(changeNotificationNameValue),
            object: nil
        )
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            changeNotificationName,
            nil,
            nil,
            true
        )
    }

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }
}

protocol LedgerWidgetCredentialStoring: Sendable {
    var isAvailable: Bool { get }
    func load() throws -> LedgerWidgetCredential?
    func save(_ credential: LedgerWidgetCredential) throws
    func suspend() throws
    func pendingRevocation() throws -> LedgerWidgetCredential?
    func completeRevocation(deviceID: String) throws
}

enum LedgerWidgetCredentialStoreError: LocalizedError {
    case unavailable
    case keychain(OSStatus)
    case invalidCredential
    case pendingRevocation

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "无法访问小组件安全凭据空间"
        case let .keychain(status):
            "无法保存小组件安全凭据（\(status)）"
        case .invalidCredential:
            "小组件安全凭据已损坏"
        case .pendingRevocation:
            "旧的小组件凭据仍在等待撤销"
        }
    }
}

final class SystemLedgerWidgetCredentialStore: LedgerWidgetCredentialStoring, @unchecked Sendable {
    static let accessGroupInfoKey = LedgerSharedAccess.widgetKeychainInfoKey

    private let service = "com.qiaoborui.ledger.mobile.widget-access"
    private let account = "current"
    private let accessGroup: String?
    private let sharedDefaults: UserDefaults?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let activeCredentialKeyKey = "ledger.widgets.active-credential-key.v1"

    convenience init(
        accessGroup: String? = SystemLedgerWidgetCredentialStore.configuredAccessGroup(),
        suiteName: String = LedgerWidgetSnapshotStore.appGroupIdentifier
    ) {
        self.init(accessGroup: accessGroup, sharedDefaults: UserDefaults(suiteName: suiteName))
    }

    init(accessGroup: String?, sharedDefaults: UserDefaults?) {
        self.accessGroup = accessGroup
        self.sharedDefaults = sharedDefaults
    }

    var isAvailable: Bool { accessGroup != nil && sharedDefaults != nil }

    func load() throws -> LedgerWidgetCredential? {
        guard let credential = try loadRaw() else { return nil }
        guard activeCredentialKey() == credential.blockKey else { return nil }
        return credential
    }

    func pendingRevocation() throws -> LedgerWidgetCredential? {
        guard let credential = try loadRaw() else { return nil }
        return activeCredentialKey() == credential.blockKey ? nil : credential
    }

    private func loadRaw() throws -> LedgerWidgetCredential? {
        guard accessGroup != nil else { throw LedgerWidgetCredentialStoreError.unavailable }
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw LedgerWidgetCredentialStoreError.keychain(status) }
        guard let data = result as? Data,
              let credential = try? decoder.decode(LedgerWidgetCredential.self, from: data) else {
            throw LedgerWidgetCredentialStoreError.invalidCredential
        }
        return credential
    }

    func save(_ credential: LedgerWidgetCredential) throws {
        guard accessGroup != nil else { throw LedgerWidgetCredentialStoreError.unavailable }
        if let pending = try pendingRevocation(), pending.deviceID != credential.deviceID {
            throw LedgerWidgetCredentialStoreError.pendingRevocation
        }
        let data = try encoder.encode(credential)
        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            try setActiveCredentialKey(credential.blockKey)
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw LedgerWidgetCredentialStoreError.keychain(updateStatus)
        }

        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw LedgerWidgetCredentialStoreError.keychain(status)
        }
        try setActiveCredentialKey(credential.blockKey)
    }

    func suspend() throws {
        try setActiveCredentialKey(nil)
    }

    func completeRevocation(deviceID: String) throws {
        guard accessGroup != nil else { throw LedgerWidgetCredentialStoreError.unavailable }
        let credential = try loadRaw()
        if credential?.deviceID == deviceID {
            let status = SecItemDelete(baseQuery() as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw LedgerWidgetCredentialStoreError.keychain(status)
            }
        }
        try setActiveCredentialKey(nil)
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func activeCredentialKey() -> String? {
        sharedDefaults?.string(forKey: Self.activeCredentialKeyKey)
    }

    private func setActiveCredentialKey(_ key: String?) throws {
        guard let sharedDefaults else { throw LedgerWidgetCredentialStoreError.unavailable }
        if let key {
            sharedDefaults.set(key, forKey: Self.activeCredentialKeyKey)
        } else {
            sharedDefaults.removeObject(forKey: Self.activeCredentialKeyKey)
        }
        // UserDefaults persists changes automatically. Its legacy synchronize()
        // result must not interrupt credential suspension or registration.
    }

    private static func configuredAccessGroup(bundle: Bundle = .main) -> String? {
        LedgerSharedAccess(infoDictionary: bundle.infoDictionary ?? [:]).widgetKeychainAccessGroup
    }
}

private extension LedgerWidgetCredential {
    var blockKey: String { "\(serverOrigin)|\(deviceID)" }
}
