import Foundation

/// A native-page consumer, not a repository or a selection model. The adapter must
/// pin the native revision and request *unfiltered* candidates for the entire date
/// range. Only Swift applies LedgerTransactionFilter. Cancellation and unlock
/// orchestration belong to that adapter. The bridge guarantees <= 1 MiB responses;
/// this reducer neither serializes nor retains pages to measure their wire size.
struct LocalTransactionScan: Sendable {
    struct Limits: Equatable, Sendable {
        var maxVisibleCount = 1_000
        var maxVisibleBytes = 4 * 1_024 * 1_024
        var maxDays = 4_096
        var maxAccounts = 10_000
        var maxTags = 10_000
        var maxPages = 10_000
        var maxStateBytes = 4 * 1_024 * 1_024
    }

    enum Capacity: Equatable, Sendable {
        case pageRows, visibleBytes, days, accounts, tags, pages, stateBytes
    }

    enum ScanError: Error, Equatable, Sendable {
        case invalidConfiguration
        case alreadyCompleted
        case failed
        case locked
        case revisionMismatch
        case unexpectedCursor
        case repeatedCursor
        case emptyCursor
        case capacityExceeded(Capacity)
        case arithmeticOverflow
    }

    struct Day: Equatable, Sendable {
        let date: String
        let matchedCount: Int
        /// Signed posting sum, with no FX conversion (same semantics as TransactionsView).
        let signedExpense: Int
        /// Clamped once, after the entire scan, not per transaction or page.
        var expense: Int { max(0, signedExpense) }
    }

    struct Result: Sendable {
        let revision: String
        let fullRangeCount: Int
        let matchedCount: Int
        /// An ordered prefix only; this is NOT an all-history selection universe.
        let visibleTransactions: [LedgerTransaction]
        let visibleAccountedBytes: Int
        let stateAccountedBytes: Int
        let availableAccounts: [String]
        let availableTags: [String]
        /// All matched days, including days outside the visible prefix, newest first.
        let days: [Day]
        var hasMoreMatches: Bool { matchedCount > visibleTransactions.count }
    }

    private struct DayAccumulator: Sendable {
        var count = 0
        var signedExpense = 0
    }

    private struct State: Sendable {
        var fullRangeCount = 0
        var matchedCount = 0
        var pageCount = 0
        var visible: [LedgerTransaction] = []
        var visibleBytes = 0
        var visiblePrefixClosed = false
        var bytes = 0
        var accounts: Set<String> = []
        var tags: Set<String> = []
        var days: [String: DayAccumulator] = [:]
        // Opaque cursors cannot be compared for monotonicity. Remember them within
        // explicit page/state limits to reject A -> B -> A, not just A -> A.
        var cursors: Set<String> = []
    }

    private let expectedRevision: String
    private let filter: LedgerTransactionFilter
    private let limits: Limits
    private var state = State()
    private var hasFailed = false
    private(set) var isComplete = false
    /// Raw continuation, regardless of how many rows matched. nil initially and at EOF.
    private(set) var nextCursor: String?

    // Diagnostics expose bounded storage, never partial financial totals.
    var retainedVisibleCount: Int { state.visible.count }
    var visibleAccountedBytes: Int { state.visibleBytes }
    var stateAccountedBytes: Int { state.bytes }

    init(expectedRevision: String, filter: LedgerTransactionFilter = .init(), limits: Limits = .init()) throws {
        guard !expectedRevision.isEmpty,
              (0...1_000).contains(limits.maxVisibleCount),
              limits.maxVisibleBytes >= 0, limits.maxStateBytes >= 0,
              limits.maxDays >= 0, limits.maxAccounts >= 0, limits.maxTags >= 0,
              limits.maxPages > 0 else { throw ScanError.invalidConfiguration }
        self.expectedRevision = expectedRevision
        self.filter = filter
        self.limits = limits
        // Account also for retained configuration, not only growing aggregates.
        var bytes = try Self.add(512, Self.stringBytes(expectedRevision))
        bytes = try Self.add(bytes, Self.stringBytes(filter.query))
        if let account = filter.account { bytes = try Self.add(bytes, Self.stringBytes(account)) }
        for tag in filter.tags { bytes = try Self.add(bytes, Self.stringBytes(tag)) }
        guard bytes <= limits.maxStateBytes else { throw ScanError.capacityExceeded(.stateBytes) }
        state.bytes = bytes
    }

