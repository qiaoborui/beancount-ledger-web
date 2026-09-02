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
    func bootstrap(
        baseURL: URL,
        start: String,
        end: String,
        today: String,
        valuationCurrency: String
    ) async throws -> LedgerBootstrap
    func homeReport(
        baseURL: URL,
        start: String,
        end: String,
        valuationCurrency: String
    ) async throws -> LedgerHomeReport
    func importDocuments(baseURL: URL) async throws -> [LedgerImportDocument]
    func importProviders(baseURL: URL) async throws -> [LedgerImportProviderInfo]
    func previewImport(
        baseURL: URL,
        file: LedgerImportSelectedFile,
        provider: String?,
        alipayFundRounding: Bool,
        archivePassword: String
    ) async throws -> LedgerImportPreview
    func commitImport(
        baseURL: URL,
        request: LedgerImportCommitRequest
    ) async throws -> LedgerImportCommitResult
    func updateTransaction(
        baseURL: URL,
        source: TransactionSource,
        entry: LedgerTransactionEntry
    ) async throws
    func addTransactionTags(
        baseURL: URL,
        sources: [TransactionSource],
        tags: [String]
    ) async throws
    func indexInfo(baseURL: URL, targetGitSHA: String?) async throws -> LedgerIndexInfo
    func accountDetail(baseURL: URL, account: String, currency: String, start: String, end: String) async throws -> LedgerAccountDetail
    func dashboard(baseURL: URL, start: String, end: String, valuationCurrency: String) async throws -> LedgerDashboard
    func incomeStatement(baseURL: URL, start: String, end: String, valuationCurrency: String) async throws -> LedgerIncomeStatement
    func investments(baseURL: URL) async throws -> LedgerInvestmentSummary
    func runBQL(baseURL: URL, query: String, valuationCurrency: String) async throws -> BQLResult
    func bqlHistory(baseURL: URL) async throws -> [BQLHistoryRecord]
    func saveBQLHistory(baseURL: URL, query: String) async throws -> BQLHistoryRecord
    func generateBQLHistoryTitle(baseURL: URL, id: String) async throws -> BQLHistoryRecord
    func renameBQLHistory(baseURL: URL, id: String, title: String) async throws -> BQLHistoryRecord
    func deleteBQLHistory(baseURL: URL, id: String) async throws
    func lock(baseURL: URL) async throws
    func logout(baseURL: URL) async throws
}

extension LedgerAPI {
    func homeReport(
        baseURL: URL,
        start: String,
        end: String,
        valuationCurrency: String
    ) async throws -> LedgerHomeReport {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持首页消费报告")
    }

    func importDocuments(baseURL: URL) async throws -> [LedgerImportDocument] {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持导入记录")
    }

    func importProviders(baseURL: URL) async throws -> [LedgerImportProviderInfo] {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持账单导入")
    }

    func previewImport(
        baseURL: URL,
        file: LedgerImportSelectedFile,
        provider: String?,
        alipayFundRounding: Bool,
        archivePassword: String
    ) async throws -> LedgerImportPreview {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持账单导入")
    }

    func commitImport(
        baseURL: URL,
        request: LedgerImportCommitRequest
    ) async throws -> LedgerImportCommitResult {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持账单导入")
    }

    func updateTransaction(
        baseURL: URL,
        source: TransactionSource,
        entry: LedgerTransactionEntry
    ) async throws {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持编辑交易")
    }

    func addTransactionTags(
        baseURL: URL,
        sources: [TransactionSource],
        tags: [String]
    ) async throws {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持批量添加标签")
    }

    func indexInfo(baseURL: URL, targetGitSHA: String?) async throws -> LedgerIndexInfo {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持索引状态查询")
    }

    func dashboard(baseURL: URL, start: String, end: String, valuationCurrency: String) async throws -> LedgerDashboard {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持仪表盘")
    }

    func incomeStatement(baseURL: URL, start: String, end: String, valuationCurrency: String) async throws -> LedgerIncomeStatement {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持损益分析")
    }

    func investments(baseURL: URL) async throws -> LedgerInvestmentSummary {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持投资分析")
    }

    func runBQL(baseURL: URL, query: String, valuationCurrency: String) async throws -> BQLResult {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持 BQL 查询")
    }

    func bqlHistory(baseURL: URL) async throws -> [BQLHistoryRecord] {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持 BQL 查询历史")
    }

