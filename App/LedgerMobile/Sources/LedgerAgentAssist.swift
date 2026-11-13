import Foundation
#if canImport(LedgerCore)
import LedgerCore
#endif

/// The recap at the bottom of a conversation: a few lines on what was asked,
/// found and changed, written by the model when the user comes back.
struct LedgerAgentRecap: Codable, Equatable, Sendable {
    let text: String
    /// How many messages the recap covers; a later message makes it stale.
    let messageCount: Int
    let createdAt: Date

    /// Answers a conversation needs before a recap says more than the
    /// conversation itself.
    static let minimumAnswers = 2

    /// The recap's points, without their bullets.
    var points: [String] {
        text.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "^[-*•]\\s*", with: "", options: .regularExpression)
        }.filter { !$0.isEmpty }
    }
}

/// The wire request of `SuggestJSON` and `RecapJSON`. The native decoder
/// rejects unknown fields, so this lists exactly what the Go side accepts.
struct LedgerAgentAssistRequest: Encodable, Sendable {
    let version = 1
    /// The committed generation starter suggestions read; nil otherwise.
    var workspaceRoot: String? = nil
    var runtimeRoot: String? = nil
    var entrypoint: String? = nil
    var modelHandle: String? = nil
    var sensitiveUnlocked = true
    let provider: String
    let model: String
    let apiKey: String
    var custom: LedgerAgentModelChoice.CustomEndpoint? = nil
    var memoryPath: String? = nil
    var history: [LedgerAgentTurnRequest.HistoryEntry]? = nil
    var recent: [String]? = nil
    var count: Int? = nil
}

struct LedgerAgentAssistResponse: Decodable, Sendable {
    let ok: Bool
    var suggestions: [String]? = nil
    var recap: String? = nil
    var title: String? = nil
    var error: String? = nil
}

/// The blocking JSON boundary to the native assist calls. Tests substitute it.
struct LedgerAgentAssistant: Sendable {
    var suggest: @Sendable (Data) async throws -> Data
    var recap: @Sendable (Data) async throws -> Data
    /// Names one conversation from its first two exchanges.
    var title: @Sendable (Data) async throws -> Data

    static let native = LedgerAgentAssistant(suggest: { request in
        #if canImport(LedgerCore)
        return try await LedgerAgentRunner.withDeadline(100, onTimeout: {}) {
            Data(MobileagentSuggestJSON(String(decoding: request, as: UTF8.self)).utf8)
        }
        #else
        throw LocalLedgerError.runtimeUnavailable
        #endif
    }, recap: { request in
        #if canImport(LedgerCore)
        return try await LedgerAgentRunner.withDeadline(100, onTimeout: {}) {
            Data(MobileagentRecapJSON(String(decoding: request, as: UTF8.self)).utf8)
        }
        #else
        throw LocalLedgerError.runtimeUnavailable
        #endif
    }, title: { request in
        #if canImport(LedgerCore)
        return try await LedgerAgentRunner.withDeadline(100, onTimeout: {}) {
            Data(MobileagentTitleJSON(String(decoding: request, as: UTF8.self)).utf8)
        }
        #else
        throw LocalLedgerError.runtimeUnavailable
        #endif
    })

    /// Decodes a response, turning a failure into an error.
    static func decode(_ data: Data) throws -> LedgerAgentAssistResponse {
        let response = try JSONDecoder().decode(LedgerAgentAssistResponse.self, from: data)
        guard response.ok else {
            throw LedgerAgentError.classify(response.error ?? String(localized: "模型没有给出结果"))
        }
        return response
    }
}

/// The starter suggestions of one ledger, as saved in its runtime directory.
/// They are written once a day, and again when the ledger or the memory
/// changes, so opening the page rarely costs a request.
struct LedgerAgentStarterCache: Codable, Equatable, Sendable {
    var version = 1
    let day: String
    let revisionID: String?
    let memoryDigest: Int
    let suggestions: [String]
    let createdAt: Date

    func isFresh(day: String, revisionID: String?, memoryDigest: Int, now: Date = Date()) -> Bool {
        guard self.day == day, !suggestions.isEmpty else { return false }
        if self.revisionID == revisionID, self.memoryDigest == memoryDigest { return true }
        // A ledger that keeps changing does not ask more than hourly.
        return now.timeIntervalSince(createdAt) < 60 * 60
    }

    static func day(of date: Date = Date()) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// A stable digest of memory.md; Swift's `hashValue` changes per launch.
    static func digest(_ text: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return Int(truncatingIfNeeded: hash)
    }
}

/// The 试试 list of the empty conversation. It shows the saved suggestions at
/// once, the fixed ones when there are none, and asks for new ones when the
/// saved ones are stale.
@MainActor
final class LedgerAgentStarters: ObservableObject {
    static let shared = LedgerAgentStarters()

    nonisolated static let fallback = [
        String(localized: "这个月花了多少，主要花在哪"),
        String(localized: "最近 10 笔餐饮"),
        String(localized: "信用卡这个月还要还多少"),
        String(localized: "把上个月的打车都归到交通"),
    ]

    @Published private(set) var suggestions: [String] = LedgerAgentStarters.fallback
    /// The suggestions are the model's, not the fixed ones.
    @Published private(set) var isDynamic = false
    @Published private(set) var loading = false
    private var ledgerID: UUID?
    private var task: Task<Void, Never>?

    struct Source: Sendable {
        var load: @Sendable () async -> LedgerAgentStarterCache?
        var save: @Sendable (LedgerAgentStarterCache) async -> Void
        /// The ledger's current revision and memory.md digest.
        var state: @Sendable () async -> (revisionID: String?, memoryDigest: Int)
        var fetch: @Sendable () async throws -> [String]
    }

    /// Shows the saved suggestions of the ledger, then refreshes them when
    /// stale or when `force` is set.
    func refresh(ledger id: UUID, source: Source, force: Bool = false) {
        if ledgerID != id {
            ledgerID = id
            task?.cancel()
            task = nil
            loading = false
            suggestions = Self.fallback
            isDynamic = false
        }
        guard task == nil else { return }
        loading = force
        task = Task { [weak self] in
            let cached = await source.load()
            let state = await source.state()
            let day = LedgerAgentStarterCache.day()
            guard let self, self.ledgerID == id else { return }
            if let cached, !force || self.suggestions == Self.fallback {
                self.suggestions = cached.suggestions
                self.isDynamic = true
            }
            defer { if self.ledgerID == id { self.task = nil; self.loading = false } }
            if !force, cached?.isFresh(day: day, revisionID: state.revisionID, memoryDigest: state.memoryDigest) == true { return }
            self.loading = true
            guard let fetched = try? await source.fetch(), !fetched.isEmpty, self.ledgerID == id else { return }
            self.suggestions = fetched
            self.isDynamic = true
            await source.save(.init(day: day, revisionID: state.revisionID, memoryDigest: state.memoryDigest,
                                    suggestions: fetched, createdAt: Date()))
        }
    }
}

/// How the saved starter suggestions are encoded.
enum LedgerAgentAssistCoding {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
