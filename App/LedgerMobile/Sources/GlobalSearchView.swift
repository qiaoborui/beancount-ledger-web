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
    @State private var completedSearch: SearchRequest?
    @State private var loading = false
    @State private var activeLoadID: UUID?
    @State private var errorMessage: String?
    @State private var revision = 0
    @State private var limit = 50
    @State private var filtersPresented = false

    private var hasSearch: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || session.globalSearchScope != .all || !session.globalSearchFilters.isEmpty
    }

    private var allTags: [String] {
        Set(session.visibleGlobalTransactions.flatMap { $0.tags ?? [] }).sorted()
    }

    private var searchRequest: SearchRequest {
        SearchRequest(query: query, scope: session.globalSearchScope, filters: session.globalSearchFilters, revision: revision)
    }

    private var isSearching: Bool { loading || completedSearch != searchRequest }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            List {
                if isSearching && hasSearch {
                    ProgressView("正在搜索…").accessibilityIdentifier("global-search-loading")
                }
                if let errorMessage, !isSearching {
                    Section {
                        Text(errorMessage).foregroundStyle(.secondary)
                        Button("重新加载") { Task { await load() } }
                    }
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
                } else if !isSearching && results.isEmpty && errorMessage == nil {
                    ContentUnavailableView {
                        Label("没有符合条件的结果", systemImage: "magnifyingglass")
                    } description: {
                        Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? "试试其他搜索范围或筛选条件。"
                             : "未找到“\(query)”的匹配结果，试试其他关键词或调整筛选条件。")
                    } actions: {
                        VStack(spacing: 8) {
                            if !session.globalSearchFilters.isEmpty {
                                Button {
                                    session.globalSearchFilters = .init()
                                } label: {
                                    Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                         ? "清除筛选" : "清除筛选，保留关键词")
                                        .frame(minHeight: 44)
                                }
                                .accessibilityIdentifier("global-search-clear-filters")
                            }
                            if session.globalSearchScope != .all {
                                Button {
                                    session.globalSearchScope = .all
                                } label: {
                                    Text("搜索全部范围").frame(minHeight: 44)
                                }
                                .accessibilityIdentifier("global-search-expand-scope")
                            }
                        }
                    }
                } else if !isSearching && !results.isEmpty {
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
                                    List(session.visibleGlobalTransactions.filter { ($0.tags ?? []).contains(tag) && session.globalSearchFilters.includes($0) }) { transaction in
                                        transactionLink(transaction)
                                    }
                                    .navigationTitle("#" + tag)
                                    .onAppear(perform: recordResultOpen)
                                    .toolbar(.visible, for: .navigationBar)
                                } label: { Label(tag, systemImage: "number") }
                            }
                        }
                    }
                    if !results.transactions.isEmpty {
                        Section("流水 · \(results.transactions.count)") {
                            ForEach(results.transactions.prefix(limit)) { transaction in transactionLink(transaction) }
                            if results.transactions.count > limit {
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
        .task { await load() }
        .refreshable { await load(forceRefresh: true) }
        .task(id: searchRequest) { await search(request: searchRequest) }
        .sheet(isPresented: $filtersPresented) {
            GlobalSearchFilterSheet(filters: session.globalSearchFilters, scope: session.globalSearchScope,
                                    accounts: session.ledger?.accounts ?? [], tags: allTags) { filters in
                session.globalSearchFilters = filters
            }
            .ledgerPrivacyProtectedSheet()
        }
        .onChange(of: session.globalSearchScope) { _, scope in
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
        loading = !session.hasCachedGlobalTransactions
        errorMessage = nil
        defer {
            if activeLoadID == loadID {
                loading = false
                activeLoadID = nil
                revision += 1
            }
        }
        do { try await session.loadGlobalTransactions(forceRefresh: forceRefresh) }
        catch is CancellationError { return }
        catch { if activeLoadID == loadID { errorMessage = "流水加载失败：" + error.localizedDescription } }
        guard activeLoadID == loadID, !Task.isCancelled else { return }
        do {
            let loadedDocuments = try await session.importDocuments()
            guard activeLoadID == loadID, !Task.isCancelled else { return }
            documents = loadedDocuments
        }
        catch is CancellationError { return }
        catch {
            if activeLoadID == loadID {
                errorMessage = [errorMessage, "导入文件加载失败：" + error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
            }
        }
    }

    private func search(request: SearchRequest) async {
        do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
        let transactions = session.visibleGlobalTransactions
        let accounts = session.ledger?.accounts ?? []
        let documents = documents
        let result = await Task.detached(priority: .userInitiated) {
            LedgerGlobalSearch.search(request.query, transactions: transactions, accounts: accounts, documents: documents, scope: request.scope, filters: request.filters)
        }.value
        guard !Task.isCancelled, request == searchRequest else { return }
        results = result
        completedSearch = request
        limit = 50
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
        Button(action: remove) {
            Label(title, systemImage: "xmark.circle.fill")
                .font(.subheadline)
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .accessibilityLabel("移除筛选：" + title)
    }

    private struct SearchRequest: Equatable, Sendable {
        let query: String
        let scope: LedgerGlobalSearchScope
        let filters: LedgerGlobalSearchFilters
        let revision: Int
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
                    Button("清除全部筛选") {
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
