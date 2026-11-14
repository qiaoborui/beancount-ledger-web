import Combine
import Foundation
#if canImport(LedgerCore)
import LedgerCore
#endif

/// A skill the ledger assistant loads on demand: an instruction file shipped
/// with the app, or one in the ledger's `skills/` folder, which Git syncs to
/// the user's other devices. Only its name and description reach the prompt;
/// the body is read when the model needs it.
struct LedgerAgentSkill: Decodable, Identifiable, Hashable, Sendable {
    let name: String
    let description: String
    /// Where it came from: `builtin` or `ledger`. A ledger skill replaces a
    /// built-in one of the same name.
    let source: String
    /// Where the body lives: an embedded path, or a ledger-relative one.
    var path: String = ""
    var body: String = ""
    /// The user turned it off, so no turn lists or loads it.
    var disabled = false

    var id: String { name }

    var isBuiltIn: Bool { source == "builtin" }

    var sourceTitle: String {
        isBuiltIn ? String(localized: "内置") : String(localized: "账本")
    }

    private enum CodingKeys: String, CodingKey { case name, description, source, path, body, disabled }

    /// Only the name, the description and the source are always sent: a core
    /// that predates this field sends no body state, and an enabled skill
    /// leaves `disabled` out.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        source = try container.decode(String.self, forKey: .source)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
    }
}

/// What the native skill catalog returns: every skill with its body, plus the
/// files it could not read.
struct LedgerAgentSkillCatalog: Decodable, Sendable {
    struct Problem: Decodable, Hashable, Sendable {
        let path: String
        let error: String
    }

    var ok = false
    var skills: [LedgerAgentSkill] = []
    var problems: [Problem] = []
    var error: String?

    private enum CodingKeys: String, CodingKey { case ok, skills, problems, error }

    /// A failed read carries only `ok: false` and the error, so the two lists
    /// are optional here and default to empty.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        skills = try container.decodeIfPresent([LedgerAgentSkill].self, forKey: .skills) ?? []
        problems = try container.decodeIfPresent([Problem].self, forKey: .problems) ?? []
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    /// The skills of a ledger, as the native side lists them. A ledger without
    /// a skills folder still gets the built-in ones.
    static func load(workspaceRoot: String, disabled: [String] = [],
                     using lister: LedgerAgentSkillLister = .native) async throws -> LedgerAgentSkillCatalog {
        try await lister.list(workspaceRoot, disabled)
    }
}

/// The blocking JSON boundary to the native skill catalog. Tests substitute it.
struct LedgerAgentSkillLister: Sendable {
    var list: @Sendable (String, [String]) async throws -> LedgerAgentSkillCatalog

    private struct Request: Encodable {
        let version = 1
        let workspaceRoot: String
        /// The names the user turned off; the native side marks them.
        let disabledSkills: [String]?
    }

    static let native = LedgerAgentSkillLister(list: { workspaceRoot, disabled in
        #if canImport(LedgerCore)
        let request = try JSONEncoder().encode(Request(workspaceRoot: workspaceRoot,
                                                       disabledSkills: disabled.isEmpty ? nil : disabled))
        let data = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Data(MobileagentSkillCatalogJSON(String(decoding: request, as: UTF8.self)).utf8))
            }
        }
        let catalog = try JSONDecoder().decode(LedgerAgentSkillCatalog.self, from: data)
        guard catalog.ok else { throw LedgerAgentError.failed(catalog.error ?? String(localized: "读取技能失败")) }
        return catalog
        #else
        throw LocalLedgerError.runtimeUnavailable
        #endif
    })
}

/// The skills the user turned off. The choice is this device's, so it stays in
/// `UserDefaults` rather than in the ledger: a ledger skill is shared through
/// Git, whether one user wants it offered is not.
@MainActor
final class LedgerAgentSkillSettings: ObservableObject {
    static let shared = LedgerAgentSkillSettings()

    /// The names no turn lists or loads, sorted.
    @Published private(set) var disabled: [String] = []
    private let defaults: UserDefaults
    private let disabledKey = "ledger.agent.disabled-skills"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        disabled = (defaults.stringArray(forKey: disabledKey) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    func isEnabled(_ name: String) -> Bool { !disabled.contains(name) }

    func setEnabled(_ on: Bool, name: String) {
        guard on == !isEnabled(name) else { return }
        if on {
            disabled.removeAll { $0 == name }
        } else {
            disabled.append(name)
            disabled.sort()
        }
        defaults.set(disabled, forKey: disabledKey)
    }

    /// What a turn sends, or nil when nothing is off: an install that never
    /// touched the page sends the same request as an older build.
    var turnValue: [String]? { disabled.isEmpty ? nil : disabled }
}
