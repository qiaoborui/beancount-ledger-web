import SwiftUI

struct GlobalSearchPage: View {
    @EnvironmentObject private var session: LedgerSession
    var body: some View {
        GlobalSearchView(query: $session.globalSearchQuery)
            .searchable(text: $session.globalSearchQuery, prompt: "搜索整个账本")
            .searchScopes($session.globalSearchScope, activation: .onSearchPresentation) {
                ForEach(LedgerGlobalSearchScope.allCases) { scope in Text(scope.title).tag(scope) }
            }
            .onSubmit(of: .search) { session.recordGlobalSearch(session.globalSearchQuery) }
    }
}

struct GlobalSearchView: View {
    @EnvironmentObject private var session: LedgerSession
    @Binding var query: String
    // Native search owns the bottom field; show the root directly without a transient title bar.
    var usesNativeSearchTab = false
    @State private var documents: [LedgerImportDocument] = []
    @State private var results = LedgerSearchResults()
    @State private var loading = false
    @State private var activeLoadID: UUID?
    @State private var errorMessage: String?
    @State private var revision = 0
    @State private var limit = 50
    @State private var filtersPresented = false
    @State private var localWindow: LedgerSession.LocalSearchWindow?
    @State private var localTags: [String]?
    @State private var localPageIndex = 0
    @State private var localSearchID: UUID?
    @State private var localSearching = false
    @State private var viewActive = false
    @State private var localSearchCompleted = false
    @State private var completedSearchRequest: SearchRequest?
    @State private var documentError: String?
    @State private var documentsLoaded = false

    private var localReadable: Bool {
        session.isLocal && session.phase == .ready && !session.privacyShielded
            && !session.isRangeLoading && !session.isValuationCurrencyLoading
            && !session.transactionMutationStates.values.contains(.pending)
    }
    private var searchRequest: SearchRequest {
        .init(query: query, scope: session.globalSearchScope, filters: session.globalSearchFilters,
              revision: revision, localRevision: session.localTransactionPresentationRevision,
              reload: session.localTransactionReloadID, readable: localReadable, page: localPageIndex,
              invalidation: session.localGlobalSearchInvalidation, active: viewActive)
    }

