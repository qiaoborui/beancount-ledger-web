import Foundation

enum ServerConfigurationError: LocalizedError, Equatable {
    case empty
    case invalid
    case requiresHTTPS
    case originOnly

    var errorDescription: String? {
        switch self {
        case .empty: return "请输入服务器地址"
        case .invalid: return "服务器地址格式无效"
        case .requiresHTTPS: return "服务器地址需要使用 HTTPS"
        case .originOnly: return "请只填写服务器域名，不包含路径、查询参数或账号信息"
        }
    }
}

enum ServerConfiguration {
    static func normalize(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServerConfigurationError.empty }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              components.host?.isEmpty == false else {
            throw ServerConfigurationError.invalid
        }
        guard components.scheme?.lowercased() == "https" else {
            throw ServerConfigurationError.requiresHTTPS
        }
        guard components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw ServerConfigurationError.originOnly
        }
        components.scheme = "https"
        components.path = ""
        guard let url = components.url else { throw ServerConfigurationError.invalid }
        return url
    }
}

enum LedgerAPIError: LocalizedError {
    case invalidResponse
    case incompatibleServer(String)
    case server(status: Int, message: String)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器返回了无法识别的响应"
        case let .incompatibleServer(message):
            return message
        case let .server(_, message):
            return message
        case let .decoding(message):
            return "账本数据格式无法识别：\(message)"
        case let .transport(message):
            return "无法连接服务器：\(message)"
        }
    }
}

protocol LedgerAPI: Sendable {
    func health(baseURL: URL) async throws -> HealthStatus
    func authStatus(baseURL: URL) async throws -> AuthStatus
    func passkeyStatus(baseURL: URL) async throws -> PasskeyStatus
    func passkeyLoginOptions(baseURL: URL) async throws -> PasskeyRequestOptions
    func verifyPasskey(baseURL: URL, assertion: PasskeyAssertion) async throws
    func login(baseURL: URL, password: String) async throws
    func registerQuickUnlock(baseURL: URL, deviceName: String) async throws -> QuickUnlockCredential
    func verifyQuickUnlock(baseURL: URL, credential: QuickUnlockCredential) async throws
    func revokeQuickUnlock(baseURL: URL, deviceID: String) async throws
    func bootstrap(baseURL: URL, start: String, end: String, today: String) async throws -> LedgerBootstrap
    func accountDetail(baseURL: URL, account: String) async throws -> LedgerAccountDetail
    func dashboard(baseURL: URL, start: String, end: String) async throws -> LedgerDashboard
    func incomeStatement(baseURL: URL, start: String, end: String) async throws -> LedgerIncomeStatement
    func investments(baseURL: URL) async throws -> LedgerInvestmentSummary
    func lock(baseURL: URL) async throws
    func logout(baseURL: URL) async throws
}

extension LedgerAPI {
    func dashboard(baseURL: URL, start: String, end: String) async throws -> LedgerDashboard {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持仪表盘")
    }

    func incomeStatement(baseURL: URL, start: String, end: String) async throws -> LedgerIncomeStatement {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持损益分析")
    }

    func investments(baseURL: URL) async throws -> LedgerInvestmentSummary {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持投资分析")
    }
}

struct LedgerAPIClient: LedgerAPI, @unchecked Sendable {
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func health(baseURL: URL) async throws -> HealthStatus {
        try await get(baseURL: baseURL, path: "/api/health")
    }

    func authStatus(baseURL: URL) async throws -> AuthStatus {
        try await get(baseURL: baseURL, path: "/api/auth/me")
    }

    func passkeyStatus(baseURL: URL) async throws -> PasskeyStatus {
        try await get(baseURL: baseURL, path: "/api/passkey/status")
    }

    func passkeyLoginOptions(baseURL: URL) async throws -> PasskeyRequestOptions {
        try await send(
            baseURL: baseURL,
            path: "/api/passkey/login/options",
            method: "POST",
            body: Optional<String>.none
        )
    }

