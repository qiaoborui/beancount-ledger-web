import CryptoKit
import Foundation

/// One Shortcuts 「记一笔」 request after the App Intents layer has resolved its
/// parameters. Everything here is portable so the whole write decision is
/// unit-tested; `LedgerRecordIntents.swift` only adapts parameters.
struct LedgerShortcutRecordRequest: Sendable, Equatable {
    var amount: Decimal
    var payee: String?
    var narration: String?
    var categoryAccount: String?
    var fundingAccount: String?
    var date: Date
    var currency: String?
    var tags: [String]
    var idempotencyKey: String?
}

struct LedgerShortcutRecordResult: Codable, Sendable, Equatable {
    let ledgerID: UUID
    let revisionID: UUID
    let beanText: String
    let dialogSummary: String
    var duplicate: Bool = false
}

enum LedgerShortcutRecordingError: LocalizedError, Equatable {
    case notEnabled, remoteUnsupported, noLedger
    case invalidAmount, invalidCurrency(String), invalidTags(String)
    case unknownAccount(String), categoryNotCategory(String), fundingNotFunding(String)
    case closedPlaceholder(String), fundingRequired
    case busy, unavailableBeforeFirstUnlock
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notEnabled: String(localized: "请先在 Ledger 设置中为一个本机账本开启「快捷指令记账」。")
        case .remoteUnsupported: String(localized: "快捷指令记账目前仅支持本机账本。")
        case .noLedger: String(localized: "找不到开启了快捷指令记账的账本，请在 Ledger 中重新开启。")
        case .invalidAmount: String(localized: "金额必须大于 0。")
        case let .invalidCurrency(code): String(localized: "币种代码无效：\(code)")
        case let .invalidTags(message): message
        case let .unknownAccount(account): String(localized: "账本中没有可用账户：\(account)")
        case let .categoryNotCategory(account): String(localized: "分类必须是支出或收入账户：\(account)")
        case let .fundingNotFunding(account): String(localized: "付款账户必须是资产或负债账户：\(account)")
        case let .closedPlaceholder(account): String(localized: "待分类账户已关闭，请在快捷指令中选择分类：\(account)")
        case .fundingRequired: String(localized: "账本中没有可用的付款账户，请在快捷指令中选择一个。")
        case .busy: String(localized: "账本正忙，请稍后再试。")
        case .unavailableBeforeFirstUnlock: String(localized: "设备重启后需先解锁一次 iPhone 才能记账。")
        case let .validationFailed(message): String(localized: "账本校验未通过，没有写入：\(message)")
        }
    }

    /// File protection before the first unlock since boot surfaces as a plain
    /// permission error, sometimes wrapped in a Cocoa error.
    static func isPermissionDenied(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(error.code) { return true }
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionDenied(underlying) }
        return false
    }
}

/// Where Shortcuts writes. Resolved from the opt-in setting, never from the
/// active ledger, which the ledger list and server switches clear.
enum LedgerShortcutTarget: Sendable, Equatable {
    case none(remoteMode: Bool)
    case local(id: UUID, valuationCurrency: String)
}

enum LedgerShortcutEntryBuilder {
    static let placeholderExpense = "Expenses:Uncategorized"
    static let placeholderAlias = "待分类"            // fixed ledger text, not localized
    static let defaultNarration = "快捷指令记账"       // written to the ledger, fixed
    static let maxTextLength = 200
    static let maxKeyLength = 128
    static let maxAmount = Decimal(1_000_000_000)
    /// The pending classifier's placeholder prefixes that an expense may reuse.
    static let placeholderPrefixes = ["expenses:uncategorized", "expenses:待分类", "expenses:未分类",
        "expenses:待整理", "expenses:unknown", "expenses:pending", "expenses:other"]

    struct Context: Sendable {
        let accounts: [LedgerAccount]
        let commodities: [String]
        let valuationCurrency: String
        let history: [LedgerTransaction]
        let rememberedFunding: String?
        let timeZone: TimeZone
    }

