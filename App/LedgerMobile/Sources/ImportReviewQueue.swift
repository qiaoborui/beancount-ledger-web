import Foundation

/// The four working sets of the import review page. Entries the person still
/// has to decide come first; the rest are ready, left out, or everything.
enum ImportReviewFilter: String, CaseIterable, Identifiable, Sendable {
    case pending
    case ready
    case unchecked
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pending: String(localized: "待确认")
        case .ready: String(localized: "已就绪")
        case .unchecked: String(localized: "未勾选")
        case .all: String(localized: "全部")
        }
    }
}

/// Splits a drafted import into the review page's working sets, in the
/// preview's own order. An included entry needs confirmation when the
/// classifier left a field for the person, or when either side of the
/// transaction still has no real account.
struct ImportReviewQueue: Equatable, Sendable {
    private(set) var pendingIDs: [String] = []
    private(set) var readyIDs: [String] = []
    private(set) var uncheckedIDs: [String] = []
    private(set) var allIDs: [String] = []

    init(entries: [LedgerImportEntry], included: Set<String>, needsReview: Set<String>) {
        for entry in entries {
            allIDs.append(entry.id)
            if !included.contains(entry.id) {
                uncheckedIDs.append(entry.id)
            } else if needsReview.contains(entry.id) || Self.needsAccount(entry) {
                pendingIDs.append(entry.id)
            } else {
                readyIDs.append(entry.id)
            }
        }
    }

    static func isMissingAccount(_ account: String) -> Bool {
        account.isEmpty || account.lowercased().contains("unknown")
    }

    static func needsAccount(_ entry: LedgerImportEntry) -> Bool {
        isMissingAccount(entry.categoryAccount) || isMissingAccount(entry.fundingAccount)
    }

    func ids(for filter: ImportReviewFilter) -> [String] {
        switch filter {
        case .pending: pendingIDs
        case .ready: readyIDs
        case .unchecked: uncheckedIDs
        case .all: allIDs
        }
    }

    func count(for filter: ImportReviewFilter) -> Int { ids(for: filter).count }

    /// Opens on the entries that need the person; with none left, on everything.
    var defaultFilter: ImportReviewFilter { pendingIDs.isEmpty ? .all : .pending }

    /// The entry `offset` steps away from `id` within `filter`, for the
    /// editor's previous / next controls. Nil past either end.
    func neighbor(of id: String, in filter: ImportReviewFilter, offset: Int) -> String? {
        let ids = ids(for: filter)
        guard let index = ids.firstIndex(of: id) else { return nil }
        let target = index + offset
        return ids.indices.contains(target) ? ids[target] : nil
    }

    /// 1-based position of `id` within `filter`, with that set's size.
    func position(of id: String, in filter: ImportReviewFilter) -> (index: Int, count: Int)? {
        let ids = ids(for: filter)
        guard let index = ids.firstIndex(of: id) else { return nil }
        return (index + 1, ids.count)
    }
}

enum ImportBulkTagMode: Sendable {
    case add
    case remove
}

enum ImportBulkEdit {
    /// Adds or removes the tags in `rawTags` on the entries named by `ids`;
    /// every other entry is returned unchanged.
    static func applyingTags(_ rawTags: String, mode: ImportBulkTagMode,
                             to entries: [LedgerImportEntry], ids: Set<String>) throws -> [LedgerImportEntry] {
        let tags = try LedgerTagRules.parse(rawTags)
        let changed = Set(tags)
        return try entries.map { entry in
            guard ids.contains(entry.id) else { return entry }
            let existing = LedgerTagRules.normalized(entry.tags ?? [])
            switch mode {
            case .add: return entry.applyingTags(try LedgerTagRules.validating(existing + tags))
            case .remove: return entry.applyingTags(existing.filter { !changed.contains($0) })
            }
        }
    }
}
