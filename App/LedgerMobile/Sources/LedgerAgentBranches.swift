import CryptoKit
import Foundation

/// Every version of a conversation, as a tree. Regenerating an answer adds
/// another answer under the same question; editing a question adds another
/// question under the same parent. The path from the first message to
/// `activeLeaf` is the conversation on screen: what the model's history, the
/// saved `messages` and the native history tools read.
struct LedgerAgentThread: Equatable, Sendable {
    struct Node: Equatable, Sendable {
        let id: UUID
        var parentID: UUID?
        var message: LedgerAgentMessage
    }

    /// A message off the active path as it is saved: its parent and its place
    /// among that parent's children, so the versions keep their order.
    struct Branch: Equatable, Sendable {
        var parentID: UUID?
        var index: Int
        var message: LedgerAgentMessage
    }

    private(set) var nodes: [UUID: Node] = [:]
    /// Each message's children, oldest first; `nil` holds the first questions.
    private(set) var children: [UUID?: [UUID]] = [:]
    private(set) var activeLeaf: UUID?

    init() {}

    init(path: [LedgerAgentMessage], branches: [Branch] = []) {
        adopt(path)
        // Saved parents first, so each branch finds its parent; inserting in
        // ascending place puts every version back where it was.
        for branch in branches where nodes[branch.message.id] == nil {
            guard branch.parentID.map({ nodes[$0] != nil }) ?? true else { continue }
            let id = branch.message.id
            nodes[id] = Node(id: id, parentID: branch.parentID, message: branch.message)
            var list = children[branch.parentID] ?? []
            list.insert(id, at: min(max(branch.index, 0), list.count))
            children[branch.parentID] = list
        }
    }

    /// The conversation on screen, first message first.
    var activePath: [LedgerAgentMessage] { activeIDs.compactMap { nodes[$0]?.message } }

    var activeIDs: [UUID] {
        var ids: [UUID] = []
        var current = activeLeaf
        while let id = current, let node = nodes[id], ids.count <= nodes.count {
            ids.append(id)
            current = node.parentID
        }
        return ids.reversed()
    }

    /// Makes `path` the active path. A new message joins under the one before
    /// it; a known one takes the new content, and moves under the one before
    /// it if it sat elsewhere (a stopped reply inserted after its question).
    /// Nothing is removed: messages that fall off the path stay as versions.
    mutating func adopt(_ path: [LedgerAgentMessage]) {
        var parent: UUID?
        for message in path {
            if var node = nodes[message.id] {
                node.message = message
                if node.parentID != parent {
                    detach(message.id, from: node.parentID)
                    node.parentID = parent
                    children[parent, default: []].append(message.id)
                }
                nodes[message.id] = node
            } else {
                nodes[message.id] = Node(id: message.id, parentID: parent, message: message)
                children[parent, default: []].append(message.id)
            }
            parent = message.id
        }
        activeLeaf = parent
    }

    /// Where a message stands among the versions at its place: its index from
    /// 0 and how many there are. A message alone is (0, 1).
    func siblings(of id: UUID) -> (index: Int, count: Int) {
        guard let node = nodes[id], let list = children[node.parentID], let index = list.firstIndex(of: id) else {
            return (0, 1)
        }
        return (index, list.count)
    }

    /// The version `offset` places before or after `id`; nil past either end.
    func sibling(of id: UUID, offset: Int) -> UUID? {
        guard let node = nodes[id], let list = children[node.parentID], let index = list.firstIndex(of: id),
              list.indices.contains(index + offset) else { return nil }
        return list[index + offset]
    }

    func children(of id: UUID?) -> [UUID] { children[id] ?? [] }

    /// Adds `newText` as another version of the question `id`, under the same
    /// parent and with the same files, and makes it the leaf.
    @discardableResult
    mutating func fork(atUser id: UUID, newText: String) -> LedgerAgentMessage? {
        guard let node = nodes[id], node.message.role == .user else { return nil }
        let message = LedgerAgentMessage(role: .user, text: newText, attachments: node.message.attachments)
        nodes[message.id] = Node(id: message.id, parentID: node.parentID, message: message)
        children[node.parentID, default: []].append(message.id)
        activeLeaf = message.id
        return message
    }

    /// Adds `answer` as another answer to the question `userID` and makes it
    /// the leaf.
    mutating func addAlternateAnswer(to userID: UUID, _ answer: LedgerAgentMessage) {
        guard nodes[userID]?.message.role == .user, nodes[answer.id] == nil else { return }
        nodes[answer.id] = Node(id: answer.id, parentID: userID, message: answer)
        children[userID, default: []].append(answer.id)
        activeLeaf = answer.id
    }

    /// Ends the active path at `id`, which must be on it; what came after
    /// stays as a version. nil empties the path.
    mutating func rewind(to id: UUID?) {
        guard let id else { activeLeaf = nil; return }
        guard activeIDs.contains(id) else { return }
        activeLeaf = id
    }

    /// Shows the version `id`: the leaf becomes its newest descendant,
    /// following the latest child at each step.
    mutating func switchTo(sibling id: UUID) {
        guard nodes[id] != nil else { return }
        activeLeaf = newestLeaf(under: id)
    }

    /// The leaf `switchTo(sibling:)` would show for `id`.
    func newestLeaf(under id: UUID) -> UUID {
        var leaf = id
        var steps = 0
        while let next = children[leaf]?.last, steps <= nodes.count {
            leaf = next
            steps += 1
        }
        return leaf
    }

    /// How many questions come before `id` on the active path; nil when it is
    /// not on it.
    func userTurnIndex(of id: UUID) -> Int? {
        let path = activePath
        guard let index = path.firstIndex(where: { $0.id == id }) else { return nil }
        return path[..<index].filter { $0.role == .user }.count
    }

