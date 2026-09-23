import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
    func registerQuickUnlock(baseURL: URL, deviceName: String, mode: String) async throws -> QuickUnlockCredential
    func verifyQuickUnlock(baseURL: URL, credential: QuickUnlockCredential) async throws
    func revokeQuickUnlock(baseURL: URL, deviceID: String) async throws
    func revokeWidgetQuickUnlock(baseURL: URL, credential: LedgerWidgetCredential) async throws
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
    func globalTransactions(baseURL: URL) async throws -> LedgerGlobalTransactions
    func importDocuments(baseURL: URL) async throws -> [LedgerImportDocument]
    func importProviders(baseURL: URL) async throws -> [LedgerImportProviderInfo]
    func gmailStatus(baseURL: URL) async throws -> LedgerGmailStatus
    func gmailConnect(baseURL: URL) async throws -> LedgerGmailConnectResponse
    func gmailSync(baseURL: URL, pendingID: String?) async throws -> LedgerGmailSyncResult
    func gmailDisconnect(baseURL: URL) async throws
    func gmailPendingImports(baseURL: URL) async throws -> [LedgerGmailPendingImport]
    func gmailPendingImport(baseURL: URL, id: String) async throws -> LedgerGmailPendingDetail
    func dismissGmailPendingImport(baseURL: URL, id: String) async throws
    func gmailPendingEvents(baseURL: URL) -> AsyncThrowingStream<Void, Error>
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
    func deleteTransaction(baseURL: URL, source: TransactionSource, reason: String) async throws
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
    func reconciliation(baseURL: URL, start: String, end: String) async throws -> LedgerReconciliationResponse
    func reconcile(baseURL: URL, request: LedgerReconcileRequest) async throws -> LedgerReconciliationResult
    func accountStatuses(baseURL: URL) async throws -> [LedgerAccountStatus]
    func addAccount(baseURL: URL, input: LedgerAccountInput) async throws
    func lock(baseURL: URL) async throws
    func logout(baseURL: URL) async throws
}

extension LedgerAPI {
    func reconciliation(baseURL: URL, start: String, end: String) async throws -> LedgerReconciliationResponse {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持对账查询")
    }

    func reconcile(baseURL: URL, request: LedgerReconcileRequest) async throws -> LedgerReconciliationResult {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持对账写入")
    }

    func accountStatuses(baseURL: URL) async throws -> [LedgerAccountStatus] {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持账户状态查询")
    }

    func addAccount(baseURL: URL, input: LedgerAccountInput) async throws {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持添加账户")
    }
    func homeReport(
        baseURL: URL,
        start: String,
        end: String,
        valuationCurrency: String
    ) async throws -> LedgerHomeReport {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持首页消费报告")
    }

    func globalTransactions(baseURL: URL) async throws -> LedgerGlobalTransactions {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持全局搜索")
    }

    func importDocuments(baseURL: URL) async throws -> [LedgerImportDocument] {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持导入记录")
    }

    func importProviders(baseURL: URL) async throws -> [LedgerImportProviderInfo] {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持账单导入")
    }

    func gmailStatus(baseURL: URL) async throws -> LedgerGmailStatus {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持 Gmail 自动导入")
    }

    func gmailConnect(baseURL: URL) async throws -> LedgerGmailConnectResponse {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持 Gmail 自动导入")
    }

    func gmailSync(baseURL: URL, pendingID: String?) async throws -> LedgerGmailSyncResult {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持 Gmail 自动导入")
    }

    func gmailDisconnect(baseURL: URL) async throws {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持 Gmail 自动导入")
    }

    func gmailPendingImports(baseURL: URL) async throws -> [LedgerGmailPendingImport] {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持 Gmail 自动导入")
    }

    func gmailPendingImport(baseURL: URL, id: String) async throws -> LedgerGmailPendingDetail {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持 Gmail 自动导入")
    }

    func dismissGmailPendingImport(baseURL: URL, id: String) async throws {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持 Gmail 自动导入")
    }

