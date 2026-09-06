import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct LedgerWidgetSnapshotRequest: Encodable, Sendable {
    let deviceID: String
    let token: String
    let today: String
    let valuationCurrency: String

    private enum CodingKeys: String, CodingKey {
        case deviceID = "deviceId"
        case token
        case today
        case valuationCurrency
    }
}

struct LedgerWidgetRemoteSnapshot: Decodable, Sendable {
    let schemaVersion: Int
    let updatedAt: String
    let expense: LedgerWidgetExpenseSnapshot
    let accounts: [LedgerWidgetAccountSnapshot]
    let imports: [LedgerWidgetImportSnapshot]?
    let importsUpdatedAt: String?

    func snapshot(previous: LedgerWidgetSnapshot?) throws -> LedgerWidgetSnapshot {
        guard (1...LedgerWidgetSnapshot.currentSchemaVersion).contains(schemaVersion),
              let updatedAt = Self.parseDate(updatedAt) else {
            throw LedgerWidgetRefreshError.invalidResponse
        }
        let resolvedImports = imports ?? previous?.imports ?? []
        let resolvedImportsUpdatedAt: Date?
        if let importsUpdatedAt {
            guard let parsed = Self.parseDate(importsUpdatedAt) else {
                throw LedgerWidgetRefreshError.invalidResponse
            }
            resolvedImportsUpdatedAt = parsed
        } else {
            resolvedImportsUpdatedAt = imports == nil ? previous?.importsUpdatedAt : nil
        }
        return LedgerWidgetSnapshot(
            updatedAt: updatedAt,
            expense: expense,
            accounts: accounts,
            imports: resolvedImports,
            importsUpdatedAt: resolvedImportsUpdatedAt
        )
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

enum LedgerWidgetRefreshError: LocalizedError {
    case invalidServer
    case invalidResponse
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidServer:
            "小组件服务器地址无效"
        case .invalidResponse:
            "小组件收到无法识别的数据"
        case let .server(status):
            "小组件刷新失败（HTTP \(status)）"
        }
    }
}

protocol LedgerWidgetRefreshing: Sendable {
    func fetch(
        credential: LedgerWidgetCredential,
        previous: LedgerWidgetSnapshot?,
        now: Date,
        calendar: Calendar
    ) async throws -> LedgerWidgetSnapshot
}

