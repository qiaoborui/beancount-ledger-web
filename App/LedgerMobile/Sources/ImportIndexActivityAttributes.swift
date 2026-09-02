import Foundation

#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit

struct ImportIndexActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        let phase: String
        let statusText: String
        let updatedAt: Date
    }

    let providerLabel: String
    let entryCount: Int
    let targetGitSHA: String?
    let baselineGitSHA: String?
}
#endif
