import Foundation

/// A local selection is a sequence of decisions against one committed ledger
/// generation. Filter rules cover the full range without storing every ID;
/// explicit row decisions override older rules. Callers must discard this
/// value when its workspace revision or date range changes.
struct LocalTransactionSelection: Equatable, Sendable {
    private struct FilterRule: Equatable, Sendable {
        let sequence: Int
        let filter: LedgerTransactionFilter
        let selected: Bool
    }
    private struct RowRule: Equatable, Sendable {
        let sequence: Int
        let selected: Bool
    }

    let revisionID: UUID
    let start: String
    let end: String
    private var nextSequence = 0
    private var filterRules: [FilterRule] = []
    private var rowRules: [String: RowRule] = [:]
    var hasDecisions: Bool { !filterRules.isEmpty || !rowRules.isEmpty }
    var explicitSelectedCount: Int? {
        guard filterRules.isEmpty else { return nil }
        return rowRules.values.reduce(into: 0) { if $1.selected { $0 += 1 } }
    }

    init(revisionID: UUID, start: String, end: String) {
        self.revisionID = revisionID
        self.start = start
        self.end = end
    }

    mutating func setAll(matching filter: LedgerTransactionFilter, selected: Bool) {
        nextSequence += 1
        filterRules.append(.init(sequence: nextSequence, filter: filter, selected: selected))
    }

    mutating func set(_ row: LedgerTransaction, selected: Bool) {
        guard row.date >= start, row.date < end else { return }
        nextSequence += 1
        rowRules[row.id] = .init(sequence: nextSequence, selected: selected)
    }

    mutating func toggle(_ row: LedgerTransaction) {
        set(row, selected: !contains(row))
    }

    func contains(_ row: LedgerTransaction) -> Bool {
        let explicit = rowRules[row.id]
        for rule in filterRules.reversed() {
            if let explicit, rule.sequence < explicit.sequence { break }
            if rule.filter.matches(row) { return rule.selected }
        }
        return explicit?.selected ?? false
    }
}

/// Computes complete selection facts without retaining selected transaction rows.
/// Legacy caller-owned ID sets remain supported; filter-rule selection does not
/// collect IDs for a full-range select-all operation.
/// Raw candidates must cover the entire range. Filters narrow sharing/preflight,
/// not remembered selection membership or the existing full-range tag scope.
struct LocalTransactionSelectionScan {
    enum SelectionError: Error, Equatable { case sourceBytes, invalidBudget }
    enum TagPreparationError: LocalizedError, Equatable {
        case noEligibleSelection, tooMany, incomplete
        var errorDescription: String? {
            switch self {
            case .noEligibleSelection: return "所选交易缺少并发校验信息，暂无法添加标签。"
            case .tooMany: return "一次最多为 \(TransactionTagSelectionRules.maximumCount) 笔交易添加标签。"
            case .incomplete: return "交易选择信息不完整，请重新读取后再试。"
            }
        }
    }
    struct Result: Sendable {
        let rangeCount: Int
        let matchingCount: Int
        let selectedCount: Int
        let selectedMatchingCount: Int
        let selectedEligibleCount: Int
        let selectedMatchingEligibleCount: Int
        /// Complete only when selectedEligibleCount <= existing tag action limit.
        /// On overflow returns nil, never a silently truncated batch.
        let tagSources: [TransactionSource]?
        /// Preserve the filtered preflight and full-range application scope.
        /// Reject a hidden-selection overflow before hydration, never take a prefix.
        func sourcesForTagPreparation() throws -> [TransactionSource] {
            guard selectedMatchingEligibleCount > 0 else { throw TagPreparationError.noEligibleSelection }
            guard selectedEligibleCount <= TransactionTagSelectionRules.maximumCount else {
                throw TagPreparationError.tooMany
            }
            guard let tagSources, !tagSources.isEmpty, tagSources.count == selectedEligibleCount else {
                throw TagPreparationError.incomplete
            }
            return tagSources
        }
        var allMatchingSelected: Bool { matchingCount > 0 && selectedMatchingCount == matchingCount }
    }
    private var validation: LocalTransactionScan
    private let filter: LedgerTransactionFilter
    private enum Membership {
        case ids(Set<String>)
        case selection(LocalTransactionSelection)

