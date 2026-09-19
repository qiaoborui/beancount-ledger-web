import Foundation

struct LocalStorageSyncStatus: Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case device, git }
    enum Phase: String, Codable, Sendable { case localOnly, pending, synchronizing, synced, conflicted, failed }
    let mode: Mode
    let phase: Phase
    var lastSyncedAt: Date? = nil
    var baseCommit: String? = nil
    var conflictPaths: [String] = []
    var message: String? = nil
}

/// Presentation shared by the toolbar and its deterministic state tests.
struct LocalSyncPresentation: Equatable {
    enum Action: Equatable { case synchronize, storageSettings }
    enum Indicator: Equatable { case local, syncing, synced, pending, attention }
    let title: String
    let indicator: Indicator
    let isBusy: Bool
    let needsAttention: Bool
    let action: Action

    init(status: LocalStorageSyncStatus?, hasGit: Bool, busy: Bool, automaticEnabled: Bool) {
        // The live execution slot owns interactivity. A cancelled operation can
        // leave a persisted synchronizing label until the next status refresh.
        isBusy = busy
        needsAttention = status?.phase == .failed || status?.phase == .conflicted
        action = !hasGit || status?.phase == .conflicted ? .storageSettings : .synchronize
        if isBusy {
            title = "正在同步"
            indicator = .syncing
        } else if !hasGit {
            title = "已保存到本机"
            indicator = .local
        } else {
            switch status?.phase {
            case .conflicted:
                title = "同步冲突"
                indicator = .attention
            case .failed:
                title = "同步失败"
                indicator = .attention
            case .synced:
                title = automaticEnabled ? "已同步" : "已同步，自动同步已暂停"
                indicator = automaticEnabled ? .synced : .local
            default:
                title = "等待同步"
                indicator = .pending
            }
        }
    }
}

/// Every provider exposes the same device-private, immutable ledger workspace.
/// Network synchronization is an explicit operation, separate from local writes.
protocol LogicalLocalStorage: Sendable {
    var workspace: LocalLedgerWorkspace { get }
    func didCommit(_ revision: LocalLedgerWorkspace.Revision) async
    func status() async throws -> LocalStorageSyncStatus
    func synchronize(validator: @escaping LocalLedgerWorkspace.Validator) async throws -> LocalStorageSyncStatus
    func resolveConflicts(keepingLocal: Bool, validator: @escaping LocalLedgerWorkspace.Validator) async throws -> LocalStorageSyncStatus
    func exportConflictVersions() async throws -> URL
}

extension LogicalLocalStorage {
    func resolveConflicts(keepingLocal: Bool, validator: @escaping LocalLedgerWorkspace.Validator) async throws -> LocalStorageSyncStatus {
        throw LocalStorageError.gitFailure("当前账本没有待处理的同步冲突")
    }
    func exportConflictVersions() async throws -> URL {
        throw LocalStorageError.gitFailure("当前账本没有待处理的同步冲突")
    }
}

enum LocalStorageError: LocalizedError, Equatable {
    case invalidGitConfiguration(String)
    case synchronizationInProgress
    case conflicts([String])
    case emptyRepository
    case unsafeFile(String)
    case treeLimitExceeded
    case corruptSyncState
    case gitUnavailable
    case gitFailure(String)

    var errorDescription: String? {
        switch self {
        case let .invalidGitConfiguration(message), let .gitFailure(message): message
        case .synchronizationInProgress: "账本正在同步，请稍候"
        case let .conflicts(paths): "这些文件在本机和远端均有修改：\(paths.joined(separator: "、"))。两边内容已保留，请处理冲突后再同步。"
        case .emptyRepository: "该分支尚无账本，请先新建本地账本再连接仓库"
        case let .unsafeFile(path): "同步目录包含不受支持的路径或文件：\(path)"
        case .treeLimitExceeded: "同步目录超过文件数量、大小或层级限制"
        case .corruptSyncState: "同步记录已损坏，请重新配置仓库连接；本地账本仍然可用"
        case .gitUnavailable: "此版本缺少设备端 Git 同步引擎"
        }
    }
}

struct LocalGitConfiguration: Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let repositoryURL: URL
    let branch: String

    init(id: UUID = UUID(), repositoryURL: String, branch: String = "main") throws {
        guard let components = URLComponents(string: repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)),
            components.scheme?.lowercased() == "https", components.host?.isEmpty == false,
            components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
            let url = components.url else {
            throw LocalStorageError.invalidGitConfiguration("请填写 HTTPS Git 仓库地址，凭据填写在独立字段中")
        }
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, branch.count <= 200,
              !branch.hasPrefix("/"), !branch.hasSuffix("/"), !branch.hasSuffix("."),
              !branch.contains(".."), !branch.contains("@{"), !branch.contains("//"),
              branch != "@", branch.split(separator: "/").allSatisfy({ !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }),
              branch.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value != 127 && !"~^:?*[\\".unicodeScalars.contains($0) }) else {
            throw LocalStorageError.invalidGitConfiguration("请输入有效的 Git 分支名称")
        }
        self.id = id
        self.repositoryURL = url
        self.branch = branch
    }
}
