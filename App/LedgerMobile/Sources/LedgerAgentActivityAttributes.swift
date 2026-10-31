import Foundation

#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit

/// The Live Activity of one 账本助手 turn that runs while the app is away.
struct LedgerAgentActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Hashable, Sendable {
            case running, answered, review, failed, interrupted
        }
        let phase: Phase
        /// The current step while running, then a line about the result.
        /// Generic when the ledger is privacy protected.
        let detail: String
        let steps: Int
    }

    let startedAt: Date
}
#endif