    /// Pass the cursor used to obtain this page (nil for the first request).
    /// Empty pages with continuations are not EOF. Only nextCursor == nil finishes.
    /// Any error poisons the scan: restart rather than publishing partial totals.
    /// A completed scan also rejects all subsequent pages.
    mutating func consume(_ page: LedgerTransactionPage, requestedCursor: String?) throws -> Result? {
        guard !isComplete else { throw ScanError.alreadyCompleted }
        guard !hasFailed else { throw ScanError.failed }
        do {
            return try consumeValidated(page, requestedCursor: requestedCursor)
        } catch {
            hasFailed = true
            state = State()
            nextCursor = nil
            throw error
        }
    }

    private mutating func consumeValidated(_ page: LedgerTransactionPage, requestedCursor: String?) throws -> Result? {
        guard page.sensitiveUnlocked else { throw ScanError.locked }
        guard page.revision == expectedRevision else { throw ScanError.revisionMismatch }
        guard requestedCursor == nextCursor else { throw ScanError.unexpectedCursor }
        guard page.transactions.count <= 500 else { throw ScanError.capacityExceeded(.pageRows) }
        guard state.pageCount < limits.maxPages else { throw ScanError.capacityExceeded(.pages) }
        state.pageCount = try Self.add(state.pageCount, 1)
        if let cursor = page.nextCursor {
            guard !cursor.isEmpty else { throw ScanError.emptyCursor }
            guard !state.cursors.contains(cursor) else { throw ScanError.repeatedCursor }
            try chargeState(Self.stringBytes(cursor))
            state.cursors.insert(cursor)
        }

        for transaction in page.transactions {
            // matches() constructs TransactionPresentation even for kind == .all.
            // Validate all unsafe integer operations BEFORE calling that helper.
            let signedExpense = try Self.checkedExpense(transaction)
            state.fullRangeCount = try Self.add(state.fullRangeCount, 1)
            for posting in transaction.postings {
                if !state.accounts.contains(posting.account) {
                    guard state.accounts.count < limits.maxAccounts else { throw ScanError.capacityExceeded(.accounts) }
                    try chargeState(Self.stringBytes(posting.account))
                    state.accounts.insert(posting.account)
                }
            }
            for tag in transaction.tags ?? [] where !tag.isEmpty {
                if !state.tags.contains(tag) {
                    guard state.tags.count < limits.maxTags else { throw ScanError.capacityExceeded(.tags) }
                    try chargeState(Self.stringBytes(tag))
                    state.tags.insert(tag)
                }
            }
            // Reuse canonical Swift equality, prefix, lowercasing and substring
            // semantics; native/Go Unicode approximations are not authoritative.
            guard filter.matches(transaction) else { continue }
            state.matchedCount = try Self.add(state.matchedCount, 1)
            if state.days[transaction.date] == nil {
                guard state.days.count < limits.maxDays else { throw ScanError.capacityExceeded(.days) }
                try chargeState(Self.add(64, Self.stringBytes(transaction.date)))
            }
            var day = state.days[transaction.date] ?? DayAccumulator()
            day.count = try Self.add(day.count, 1)
            day.signedExpense = try Self.add(day.signedExpense, signedExpense)
            state.days[transaction.date] = day

            if !state.visiblePrefixClosed, state.visible.count < limits.maxVisibleCount {
                let rowBytes = try Self.transactionBytes(transaction)
                if rowBytes <= limits.maxVisibleBytes - state.visibleBytes {
                    state.visible.append(transaction)
                    state.visibleBytes = try Self.add(state.visibleBytes, rowBytes)
                } else {
                    // Keep an ordered prefix: never retain smaller rows after this one,
                    // even on later pages. Counts, days and facets still scan to EOF.
                    // If the first row cannot fit, an empty visible result is valid
                    // with hasMoreMatches == true; the caller owns later pagination.
                    state.visiblePrefixClosed = true
                }
            }
        }
        nextCursor = page.nextCursor
        guard nextCursor == nil else { return nil }
        let result = Result(
            revision: expectedRevision,
            fullRangeCount: state.fullRangeCount,
            matchedCount: state.matchedCount,
            visibleTransactions: state.visible,
            visibleAccountedBytes: state.visibleBytes,
            stateAccountedBytes: state.bytes,
            availableAccounts: state.accounts.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            availableTags: state.tags.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            days: state.days.map { Day(date: $0.key, matchedCount: $0.value.count, signedExpense: $0.value.signedExpense) }
                .sorted { $0.date > $1.date }
        )
        isComplete = true
        state = State() // The final result, not the reducer, now owns the visible prefix.
        return result
    }