    /// Drops a message nothing hangs under, such as a failed question asked
    /// again in other words. The leaf moves to its parent.
    mutating func remove(_ id: UUID) {
        guard let node = nodes[id], children(of: id).isEmpty else { return }
        detach(id, from: node.parentID)
        nodes[id] = nil
        if activeLeaf == id { activeLeaf = node.parentID }
    }

    /// Whether any message has another version.
    var hasBranches: Bool { children.values.contains { $0.count > 1 } }

    /// Every leaf except the active one: the ends of the other versions,
    /// whose transcripts are kept apart.
    var inactiveLeaves: Set<UUID> {
        Set(nodes.keys.filter { children(of: $0).isEmpty && $0 != activeLeaf })
    }

    /// The messages off the active path, parents before their children, each
    /// with its place among its siblings.
    var branches: [Branch] {
        let active = Set(activeIDs)
        var result: [Branch] = []
        var queue: [UUID?] = [nil]
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            for (index, id) in children(of: parent).enumerated() {
                if !active.contains(id), let node = nodes[id] {
                    result.append(Branch(parentID: parent, index: index, message: node.message))
                }
                queue.append(id)
            }
        }
        return result
    }

    private mutating func detach(_ id: UUID, from parent: UUID?) {
        children[parent]?.removeAll { $0 == id }
        if children[parent]?.isEmpty == true { children[parent] = nil }
    }
}

/// A message's id in a conversation saved before messages had ids: derived
/// from the conversation and the message's place, so it is the same on every
/// load without rewriting the record.
enum LedgerAgentMessageID {
    static func derived(conversation: UUID, index: Int) -> UUID {
        var bytes = withUnsafeBytes(of: conversation.uuid) { Array($0) }
        bytes += Array("message-\(index)".utf8)
        var hash = Array(Insecure.SHA1.hash(data: bytes).prefix(16))
        // A name-based (version 5) UUID, RFC 4122 variant.
        hash[6] = (hash[6] & 0x0F) | 0x50
        hash[8] = (hash[8] & 0x3F) | 0x80
        return UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                           hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
    }
}

extension LedgerAgentMessage {
    /// A saved message; `fallbackID` names it when the save has no id.
    init?(saved stored: LedgerAgentSavedConversation.Message, fallbackID: UUID) {
        guard let role = Role(rawValue: stored.role) else { return nil }
        self.init(id: stored.id ?? fallbackID, role: role, text: stored.text, toolCalls: stored.toolCalls,
                  duration: stored.duration, attachments: stored.attachments ?? [],
                  rememberedMemory: stored.memory ?? false, ask: stored.ask, write: stored.write,
                  steps: stored.steps ?? [], stopped: stored.stopped ?? false, usage: stored.usage,
                  compacted: stored.compacted ?? false, outsideTranscript: stored.outsideTranscript ?? false,
                  settings: stored.settings)
    }
}

extension LedgerAgentSavedConversation.Message {
    init(_ message: LedgerAgentMessage) {
        self.init(id: message.id, role: message.role.rawValue, text: message.text, toolCalls: message.toolCalls,
                  duration: message.duration, attachments: message.attachments.isEmpty ? nil : message.attachments,
                  memory: message.rememberedMemory ? true : nil, ask: message.ask, write: message.write,
                  steps: message.steps.isEmpty ? nil : message.steps, stopped: message.stopped ? true : nil,
                  usage: message.usage, compacted: message.compacted ? true : nil,
                  outsideTranscript: message.outsideTranscript ? true : nil, settings: message.settings)
    }
}

extension LedgerAgentSavedConversation {
    /// The saved versions as a thread. Messages without an id, from saves
    /// before version 2, get ids derived from their place; a version 1 save
    /// is one branch.
    func thread() -> LedgerAgentThread {
        var path = messages.enumerated().compactMap { index, stored in
            LedgerAgentMessage(saved: stored, fallbackID: LedgerAgentMessageID.derived(conversation: id, index: index))
        }
        // An older save did not note which questions its transcript lacks. A
        // question it ends on failed or was cut off, so the transcript never
        // took it in.
        if messages.last?.id == nil, let last = path.indices.last, path[last].role == .user {
            path[last].outsideTranscript = true
        }
        let branches = (branches ?? []).enumerated().compactMap { index, branch -> LedgerAgentThread.Branch? in
            let fallback = LedgerAgentMessageID.derived(conversation: id, index: messages.count + index)
            return LedgerAgentMessage(saved: branch.message, fallbackID: fallback).map {
                LedgerAgentThread.Branch(parentID: branch.parent, index: branch.index, message: $0)
            }
        }
        return LedgerAgentThread(path: path, branches: branches)
    }
}

/// Why a regenerate, an edit or a switch to another version waits for the
/// user's word.
struct LedgerAgentBranchWarning: OptionSet, Equatable, Sendable {
    let rawValue: Int
    /// The answers being replaced wrote to the ledger, and replacing them does
    /// not undo that.
    static let written = LedgerAgentBranchWarning(rawValue: 1 << 0)
    /// A stopped or interrupted turn may have left edits in the draft that no
    /// change card showed; going on discards the draft.
    static let unreviewedDraft = LedgerAgentBranchWarning(rawValue: 1 << 1)
}

/// What became of a regenerate, an edit or a switch to another version.
enum LedgerAgentBranchResult: Equatable, Sendable {
    /// Not now: a turn runs, a change is on the card or being written, or
    /// the message has nothing to do it on.
    case refused
    /// Asks again with `confirmed` once the user agrees.
    case needsConfirmation(LedgerAgentBranchWarning)
    case started
}
