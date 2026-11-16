import Foundation
#if canImport(Combine)
import Combine
#endif

/// An artifact: a page the assistant builds to be kept, reopened and changed
/// later, the way Claude's artifacts are. The reply writes it as a fenced
/// `artifact` block, the same declarative JSON as a `visual` plus an `id`, a
/// `title` and a one-line `summary`. The chat shows it as a card that opens
/// full screen; the app saves every one under runtime/agent-artifacts, where
/// the 产物 list, cloud sync and the model's `read_artifact` find it.
///
/// Writing the same `id` again saves a new version, so the user can ask for a
/// change or a refresh and still go back to what it was.
struct LedgerAgentArtifactSpec: Equatable, Sendable {
    var id: String
    var title: String
    var summary: String?
    var visual: LedgerAgentVisual
    /// The block's JSON as the reply wrote it, saved unchanged so the model
    /// reads back exactly what it wrote.
    var json: String

    static let maximumIDLength = 48

    init?(json: String, logging: Bool = false) {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let object = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any],
              let visual = LedgerAgentVisual(json: trimmed, logging: logging) else { return nil }
        let title = Self.text(object["title"]) ?? visual.title ?? String(localized: "未命名产物")
        self.title = title
        self.summary = Self.text(object["summary"])
        self.id = Self.normalizedID(Self.text(object["id"]), title: title)
        // The page's own heading is the card's and the screen's title.
        var page = visual
        page.title = nil
        self.visual = page
        self.json = trimmed
    }

    /// The title and id a block still being written already shows.
    static func partialTitle(json: String) -> String? {
        LedgerAgentVisual.partial(json: json).title
    }

    /// Lowercase letters, digits and single hyphens, at most 48 long, as the
    /// file name and the native tools expect. An id the model left out or
    /// wrote in other letters becomes one derived from the title, the same
    /// every time, so writing it again still makes a new version.
    static func normalizedID(_ raw: String?, title: String) -> String {
        var slug = ""
        for scalar in (raw ?? "").lowercased().unicodeScalars {
            if (97...122).contains(scalar.value) || (48...57).contains(scalar.value) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty, slug.last != "-" {
                slug.append("-")
            }
        }
        slug = String(slug.prefix(maximumIDLength))
        while slug.hasSuffix("-") { slug.removeLast() }
        if !slug.isEmpty { return slug }
        // FNV-1a: stable across launches, unlike `hashValue`.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in title.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return "artifact-" + String(String(hash, radix: 16).prefix(10))
    }

    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= maximumIDLength && normalizedID(id, title: "") == id
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
        return string
    }
}

/// One artifact as saved at runtime/agent-artifacts/<id>.json: every version
/// the replies wrote, oldest first.
struct LedgerAgentArtifactRecord: Codable, Equatable, Identifiable, Sendable {
    struct Version: Codable, Equatable, Sendable {
        var number: Int
        var savedAt: Date
        /// The conversation and reply that wrote it, so a reply's card opens
        /// its own version and saving the same reply twice adds nothing.
        var conversationId: UUID?
        var messageId: UUID?
        var spec: String
    }

    var formatVersion = 1
    var id: String
    var title: String
    var summary: String?
    var createdAt: Date
    var updatedAt: Date
    var versions: [Version]

    /// Older versions beyond this are dropped, oldest first.
    static let maximumVersions = 20

    var latest: Version? { versions.last }

    /// The version a reply wrote; nil for a reply that wrote none of them.
    func version(writtenBy messageID: UUID) -> Version? {
        versions.last { $0.messageId == messageID }
    }

    func version(_ number: Int) -> Version? {
        versions.first { $0.number == number }
    }

    /// `existing` with `spec` saved as its newest version, or a new record
    /// when there is none. Nil when the reply's version is already saved, so
    /// saving a conversation again writes nothing.
    static func recording(_ spec: LedgerAgentArtifactSpec, in existing: Self?, conversation: UUID?, message: UUID?,
                          at date: Date = Date()) -> Self? {
        if let existing, let message, existing.version(writtenBy: message) != nil { return nil }
        if let existing, existing.latest?.spec == spec.json { return nil }
        // Whole seconds, as the file keeps them.
        let date = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        var record = existing ?? Self(id: spec.id, title: spec.title, summary: spec.summary, createdAt: date,
                                      updatedAt: date, versions: [])
        let number = (record.versions.map(\.number).max() ?? 0) + 1
        record.versions.append(Version(number: number, savedAt: date, conversationId: conversation, messageId: message,
                                       spec: spec.json))
        if record.versions.count > maximumVersions { record.versions.removeFirst(record.versions.count - maximumVersions) }
        record.title = spec.title
        record.summary = spec.summary
        record.updatedAt = date
        return record
    }

    /// The artifacts a finished reply wrote, last one of an id winning.
    static func specs(in reply: String) -> [LedgerAgentArtifactSpec] {
        var byID: [String: LedgerAgentArtifactSpec] = [:]
        var order: [String] = []
        for case let .artifact(spec) in LedgerAgentReplyText.segments(reply) {
            if byID[spec.id] == nil { order.append(spec.id) }
            byID[spec.id] = spec
        }
        return order.compactMap { byID[$0] }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func decode(_ data: Data) -> Self? {
        guard let record = try? decoder.decode(Self.self, from: data), !record.versions.isEmpty,
              LedgerAgentArtifactSpec.isValidID(record.id) else { return nil }
        return record
    }
}

#if canImport(Combine)
/// Tells the 产物 list and open artifacts that a reply saved a version, so
/// they read the files again.
@MainActor
final class LedgerAgentArtifactShelf: ObservableObject {
    static let shared = LedgerAgentArtifactShelf()
    @Published private(set) var revision = 0

    func changed() { revision += 1 }
}
#endif