    struct Built: Sendable, Equatable {
        let entry: LedgerTransactionEntry
        let openingAccounts: [LedgerAccountInput]
        let categoryAccount: String
        let categoryLabel: String
        let fundingAccount: String
        let fundingLabel: String
        let currency: String
        let isIncome: Bool
    }

    /// Validates and cleans the caller's input without reading the ledger, so
    /// a bad request fails before any file is touched.
    static func normalized(_ request: LedgerShortcutRecordRequest) throws -> LedgerShortcutRecordRequest {
        _ = try normalizedAmount(request.amount)
        var result = request
        result.payee = normalizedText(request.payee)
        result.narration = normalizedText(request.narration)
        do { result.tags = try LedgerTagRules.validating(request.tags) }
        catch { throw LedgerShortcutRecordingError.invalidTags(error.localizedDescription) }
        if let raw = request.currency?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let code = raw.uppercased()
            guard code.range(of: "^[A-Z][A-Z0-9._-]{0,23}$", options: .regularExpression) != nil else {
                throw LedgerShortcutRecordingError.invalidCurrency(raw)
            }
            result.currency = code
        } else {
            result.currency = nil
        }
        let category = request.categoryAccount?.trimmingCharacters(in: .whitespacesAndNewlines)
        result.categoryAccount = category?.isEmpty == false ? category : nil
        let funding = request.fundingAccount?.trimmingCharacters(in: .whitespacesAndNewlines)
        result.fundingAccount = funding?.isEmpty == false ? funding : nil
        result.idempotencyKey = normalizedKey(request.idempotencyKey)
        return result
    }

    static func build(_ request: LedgerShortcutRecordRequest, context: Context) throws -> Built {
        let request = try normalized(request)
        let amount = try normalizedAmount(request.amount)
        let usable = context.accounts.filter(\.active)
        let payee = request.payee ?? ""
        let note = request.narration ?? ""
        let matchText = [payee, note].filter { !$0.isEmpty }.joined(separator: " ")
        let date = dateString(request.date, timeZone: context.timeZone)

        var openingAccounts: [LedgerAccountInput] = []
        let category: String
        if let explicit = request.categoryAccount {
            guard usable.contains(where: { $0.account == explicit }) else {
                throw LedgerShortcutRecordingError.unknownAccount(explicit)
            }
            guard explicit.hasPrefix("Expenses:") || explicit.hasPrefix("Income:") else {
                throw LedgerShortcutRecordingError.categoryNotCategory(explicit)
            }
            category = explicit
        } else if let matched = BookkeepingAccountMatcher.match(role: "expense", text: matchText,
                      accounts: usable, history: context.history, payee: payee) {
            category = matched
        } else if let placeholder = placeholderPrefixes.lazy.compactMap({ prefix in
                      usable.first { $0.account.lowercased().hasPrefix(prefix) }?.account }).first {
            category = placeholder
        } else if context.accounts.contains(where: { $0.account == placeholderExpense }) {
            throw LedgerShortcutRecordingError.closedPlaceholder(placeholderExpense)
        } else {
            // Open the placeholder no later than the ledger's first account so
            // backdated entries stay valid too. Expenses carry no currency
            // constraint in the Go writer.
            let earliest = context.accounts.map(\.openDate).filter { LedgerDateRange.parse($0) != nil }.min()
            openingAccounts.append(LedgerAccountInput(date: min(date, earliest ?? date), account: placeholderExpense,
                alias: placeholderAlias, currency: ""))
            category = placeholderExpense
        }
        let isIncome = category.hasPrefix("Income:")

        func isFunding(_ account: String) -> Bool {
            account.hasPrefix("Assets:") || account.hasPrefix("Liabilities:")
        }
        let funding: String
        if let explicit = request.fundingAccount {
            guard usable.contains(where: { $0.account == explicit }) else {
                throw LedgerShortcutRecordingError.unknownAccount(explicit)
            }
            guard isFunding(explicit) else { throw LedgerShortcutRecordingError.fundingNotFunding(explicit) }
            funding = explicit
        } else if let remembered = context.rememberedFunding, isFunding(remembered),
                  usable.contains(where: { $0.account == remembered }) {
            funding = remembered
        } else if let matched = BookkeepingAccountMatcher.match(role: "funding", text: matchText,
                      accounts: usable, history: context.history, payee: payee), isFunding(matched) {
            funding = matched
        } else {
            throw LedgerShortcutRecordingError.fundingRequired
        }

        let fundingAccount = usable.first { $0.account == funding }
        let currency: String
        if let explicit = request.currency {
            currency = explicit
        } else {
            // The engine reports only an account's first open currency, not
            // its full constraint list, so it cannot tell whether the account
            // also accepts the valuation currency. Like the editor, default to
            // the valuation currency and let the validator reject it; the
            // caller can then pass 币种 explicitly.
            let valuation = context.valuationCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let primary = (fundingAccount?.currency ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !valuation.isEmpty {
                currency = valuation
            } else if !primary.isEmpty {
                currency = primary
            } else {
                currency = defaultCurrency(valuation: nil, commodities: context.commodities)
            }
        }

        var metadata: [String: LedgerMetadataValue] = ["source": .string("shortcuts")]
        if let key = request.idempotencyKey { metadata["shortcut_id"] = .string(key) }
        let positive = amount, negative = "-" + amount
        let postings: [LedgerTransactionEntryPosting] = isIncome
            ? [.init(account: funding, amount: positive, currency: currency),
               .init(account: category, amount: negative, currency: currency)]
            : [.init(account: category, amount: positive, currency: currency),
               .init(account: funding, amount: negative, currency: currency)]
        let entry = LedgerTransactionEntry(date: date, flag: "!", payee: payee,
            narration: payee.isEmpty && note.isEmpty ? defaultNarration : note,
            metadata: metadata, tags: request.tags, postings: postings)
        do { try BookkeepingDraft.manual(entry).validate() }
        catch { throw LedgerShortcutRecordingError.validationFailed(error.localizedDescription) }
        return Built(entry: entry, openingAccounts: openingAccounts,
            categoryAccount: category, categoryLabel: label(for: category, in: context.accounts),
            fundingAccount: funding, fundingLabel: label(for: funding, in: context.accounts),
            currency: currency, isIncome: isIncome)
    }

    /// Shortcuts hands numbers over as `Double`; its shortest round-trip text
    /// is what the user typed, so the ledger never sees binary noise.
    static func amount(fromShortcutValue value: Double) -> Decimal? {
        guard value.isFinite else { return nil }
        return Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX"))
    }

    static func normalizedAmount(_ value: Decimal) throws -> String {
        guard !value.isNaN, value > 0, value <= maxAmount else { throw LedgerShortcutRecordingError.invalidAmount }
        let text = ExactBookkeepingAmount.text(value)
        guard ExactBookkeepingAmount.parse(text) == value else { throw LedgerShortcutRecordingError.invalidAmount }
        return text
    }

    /// One line of ledger text: control characters become spaces, runs of
    /// spaces collapse, and long message bodies are cut rather than rejected.
    static func normalizedText(_ value: String?) -> String {
        let flattened = singleLine(value ?? "")
        guard flattened.count > maxTextLength else { return flattened }
        return String(flattened.prefix(maxTextLength - 1)) + "…"
    }

    static func normalizedKey(_ value: String?) -> String? {
        let key = singleLine(value ?? "")
        return key.isEmpty ? nil : String(key.prefix(maxKeyLength))
    }

    static func dateString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// The currency a blank entry starts in. `commodities` is sorted, so its
    /// first entry is often a ticker like AAPL; prefer the ledger's valuation
    /// currency, then a common fiat code the ledger declares, then CNY.
    static func defaultCurrency(valuation: String?, commodities: [String]) -> String {
        if let valuation, !valuation.isEmpty { return valuation }
        let fiat = ["CNY", "USD", "EUR", "HKD", "JPY", "GBP"]
        return fiat.first(where: commodities.contains) ?? "CNY"
    }

    /// `11/10 星巴克 · 咖啡 ¥35.80 ← 微信`: the arrow points at where the
    /// money went. It echoes input and account labels only, never balances.
    static func dialogSummary(_ built: Built, amount: String, timeZone: TimeZone) -> String {
        let date = built.entry.date
        let day = date.count == 10 ? String(date.dropFirst(5)).replacingOccurrences(of: "-", with: "/") : date
        let subject = built.entry.payee.isEmpty ? built.entry.narration : built.entry.payee
        let symbol = MoneyText.currencySymbol(for: built.currency)
        let arrow = built.isIncome ? "→" : "←"
        return "\(day) \(subject) · \(built.categoryLabel) \(symbol)\(displayAmount(amount)) \(arrow) \(built.fundingLabel)"
    }

    /// The entry as Beancount text, for an engine reply without `beanText`.
    static func fallbackBeanText(_ built: Built) -> String {
        let entry = built.entry
        var header = "\(entry.date) \(entry.flag ?? "*") \"\(quoted(entry.payee))\" \"\(quoted(entry.narration))\""
        for tag in entry.tags { header += " #\(tag)" }
        var lines = [header]
        for key in entry.metadata.keys.sorted() {
            if case let .string(value) = entry.metadata[key] { lines.append("  \(key): \"\(quoted(value))\"") }
        }
        for posting in entry.postings { lines.append("  \(posting.account) \(posting.amount) \(posting.currency)") }
        return lines.joined(separator: "\n")
    }

    private static func singleLine(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
                ? " " : Character(scalar)
        }
        return String(scalars).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func label(for account: String, in accounts: [LedgerAccount]) -> String {
        if account == placeholderExpense, !accounts.contains(where: { $0.account == account }) { return placeholderAlias }
        if let label = accounts.first(where: { $0.account == account })?.label, !label.isEmpty { return label }
        return String(account.split(separator: ":").last ?? Substring(account))
    }

    private static func displayAmount(_ amount: String) -> String {
        guard let dot = amount.firstIndex(of: ".") else { return amount + ".00" }
        let fraction = amount.distance(from: dot, to: amount.endIndex) - 1
        return fraction < 2 ? amount + String(repeating: "0", count: 2 - fraction) : amount
    }

    private static func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Remembers recent deduplication IDs per ledger. The file lives inside the
/// ledger directory, so deleting the ledger deletes it; keys are hashed.
struct LedgerShortcutIdempotencyStore: Sendable {
    static let retention: TimeInterval = 30 * 24 * 60 * 60
    static let maximumRecords = 200

    private struct Record: Codable {
        let keyHash: String
        let recordedAt: Date
        let result: LedgerShortcutRecordResult
    }
    private struct File: Codable {
        var version = 1
        var records: [Record]
    }

    let fileURL: URL
    private let now: @Sendable () -> Date

    init(fileURL: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
    }

    static func forLedger(root: URL, now: @escaping @Sendable () -> Date = Date.init) -> Self {
        Self(fileURL: root.appendingPathComponent(".shortcut-records.json"), now: now)
    }

    func lookup(key: String) throws -> LedgerShortcutRecordResult? {
        let hash = Self.hash(key), cutoff = now().addingTimeInterval(-Self.retention)
        return load().first { $0.keyHash == hash && $0.recordedAt >= cutoff }?.result
    }

    func remember(_ result: LedgerShortcutRecordResult, key: String) throws {
        let hash = Self.hash(key), date = now(), cutoff = date.addingTimeInterval(-Self.retention)
        var stored = result
        stored.duplicate = false
        var records = load().filter { $0.keyHash != hash && $0.recordedAt >= cutoff }
        records.append(Record(keyHash: hash, recordedAt: date, result: stored))
        records.sort { $0.recordedAt > $1.recordedAt }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(File(records: Array(records.prefix(Self.maximumRecords))))
            .write(to: fileURL, options: .ledgerProtectedUntilFirstUserAuthentication)
        // An atomic write replaces the file, so its attributes are reapplied each time.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = fileURL
        try url.setResourceValues(values)
    }

    static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A missing or corrupt file reads as empty; it only ever suppresses duplicates.
    private func load() -> [Record] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(File.self, from: data))?.records ?? []
    }
}

