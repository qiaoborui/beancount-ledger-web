import Foundation

struct LocalLedgerFileDraft: Sendable {
    let path: String
    let text: String
    let revisionID: UUID
}

actor LocalLedgerRepository: LedgerRepository {
    nonisolated static let didSaveNotification = Notification.Name("LedgerLocalRevisionSaved")
    nonisolated let descriptor: LocalLedgerDescriptor
    nonisolated let workspace: LocalLedgerWorkspace
    nonisolated let storage: any LogicalLocalStorage
    private let engine: any LocalLedgerEngine
    private let validator: LocalLedgerCatalog.Validator
    private(set) var presentedRevisionID: UUID?
    private var importRevisionIDs: [String: UUID] = [:]
    private var importPreviewDates: [String: Date] = [:]
    private var lastRuntimeMaintenance: Date?
    private struct PreparedOperation: Sendable {
        let preview: PreparedBookkeepingChange
        let importID: String?
        let result: LocalLedgerResponse?
    }
    private var preparedOperations: [UUID: PreparedOperation] = [:]

    init(descriptor: LocalLedgerDescriptor, workspace: LocalLedgerWorkspace,
         engine: any LocalLedgerEngine = EmbeddedLocalLedgerEngine.shared,
         validator: @escaping LocalLedgerCatalog.Validator = { root, entry in
             try await EmbeddedBeancountValidator.shared.validate(workspace: root, entryFile: entry)
         }) {
        self.descriptor = descriptor
        self.workspace = workspace
        self.storage = DeviceLocalStorage(workspace: workspace)
        self.engine = engine
        self.validator = validator
    }

    init(descriptor: LocalLedgerDescriptor, storage: any LogicalLocalStorage,
         engine: any LocalLedgerEngine = EmbeddedLocalLedgerEngine.shared,
         validator: @escaping LocalLedgerCatalog.Validator) {
        self.descriptor = descriptor
        self.storage = storage
        self.workspace = storage.workspace
        self.engine = engine
        self.validator = validator
    }

    func storageStatus() async throws -> LocalStorageSyncStatus { try await storage.status() }
    func synchronize() async throws -> LocalStorageSyncStatus {
        let validate = validator, entry = descriptor.entrypoint
        return try await storage.synchronize { root in try await validate(root, entry) }
    }
    func resolveSyncConflicts(keepingLocal: Bool) async throws -> LocalStorageSyncStatus {
        let validate = validator, entry = descriptor.entrypoint
        return try await storage.resolveConflicts(keepingLocal: keepingLocal) { root in try await validate(root, entry) }
    }
    func exportSyncConflictVersions() async throws -> URL { try await storage.exportConflictVersions() }

    func bootstrap(start: String, end: String, today: String, valuationCurrency: String) async throws -> LedgerBootstrap {
        try await bootstrapSnapshot(start: start, end: end, today: today, valuationCurrency: valuationCurrency).payload
    }

    /// Return the revision that produced the presentation, including when a writer
    /// publishes a new generation while the engine is reading the pinned snapshot.
    func bootstrapSnapshot(start: String, end: String, today: String, valuationCurrency: String) async throws
        -> (revisionID: UUID, payload: LedgerBootstrap) {
        var query = range(start, end, valuationCurrency)
        query["today"] = today
        let cacheQuery = query
        let cache = BootstrapPresentationCache(ledgerID: descriptor.id, entrypoint: descriptor.entrypoint,
            url: workspace.rootDirectory.appendingPathComponent(".bootstrap-presentation.json"))
        if let restored = try await workspace.withCurrentSnapshot({ revision, _ in
            cache.load(revisionID: revision.id, query: cacheQuery)
        }) {
            presentedRevisionID = restored.revisionID
            return (restored.revisionID, restored.payload)
        }
        let (revisionID, data) = try await readSnapshot("/api/ledger/bootstrap", query: query)
        let payload = try data.decode(LedgerBootstrap.self)
        presentedRevisionID = revisionID
        if payload.sensitiveUnlocked, let cachedData = try? data.resultData() {
            cache.save(cachedData, revisionID: revisionID, query: query)
        }
        return (revisionID, payload)
    }
    func homeReport(start: String, end: String, valuationCurrency: String) async throws -> LedgerHomeReport {
        try await read("/api/ledger/home-report", query: range(start, end, valuationCurrency))
    }
    /// Additive native page API. Callers must keep cursor and query together and
    /// restart after a revision conflict; it is not an all-history response.
    func transactionPage(start: String = "0001-01-01", end: String = "9999-12-31",
                         query: String = "", cursor: String? = nil, limit: Int = 100,
                         account: String? = nil, tag: String? = nil, kind: String? = nil) async throws -> LedgerTransactionPage {
        guard (1...500).contains(limit) else { throw LocalLedgerError.invalidConfiguration("分页数量必须为 1 到 500") }
        var parameters = ["start": start, "end": end, "q": query, "limit": String(limit)]
        parameters["cursor"] = cursor
        parameters["account"] = account
        parameters["tag"] = tag
        parameters["kind"] = kind
        let (revision, response) = try await readSnapshot("/api/ledger/transactions/page", query: parameters)
        let page = try response.decodeTransactionPage()
        presentedRevisionID = revision
        return page
    }

    /// Raw date-range candidates; filtering belongs exclusively to the Swift reducer.
    /// This read never advances the presentation revision that authorizes writes.
    func candidatePage(start: String, end: String, cursor: String? = nil, limit: Int = 500,
                       expectedRevisionID: UUID) async throws -> LedgerTransactionPage {
        guard (1...500).contains(limit),
              cursor.map({ !$0.isEmpty && $0.utf8.count <= 1_024 }) ?? true else {
            throw LocalLedgerError.invalidConfiguration("候选分页参数无效")
        }
        var query = ["dialect": "native-candidates-v1", "start": start, "end": end, "limit": String(limit)]
        query["cursor"] = cursor
        try Task.checkCancellation()
        let (_, response) = try await readSnapshot("/api/ledger/transactions/page", query: query,
                                                  expectedRevisionID: expectedRevisionID)
        try Task.checkCancellation()
        let page = try response.decodeTransactionPage(maximumBytes: 1 << 20)
        guard page.sensitiveUnlocked else {
            throw LedgerAPIError.server(status: 423, message: "账本敏感数据已锁定")
        }
        guard !page.revision.isEmpty, page.transactions.count <= limit,
              page.nextCursor.map({ !$0.isEmpty && $0.utf8.count <= 1_024 && $0 != cursor }) ?? true else {
            throw LocalLedgerError.operationFailed("候选分页响应无效")
        }
        // Pinning keeps the generation readable, not current: a writer can commit
        // while the engine is suspended, including on the very last page.
        try Task.checkCancellation()
        let current = try await workspace.currentRevision()
        try Task.checkCancellation()
        guard current?.id == expectedRevisionID else { throw LocalLedgerWorkspace.WorkspaceError.staleRevision }
        return page
    }

    func scanTransactions(start: String, end: String, filter: LedgerTransactionFilter,
                          expectedRevisionID: UUID, limits: LocalTransactionScan.Limits = .init()) async throws
        -> LocalTransactionScan.Result {
        var scan: LocalTransactionScan?
        var cursor: String?
        while true {
            try Task.checkCancellation()
            let page = try await candidatePage(start: start, end: end, cursor: cursor,
                                               expectedRevisionID: expectedRevisionID)
            try Task.checkCancellation()
            if scan == nil {
                scan = try LocalTransactionScan(expectedRevision: page.revision, filter: filter, limits: limits)
            }
            if let result = try scan?.consume(page, requestedCursor: cursor) {
                try Task.checkCancellation()
                let current = try await workspace.currentRevision()
                try Task.checkCancellation()
                guard current?.id == expectedRevisionID else { throw LocalLedgerWorkspace.WorkspaceError.staleRevision }
                // Session/request guards still own publication after this async return.
                return result
            }
            // Empty/nonmatching pages are not EOF; follow the raw continuation.
            cursor = scan?.nextCursor
        }
    }

    /// The native model revision is opaque; the workspace UUID is the bootstrap
    /// pairing boundary. Check it inside the pinned snapshot, not in a prior read.
    func overviewCategories(start: String, end: String,
                            expectedRevisionID: UUID) async throws -> LedgerOverviewCategories {
        let (_, response) = try await readSnapshot("/api/ledger/overview/categories",
            query: ["start": start, "end": end], expectedRevisionID: expectedRevisionID)
        let result = try response.decode(LedgerOverviewCategories.self)
        guard result.sensitiveUnlocked else {
            throw LedgerAPIError.server(status: 423, message: "账本敏感数据已锁定")
        }
        guard result.start == start, result.end == end, !result.revision.isEmpty,
              result.categories.count <= 4, result.positiveTotalMinorUnits >= 0,
              result.categories.isEmpty == (result.positiveTotalMinorUnits == 0),
              Set(result.categories.map(\.label)).count == result.categories.count,
              result.categories.allSatisfy({ $0.totalMinorUnits > 0
                  && $0.totalMinorUnits <= result.positiveTotalMinorUnits
                  && $0.positiveTransactionCount > 0 }) else {
            throw LocalLedgerError.operationFailed("概览汇总响应无效")
        }
        // This read must not change the revision used to authorize financial writes.
        return result
    }

    func transactionDetail(source: TransactionSource) async throws -> LedgerTransaction {
        try await read("/api/ledger/transactions/detail", query: ["file": source.file, "line": String(source.line), "hash": source.hash ?? ""])
    }

    /// Bare detail transport has no sensitiveUnlocked flag: authentication belongs
    /// to the owning session, which must discard results on lock/workspace changes.
    /// Unlike presentation reads, this pinned read never authorizes later writes.
    func transactionDetail(source: TransactionSource, expectedRevisionID: UUID) async throws -> LedgerTransaction {
        try Task.checkCancellation()
        guard !source.file.isEmpty, !source.file.hasPrefix("/"),
              !source.file.contains("\\"), !source.file.contains("\0"),
              source.line >= 0, let hash = source.hash, !hash.isEmpty else {
            throw LocalLedgerError.invalidConfiguration("交易来源无效")
        }
        var depth = 0
        for component in source.file.split(separator: "/") where component != "." {
            depth += component == ".." ? -1 : 1
            guard depth >= 0 else { throw LocalLedgerError.invalidConfiguration("交易来源无效") }
        }
        let (_, response) = try await readSnapshot("/api/ledger/transactions/detail",
            query: ["file": source.file, "line": String(source.line), "hash": hash],
            expectedRevisionID: expectedRevisionID)
        try Task.checkCancellation()
        let detail = try response.decode(LedgerTransaction.self)
        guard detail.source == source else { throw LocalLedgerError.staleTransactionCursor }
        let current = try await workspace.currentRevision()
        try Task.checkCancellation()
        guard current?.id == expectedRevisionID else { throw LocalLedgerWorkspace.WorkspaceError.staleRevision }
        return detail
    }

    /// Additive reader only, not production UI wiring. The provider checks freshness
    /// after each new page read; it is NOT called when serving cached rows. The owner
    /// must explicitly invalidate the window on revision, workspace or lock changes
    /// and discard already returned windows. Authentication belongs to that session.
    func makeTransactionWindow(start: String, end: String, filter: LedgerTransactionFilter = .init(),
                               expectedRevisionID: UUID, limits: LocalTransactionWindow.Limits = .init(),
                               checkpoint: LocalTransactionWindow.Checkpoint? = nil) async throws -> LocalTransactionWindow {
        try Task.checkCancellation()
        let current = try await workspace.currentRevision()
        try Task.checkCancellation()
        guard current?.id == expectedRevisionID else { throw LocalLedgerWorkspace.WorkspaceError.staleRevision }
        let workspaceID = descriptor.id
        let scope = [workspaceID.uuidString, expectedRevisionID.uuidString, start, end].joined(separator: "|")
        return try LocalTransactionWindow(workspaceID: workspaceID, scope: scope, filter: filter, limits: limits,
                                          checkpoint: checkpoint) { request in
            guard request.workspaceID == workspaceID else {
                throw LocalTransactionWindow.WindowError.invalidConfiguration
            }
            let page = try await self.candidatePage(start: start, end: end, cursor: request.cursor,
                                                  limit: request.limit, expectedRevisionID: expectedRevisionID)
            try Task.checkCancellation()
            if let expected = request.expectedRevision, page.revision != expected {
                throw LocalTransactionWindow.WindowError.revisionMismatch
            }
            return page
        }
    }

    func classificationHistoryPage(cursor: String?) async throws -> LedgerTransactionPage {
        var query = ["limit": "500"]
        query["cursor"] = cursor
        let (_, response) = try await readSnapshot("/api/ledger/transactions/history-page", query: query)
        return try response.decodeTransactionPage()
    }

    func globalTransactions() async throws -> LedgerGlobalTransactions {
        try await read("/api/ledger/transactions", query: ["start": "0001-01-01", "end": "9999-12-31"])
    }
    func importDocuments() async throws -> [LedgerImportDocument] {
        let result: LedgerImportDocumentsResponse = try await read("/api/ledger/imports/documents")
        return result.documents
    }
    func importProviders() async throws -> [LedgerImportProviderInfo] {
        struct Response: Decodable { let providers: [LedgerImportProviderInfo] }
        let result: Response = try await read("/api/ledger/imports/providers")
        return result.providers
    }
    func previewImport(file: LedgerImportSelectedFile, provider: String?, alipayFundRounding: Bool,
                       archivePassword: String) async throws -> LedgerImportPreview {
        let body: BQLCell = .object(["provider": .string(provider ?? ""),
            "alipayFundRounding": .bool(alipayFundRounding), "archivePassword": .string(archivePassword)])
        let (revision, data) = try await readSnapshot("/api/ledger/imports/preview", method: "POST", body: body,
            importFile: .init(name: file.name, data: file.data))
        let result = try data.decode(LedgerImportPreview.self)
        presentedRevisionID = revision
        importRevisionIDs[result.importID] = revision
        importPreviewDates[result.importID] = Date()
        return result
    }
    func commitImport(request: LedgerImportCommitRequest) async throws -> LedgerImportCommitResult {
        guard let expected = importRevisionIDs[request.importID] else { throw LocalLedgerError.previewRequired }
        guard let created = importPreviewDates[request.importID],
              Date().timeIntervalSince(created) < LocalLedgerWorkspace.importPreviewRetention else {
            importRevisionIDs.removeValue(forKey: request.importID)
            importPreviewDates.removeValue(forKey: request.importID)
            throw LocalLedgerError.previewRequired
        }
        let result: LedgerImportCommitResult = try await mutate("/api/ledger/imports/commit", method: "POST",
            body: json(request), expected: expected, consumingImportID: request.importID)
        importRevisionIDs.removeValue(forKey: request.importID)
        importPreviewDates.removeValue(forKey: request.importID)
        return result
    }
    func reconciliation(start: String, end: String) async throws -> LedgerReconciliationResponse {
        try await read("/api/ledger/reconciliation", query: ["start": start, "end": end])
    }
    func reconcile(request: LedgerReconcileRequest) async throws -> LedgerReconciliationResult {
        try await mutate("/api/ledger/reconciliation", method: "POST", body: json(request))
    }
    func updateTransaction(source: TransactionSource, entry: LedgerTransactionEntry) async throws {
        let _: BQLCell = try await mutate("/api/ledger/transactions", method: "PUT",
            body: json(LedgerTransactionUpdateRequest(source: source, entry: entry)))
    }
    func deleteTransaction(source: TransactionSource, reason: String) async throws {
        let _: BQLCell = try await mutate("/api/ledger/transactions", method: "DELETE",
            body: json(LedgerTransactionDeleteRequest(source: source, reason: reason)))
    }
    func addTransactionTags(sources: [TransactionSource], tags: [String]) async throws {
        let _: BQLCell = try await mutate("/api/ledger/transactions/tags", method: "POST",
            body: json(LedgerTransactionTagsRequest(sources: sources, tags: tags)))
    }
    func updateTransaction(source: TransactionSource, entry: LedgerTransactionEntry, expectedRevisionID: UUID) async throws {
        let _: BQLCell = try await mutate("/api/ledger/transactions", method: "PUT",
            body: json(LedgerTransactionUpdateRequest(source: source, entry: entry)), expected: expectedRevisionID)
    }
    func deleteTransaction(source: TransactionSource, reason: String, expectedRevisionID: UUID) async throws {
        let _: BQLCell = try await mutate("/api/ledger/transactions", method: "DELETE",
            body: json(LedgerTransactionDeleteRequest(source: source, reason: reason)), expected: expectedRevisionID)
    }
    func addTransactionTags(sources: [TransactionSource], tags: [String], expectedRevisionID: UUID) async throws {
        let _: BQLCell = try await mutate("/api/ledger/transactions/tags", method: "POST",
            body: json(LedgerTransactionTagsRequest(sources: sources, tags: tags)), expected: expectedRevisionID)
    }
    func addTransaction(entry: LedgerTransactionEntry) async throws {
        let _: BQLCell = try await mutate("/api/ledger/append", method: "POST", body: json(entry))
    }

    func prepareBookkeeping(_ draft: BookkeepingDraft) async throws -> PreparedBookkeepingChange {
        try draft.validate()
        guard let revision = try await workspace.currentRevision() else { throw LocalLedgerError.previewRequired }
        let bodies = try draft.records.map { try json($0) }
        return try await prepare(draftRevision: draft.revision, expected: revision.id,
            operations: bodies.map { ("/api/ledger/append", $0) })
    }

    func prepareImport(_ request: LedgerImportCommitRequest) async throws -> PreparedBookkeepingChange {
        guard let expected = importRevisionIDs[request.importID], let date = importPreviewDates[request.importID],
              Date().timeIntervalSince(date) < LocalLedgerWorkspace.importPreviewRetention else {
            throw LocalLedgerError.previewRequired
        }
        // Archive-only imports deliberately have no transaction records.
        if !request.entries.isEmpty { try BookkeepingDraft.imported(request.entries).validate() }
        return try await prepare(draftRevision: UUID(), expected: expected,
            operations: [("/api/ledger/imports/commit", try json(request))], importID: request.importID)
    }

    func prepareBeanTransactions(_ text: String) async throws -> PreparedBookkeepingChange {
        _ = try BeanTransactionParser.transactionCount(text)
        guard let revision = try await workspace.currentRevision() else { throw LocalLedgerError.previewRequired }
        let evidence = BookkeepingDraft.Evidence.make(.beancount, original: text)
        let validator = validator, entrypoint = descriptor.entrypoint
        let files = try await workspace.prepare(expectedRevisionID: revision.id, mutateStage: { root in
            let main = root.appendingPathComponent(entrypoint)
            guard FileManager.default.fileExists(atPath: main.path) else {
                throw BookkeepingError.reviewRequired("未找到入口文件：\(entrypoint)")
            }
            let raw = try Data(contentsOf: main)
            guard let content = String(data: raw, encoding: .utf8) else {
                throw BookkeepingError.reviewRequired("入口文件编码异常")
            }
            let marker = "; import-fingerprint: " + evidence.fingerprint
            if content.contains(marker) {
                throw BookkeepingError.reviewRequired("相同交易内容已导入，请核对现有记录。")
            }
            var next = content
            if !next.hasSuffix("\n") { next += "\n" }
            next += "\n" + marker + "\n" + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            try Data(next.utf8).write(to: main)
        }, validator: { root in try await validator(root, entrypoint) })
        let preview = PreparedBookkeepingChange(id: UUID(), ledgerID: descriptor.id, draftRevision: UUID(),
            files: files, createdAt: Date())
        if preparedOperations.count >= 4 { preparedOperations.removeAll() }
        preparedOperations[preview.id] = .init(preview: preview, importID: nil, result: nil)
        return preview
    }

    private func prepare(draftRevision: UUID, expected: UUID, operations: [(String, BQLCell)],
                         importID: String? = nil) async throws -> PreparedBookkeepingChange {
        let engine = engine, validator = validator, entrypoint = descriptor.entrypoint
        let runtimeRoot = workspace.rootDirectory.appendingPathComponent("runtime").path
        let box = ResultBox()
        let files = try await workspace.prepare(expectedRevisionID: expected, mutateStage: { root in
            for (path, body) in operations {
                let data = try await engine.response(.init(workspaceRoot: root.path, runtimeRoot: runtimeRoot,
                    entrypoint: entrypoint, method: "POST", path: path, body: body, staging: true))
                if importID != nil { _ = try data.decode(LedgerImportCommitResult.self) }
                else { _ = try data.decode(BQLCell.self) }
                await box.set(data)
            }
        }, validator: { root in try await validator(root, entrypoint) })
        let preview = PreparedBookkeepingChange(id: UUID(), ledgerID: descriptor.id,
            draftRevision: draftRevision, files: files, createdAt: Date())
        preparedOperations = preparedOperations.filter { Date().timeIntervalSince($0.value.preview.createdAt) < 900 }
        // Bound retained source/attachment bytes; previews are cheap to regenerate.
        if preparedOperations.count >= 4 { preparedOperations.removeAll() }
        preparedOperations[preview.id] = .init(preview: preview, importID: importID, result: await box.data)
        return preview
    }

    func discardPrepared(_ preview: PreparedBookkeepingChange) { preparedOperations.removeValue(forKey: preview.id) }

    /// The opaque token resolves to repository-owned bytes. Confirming never
    /// reruns inference or rendering against a different source revision.
    func commitPrepared(_ preview: PreparedBookkeepingChange) async throws -> LedgerImportCommitResult? {
        guard let operation = preparedOperations.removeValue(forKey: preview.id),
              preview.ledgerID == descriptor.id, Date().timeIntervalSince(operation.preview.createdAt) < 900 else {
            throw BookkeepingError.expiredPreview
        }
        let validator = validator, entrypoint = descriptor.entrypoint
        let revision = try await workspace.commit(expectedRevisionID: operation.preview.files.revisionID,
            changes: operation.preview.files.changes, consumingImportID: operation.importID,
            validator: { root in try await validator(root, entrypoint) })
        presentedRevisionID = revision.id
        if let importID = operation.importID {
            importRevisionIDs.removeValue(forKey: importID)
            importPreviewDates.removeValue(forKey: importID)
        }
        await storage.didCommit(revision)
        NotificationCenter.default.post(name: Self.didSaveNotification, object: descriptor.id)
        if operation.importID != nil, let result = operation.result {
            return try result.decode(LedgerImportCommitResult.self)
        }
        return nil
    }
    func addAccount(input: LedgerAccountInput) async throws {
        let _: BQLCell = try await mutate("/api/ledger/accounts", method: "POST", body: json(input))
    }
    func indexInfo(targetGitSHA: String?) async throws -> LedgerIndexInfo {
        try await read("/api/ledger/index-info")
    }
    func accountDetail(account: String, currency: String, start: String, end: String) async throws -> LedgerAccountDetail {
        try await read("/api/ledger/accounts/detail", query: ["account": account, "currency": currency, "start": start, "end": end])
    }
    func dashboard(start: String, end: String, valuationCurrency: String) async throws -> LedgerDashboard {
        try await read("/api/ledger/dashboard", query: range(start, end, valuationCurrency))
    }
    func incomeStatement(start: String, end: String, valuationCurrency: String) async throws -> LedgerIncomeStatement {
        try await read("/api/ledger/income-statement", query: range(start, end, valuationCurrency))
    }
    func investments() async throws -> LedgerInvestmentSummary { try await read("/api/ledger/investments") }
    func runBQL(query: String, valuationCurrency: String) async throws -> BQLResult {
        try await read("/api/ledger/bql", method: "POST",
            body: .object(["query": .string(query), "valuationCurrency": .string(valuationCurrency)]))
    }

    func files() async throws -> [String] {
        try await workspace.withCurrentSnapshot { _, root in
            let root = root.resolvingSymlinksInPath().standardizedFileURL
            guard let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
            var paths: [String] = []
            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension == "bean" else { continue }
                if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    let normalized = url.standardizedFileURL
                    guard normalized.path.hasPrefix(root.path + "/") else {
                        throw LocalLedgerError.invalidConfiguration("文件路径超出当前账本")
                    }
                    paths.append(String(normalized.path.dropFirst(root.path.count + 1)))
                }
            }
            return paths.sorted()
        }
    }
    func readFile(path: String) async throws -> LocalLedgerFileDraft {
        try validBeanPath(path)
        let snapshot = try await workspace.readFileSnapshot(at: path)
        guard let text = String(data: snapshot.data, encoding: .utf8) else {
            throw LocalLedgerError.invalidConfiguration("文件需要使用 UTF-8 编码")
        }
        return LocalLedgerFileDraft(path: path, text: text, revisionID: snapshot.revision.id)
    }
    func saveFile(_ draft: LocalLedgerFileDraft, text: String) async throws {
        try validBeanPath(draft.path)
        let validator = validator, entry = descriptor.entrypoint
        let revision = try await workspace.commit(expectedRevisionID: draft.revisionID,
            changes: [.write(Data(text.utf8), to: draft.path)]) { root in
                try await validator(root, entry)
            }
        presentedRevisionID = revision.id
        await storage.didCommit(revision)
        NotificationCenter.default.post(name: Self.didSaveNotification, object: descriptor.id)
    }
    func exportLedger() async throws -> URL {
        try await workspace.withCurrentSnapshot { _, root in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("LedgerExport-" + UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.copyItem(at: root, to: destination)
                // A ledger share contains financial files. Imported Git config,
                // reflogs and object history stay in the original local workspace.
                guard let enumerator = FileManager.default.enumerator(at: destination,
                    includingPropertiesForKeys: nil) else {
                    throw LocalLedgerError.operationFailed("无法读取账本导出目录")
                }
                var metadata: [URL] = []
                while let url = enumerator.nextObject() as? URL {
                    if url.lastPathComponent.caseInsensitiveCompare(".git") == .orderedSame {
                        metadata.append(url)
                        enumerator.skipDescendants()
                        continue
                    }
                    #if os(iOS)
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
                    #endif
                }
                for url in metadata { try FileManager.default.removeItem(at: url) }
                #if os(iOS)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
                #endif
                return destination
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
    }

    // Query history is device-local UI state, kept outside immutable ledger generations.
    func bqlHistory() async throws -> [BQLHistoryRecord] {
        let url = historyURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([BQLHistoryRecord].self, from: Data(contentsOf: url))
    }
    func saveBQLHistory(query: String) async throws -> BQLHistoryRecord {
        var records = try await bqlHistory()
        let now = ISO8601DateFormatter().string(from: Date())
        let old = records.first { $0.query == query }
        let record = BQLHistoryRecord(id: old?.id ?? UUID().uuidString, query: query,
            title: old?.title ?? String(query.prefix(60)), titleSource: old?.titleSource ?? "local",
            createdAt: old?.createdAt ?? now, lastRunAt: now, runCount: (old?.runCount ?? 0) + 1)
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        try saveHistory(Array(records.prefix(200)))
        return record
    }
    func generateBQLHistoryTitle(id: String) async throws -> BQLHistoryRecord {
        guard let record = try await bqlHistory().first(where: { $0.id == id }) else {
            throw LocalLedgerError.operationFailed("查询记录已移除")
        }
        return try await renameBQLHistory(id: id, title: String(record.query.prefix(60)))
    }
    func renameBQLHistory(id: String, title: String) async throws -> BQLHistoryRecord {
        var records = try await bqlHistory()
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw LocalLedgerError.operationFailed("查询记录已移除")
        }
        let old = records[index]
        let record = BQLHistoryRecord(id: old.id, query: old.query, title: title, titleSource: "manual",
            createdAt: old.createdAt, lastRunAt: old.lastRunAt, runCount: old.runCount)
        records[index] = record
        try saveHistory(records)
        return record
    }
    func deleteBQLHistory(id: String) async throws {
        try saveHistory(try await bqlHistory().filter { $0.id != id })
    }

    private var historyURL: URL { workspace.rootDirectory.appendingPathComponent("runtime/bql-history.json") }
    private func saveHistory(_ records: [BQLHistoryRecord]) throws {
        try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try JSONEncoder().encode(records).write(to: historyURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try JSONEncoder().encode(records).write(to: historyURL, options: .atomic)
        #endif
    }
    private func range(_ start: String, _ end: String, _ currency: String) -> [String: String] {
        ["start": start, "end": end, "valuationCurrency": currency]
    }
    private func json<T: Encodable>(_ value: T) throws -> BQLCell {
        try JSONDecoder().decode(BQLCell.self, from: JSONEncoder().encode(value))
    }
    private func validBeanPath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasSuffix(".bean"), !path.contains("\\"), !path.contains("\0"),
            parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LocalLedgerError.invalidConfiguration("请选择账本内的 .bean 文件")
        }
    }
    private func read<T: Decodable>(_ path: String, method: String = "GET", query: [String: String] = [:],
        body: BQLCell? = nil, importFile: LocalLedgerEngineRequest.ImportFile? = nil) async throws -> T {
        let (revision, data) = try await readSnapshot(path, method: method, query: query, body: body, importFile: importFile)
        let result = try data.decode(T.self)
        presentedRevisionID = revision
        return result
    }
    private func readSnapshot(_ path: String, method: String = "GET", query: [String: String] = [:],
        body: BQLCell? = nil, importFile: LocalLedgerEngineRequest.ImportFile? = nil,
        expectedRevisionID: UUID? = nil) async throws -> (UUID, LocalLedgerResponse) {
        let now = Date()
        if lastRuntimeMaintenance.map({ now.timeIntervalSince($0) >= 60 * 60 }) ?? true {
            // Opportunistic maintenance also runs for read-only app sessions.
            // An active write/preview owns the lock; ordinary reads still proceed.
            if (try? await workspace.maintainImportRuntime(now: now)) != nil {
                lastRuntimeMaintenance = now
            }
            for (id, created) in importPreviewDates where now.timeIntervalSince(created) >= LocalLedgerWorkspace.importPreviewRetention {
                importPreviewDates.removeValue(forKey: id)
                importRevisionIDs.removeValue(forKey: id)
            }
        }
        let engine = engine, entrypoint = descriptor.entrypoint
        let runtimeRoot = workspace.rootDirectory.appendingPathComponent("runtime").path
        let operation: @Sendable (LocalLedgerWorkspace.Revision, URL) async throws -> (UUID, LocalLedgerResponse) = { revision, root in
            if let expectedRevisionID, revision.id != expectedRevisionID {
                throw LocalLedgerWorkspace.WorkspaceError.staleRevision
            }
            let data = try await engine.response(.init(workspaceRoot: root.path, runtimeRoot: runtimeRoot,
                entrypoint: entrypoint, method: method, path: path, query: query, body: body, importFile: importFile))
            return (revision.id, data)
        }
        if path == "/api/ledger/imports/preview" {
            return try await workspace.withImportPreviewSnapshot(operation)
        }
        return try await workspace.withCurrentSnapshot(operation)
    }
    private actor ResultBox {
        var data: LocalLedgerResponse?
        func set(_ value: LocalLedgerResponse) { data = value }
    }
    private func mutate<T: Decodable & Sendable>(_ path: String, method: String, body: BQLCell,
        expected: UUID? = nil, consumingImportID: String? = nil) async throws -> T {
        guard let revisionID = expected ?? presentedRevisionID else { throw LocalLedgerError.previewRequired }
        let engine = engine, validator = validator, entrypoint = descriptor.entrypoint
        let runtimeRoot = workspace.rootDirectory.appendingPathComponent("runtime").path
        let box = ResultBox()
        let revision = try await workspace.commit(expectedRevisionID: revisionID, changes: [],
            consumingImportID: consumingImportID, mutateStage: { root in
            let data = try await engine.response(.init(workspaceRoot: root.path, runtimeRoot: runtimeRoot,
                entrypoint: entrypoint, method: method, path: path, body: body, staging: true))
            // Decode before publication; malformed replies cannot produce a successful financial write.
            _ = try data.decode(T.self)
            await box.set(data)
        }, validator: { root in try await validator(root, entrypoint) })
        guard let data = await box.data else { throw LocalLedgerError.operationFailed("本地修改缺少结果") }
        presentedRevisionID = revision.id
        await storage.didCommit(revision)
        NotificationCenter.default.post(name: Self.didSaveNotification, object: descriptor.id)
        return try data.decode(T.self)
    }
}