    func gmailPendingEvents(baseURL: URL) -> AsyncThrowingStream<Void, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: LedgerAPIError.incompatibleServer("服务器暂不支持 Gmail 实时更新"))
        }
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

    func deleteTransaction(baseURL: URL, source: TransactionSource, reason: String) async throws {
        throw LedgerAPIError.incompatibleServer("服务器暂不支持删除交易")
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

/// Stable identity for either a server origin or an on-device workspace.
enum LedgerLocation: Hashable, Sendable {
    case remote(URL)
    case local(UUID)
}

enum LedgerRepositoryError: Error, Equatable {
    case unsupportedLocation(LedgerLocation)
    case capabilityUnavailable(String)
}

protocol LedgerRemoteHealth: Sendable {
    func health() async throws -> HealthStatus
}

protocol LedgerRemoteAuthentication: Sendable {
    func authStatus() async throws -> AuthStatus
    func login(password: String) async throws
}

protocol LedgerRemotePasskeys: Sendable {
    func passkeyStatus() async throws -> PasskeyStatus
    func passkeyLoginOptions() async throws -> PasskeyRequestOptions
    func verifyPasskey(assertion: PasskeyAssertion) async throws
}

protocol LedgerRemoteQuickUnlock: Sendable {
    func registerQuickUnlock(deviceName: String, mode: String) async throws -> QuickUnlockCredential
    func verifyQuickUnlock(credential: QuickUnlockCredential) async throws
    func revokeQuickUnlock(deviceID: String) async throws
    func revokeWidgetQuickUnlock(credential: LedgerWidgetCredential) async throws
}

protocol LedgerRemoteGmail: Sendable {
    func gmailStatus() async throws -> LedgerGmailStatus
    func gmailConnect() async throws -> LedgerGmailConnectResponse
    func gmailSync(pendingID: String?) async throws -> LedgerGmailSyncResult
    func gmailDisconnect() async throws
    func gmailPendingImports() async throws -> [LedgerGmailPendingImport]
    func gmailPendingImport(id: String) async throws -> LedgerGmailPendingDetail
    func dismissGmailPendingImport(id: String) async throws
    func gmailPendingEvents() -> AsyncThrowingStream<Void, Error>
}

typealias RemoteLedgerCapabilities = LedgerRemoteHealth & LedgerRemoteAuthentication
    & LedgerRemotePasskeys & LedgerRemoteQuickUnlock & LedgerRemoteGmail

/// Core ledger operations shared by remote and local implementations.
/// Reference identity lets a session reuse repository-owned caches and indexes.
protocol LedgerRepository: AnyObject, Sendable {
    func bootstrap(
        start: String,
        end: String,
        today: String,
        valuationCurrency: String
    ) async throws -> LedgerBootstrap
    func homeReport(
        start: String,
        end: String,
        valuationCurrency: String
    ) async throws -> LedgerHomeReport
    func globalTransactions() async throws -> LedgerGlobalTransactions
    func transactionPage(start: String, end: String, query: String, cursor: String?, limit: Int, account: String?, tag: String?, kind: String?) async throws -> LedgerTransactionPage
    func transactionDetail(source: TransactionSource) async throws -> LedgerTransaction
    func classificationHistoryPage(cursor: String?) async throws -> LedgerTransactionPage
    func importDocuments() async throws -> [LedgerImportDocument]
    func importProviders() async throws -> [LedgerImportProviderInfo]
    func previewImport(
        file: LedgerImportSelectedFile,
        provider: String?,
        alipayFundRounding: Bool,
        archivePassword: String
    ) async throws -> LedgerImportPreview
    func commitImport(request: LedgerImportCommitRequest) async throws -> LedgerImportCommitResult
    func updateTransaction(source: TransactionSource, entry: LedgerTransactionEntry) async throws
    func deleteTransaction(source: TransactionSource, reason: String) async throws
    func addTransactionTags(sources: [TransactionSource], tags: [String]) async throws
    func indexInfo(targetGitSHA: String?) async throws -> LedgerIndexInfo
    func accountDetail(
        account: String,
        currency: String,
        start: String,
        end: String
    ) async throws -> LedgerAccountDetail
    func dashboard(start: String, end: String, valuationCurrency: String) async throws -> LedgerDashboard
    func incomeStatement(start: String, end: String, valuationCurrency: String) async throws -> LedgerIncomeStatement
    func investments() async throws -> LedgerInvestmentSummary
    func runBQL(query: String, valuationCurrency: String) async throws -> BQLResult
    func bqlHistory() async throws -> [BQLHistoryRecord]
    func saveBQLHistory(query: String) async throws -> BQLHistoryRecord
    func generateBQLHistoryTitle(id: String) async throws -> BQLHistoryRecord
    func renameBQLHistory(id: String, title: String) async throws -> BQLHistoryRecord
    func reconciliation(start: String, end: String) async throws -> LedgerReconciliationResponse
    func reconcile(request: LedgerReconcileRequest) async throws -> LedgerReconciliationResult
    func addAccount(input: LedgerAccountInput) async throws
    func deleteBQLHistory(id: String) async throws
}

extension LedgerRepository {
    func classificationHistoryPage(cursor: String?) async throws -> LedgerTransactionPage {
        throw LedgerRepositoryError.capabilityUnavailable("bounded classification history")
    }

    func transactionPage(start: String, end: String, query: String, cursor: String?, limit: Int,
                         account: String?, tag: String?, kind: String?) async throws -> LedgerTransactionPage {
        throw LedgerRepositoryError.capabilityUnavailable("native transaction pagination")
    }
    func transactionDetail(source: TransactionSource) async throws -> LedgerTransaction {
        throw LedgerRepositoryError.capabilityUnavailable("native transaction detail")
    }

    func addAccount(input: LedgerAccountInput) async throws {
        throw LedgerRepositoryError.capabilityUnavailable("add account")
    }
}

typealias LedgerRepositoryFactory = @MainActor @Sendable (LedgerLocation) throws -> any LedgerRepository

/// Adapts the existing server API to the repository boundary and keeps the
/// remote origin out of `LedgerSession` request closures.
final class RemoteLedgerRepository: LedgerRepository, RemoteLedgerCapabilities {
    let baseURL: URL
    private let api: any LedgerAPI

    init(api: any LedgerAPI, baseURL: URL) {
        self.api = api
        self.baseURL = baseURL
    }

    func addAccount(input: LedgerAccountInput) async throws {
        try await api.addAccount(baseURL: baseURL, input: input)
    }

    func reconciliation(start: String, end: String) async throws -> LedgerReconciliationResponse {
        try await api.reconciliation(baseURL: baseURL, start: start, end: end)
    }

    func reconcile(request: LedgerReconcileRequest) async throws -> LedgerReconciliationResult {
        try await api.reconcile(baseURL: baseURL, request: request)
    }

    func health() async throws -> HealthStatus { try await api.health(baseURL: baseURL) }
    func authStatus() async throws -> AuthStatus { try await api.authStatus(baseURL: baseURL) }
    func passkeyStatus() async throws -> PasskeyStatus { try await api.passkeyStatus(baseURL: baseURL) }
    func passkeyLoginOptions() async throws -> PasskeyRequestOptions {
        try await api.passkeyLoginOptions(baseURL: baseURL)
    }
    func verifyPasskey(assertion: PasskeyAssertion) async throws {
        try await api.verifyPasskey(baseURL: baseURL, assertion: assertion)
    }
    func login(password: String) async throws { try await api.login(baseURL: baseURL, password: password) }
    func registerQuickUnlock(deviceName: String, mode: String) async throws -> QuickUnlockCredential {
        try await api.registerQuickUnlock(baseURL: baseURL, deviceName: deviceName, mode: mode)
    }
    func verifyQuickUnlock(credential: QuickUnlockCredential) async throws {
        try await api.verifyQuickUnlock(baseURL: baseURL, credential: credential)
    }
    func revokeQuickUnlock(deviceID: String) async throws {
        try await api.revokeQuickUnlock(baseURL: baseURL, deviceID: deviceID)
    }
    func revokeWidgetQuickUnlock(credential: LedgerWidgetCredential) async throws {
        try await api.revokeWidgetQuickUnlock(baseURL: baseURL, credential: credential)
    }
    func bootstrap(
        start: String,
        end: String,
        today: String,
        valuationCurrency: String
    ) async throws -> LedgerBootstrap {
        try await api.bootstrap(
            baseURL: baseURL,
            start: start,
            end: end,
            today: today,
            valuationCurrency: valuationCurrency
        )
    }
    func homeReport(start: String, end: String, valuationCurrency: String) async throws -> LedgerHomeReport {
        try await api.homeReport(
            baseURL: baseURL,
            start: start,
            end: end,
            valuationCurrency: valuationCurrency
        )
    }
    func globalTransactions() async throws -> LedgerGlobalTransactions {
        try await api.globalTransactions(baseURL: baseURL)
    }
    func importDocuments() async throws -> [LedgerImportDocument] {
        try await api.importDocuments(baseURL: baseURL)
    }
    func importProviders() async throws -> [LedgerImportProviderInfo] {
        try await api.importProviders(baseURL: baseURL)
    }
    func gmailStatus() async throws -> LedgerGmailStatus { try await api.gmailStatus(baseURL: baseURL) }
    func gmailConnect() async throws -> LedgerGmailConnectResponse { try await api.gmailConnect(baseURL: baseURL) }
    func gmailSync(pendingID: String?) async throws -> LedgerGmailSyncResult {
        try await api.gmailSync(baseURL: baseURL, pendingID: pendingID)
    }
    func gmailDisconnect() async throws { try await api.gmailDisconnect(baseURL: baseURL) }
    func gmailPendingImports() async throws -> [LedgerGmailPendingImport] {
        try await api.gmailPendingImports(baseURL: baseURL)
    }
    func gmailPendingImport(id: String) async throws -> LedgerGmailPendingDetail {
        try await api.gmailPendingImport(baseURL: baseURL, id: id)
    }
    func dismissGmailPendingImport(id: String) async throws {
        try await api.dismissGmailPendingImport(baseURL: baseURL, id: id)
    }
    func gmailPendingEvents() -> AsyncThrowingStream<Void, Error> {
        api.gmailPendingEvents(baseURL: baseURL)
    }
    func previewImport(
        file: LedgerImportSelectedFile,
        provider: String?,
        alipayFundRounding: Bool,
        archivePassword: String
    ) async throws -> LedgerImportPreview {
        try await api.previewImport(
            baseURL: baseURL,
            file: file,
            provider: provider,
            alipayFundRounding: alipayFundRounding,
            archivePassword: archivePassword
        )
    }
    func commitImport(request: LedgerImportCommitRequest) async throws -> LedgerImportCommitResult {
        try await api.commitImport(baseURL: baseURL, request: request)
    }
    func updateTransaction(source: TransactionSource, entry: LedgerTransactionEntry) async throws {
        try await api.updateTransaction(baseURL: baseURL, source: source, entry: entry)
    }
    func deleteTransaction(source: TransactionSource, reason: String) async throws {
        try await api.deleteTransaction(baseURL: baseURL, source: source, reason: reason)
    }
    func addTransactionTags(sources: [TransactionSource], tags: [String]) async throws {
        try await api.addTransactionTags(baseURL: baseURL, sources: sources, tags: tags)
    }
    func indexInfo(targetGitSHA: String?) async throws -> LedgerIndexInfo {
        try await api.indexInfo(baseURL: baseURL, targetGitSHA: targetGitSHA)
    }
    func accountDetail(
        account: String,
        currency: String,
        start: String,
        end: String
    ) async throws -> LedgerAccountDetail {
        try await api.accountDetail(
            baseURL: baseURL,
            account: account,
            currency: currency,
            start: start,
            end: end
        )
    }
    func dashboard(start: String, end: String, valuationCurrency: String) async throws -> LedgerDashboard {
        try await api.dashboard(
            baseURL: baseURL,
            start: start,
            end: end,
            valuationCurrency: valuationCurrency
        )
    }
    func incomeStatement(start: String, end: String, valuationCurrency: String) async throws -> LedgerIncomeStatement {
        try await api.incomeStatement(
            baseURL: baseURL,
            start: start,
            end: end,
            valuationCurrency: valuationCurrency
        )
    }
    func investments() async throws -> LedgerInvestmentSummary { try await api.investments(baseURL: baseURL) }
    func runBQL(query: String, valuationCurrency: String) async throws -> BQLResult {
        try await api.runBQL(baseURL: baseURL, query: query, valuationCurrency: valuationCurrency)
    }
    func bqlHistory() async throws -> [BQLHistoryRecord] { try await api.bqlHistory(baseURL: baseURL) }
    func saveBQLHistory(query: String) async throws -> BQLHistoryRecord {
        try await api.saveBQLHistory(baseURL: baseURL, query: query)
    }
    func generateBQLHistoryTitle(id: String) async throws -> BQLHistoryRecord {
        try await api.generateBQLHistoryTitle(baseURL: baseURL, id: id)
    }
    func renameBQLHistory(id: String, title: String) async throws -> BQLHistoryRecord {
        try await api.renameBQLHistory(baseURL: baseURL, id: id, title: title)
    }
    func deleteBQLHistory(id: String) async throws {
        try await api.deleteBQLHistory(baseURL: baseURL, id: id)
    }
}

struct LedgerAPIClient: LedgerAPI, @unchecked Sendable {
    private let session: URLSession
    private let gmailEventSession: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    static let gmailEventResourceTimeout: TimeInterval = 7 * 24 * 60 * 60

    var gmailEventResourceTimeoutForTesting: TimeInterval {
        gmailEventSession.configuration.timeoutIntervalForResource
    }

    init(session: URLSession = .shared) {
        self.session = session
        let eventConfiguration = session.configuration
        eventConfiguration.timeoutIntervalForResource = Self.gmailEventResourceTimeout
        gmailEventSession = URLSession(configuration: eventConfiguration)
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

    func registerQuickUnlock(baseURL: URL, deviceName: String, mode: String) async throws -> QuickUnlockCredential {
        try await send(
            baseURL: baseURL,
            path: "/api/quick-unlock/register",
            method: "POST",
            body: QuickUnlockRegisterRequest(mode: mode, name: deviceName)
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

    func revokeWidgetQuickUnlock(baseURL: URL, credential: LedgerWidgetCredential) async throws {
        let _: EmptySuccess = try await send(
            baseURL: baseURL,
            path: "/api/quick-unlock/revoke",
            method: "POST",
            body: QuickUnlockRevokeRequest(deviceID: credential.deviceID, token: credential.token)
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

    func globalTransactions(baseURL: URL) async throws -> LedgerGlobalTransactions {
        var components = URLComponents(url: baseURL.appending(path: "/api/ledger/transactions"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "start", value: "0001-01-01"), URLQueryItem(name: "end", value: "9999-12-31")]
        guard let url = components?.url else { throw LedgerAPIError.invalidResponse }
        return try await request(URLRequest(url: url))
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

    func gmailStatus(baseURL: URL) async throws -> LedgerGmailStatus {
        try await get(baseURL: baseURL, path: "/api/integrations/gmail/status")
    }

    func gmailConnect(baseURL: URL) async throws -> LedgerGmailConnectResponse {
        var components = URLComponents(
            url: baseURL.appending(path: "/api/integrations/gmail/connect"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "client", value: "ios")]
        guard let url = components?.url else { throw LedgerAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await self.request(request)
    }

    func gmailSync(baseURL: URL, pendingID: String?) async throws -> LedgerGmailSyncResult {
        var components = URLComponents(
            url: baseURL.appending(path: "/api/integrations/gmail/sync"),
            resolvingAgainstBaseURL: false
        )
        if let pendingID {
            components?.queryItems = [URLQueryItem(name: "pendingId", value: pendingID)]
        }
        guard let url = components?.url else { throw LedgerAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await self.request(request)
    }

    func gmailDisconnect(baseURL: URL) async throws {
        try await sendWithoutResponse(
            baseURL: baseURL,
            path: "/api/integrations/gmail",
            method: "DELETE"
        )
    }

    func gmailPendingImports(baseURL: URL) async throws -> [LedgerGmailPendingImport] {
        let response: LedgerGmailPendingResponse = try await get(
            baseURL: baseURL,
            path: "/api/ledger/imports/pending"
        )
        return response.items
    }

    func gmailPendingImport(baseURL: URL, id: String) async throws -> LedgerGmailPendingDetail {
        try await get(baseURL: baseURL, path: try gmailPendingPath(id: id))
    }

    func dismissGmailPendingImport(baseURL: URL, id: String) async throws {
        try await sendWithoutResponse(
            baseURL: baseURL,
            path: try gmailPendingPath(id: id),
            method: "DELETE"
        )
    }

    func gmailPendingEvents(baseURL: URL) -> AsyncThrowingStream<Void, Error> {
        #if canImport(FoundationNetworking)
        return AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: LedgerAPIError.incompatibleServer("当前平台不支持 Gmail 实时更新")
            )
        }
        #else
        let session = gmailEventSession
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(
                        url: baseURL.appending(path: "/api/ledger/imports/pending/events")
                    )
                    request.httpMethod = "GET"
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw LedgerAPIError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw LedgerAPIError.server(
                            status: http.statusCode,
                            message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                        )
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if line == "event: pending" {
                            continuation.yield(())
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        #endif
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

    func reconciliation(baseURL: URL, start: String, end: String) async throws -> LedgerReconciliationResponse {
        var components = URLComponents(url: baseURL.appending(path: "/api/ledger/reconciliation"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "start", value: start),
            URLQueryItem(name: "end", value: end),
        ]
        guard let url = components?.url else { throw LedgerAPIError.invalidResponse }
        return try await request(URLRequest(url: url))
    }

    func reconcile(baseURL: URL, request: LedgerReconcileRequest) async throws -> LedgerReconciliationResult {
        try await send(
            baseURL: baseURL,
            path: "/api/ledger/reconciliation",
            method: "POST",
            body: request
        )
    }

    func accountStatuses(baseURL: URL) async throws -> [LedgerAccountStatus] {
        try await get(baseURL: baseURL, path: "/api/ledger/account-status")
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

    func deleteTransaction(baseURL: URL, source: TransactionSource, reason: String) async throws {
        let _: EmptySuccess = try await send(
            baseURL: baseURL,
            path: "/api/ledger/transactions",
            method: "DELETE",
            body: LedgerTransactionDeleteRequest(source: source, reason: reason)
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

    func addAccount(
        baseURL: URL,
        input: LedgerAccountInput
    ) async throws {
        let _: EmptySuccess = try await send(
            baseURL: baseURL,
            path: "/api/ledger/accounts",
            method: "POST",
            body: input
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

    private func gmailPendingPath(id: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !id.isEmpty, id.unicodeScalars.allSatisfy(allowed.contains) else {
            throw LedgerAPIError.invalidResponse
        }
        return "/api/ledger/imports/pending/\(id)"
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

private struct LedgerGmailPendingResponse: Decodable {
    let items: [LedgerGmailPendingImport]
}

private extension Data {
    mutating func appendUTF8(_ value: String) {
        append(Data(value.utf8))
    }
}
