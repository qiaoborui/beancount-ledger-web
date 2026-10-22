import Foundation
import LocalAuthentication

@MainActor
protocol LocalLedgerAuthenticating {
    var isAvailable: Bool { get }
    func authenticate() async throws
}

@MainActor
final class SystemLocalLedgerAuthenticator: LocalLedgerAuthenticating {
    var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func authenticate() async throws {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "取消")
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            throw LocalLedgerAuthenticationError.devicePasscodeRequired
        }
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "解锁这台设备上的本地账本")) else {
            throw LocalLedgerAuthenticationError.cancelled
        }
    }
}

enum LocalLedgerAuthenticationError: LocalizedError {
    case devicePasscodeRequired
    case cancelled

    var errorDescription: String? {
        switch self {
        case .devicePasscodeRequired: String(localized: "请先在系统设置中启用设备密码，再打开本地账本。")
        case .cancelled: String(localized: "已取消解锁，本地账本保持锁定。")
        }
    }
}
