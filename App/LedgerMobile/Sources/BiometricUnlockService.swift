import Foundation
import LocalAuthentication
import Security

enum LedgerBiometricKind: Equatable, Sendable {
    case faceID
    case touchID
    case opticID
    case unavailable

    var title: String {
        switch self {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        case .unavailable: "生物识别"
        }
    }
}

enum BiometricCredentialError: LocalizedError {
    case unavailable
    case keychain(OSStatus)
    case invalidCredential

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "此设备尚未设置可用的生物识别"
        case let .keychain(status):
            if status == errSecUserCanceled || status == errSecAuthFailed {
                return "生物识别验证已取消"
            }
            return "无法访问设备安全凭据（\(status)）"
        case .invalidCredential:
            return "设备安全凭据已损坏，请使用密码重新启用"
        }
    }
}

@MainActor
protocol BiometricCredentialStore {
    var biometricKind: LedgerBiometricKind { get }
    func containsCredential(for origin: URL) -> Bool
    func save(_ credential: QuickUnlockCredential, for origin: URL) throws
    func readCredential(for origin: URL, reason: String) async throws -> QuickUnlockCredential
    func deleteCredential(for origin: URL)
}

@MainActor
final class SystemBiometricCredentialStore: BiometricCredentialStore {
    private let service = "com.qiaoborui.ledger.mobile.quick-unlock"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    var biometricKind: LedgerBiometricKind {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .unavailable
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        case .none: return .unavailable
        @unknown default: return .unavailable
        }
    }

    func containsCredential(for origin: URL) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = baseQuery(for: origin)
        query[kSecReturnAttributes as String] = true
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    func save(_ credential: QuickUnlockCredential, for origin: URL) throws {
        guard biometricKind != .unavailable else { throw BiometricCredentialError.unavailable }
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &accessError
        ) else {
            throw BiometricCredentialError.keychain(errSecParam)
        }

        let credentialData = try encoder.encode(credential)
        let updateAttributes: [String: Any] = [kSecValueData as String: credentialData]
        let updateStatus = SecItemUpdate(
            baseQuery(for: origin) as CFDictionary,
            updateAttributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw BiometricCredentialError.keychain(updateStatus)
        }

        var query = baseQuery(for: origin)
        query[kSecValueData as String] = credentialData
        query[kSecAttrAccessControl as String] = access
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw BiometricCredentialError.keychain(status) }
    }

    func readCredential(for origin: URL, reason: String) async throws -> QuickUnlockCredential {
        guard biometricKind != .unavailable else { throw BiometricCredentialError.unavailable }
        let context = LAContext()
        context.localizedCancelTitle = "使用密码"
        context.localizedReason = reason
        var query = baseQuery(for: origin)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw BiometricCredentialError.keychain(status) }
        guard let data = result as? Data,
              let credential = try? decoder.decode(QuickUnlockCredential.self, from: data) else {
            throw BiometricCredentialError.invalidCredential
        }
        return credential
    }

    func deleteCredential(for origin: URL) {
        SecItemDelete(baseQuery(for: origin) as CFDictionary)
    }

    private func baseQuery(for origin: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: origin.absoluteString,
        ]
    }
}
