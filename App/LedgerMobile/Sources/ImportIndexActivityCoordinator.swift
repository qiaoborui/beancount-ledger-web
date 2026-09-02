import Foundation

#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit

struct ImportIndexActivityResumeState: Equatable, Sendable {
    let providerLabel: String
    let entryCount: Int
    let targetGitSHA: String?
    let baselineGitSHA: String?
    let phase: String
}

// The coordinator actor serializes every access to ActivityKit's non-Sendable handle.
private struct ImportIndexActivityHandle: @unchecked Sendable {
    let activity: Activity<ImportIndexActivityAttributes>

    func update(_ content: ActivityContent<ImportIndexActivityAttributes.ContentState>) async {
        await activity.update(content)
    }

    func end(
        _ content: ActivityContent<ImportIndexActivityAttributes.ContentState>?,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) async {
        await activity.end(content, dismissalPolicy: dismissalPolicy)
    }
}

actor ImportIndexActivityCoordinator {
    private var handle: ImportIndexActivityHandle?

    func start(
        providerLabel: String,
        entryCount: Int,
        targetGitSHA: String?,
        baselineGitSHA: String?
    ) async {
        await end(immediately: true)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = ImportIndexActivityAttributes(
            providerLabel: providerLabel,
            entryCount: entryCount,
            targetGitSHA: targetGitSHA,
            baselineGitSHA: baselineGitSHA
        )
        let content = ActivityContent(
            state: ImportIndexActivityAttributes.ContentState(
                phase: "indexing",
                statusText: "正在更新索引",
                updatedAt: Date()
            ),
            staleDate: Date().addingTimeInterval(90)
        )
        if let activity = try? Activity.request(attributes: attributes, content: content) {
            handle = ImportIndexActivityHandle(activity: activity)
        }
    }

    func restorePending() -> ImportIndexActivityResumeState? {
        guard let activity = Activity<ImportIndexActivityAttributes>.activities.first(where: {
            $0.activityState == .active || $0.activityState == .stale
        }) else { return nil }
        handle = ImportIndexActivityHandle(activity: activity)
        return ImportIndexActivityResumeState(
            providerLabel: activity.attributes.providerLabel,
            entryCount: activity.attributes.entryCount,
            targetGitSHA: activity.attributes.targetGitSHA,
            baselineGitSHA: activity.attributes.baselineGitSHA,
            phase: activity.content.state.phase
        )
    }

    func updateIndexing() async {
        guard let handle else { return }
        await handle.update(
            ActivityContent(
                state: ImportIndexActivityAttributes.ContentState(
                    phase: "indexing",
                    statusText: "正在更新索引",
                    updatedAt: Date()
                ),
                staleDate: Date().addingTimeInterval(90)
            )
        )
    }

    func complete() async {
        guard let handle else { return }
        let content = ActivityContent(
            state: ImportIndexActivityAttributes.ContentState(
                phase: "indexed",
                statusText: "索引已完成",
                updatedAt: Date()
            ),
            staleDate: nil
        )
        await handle.update(content)
        await handle.end(content, dismissalPolicy: .after(Date().addingTimeInterval(30)))
        self.handle = nil
    }

    func end(immediately: Bool) async {
        let handles = activeHandles()
        for handle in handles {
            await handle.end(nil, dismissalPolicy: immediately ? .immediate : .default)
        }
        self.handle = nil
    }

    private func activeHandles() -> [ImportIndexActivityHandle] {
        var handles = Activity<ImportIndexActivityAttributes>.activities
            .filter { $0.activityState == .active || $0.activityState == .stale }
            .map(ImportIndexActivityHandle.init)
        if let handle, handles.isEmpty {
            handles.append(handle)
        }
        return handles
    }
}
#else
struct ImportIndexActivityResumeState: Equatable, Sendable {
    let providerLabel: String
    let entryCount: Int
    let targetGitSHA: String?
    let baselineGitSHA: String?
    let phase: String
}

actor ImportIndexActivityCoordinator {
    func start(
        providerLabel: String,
        entryCount: Int,
        targetGitSHA: String?,
        baselineGitSHA: String?
    ) async {}
    func restorePending() -> ImportIndexActivityResumeState? { nil }
    func updateIndexing() async {}
    func complete() async {}
    func end(immediately: Bool) async {}
}
#endif
