import Foundation

/// Computes complete selection facts without retaining selected transaction rows.
/// The existing ID selection is caller-owned (and can itself be large); this is
/// not a constant-memory selection representation or an all-history ID collector.
/// Raw candidates must cover the entire range. Filters narrow sharing/preflight,
/// not remembered selection membership or the existing full-range tag scope.
struct LocalTransactionSelectionScan {
    enum SelectionError: Error, Equatable { case sourceBytes, invalidBudget }
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
        var allMatchingSelected: Bool { matchingCount > 0 && selectedMatchingCount == matchingCount }
    }
    private var validation: LocalTransactionScan
    private let filter: LedgerTransactionFilter
    private let selectedIDs: Set<String>
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
        self.selectedIDs = selectedIDs
        self.blockedIDs = blockedIDs
    }

    mutating func consume(_ page: LedgerTransactionPage, requestedCursor: String?) throws -> Result? {
        guard !failed else { throw LocalTransactionScan.ScanError.failed }
        do {
            // Validate the whole page (including arithmetic and source revision)
            // before evaluating matching or retaining any selection facts.
            let summary = try validation.consume(page, requestedCursor: requestedCursor)
            for row in page.transactions where selectedIDs.contains(row.id) {
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