    func verifyPasskey(baseURL: URL, assertion: PasskeyAssertion) async throws {
        let _: EmptySuccess = try await send(
            baseURL: baseURL,
            path: "/api/passkey/login/verify",
            method: "POST",
            body: assertion
        )
    }

    func login(baseURL: URL, password: String) async throws {
        let _: EmptySuccess = try await send(
            baseURL: baseURL,
            path: "/api/auth/login",
            method: "POST",
            body: LoginRequest(password: password)
        )
    }

    func registerQuickUnlock(baseURL: URL, deviceName: String) async throws -> QuickUnlockCredential {
        try await send(
            baseURL: baseURL,
            path: "/api/quick-unlock/register",
            method: "POST",
            body: QuickUnlockRegisterRequest(mode: "text", name: deviceName)
        )
    }

    func verifyQuickUnlock(baseURL: URL, credential: QuickUnlockCredential) async throws {
        let _: EmptySuccess = try await send(
            baseURL: baseURL,
            path: "/api/quick-unlock/verify",
            method: "POST",
            body: QuickUnlockVerifyRequest(deviceID: credential.deviceID, token: credential.token)
        )
    }

    func revokeQuickUnlock(baseURL: URL, deviceID: String) async throws {
        let _: EmptySuccess = try await send(
            baseURL: baseURL,
            path: "/api/quick-unlock/revoke",
            method: "POST",
            body: QuickUnlockRevokeRequest(deviceID: deviceID)
        )
    }

    func bootstrap(baseURL: URL, start: String, end: String, today: String) async throws -> LedgerBootstrap {
        var components = URLComponents(url: baseURL.appending(path: "/api/ledger/bootstrap"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "start", value: start),
            URLQueryItem(name: "end", value: end),
            URLQueryItem(name: "today", value: today),
        ]
        guard let url = components?.url else { throw LedgerAPIError.invalidResponse }
        return try await request(URLRequest(url: url))
    }

    func accountDetail(baseURL: URL, account: String) async throws -> LedgerAccountDetail {
        var components = URLComponents(
            url: baseURL.appending(path: "/api/ledger/accounts/detail"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "account", value: account)]
        guard let url = components?.url else { throw LedgerAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await self.request(request)
    }

    func dashboard(baseURL: URL, start: String, end: String) async throws -> LedgerDashboard {
        try await rangedGet(baseURL: baseURL, path: "/api/ledger/dashboard", start: start, end: end)
    }

    func incomeStatement(baseURL: URL, start: String, end: String) async throws -> LedgerIncomeStatement {
        try await rangedGet(baseURL: baseURL, path: "/api/ledger/income-statement", start: start, end: end)
    }

    func investments(baseURL: URL) async throws -> LedgerInvestmentSummary {
        try await get(baseURL: baseURL, path: "/api/ledger/investments")
    }

    func lock(baseURL: URL) async throws {
        let _: EmptySuccess = try await send(baseURL: baseURL, path: "/api/auth/lock", method: "POST", body: Optional<String>.none)
    }

    func logout(baseURL: URL) async throws {
        let _: EmptySuccess = try await send(baseURL: baseURL, path: "/api/auth/logout", method: "POST", body: Optional<String>.none)
    }

    private func get<Response: Decodable>(baseURL: URL, path: String) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await self.request(request)
    }

    private func rangedGet<Response: Decodable>(baseURL: URL, path: String, start: String, end: String) async throws -> Response {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "start", value: start),
            URLQueryItem(name: "end", value: end),
        ]
        guard let url = components?.url else { throw LedgerAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await self.request(request)
    }

    private func send<Body: Encodable, Response: Decodable>(
        baseURL: URL,
        path: String,
        method: String,
        body: Body?
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await self.request(request)
    }

    private func request<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw LedgerAPIError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LedgerAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let payload = try? decoder.decode(APIErrorPayload.self, from: data)
            let message = payload?.error ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw LedgerAPIError.server(status: http.statusCode, message: message)
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw LedgerAPIError.decoding(error.localizedDescription)
        }
    }
}

private struct EmptySuccess: Decodable {
    let ok: Bool
}