/// Validated headless append for Shortcuts. Every write is one workspace
/// commit (stage, engine append, validator, atomic publish), flagged `!` for
/// review. Records run one at a time, and a busy or moved ledger is retried
/// from a fresh revision.
actor LedgerShortcutRecorder {
    enum AccountRole: Sendable { case category, funding }

    private let catalog: LocalLedgerCatalog
    private let retryDelays: [Duration]
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone
    private var tail: Task<Void, Never>?
    private var repositoryCache: (descriptor: LocalLedgerDescriptor, repository: LocalLedgerRepository)?
    private var accountCache: (ledgerID: UUID, revisionID: UUID, accounts: [LedgerAccount])?

    init(catalog: LocalLedgerCatalog,
         retryDelays: [Duration] = [.milliseconds(200), .milliseconds(500), .seconds(1)],
         now: @escaping @Sendable () -> Date = Date.init,
         timeZone: TimeZone = .current) {
        self.catalog = catalog
        self.retryDelays = retryDelays
        self.now = now
        self.timeZone = timeZone
    }

    func record(_ request: LedgerShortcutRecordRequest, target: LedgerShortcutTarget,
                rememberedFunding: String?) async throws -> LedgerShortcutRecordResult {
        // Actor methods re-enter across awaits; chaining on the previous record
        // keeps two records (and their duplicate checks) strictly ordered.
        let previous = tail
        let work = Task {
            await previous?.value
            return try await self.perform(request, target: target, rememberedFunding: rememberedFunding)
        }
        tail = Task { _ = await work.result }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    func accounts(role: AccountRole, target: LedgerShortcutTarget) async throws -> [LedgerAccount] {
        guard case let .local(id, valuation) = target else { return [] }
        let repository = try await repository(for: id)
        let accounts: [LedgerAccount]
        do {
            guard let revision = try await repository.workspace.currentRevision() else { return [] }
            if let cached = accountCache, cached.ledgerID == id, cached.revisionID == revision.id {
                accounts = cached.accounts
            } else {
                accounts = try await readPage(repository, revisionID: revision.id, valuation: valuation).accounts
                accountCache = (id, revision.id, accounts)
            }
        } catch {
            throw Self.mapped(error)
        }
        let prefixes = role == .category ? ["Expenses:", "Income:"] : ["Assets:", "Liabilities:"]
        return prefixes.flatMap { prefix in
            accounts.filter { $0.active && $0.account.hasPrefix(prefix) }
                .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        }
    }

    private func perform(_ request: LedgerShortcutRecordRequest, target: LedgerShortcutTarget,
                         rememberedFunding: String?) async throws -> LedgerShortcutRecordResult {
        guard case let .local(id, valuation) = target else {
            // Before the first unlock the setting itself is unreadable; say so
            // instead of claiming the feature is off.
            do { _ = try await catalog.list() } catch where LedgerShortcutRecordingError.isPermissionDenied(error) {
                throw LedgerShortcutRecordingError.unavailableBeforeFirstUnlock
            } catch {}
            if case .none(remoteMode: true) = target { throw LedgerShortcutRecordingError.remoteUnsupported }
            throw LedgerShortcutRecordingError.notEnabled
        }
        let repository = try await repository(for: id)
        let normalized = try LedgerShortcutEntryBuilder.normalized(request)
        let store = LedgerShortcutIdempotencyStore.forLedger(root: repository.workspace.rootDirectory, now: now)
        if let key = normalized.idempotencyKey, var stored = try? store.lookup(key: key) {
            stored.duplicate = true
            return stored
        }
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (revisionID, context) = try await readContext(repository, request: normalized,
                    valuation: valuation, rememberedFunding: rememberedFunding)
                try Task.checkCancellation()
                let built = try LedgerShortcutEntryBuilder.build(normalized, context: context)
                try Task.checkCancellation()
                let (receipt, beanText) = try await repository.appendTransaction(built.entry,
                    openingAccounts: built.openingAccounts, expectedRevisionID: revisionID)
                let text = beanText?.trimmingCharacters(in: .whitespacesAndNewlines)
                let amount = try LedgerShortcutEntryBuilder.normalizedAmount(normalized.amount)
                let result = LedgerShortcutRecordResult(ledgerID: receipt.ledgerID, revisionID: receipt.revisionID,
                    beanText: text?.isEmpty == false ? text! : LedgerShortcutEntryBuilder.fallbackBeanText(built),
                    dialogSummary: LedgerShortcutEntryBuilder.dialogSummary(built, amount: amount, timeZone: timeZone))
                if let key = normalized.idempotencyKey { try? store.remember(result, key: key) }
                return result
            } catch let error as LocalLedgerWorkspace.WorkspaceError
                        where error == .transactionInProgress || error == .staleRevision {
                guard attempt < retryDelays.count else { throw LedgerShortcutRecordingError.busy }
                try await Task.sleep(for: retryDelays[attempt])
                attempt += 1
            } catch {
                throw Self.mapped(error)
            }
        }
    }

    private func readContext(_ repository: LocalLedgerRepository, request: LedgerShortcutRecordRequest,
                             valuation: String, rememberedFunding: String?) async throws
        -> (UUID, LedgerShortcutEntryBuilder.Context) {
        guard let revision = try await repository.workspace.currentRevision() else {
            throw LedgerShortcutRecordingError.validationFailed(String(localized: "账本尚未初始化"))
        }
        let ledger = try await readPage(repository, revisionID: revision.id, valuation: valuation)
        accountCache = (repository.descriptor.id, revision.id, ledger.accounts)
        var history: [LedgerTransaction] = []
        if let payee = request.payee, !payee.isEmpty, request.categoryAccount == nil {
            // Two pages bound the read; older payee history falls back to keywords.
            var cursor: String?
            for _ in 0..<2 {
                try Task.checkCancellation()
                let page = try await repository.classificationHistoryPage(cursor: cursor)
                history += page.transactions.filter { $0.payee == payee }
                guard let next = page.nextCursor else { break }
                cursor = next
            }
        }
        return (revision.id, .init(accounts: ledger.accounts, commodities: ledger.commodities,
            valuationCurrency: valuation, history: history, rememberedFunding: rememberedFunding, timeZone: timeZone))
    }

    /// The widget publisher's bounded one-row read; it shares that cache.
    private func readPage(_ repository: LocalLedgerRepository, revisionID: UUID,
                          valuation: String) async throws -> LedgerBootstrap {
        let date = now()
        let month = LedgerDateRange.current(.month, now: date)
        return try await repository.bootstrapPage(start: month.start, end: month.queryEndExclusive,
            today: LedgerDateRange.today(now: date), valuationCurrency: valuation, limit: 1,
            expectedRevisionID: revisionID).bootstrap
    }

    private func repository(for id: UUID) async throws -> LocalLedgerRepository {
        let descriptors: [LocalLedgerDescriptor]
        do { descriptors = try await catalog.list() } catch { throw Self.mapped(error, fallback: .noLedger) }
        guard let descriptor = descriptors.first(where: { $0.id == id }) else {
            throw LedgerShortcutRecordingError.noLedger
        }
        if let cached = repositoryCache, cached.descriptor == descriptor { return cached.repository }
        let repository = catalog.repository(for: descriptor)
        repositoryCache = (descriptor, repository)
        accountCache = nil
        return repository
    }

    private static func mapped(_ error: any Error,
                               fallback: LedgerShortcutRecordingError? = nil) -> any Error {
        if error is LedgerShortcutRecordingError || error is CancellationError { return error }
        if LedgerShortcutRecordingError.isPermissionDenied(error) {
            return LedgerShortcutRecordingError.unavailableBeforeFirstUnlock
        }
        return fallback ?? LedgerShortcutRecordingError.validationFailed(error.localizedDescription)
    }
}