    private var hasSearch: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || session.globalSearchScope != .all || !session.globalSearchFilters.isEmpty
    }

    private var allTags: [String] {
        session.isLocal ? (localTags ?? []) : Set(session.visibleGlobalTransactions.flatMap { $0.tags ?? [] }).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            List {
                if (loading || localSearching) && hasSearch {
                    ProgressView("正在搜索…").accessibilityIdentifier("global-search-loading")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.secondary)
                        Button("重新加载") { Task { await load(forceRefresh: true) } }
                    }
                }
                if let documentError {
                    Text(documentError).foregroundStyle(.secondary)
                    Button("重新加载文件") { Task { await load() } }
                }
                if !hasSearch {
                    if !session.recentGlobalSearches.isEmpty {
                        Section {
                            ForEach(session.recentGlobalSearches, id: \.self) { recent in
                                Button {
                                    query = recent
                                    session.recordGlobalSearch(recent)
                                } label: { Label(recent, systemImage: "clock.arrow.circlepath") }
                            }
                        } header: {
                            HStack {
                                Text("最近搜索")
                                Spacer()
                                Button("清除") { session.clearRecentGlobalSearches() }
                                    .font(.subheadline)
                            }
                            .textCase(nil)
                        }
                    } else {
                        ContentUnavailableView("搜索整个账本", systemImage: "magnifyingglass",
                                               description: Text("查找流水、账户、标签和文件"))
                            .listRowSeparator(.hidden)
                    }
                } else if results.isEmpty && !loading && !localSearching && errorMessage == nil && documentError == nil
                            && (!session.isLocal || (localSearchCompleted &&
                                ((session.globalSearchScope != .all && session.globalSearchScope != .documents) || documentsLoaded))) {
                    ContentUnavailableView {
                        Label("没有符合条件的结果", systemImage: "magnifyingglass")
                    } description: {
                        Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? "试试其他搜索范围或筛选条件。"
                             : "未找到“\(query)”的匹配结果，试试其他关键词或调整筛选条件。")
                    }
                } else {
                    if !results.destinations.isEmpty {
                        Section("功能") {
                            ForEach(results.destinations) { destination in
                                NavigationLink { LedgerDestinationView(destination: destination).toolbar(.visible, for: .navigationBar).onAppear(perform: recordResultOpen) } label: {
                                    Label(destination.title, systemImage: destination.systemImage)
                                }
                            }
                        }
                    }
                    if !results.accounts.isEmpty {
                        Section("账户 · \(results.accounts.count)") {
                            ForEach(results.accounts, id: \.account) { account in
                                NavigationLink { AccountDetailView(account: account.account, currency: account.currency).toolbar(.visible, for: .navigationBar).onAppear(perform: recordResultOpen) } label: {
                                    VStack(alignment: .leading) {
                                        Text(account.label)
                                        Text(account.account).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    if !results.tags.isEmpty {
                        Section("标签") {
                            ForEach(results.tags, id: \.self) { tag in
                                NavigationLink {
                                    if session.isLocal {
                                        LocalSearchTagTransactionsView(tag: tag, filters: session.globalSearchFilters)
                                            .onAppear(perform: recordResultOpen)
                                    } else {
                                        List(session.visibleGlobalTransactions.filter { ($0.tags ?? []).contains(tag) && session.globalSearchFilters.includes($0) }) { transaction in
                                            transactionLink(transaction)
                                        }
                                        .navigationTitle("#" + tag)
                                        .onAppear(perform: recordResultOpen)
                                        .toolbar(.visible, for: .navigationBar)
                                    }
                                } label: { Label(tag, systemImage: "number") }
                                .accessibilityIdentifier("global-search-tag-" + tag)
                                .disabled(session.isLocal && localSearching)
                            }
                        }
                    }
                    if !results.transactions.isEmpty {
                        Section("流水 · \(localWindow?.result.matchedCount ?? results.transactions.count)") {
                            ForEach(results.transactions.prefix(session.isLocal ? 100 : limit)) { transaction in
                                transactionLink(transaction).disabled(session.isLocal && localSearching)
                            }
                            if session.isLocal {
                                HStack {
                                    Button("上一页") { localPageIndex -= 1 }
                                        .disabled(localPageIndex == 0 || localSearching)
                                    Spacer()
                                    Text("第 \(localPageIndex + 1) 页").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("下一页") { localPageIndex += 1 }
                                        .disabled(localWindow?.continuation == nil || localSearching)
                                }
                            } else if results.transactions.count > limit {
                                Button("显示更多流水") { limit += 50 }
                            }
                        }
                    }
                    if !results.documents.isEmpty {
                        Section("导入文件 · \(results.documents.count)") {
                            ForEach(results.documents) { document in
                                NavigationLink {
                                    List {
                                        LabeledContent("文件", value: document.name ?? "账单归档")
                                        LabeledContent("渠道", value: document.provider ?? "其他")
                                        LabeledContent("覆盖日期", value: LedgerImportHistory.coverageText(document))
                                        if let path = document.path { Text(path).font(.caption).textSelection(.enabled) }
                                        NavigationLink("查看导入记录") { ImportHistoryView() }
                                    }.navigationTitle("导入文件")
                                        .onAppear(perform: recordResultOpen)
                                        .toolbar(.visible, for: .navigationBar)
                                } label: { Label(document.name ?? "账单归档", systemImage: "doc.text") }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .contentMargins(.top, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(usesNativeSearchTab ? .hidden : .automatic, for: .navigationBar)
        .scrollContentBackground(.hidden)
        .background(LedgerPalette.canvas)
        .scrollDismissesKeyboard(.interactively)
        .task(id: DocumentRequest(readable: session.isLocal ? localReadable : true,
            revision: session.localTransactionPresentationRevision, invalidation: session.localGlobalSearchInvalidation)) {
            if !session.isLocal || localReadable { await load() }
        }
        .refreshable { await load(forceRefresh: true) }
        .task(id: searchRequest) { await search() }
        .onAppear { viewActive = true }
        .onDisappear { viewActive = false }
        .onChange(of: documents) { _, _ in
            if session.isLocal && localReadable { updateLocalAuxiliaryResults() }
        }
        .onChange(of: query) { _, _ in localPageIndex = 0 }
        .onChange(of: session.globalSearchFilters) { _, _ in localPageIndex = 0 }
        .onChange(of: session.localTransactionPresentationRevision) { _, _ in localPageIndex = 0 }
        .onChange(of: localReadable) { _, readable in
            if session.isLocal && !readable {
                clearLocalSearch()
                if session.privacyShielded || session.phase != .ready {
                    activeLoadID = nil; documents = []; documentError = nil; documentsLoaded = false; loading = false
                }
            }
        }
        .sheet(isPresented: $filtersPresented) {
            GlobalSearchFilterSheet(filters: session.globalSearchFilters, scope: session.globalSearchScope,
                                    accounts: session.ledger?.accounts ?? [], tags: allTags) { filters in
                session.globalSearchFilters = filters
            }
            .ledgerPrivacyProtectedSheet()
        }
        .onChange(of: session.globalSearchScope) { _, scope in
            localPageIndex = 0
            if scope == .accounts {
                session.globalSearchFilters.tag = nil
                session.globalSearchFilters.startDate = nil
                session.globalSearchFilters.endDate = nil
            } else if scope == .documents {
                session.globalSearchFilters.account = nil
                session.globalSearchFilters.tag = nil
            }
        }
        .onChange(of: session.globalTransactions) { _, _ in revision += 1 }
        .onChange(of: session.transactionMutationStates) { _, _ in revision += 1 }
    }

    private func transactionLink(_ transaction: LedgerTransaction) -> some View {
        NavigationLink { TransactionDetailView(transaction: transaction).toolbar(.visible, for: .navigationBar).onAppear(perform: recordResultOpen) } label: {
            TransactionRow(transaction: transaction, accountLabels: TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? []))
        }
        .accessibilityIdentifier("transaction-row-\(transaction.source.line)")
        .ledgerTransactionActions(transaction)
    }

    private func load(forceRefresh: Bool = false) async {
        // Native search can reattach while the previous appearance task is cancelling.
        // Let the latest appearance take over instead of skipping it behind a busy flag.
        let loadID = UUID()
        activeLoadID = loadID
        let documentContext = DocumentRequest(readable: session.isLocal ? localReadable : true,
            revision: session.localTransactionPresentationRevision, invalidation: session.localGlobalSearchInvalidation)
        documentsLoaded = false
        loading = session.isLocal || !session.hasCachedGlobalTransactions
        if !session.isLocal { errorMessage = nil }
        documentError = nil
        defer {
            if activeLoadID == loadID {
                loading = false
                activeLoadID = nil
                if !session.isLocal { revision += 1 }
            }
        }
        if !session.isLocal {
            do { try await session.loadGlobalTransactions(forceRefresh: forceRefresh) }
            catch is CancellationError { return }
            catch { if activeLoadID == loadID { errorMessage = "流水加载失败：" + error.localizedDescription } }
        } else if forceRefresh {
            localPageIndex = 0
            revision += 1
        }
        guard activeLoadID == loadID, !Task.isCancelled else { return }
        do {
            let loadedDocuments = try await session.importDocuments()
            guard activeLoadID == loadID, !Task.isCancelled else { return }
            if session.isLocal {
                guard localReadable, documentContext == DocumentRequest(readable: localReadable,
                    revision: session.localTransactionPresentationRevision, invalidation: session.localGlobalSearchInvalidation) else { return }
            }
            documents = loadedDocuments
            documentsLoaded = true
        }
        catch is CancellationError {
            if session.isLocal, !Task.isCancelled, activeLoadID == loadID, localReadable {
                documentError = "文件读取已中断，请重新加载文件。"
            }
            return
        }
        catch {
            if activeLoadID == loadID {
                if session.isLocal {
                    documents = []
                    documentError = "导入文件加载失败：" + error.localizedDescription
                } else {
                    errorMessage = [errorMessage, "导入文件加载失败：" + error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
                }
            }
        }
    }

    private func search() async {
        if session.isLocal { await searchLocal(); return }
        do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
        let query = query
        let transactions = session.visibleGlobalTransactions
        let accounts = session.ledger?.accounts ?? []
        let documents = documents
        let scope = session.globalSearchScope
        let filters = session.globalSearchFilters
        let result = await Task.detached(priority: .userInitiated) {
            LedgerGlobalSearch.search(query, transactions: transactions, accounts: accounts, documents: documents, scope: scope, filters: filters)
        }.value
        guard !Task.isCancelled else { return }
        results = result
        limit = 50
    }

    private func clearLocalSearch() {
        localSearchID = nil
        localSearching = false
        localWindow = nil
        localTags = nil
        localSearchCompleted = false
        completedSearchRequest = nil
        results = LedgerSearchResults()
    }

    private func updateLocalAuxiliaryResults() {
        let auxiliary = LedgerGlobalSearch.search(query, transactions: [], accounts: session.ledger?.accounts ?? [],
            documents: documents, scope: session.globalSearchScope, filters: session.globalSearchFilters)
        results.accounts = auxiliary.accounts
        results.documents = auxiliary.documents
        results.destinations = auxiliary.destinations
    }

    private func searchLocal() async {
        guard viewActive else { return }
        guard localReadable else { clearLocalSearch(); return }
        localSearchCompleted = false
        updateLocalAuxiliaryResults()
        let id = UUID(), request = searchRequest
        localSearchID = id
        localSearching = true
        defer { if localSearchID == id { localSearching = false } }
        do {
            try await Task.sleep(for: .milliseconds(180))
            var previous = completedSearchRequest
            previous?.page = request.page
            let advance = previous == request && completedSearchRequest?.page == request.page - 1
                && localWindow?.continuation != nil
            var window: LedgerSession.LocalSearchWindow
            if advance, let continuation = localWindow?.continuation {
                window = try await session.localGlobalSearchWindow(query: request.query, scope: request.scope,
                    filters: request.filters, continuation: continuation)
            } else {
                window = try await session.localGlobalSearchWindow(query: request.query, scope: request.scope, filters: request.filters)
            }
            // Forward uses one scan and the current continuation. Backward or
            // invalidated anchors replay without retaining old transaction windows.
            if request.page > 0 && !advance {
                for index in 0..<request.page {
                    guard let continuation = window.continuation else {
                        if !Task.isCancelled, localSearchID == id, request == searchRequest { localPageIndex = index }
                        return
                    }
                    window = try await session.localGlobalSearchWindow(query: request.query, scope: request.scope,
                        filters: request.filters, continuation: continuation)
                }
            }
            guard !Task.isCancelled, localSearchID == id, request == searchRequest, localReadable else { return }
            var combined = LedgerGlobalSearch.search(request.query, transactions: [],
                accounts: session.ledger?.accounts ?? [], documents: documents, scope: request.scope, filters: request.filters)
            combined.transactions = window.result.transactions
            combined.tags = window.result.tags
            results = combined
            localWindow = window
            localTags = window.result.availableTags
            localSearchCompleted = true
            completedSearchRequest = request
            errorMessage = nil
        } catch is CancellationError {
            if !Task.isCancelled, localSearchID == id, request == searchRequest, viewActive {
                errorMessage = "搜索已中断，请重新加载。"
            }
        }
        catch {
            if !Task.isCancelled, localSearchID == id, request == searchRequest {
                localWindow = nil
                results.transactions = []
                results.tags = []
                localTags = nil
                errorMessage = "搜索失败：" + error.localizedDescription
            }
        }
    }

    private func recordResultOpen() { session.recordGlobalSearch(query) }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if usesNativeSearchTab {
                    Text("搜索").font(.largeTitle.bold())
                }
                Spacer()
                Button { filtersPresented = true } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(session.globalSearchFilters.isEmpty ? Color.primary : Color.accentColor)
                .background(.quaternary, in: Circle())
                .accessibilityLabel("筛选")
                .accessibilityValue(session.globalSearchFilters.isEmpty ? "全部日期" : "\(session.globalSearchFilters.count) 项条件")
                .accessibilityIdentifier("global-search-filters")
                .disabled(session.isLocal && localTags == nil)
            }
            if usesNativeSearchTab {
                Picker("搜索范围", selection: $session.globalSearchScope) {
                    ForEach(LedgerGlobalSearchScope.allCases) { scope in Text(scope.title).tag(scope) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("global-search-scopes")
            }
            if !session.globalSearchFilters.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        if let account = session.globalSearchFilters.account {
                            filterChip(session.ledger?.accounts.first { $0.account == account }?.label ?? account) {
                                session.globalSearchFilters.account = nil
                            }
                        }
                        if let tag = session.globalSearchFilters.tag {
                            filterChip("#" + tag) { session.globalSearchFilters.tag = nil }
                        }
                        if session.globalSearchFilters.hasDateRange {
                            filterChip((session.globalSearchFilters.startDate ?? "最早") + " 至 " + (session.globalSearchFilters.endDate ?? "最新")) {
                                session.globalSearchFilters.startDate = nil
                                session.globalSearchFilters.endDate = nil
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func filterChip(_ title: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) { Label(title, systemImage: "xmark.circle.fill").font(.subheadline) }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .accessibilityLabel("移除筛选：" + title)
    }

    private struct DocumentRequest: Equatable {
        let readable: Bool
        let revision: UUID?
        let invalidation: Int
    }
    private struct SearchRequest: Equatable {
        let query: String
        let scope: LedgerGlobalSearchScope
        let filters: LedgerGlobalSearchFilters
        let revision: Int
        let localRevision: UUID?
        let reload: Int
        let readable: Bool
        var page: Int
        let invalidation: Int
        let active: Bool
    }
}

private struct LocalSearchTagTransactionsView: View {
    @EnvironmentObject private var session: LedgerSession
    let tag: String
    let filters: LedgerGlobalSearchFilters
    @State private var window: LedgerSession.LocalSearchWindow?
    @State private var pageIndex = 0
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var reload = 0
    @State private var viewActive = false
    private var readable: Bool {
        session.phase == .ready && !session.privacyShielded && !session.isRangeLoading
            && !session.isValuationCurrencyLoading && !session.transactionMutationStates.values.contains(.pending)
    }
    private struct RequestKey: Equatable {
        let revision: UUID?
        let invalidation: Int
        let readable: Bool
        let page: Int
        let reload: Int
        let tag: String
        let filters: LedgerGlobalSearchFilters
        let active: Bool
    }
    private var key: RequestKey {
        .init(revision: session.localTransactionPresentationRevision, invalidation: session.localGlobalSearchInvalidation,
            readable: readable, page: pageIndex, reload: reload, tag: tag, filters: filters, active: viewActive)
    }
    var body: some View {
        List {
            if loading { ProgressView("正在读取标签流水…") }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.secondary)
                Button("重试") { reload += 1 }
            }
            if let window {
                Section("流水 · \(window.result.matchedCount)") {
                    ForEach(window.result.transactions) { transaction in
                        NavigationLink {
                            TransactionDetailView(transaction: transaction)
                        } label: {
                            TransactionRow(transaction: transaction,
                                accountLabels: TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? []))
                        }
                        .ledgerTransactionActions(transaction)
                        .disabled(loading)
                    }
                    HStack {
                        Button("上一页") { pageIndex -= 1 }.disabled(pageIndex == 0 || loading)
                        Spacer()
                        Text("第 \(pageIndex + 1) 页").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("下一页") { pageIndex += 1 }.disabled(window.continuation == nil || loading)
                    }
                }
            }
        }
        .navigationTitle("#" + tag)
        .toolbar(.visible, for: .navigationBar)
        .task(id: key) { await load() }
        .onAppear { viewActive = true }
        .onDisappear { viewActive = false }
        .onChange(of: readable) { _, allowed in if !allowed { window = nil; errorMessage = nil } }
        .onChange(of: session.localTransactionPresentationRevision) { _, _ in pageIndex = 0 }
    }
    private func load() async {
        guard viewActive else { return }
        guard readable else { window = nil; loading = false; return }
        errorMessage = nil
        let captured = key
        loading = true
        defer { if captured == key { loading = false } }
        do {
            var narrowed = filters
            narrowed.tag = tag
            var result = try await session.localGlobalSearchWindow(query: "", scope: .transactions, filters: narrowed)
            if captured.page > 0 {
                for index in 0..<captured.page {
                    guard let continuation = result.continuation else {
                        if !Task.isCancelled, captured == key { pageIndex = index }
                        return
                    }
                    result = try await session.localGlobalSearchWindow(query: "", scope: .transactions,
                        filters: narrowed, continuation: continuation)
                }
            }
            guard !Task.isCancelled, captured == key, readable else { return }
            window = result
        } catch is CancellationError {
            if !Task.isCancelled, captured == key { errorMessage = "读取已中断，请重试。" }
        }
        catch { if !Task.isCancelled, captured == key { errorMessage = error.localizedDescription } }
    }
}

private struct GlobalSearchFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LedgerGlobalSearchFilters
    @State private var limitsDates: Bool
    @State private var start: Date
    @State private var end: Date
    let scope: LedgerGlobalSearchScope
    let accounts: [LedgerAccount]
    let tags: [String]
    let apply: (LedgerGlobalSearchFilters) -> Void

    init(filters: LedgerGlobalSearchFilters, scope: LedgerGlobalSearchScope, accounts: [LedgerAccount], tags: [String], apply: @escaping (LedgerGlobalSearchFilters) -> Void) {
        _draft = State(initialValue: filters)
        _limitsDates = State(initialValue: filters.hasDateRange)
        _start = State(initialValue: Self.parse(filters.startDate) ?? Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date())
        _end = State(initialValue: Self.parse(filters.endDate) ?? Date())
        self.scope = scope
        self.accounts = accounts
        self.tags = tags
        self.apply = apply
    }

    var body: some View {
        NavigationStack {
            Form {
                if scope != .documents {
                    Section("账户") {
                        Picker("账户", selection: $draft.account) {
                            Text("全部账户").tag(String?.none)
                            ForEach(accounts, id: \.account) { account in
                                Text(account.label + " · " + account.account).tag(Optional(account.account))
                            }
                        }
                        .pickerStyle(.navigationLink)
                        .accessibilityIdentifier("global-search-account-filter")
                    }
                }
                if scope == .all || scope == .transactions {
                    Section("标签") {
                        Picker("标签", selection: $draft.tag) {
                            Text("全部标签").tag(String?.none)
                            ForEach(tags, id: \.self) { tag in Text("#" + tag).tag(Optional(tag)) }
                        }
                        .pickerStyle(.navigationLink)
                        .accessibilityIdentifier("global-search-tag-filter")
                    }
                }
                if scope != .accounts {
                    Section {
                        Toggle("限定日期", isOn: $limitsDates)
                            .accessibilityIdentifier("global-search-date-filter")
                        if limitsDates {
                            DatePicker("开始", selection: $start, displayedComponents: .date)
                            DatePicker("结束", selection: $end, in: start..., displayedComponents: .date)
                        }
                    } header: { Text("日期") } footer: {
                        Text("日期包含开始与结束当天，文件按账单覆盖日期匹配。")
                    }
                }
                Section {
                    Button("清除全部筛选", role: .destructive) {
                        draft = .init()
                        limitsDates = false
                    }
                }
            }
            .navigationTitle("筛选搜索结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        draft.startDate = limitsDates ? Self.format(start) : nil
                        draft.endDate = limitsDates ? Self.format(end) : nil
                        apply(draft)
                        dismiss()
                    }
                    .accessibilityIdentifier("global-search-apply-filters")
                }
            }
            .onChange(of: start) { _, value in if end < value { end = value } }
        }
    }

    private static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