struct LedgerWidgetRefreshClient: LedgerWidgetRefreshing, @unchecked Sendable {
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: configuration)
    }

    func fetch(
        credential: LedgerWidgetCredential,
        previous: LedgerWidgetSnapshot?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> LedgerWidgetSnapshot {
        guard credential.enabled,
              var components = URLComponents(string: credential.serverOrigin),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false else {
            throw LedgerWidgetRefreshError.invalidServer
        }
        components.path = "/api/widget/snapshot"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw LedgerWidgetRefreshError.invalidServer }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try encoder.encode(
            LedgerWidgetSnapshotRequest(
                deviceID: credential.deviceID,
                token: credential.token,
                today: Self.dateString(now, calendar: calendar),
                valuationCurrency: credential.valuationCurrency
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LedgerWidgetRefreshError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw LedgerWidgetRefreshError.server(http.statusCode)
        }
        let remote: LedgerWidgetRemoteSnapshot
        do {
            remote = try decoder.decode(LedgerWidgetRemoteSnapshot.self, from: data)
        } catch {
            throw LedgerWidgetRefreshError.invalidResponse
        }
        return try remote.snapshot(previous: previous)
    }

    private static func dateString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

actor LedgerWidgetTimelineLoader {
    static let shared = LedgerWidgetTimelineLoader()
    static let cacheFreshness: TimeInterval = 2 * 60
    static let successRefreshInterval: TimeInterval = 30 * 60
    static let failureRefreshInterval: TimeInterval = 15 * 60

    private let credentialStore: any LedgerWidgetCredentialStoring
    private let snapshotStore: LedgerWidgetSnapshotStore
    private let client: any LedgerWidgetRefreshing
    private var inFlight: Task<LedgerWidgetFetchResult, Never>?
    private var lastAttemptAt: Date?
    private var lastAttemptCredential: LedgerWidgetCredential?
    private var lastAttemptRefreshInterval: TimeInterval?

    init(
        credentialStore: any LedgerWidgetCredentialStoring = SystemLedgerWidgetCredentialStore(),
        snapshotStore: LedgerWidgetSnapshotStore = .shared,
        client: any LedgerWidgetRefreshing = LedgerWidgetRefreshClient()
    ) {
        self.credentialStore = credentialStore
        self.snapshotStore = snapshotStore
        self.client = client
    }

    func load(now: Date = Date()) async -> LedgerWidgetTimelineLoadResult {
        let cached = snapshotStore.load()
        guard let credential = try? credentialStore.load(), credential.enabled else {
            return LedgerWidgetTimelineLoadResult(
                snapshot: cached,
                refreshInterval: Self.failureRefreshInterval
            )
        }
        if let cached {
            let cacheAge = now.timeIntervalSince(cached.updatedAt)
            if cacheAge >= 0, cacheAge < Self.cacheFreshness {
                return LedgerWidgetTimelineLoadResult(
                    snapshot: cached,
                    refreshInterval: Self.successRefreshInterval
                )
            }
        }
        if let lastAttemptAt,
           lastAttemptCredential == credential,
           let lastAttemptRefreshInterval,
           now.timeIntervalSince(lastAttemptAt) >= 0,
           now.timeIntervalSince(lastAttemptAt) < Self.cacheFreshness {
            return LedgerWidgetTimelineLoadResult(
                snapshot: cached,
                refreshInterval: lastAttemptRefreshInterval
            )
        }
        if let inFlight {
            let result = await inFlight.value
            return finish(result, cached: cached, now: now)
        }

        let task = Task { [client] in
            do {
                let refreshed = try await client.fetch(
                    credential: credential,
                    previous: cached,
                    now: now,
                    calendar: .current
                )
                return LedgerWidgetFetchResult(
                    credential: credential,
                    snapshot: refreshed,
                    authorizationRejected: false
                )
            } catch LedgerWidgetRefreshError.server(let status) where status == 401 || status == 403 {
                return LedgerWidgetFetchResult(
                    credential: credential,
                    snapshot: nil,
                    authorizationRejected: true
                )
            } catch {
                return LedgerWidgetFetchResult(
                    credential: credential,
                    snapshot: nil,
                    authorizationRejected: false
                )
            }
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return finish(result, cached: cached, now: now)
    }

    private func finish(
        _ fetch: LedgerWidgetFetchResult,
        cached: LedgerWidgetSnapshot?,
        now: Date
    ) -> LedgerWidgetTimelineLoadResult {
        let credential = fetch.credential
        guard (try? credentialStore.load()) == credential else {
            return LedgerWidgetTimelineLoadResult(
                snapshot: snapshotStore.load(),
                refreshInterval: Self.failureRefreshInterval
            )
        }

        if fetch.authorizationRejected {
            try? credentialStore.suspend()
        }

        let refreshInterval: TimeInterval
        if let refreshed = fetch.snapshot, !fetch.authorizationRejected {
            try? snapshotStore.save(refreshed)
            if (try? credentialStore.load()) == credential {
                refreshInterval = Self.successRefreshInterval
            } else {
                if snapshotStore.load() == refreshed {
                    snapshotStore.clear()
                }
                return LedgerWidgetTimelineLoadResult(
                    snapshot: snapshotStore.load(),
                    refreshInterval: Self.failureRefreshInterval
                )
            }
        } else {
            refreshInterval = Self.failureRefreshInterval
        }

        lastAttemptAt = now
        lastAttemptCredential = credential
        lastAttemptRefreshInterval = refreshInterval
        return LedgerWidgetTimelineLoadResult(
            snapshot: fetch.snapshot ?? cached,
            refreshInterval: refreshInterval
        )
    }
}

struct LedgerWidgetTimelineLoadResult: Sendable {
    let snapshot: LedgerWidgetSnapshot?
    let refreshInterval: TimeInterval
}

private struct LedgerWidgetFetchResult: Sendable {
    let credential: LedgerWidgetCredential
    let snapshot: LedgerWidgetSnapshot?
    let authorizationRejected: Bool
}
