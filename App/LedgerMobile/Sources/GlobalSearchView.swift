import SwiftUI

struct GlobalSearchPage: View {
    @State private var query = ""
    var body: some View {
        GlobalSearchView(query: $query)
            .searchable(text: $query, prompt: "搜索整个账本")
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
    @State private var refreshing = false
    @State private var errorMessage: String?
    @State private var revision = 0
    @State private var limit = 50

    var body: some View {
        List {
            if loading && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ProgressView("正在搜索…").accessibilityIdentifier("global-search-loading")
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.secondary)
                    Button("重新加载") { Task { await load() } }
                }
            }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    Label("搜索整个账本", systemImage: "magnifyingglass")
                        .font(.title2.weight(.semibold))
                    Text("查找流水、账户、标签、导入文件和功能。支持商户、备注、金额、日期及账户名称，范围覆盖全部日期。")
                        .foregroundStyle(.secondary)
                }
            } else if results.isEmpty && !loading {
                ContentUnavailableView.search(text: query)
            } else {
                if !results.destinations.isEmpty {
                    Section("功能") {
                        ForEach(results.destinations) { destination in
                            NavigationLink { LedgerDestinationView(destination: destination).toolbar(.visible, for: .navigationBar) } label: {
                                Label(destination.title, systemImage: destination.systemImage)
                            }
                        }
                    }
                }
                if !results.accounts.isEmpty {
                    Section("账户 · \(results.accounts.count)") {
                        ForEach(results.accounts, id: \.account) { account in
                            NavigationLink { AccountDetailView(account: account.account, currency: account.currency).toolbar(.visible, for: .navigationBar) } label: {
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
                                List(session.visibleGlobalTransactions.filter { ($0.tags ?? []).contains(tag) }) { transaction in
                                    transactionLink(transaction)
                                }
                                .navigationTitle("#" + tag)
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
                                    .toolbar(.visible, for: .navigationBar)
                            } label: { Label(document.name ?? "账单归档", systemImage: "doc.text") }
                        }
                    }
                }
            }
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(usesNativeSearchTab ? .hidden : .automatic, for: .navigationBar)
        .scrollContentBackground(.hidden)
        .background(LedgerPalette.canvas)
        .scrollDismissesKeyboard(.interactively)
        .task { await load() }
        .refreshable { await load(forceRefresh: true) }
        .task(id: SearchRequest(query: query, revision: revision)) { await search() }
        .onChange(of: session.globalTransactions) { _, _ in revision += 1 }
        .onChange(of: session.transactionMutationStates) { _, _ in revision += 1 }
    }

    private func transactionLink(_ transaction: LedgerTransaction) -> some View {
        NavigationLink { TransactionDetailView(transaction: transaction).toolbar(.visible, for: .navigationBar) } label: {
            TransactionRow(transaction: transaction, accountLabels: TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? []))
        }
        .accessibilityIdentifier("transaction-row-\(transaction.source.line)")
    }

    private func load(forceRefresh: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        loading = !session.hasCachedGlobalTransactions
        errorMessage = nil
        defer { loading = false; refreshing = false; revision += 1 }
        do { try await session.loadGlobalTransactions(forceRefresh: forceRefresh) }
        catch is CancellationError { return }
        catch { errorMessage = "流水加载失败：" + error.localizedDescription }
        do { documents = try await session.importDocuments() }
        catch is CancellationError { return }
        catch { errorMessage = [errorMessage, "导入文件加载失败：" + error.localizedDescription].compactMap { $0 }.joined(separator: "\n") }
    }

    private func search() async {
        do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
        let query = query
        let transactions = session.visibleGlobalTransactions
        let accounts = session.ledger?.accounts ?? []
        let documents = documents
        let result = await Task.detached(priority: .userInitiated) {
            LedgerGlobalSearch.search(query, transactions: transactions, accounts: accounts, documents: documents)
        }.value
        guard !Task.isCancelled else { return }
        results = result
        limit = 50
    }

    private struct SearchRequest: Equatable { let query: String; let revision: Int }
}