    func saveBQLHistory(baseURL: URL, query: String) async throws -> BQLHistoryRecord {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持 BQL 查询历史")
    }

    func generateBQLHistoryTitle(baseURL: URL, id: String) async throws -> BQLHistoryRecord {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持 BQL 查询历史")
    }

    func renameBQLHistory(baseURL: URL, id: String, title: String) async throws -> BQLHistoryRecord {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持 BQL 查询历史")
    }

    func deleteBQLHistory(baseURL: URL, id: String) async throws {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持 BQL 查询历史")
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

    func bootstrap(
        baseURL: URL,
        start: String,
        end: String,
        today: String,
        valuationCurrency: String
    ) async throws -> LedgerBootstrap {
        var components = URLComponents(url: baseURL.appending(path: "/api/ledger/bootstrap"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "start", value: start),
            URLQueryItem(name: "end", value: end),
            URLQueryItem(name: "today", value: today),
            URLQueryItem(name: "valuationCurrency", value: valuationCurrency),
        ]
        guard let url = components?.url else { throw LedgerAPIError.invalidResponse }
        return try await request(URLRequest(url: url))
    }

    func homeReport(
        baseURL: URL,
        start: String,
        end: String,
        valuationCurrency: String
    ) async throws -> LedgerHomeReport {
        try await rangedGet(
            baseURL: baseURL,
            path: "/api/ledger/home-report",
            start: start,
            end: end,
            valuationCurrency: valuationCurrency
        )
    }

    func importDocuments(baseURL: URL) async throws -> [LedgerImportDocument] {
        let response: LedgerImportDocumentsResponse = try await get(
            baseURL: baseURL,
            path: "/api/ledger/imports/documents"
        )
        return response.documents
    }

    func importProviders(baseURL: URL) async throws -> [LedgerImportProviderInfo] {
        let response: LedgerImportProvidersResponse = try await get(
            baseURL: baseURL,
            path: "/api/ledger/imports/providers"
        )
        return response.providers
    }

    func previewImport(
        baseURL: URL,
        file: LedgerImportSelectedFile,
        provider: String?,
        alipayFundRounding: Bool,
        archivePassword: String
    ) async throws -> LedgerImportPreview {
        let boundary = "LedgerMobile-\(UUID().uuidString)"
        var body = Data()
        if let provider, !provider.isEmpty {
            appendMultipartField(name: "provider", value: provider, boundary: boundary, to: &body)
        }
        appendMultipartField(
            name: "alipayFundRounding",
            value: alipayFundRounding ? "true" : "false",
            boundary: boundary,
            to: &body
        )
        if file.isZIP, !archivePassword.isEmpty {
            appendMultipartField(
                name: "archivePassword",
                value: archivePassword,
                boundary: boundary,
                to: &body
            )
        }
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(safeMultipartFilename(file.name))\"\r\n"
        )
        body.appendUTF8("Content-Type: application/octet-stream\r\n\r\n")
        body.append(file.data)
        body.appendUTF8("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: baseURL.appending(path: "/api/ledger/imports/preview"))
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await self.request(request)
    }

    func commitImport(
        baseURL: URL,
        request: LedgerImportCommitRequest
    ) async throws -> LedgerImportCommitResult {
        try await send(
            baseURL: baseURL,
            path: "/api/ledger/imports/commit",
            method: "POST",
            body: request
        )
    }

    func updateTransaction(
        baseURL: URL,
        source: TransactionSource,
        entry: LedgerTransactionEntry
    ) async throws {
        let _: EmptySuccess = try await send(
            baseURL: baseURL,
            path: "/api/ledger/transactions",
            method: "PUT",
            body: LedgerTransactionUpdateRequest(source: source, entry: entry)
        )
    }

    func addTransactionTags(
        baseURL: URL,
        sources: [TransactionSource],
        tags: [String]
    ) async throws {
        let _: EmptySuccess = try await send(
            baseURL: baseURL,
            path: "/api/ledger/transactions/tags",
            method: "POST",
            body: LedgerTransactionTagsRequest(sources: sources, tags: tags)
        )
    }

    func indexInfo(baseURL: URL, targetGitSHA: String?) async throws -> LedgerIndexInfo {
        var components = URLComponents(
            url: baseURL.appending(path: "/api/ledger/index-info"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [
            URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970 * 1_000)))
        ]
        if let targetGitSHA = targetGitSHA?.trimmingCharacters(in: .whitespacesAndNewlines),
           !targetGitSHA.isEmpty {
            queryItems.append(URLQueryItem(name: "gitSHA", value: targetGitSHA))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw LedgerAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await self.request(request)
    }

    func accountDetail(baseURL: URL, account: String, currency: String, start: String, end: String) async throws -> LedgerAccountDetail {
        var components = URLComponents(
            url: baseURL.appending(path: "/api/ledger/accounts/detail"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "account", value: account),
            URLQueryItem(name: "currency", value: currency),
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

    func dashboard(baseURL: URL, start: String, end: String, valuationCurrency: String) async throws -> LedgerDashboard {
        try await rangedGet(
            baseURL: baseURL,
            path: "/api/ledger/dashboard",
            start: start,
            end: end,
            valuationCurrency: valuationCurrency
        )
    }

    func incomeStatement(baseURL: URL, start: String, end: String, valuationCurrency: String) async throws -> LedgerIncomeStatement {
        try await rangedGet(
            baseURL: baseURL,
            path: "/api/ledger/income-statement",
            start: start,
            end: end,
            valuationCurrency: valuationCurrency
        )
    }

    func investments(baseURL: URL) async throws -> LedgerInvestmentSummary {
        try await get(baseURL: baseURL, path: "/api/ledger/investments")
    }

    func runBQL(baseURL: URL, query: String, valuationCurrency: String) async throws -> BQLResult {
        try await send(
            baseURL: baseURL,
            path: "/api/ledger/bql",
            method: "POST",
            body: BQLRequest(query: query, valuationCurrency: valuationCurrency)
        )
    }

    func bqlHistory(baseURL: URL) async throws -> [BQLHistoryRecord] {
        let response: BQLHistoryResponse = try await get(baseURL: baseURL, path: "/api/ledger/bql-history")
        return response.records
    }

    func saveBQLHistory(baseURL: URL, query: String) async throws -> BQLHistoryRecord {
        try await send(
            baseURL: baseURL,
            path: "/api/ledger/bql-history",
            method: "POST",
            body: BQLHistorySaveRequest(query: query)
        )
    }

    func generateBQLHistoryTitle(baseURL: URL, id: String) async throws -> BQLHistoryRecord {
        try await send(
            baseURL: baseURL,
            path: "/api/ledger/bql-history/\(id)/title",
            method: "POST",
            body: Optional<String>.none
        )
    }

    func renameBQLHistory(baseURL: URL, id: String, title: String) async throws -> BQLHistoryRecord {
        try await send(
            baseURL: baseURL,
            path: "/api/ledger/bql-history/\(id)",
            method: "PATCH",
            body: BQLHistoryRenameRequest(title: title)
        )
    }

    func deleteBQLHistory(baseURL: URL, id: String) async throws {
        try await sendWithoutResponse(
            baseURL: baseURL,
            path: "/api/ledger/bql-history/\(id)",
            method: "DELETE"
        )
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

    private func rangedGet<Response: Decodable>(
        baseURL: URL,
        path: String,
        start: String,
        end: String,
        valuationCurrency: String
    ) async throws -> Response {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "start", value: start),
            URLQueryItem(name: "end", value: end),
            URLQueryItem(name: "valuationCurrency", value: valuationCurrency),
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

    private func sendWithoutResponse(baseURL: URL, path: String, method: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        _ = try await responseData(for: request)
    }

    private func appendMultipartField(
        name: String,
        value: String,
        boundary: String,
        to body: inout Data
    ) {
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.appendUTF8(value)
        body.appendUTF8("\r\n")
    }

    private func safeMultipartFilename(_ filename: String) -> String {
        filename
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
    }

    private func request<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data = try await responseData(for: request)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw LedgerAPIError.decoding(error.localizedDescription)
        }
    }

    private func responseData(for request: URLRequest) async throws -> Data {
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
        return data
    }
}

private struct EmptySuccess: Decodable {
    let ok: Bool
}

private struct LedgerImportProvidersResponse: Decodable {
    let providers: [LedgerImportProviderInfo]
}

private extension Data {
    mutating func appendUTF8(_ value: String) {
        append(Data(value.utf8))
    }
}