        func contains(_ row: LedgerTransaction) -> Bool {
            switch self {
            case .ids(let ids): ids.contains(row.id)
            case .selection(let selection): selection.contains(row)
            }
        }
    }
    private let membership: Membership
    private let blockedIDs: Set<String>
    private var selectedCount = 0
    private var selectedMatchingCount = 0
    private var selectedEligibleCount = 0
    private var selectedMatchingEligibleCount = 0
    private var sources: [TransactionSource]? = []
    private var failed = false
    private let maximumSourceBytes: Int
    private(set) var retainedSourceBytes = 0

    init(revision: String, filter: LedgerTransactionFilter, selectedIDs: Set<String>, blockedIDs: Set<String> = [], maximumSourceBytes: Int = 256 * 1_024) throws {
        guard (0...256 * 1_024).contains(maximumSourceBytes) else { throw SelectionError.invalidBudget }
        self.maximumSourceBytes = maximumSourceBytes
        self.validation = try LocalTransactionScan(expectedRevision: revision, filter: filter,
            limits: .init(maxVisibleCount: 0))
        self.filter = filter
        self.membership = .ids(selectedIDs)
        self.blockedIDs = blockedIDs
    }

    init(revision: String, filter: LedgerTransactionFilter, selection: LocalTransactionSelection,
         blockedIDs: Set<String> = [], maximumSourceBytes: Int = 256 * 1_024) throws {
        guard (0...256 * 1_024).contains(maximumSourceBytes) else { throw SelectionError.invalidBudget }
        self.maximumSourceBytes = maximumSourceBytes
        self.validation = try LocalTransactionScan(expectedRevision: revision, filter: filter,
            limits: .init(maxVisibleCount: 0))
        self.filter = filter
        self.membership = .selection(selection)
        self.blockedIDs = blockedIDs
    }

    mutating func consume(_ page: LedgerTransactionPage, requestedCursor: String?) throws -> Result? {
        guard !failed else { throw LocalTransactionScan.ScanError.failed }
        do {
            // Validate the whole page (including arithmetic and source revision)
            // before evaluating matching or retaining any selection facts.
            let summary = try validation.consume(page, requestedCursor: requestedCursor)
            for row in page.transactions where membership.contains(row) {
                selectedCount = try LocalTransactionScan.add(selectedCount, 1)
                let matches = filter.matches(row)
                if matches { selectedMatchingCount = try LocalTransactionScan.add(selectedMatchingCount, 1) }
                if row.source.hash?.isEmpty == false && !blockedIDs.contains(row.id) {
                    selectedEligibleCount = try LocalTransactionScan.add(selectedEligibleCount, 1)
                    if matches { selectedMatchingEligibleCount = try LocalTransactionScan.add(selectedMatchingEligibleCount, 1) }
                    if selectedEligibleCount <= TransactionTagSelectionRules.maximumCount {
                        let total = try LocalTransactionScan.add(retainedSourceBytes, Self.sourceBytes(row.source))
                        guard total <= maximumSourceBytes else { throw SelectionError.sourceBytes }
                        sources?.append(row.source)
                        retainedSourceBytes = total
                    } else { sources = nil; retainedSourceBytes = 0 }
                }
            }
            guard let summary else { return nil }
            return Result(rangeCount: summary.fullRangeCount, matchingCount: summary.matchedCount,
                selectedCount: selectedCount, selectedMatchingCount: selectedMatchingCount,
                selectedEligibleCount: selectedEligibleCount, selectedMatchingEligibleCount: selectedMatchingEligibleCount,
                tagSources: sources)
        } catch {
            failed = true
            sources = nil
            retainedSourceBytes = 0
            throw error
        }
    }
    static func sourceBytes(_ source: TransactionSource) throws -> Int {
        var bytes = try LocalTransactionScan.add(128, LocalTransactionScan.stringBytes(source.file))
        for value in [source.hash, source.gitSHA].compactMap({ $0 }) {
            bytes = try LocalTransactionScan.add(bytes, LocalTransactionScan.stringBytes(value))
        }
        return bytes
    }

}