/// A derived presentation of one immutable generation. A reopened app can show
/// authenticated local content without starting Python or rebuilding analytics.
/// Date, range, currency, entrypoint and build changes all require a fresh read.
private struct BootstrapPresentationCache: Sendable {
    let ledgerID: UUID
    let entrypoint: String
    let url: URL
    private static let maximumBytes = 16 * 1_024 * 1_024
    private static let applicationVersion = ["CFBundleShortVersionString", "CFBundleVersion"]
        .map { Bundle.main.object(forInfoDictionaryKey: $0) as? String ?? "development" }
        .joined(separator: "/")

    private struct Record: Codable {
        let formatVersion: Int
        let applicationVersion: String
        let ledgerID: UUID
        let revisionID: UUID
        let entrypoint: String
        let query: [String: String]
        let payload: Data
    }

    struct Restored: Sendable {
        let revisionID: UUID
        let payload: LedgerBootstrap
    }

    func load(revisionID: UUID, query: [String: String]) -> Restored? {
        // The workspace has checked its managed root and current generation.
        // Cache failures are misses, so damaged or unsupported data is rebuilt.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumBytes,
              let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.formatVersion == 1, record.applicationVersion == Self.applicationVersion,
              record.ledgerID == ledgerID, record.revisionID == revisionID,
              record.entrypoint == entrypoint, record.query == query,
              let payload = try? JSONDecoder().decode(LedgerBootstrap.self, from: record.payload),
              payload.sensitiveUnlocked else { return nil }
        return Restored(revisionID: revisionID, payload: payload)
    }

    func save(_ payload: Data, revisionID: UUID, query: [String: String]) {
        guard payload.count <= Self.maximumBytes else { return }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           attributes[.type] as? FileAttributeType != .typeRegular { return }
        let record = Record(formatVersion: 1, applicationVersion: Self.applicationVersion,
            ledgerID: ledgerID, revisionID: revisionID, entrypoint: entrypoint, query: query, payload: payload)
        guard let data = try? JSONEncoder().encode(record), data.count <= Self.maximumBytes else { return }
        do {
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            var cacheURL = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try cacheURL.setResourceValues(values)
        } catch {
            // This disposable read model never determines financial write success.
        }
    }
}