    private mutating func chargeState(_ bytes: Int) throws {
        let total = try Self.add(state.bytes, bytes)
        guard total <= limits.maxStateBytes else { throw ScanError.capacityExceeded(.stateBytes) }
        state.bytes = total
    }

    private static func add(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw ScanError.arithmeticOverflow }
        return value
    }

    private static func checkedExpense(_ transaction: LedgerTransaction) throws -> Int {
        // Mirror TransactionPresentation's early returns: only validate arithmetic
        // that its selected branch reaches, including intermediate sum overflows.
        var expense = 0
        for posting in transaction.postings where posting.account.hasPrefix("Expenses:") {
            expense = try add(expense, posting.amount)
        }
        if expense != 0 {
            guard expense != Int.min else { throw ScanError.arithmeticOverflow }
            return expense
        }

        var income = 0
        for posting in transaction.postings where posting.account.hasPrefix("Income:") {
            income = try add(income, posting.amount)
        }
        if income != 0 {
            guard income != Int.min else { throw ScanError.arithmeticOverflow }
            return 0
        }

        // Only the transfer branch takes abs() of individual posting amounts.
        guard transaction.postings.allSatisfy({ $0.amount != Int.min }) else {
            throw ScanError.arithmeticOverflow
        }
        return 0
    }

    // Deterministic accounting, NOT a claim about allocator RSS. Charges include
    // fixed container/element allowances plus every retained UTF-8 payload, including
    // optional metadata and editable entries. No JSON copies or cached page bodies.
    // The independent row, group, page and byte caps bound each growing dimension.
    private static func stringBytes(_ value: String) throws -> Int {
        try add(128, value.utf8.count)
    }

    private static func transactionBytes(_ transaction: LedgerTransaction) throws -> Int {
        var bytes = 512
        func string(_ value: String?) throws {
            if let value { bytes = try add(bytes, stringBytes(value)) }
        }
        func strings(_ values: [String]) throws {
            bytes = try add(bytes, 64)
            for value in values { try string(value) }
        }
        func metadata(_ values: [String: LedgerMetadataValue]) throws {
            bytes = try add(bytes, 64)
            for (key, value) in values {
                try string(key)
                bytes = try add(bytes, 128)
                if case let .string(text) = value { try string(text) }
            }
        }
        try string(transaction.date)
        try string(transaction.payee)
        try string(transaction.narration)
        try string(transaction.source.file)
        try string(transaction.source.hash)
        try string(transaction.source.gitSHA)
        if let tags = transaction.tags { try strings(tags) }
        if let values = transaction.metadata { try metadata(values) }
        bytes = try add(bytes, 64)
        for posting in transaction.postings {
            bytes = try add(bytes, 128)
            try string(posting.account)
            try string(posting.currency)
        }
        if let entry = transaction.editableEntry {
            bytes = try add(bytes, 512)
            for value in [entry.kind, entry.date, entry.flag, entry.payee, entry.narration, entry.currency] {
                try string(value)
            }
            try metadata(entry.metadata)
            try strings(entry.tags)
            try strings(entry.links)
            try strings(entry.questions)
            bytes = try add(bytes, 64)
            for posting in entry.postings {
                bytes = try add(bytes, 256)
                for value in [posting.account, posting.flag, posting.amount, posting.currency,
                              posting.costKind, posting.costAmount, posting.costCurrency, posting.costSpec,
                              posting.priceKind, posting.priceAmount, posting.priceCurrency] {
                    try string(value)
                }
            }
        }
        return bytes
    }
}
