#if os(iOS)
@preconcurrency import BackgroundTasks
import Foundation
import UIKit
@preconcurrency import UserNotifications
#if !targetEnvironment(macCatalyst)
import ActivityKit
#endif

/// Keeps a 账本助手 turn running after the user leaves the app, and says how
/// it ended.
///
/// iOS gives an app that moves to the background about 30 seconds. A turn can
/// take minutes, so on iOS 26 each turn is a `BGContinuedProcessingTask`: the
/// user started it, and the system shows its progress (title, the current
/// step) on the Lock Screen and in the Dynamic Island while it runs. The
/// system expires a continued task that stops reporting progress, so a timer
/// moves the progress along between the loop's own steps. Where that task is
/// unavailable or refused, the turn holds the ordinary background grace time
/// and shows its own Live Activity. When the time runs out either way the
/// turn is interrupted, not left to fail on a dead connection: the question
/// returns for a retry and the draft keeps what was already changed.
///
/// A turn that ends while the Agent screen is not in front of the user posts
/// a local notification; tapping it opens the screen.
@MainActor
final class LedgerAgentBackgroundRun: LedgerAgentLifecycle {
    static let shared = LedgerAgentBackgroundRun()

    /// Continued tasks are registered per turn under this wildcard prefix,
    /// which Info.plist permits.
    static let taskPrefix = "com.qiaoborui.ledger.mobile.agent."

    /// Set from the ledger's privacy protection: the Lock Screen and
    /// notifications then say only that the assistant is working or done.
    var concealsContent = false

    private weak var conversation: LedgerAgentConversation?
    /// From a turn's start to its end.
    private var running = false
    private var grace: UIBackgroundTaskIdentifier = .invalid
    private var startedAt = Date()
    private var steps = 0
    private var ticker: Task<Void, Never>?
    private var continued: AnyObject?
    private var continuedID: String?
    #if !targetEnvironment(macCatalyst)
    private var activity: ActivityHandle?
    #endif

    func turnStarted(question: String, conversation: LedgerAgentConversation) {
        finishHolding()
        endActivity(nil, immediately: true)
        self.conversation = conversation
        running = true
        startedAt = Date()
        steps = 0
        LedgerAgentNotifications.shared.requestAuthorizationIfNeeded()
        grace = UIApplication.shared.beginBackgroundTask(withName: "ledger.agent-turn") { [weak self] in
            MainActor.assumeIsolated { self?.graceExpired() }
        }
        let subtitle = concealsContent ? String(localized: "正在处理你的问题") : question
        if #available(iOS 26.0, *), submitContinued(subtitle: subtitle) { return }
        startActivity()
    }

    func turnStepped(_ step: LedgerAgentStep, count: Int) {
        steps = count
        let detail = concealsContent ? String(localized: "正在处理（第 \(count) 步）") : step.title
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.updateTitle(String(localized: "账本助手正在处理"), subtitle: detail)
            advanceProgress(task, by: 20)
        }
        updateActivity(.init(phase: .running, detail: detail, steps: count))
    }

    func turnEnded(_ ending: LedgerAgentTurnEnding) {
        guard running else { return }
        running = false
        let seen = UIApplication.shared.applicationState == .active && conversation?.isOnScreen == true
        let summary = Self.summary(ending, concealed: concealsContent)
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.updateTitle(summary.title, subtitle: summary.body)
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: summary.phase == .answered || summary.phase == .review)
            continued = nil
            continuedID = nil
        }
        if let phase = summary.phase {
            endActivity(.init(phase: phase, detail: summary.body, steps: steps), immediately: seen)
        } else {
            endActivity(nil, immediately: true)
        }
        if !seen, ending != .stopped {
            LedgerAgentNotifications.shared.post(title: summary.title, body: summary.body)
        }
        finishHolding()
    }

    /// The Agent screen is in front of the user: what the Lock Screen and the
    /// notification list said about it is now old news.
    func conversationSeen() {
        guard !running else { return }
        endActivity(nil, immediately: true)
        LedgerAgentNotifications.shared.clearDelivered()
    }

    /// The grace time is spent. A continued task keeps the app running on
    /// its own, so only a turn without one has to stop.
    private func graceExpired() {
        if grace != .invalid {
            UIApplication.shared.endBackgroundTask(grace)
            grace = .invalid
        }
        if continued == nil { expire() }
    }

    /// The system wants the background time back.
    private func expire() {
        if let conversation, conversation.isRunning {
            conversation.interrupt()
        } else {
            finishHolding()
        }
    }

    private func finishHolding() {
        ticker?.cancel()
        ticker = nil
        if let continuedID {
            if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
                task.setTaskCompleted(success: false)
            } else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: continuedID)
            }
        }
        continued = nil
        continuedID = nil
        if grace != .invalid {
            UIApplication.shared.endBackgroundTask(grace)
            grace = .invalid
        }
    }

    // MARK: Continued processing (iOS 26)

    /// Asks for a continued task that starts now; false when the system
    /// refuses, so the turn falls back to grace time and a Live Activity.
    @available(iOS 26.0, *)
    private func submitContinued(subtitle: String) -> Bool {
        let identifier = Self.taskPrefix + UUID().uuidString
        let box = TaskBox()
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            box.task = task
            MainActor.assumeIsolated { LedgerAgentBackgroundRun.shared.attach(box, identifier: identifier) }
        }
        guard registered else { return false }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier,
            title: String(localized: "账本助手正在处理"), subtitle: subtitle)
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) } catch { return false }
        continuedID = identifier
        return true
    }

    @available(iOS 26.0, *)
    private func attach(_ box: TaskBox, identifier: String) {
        guard let task = box.task as? BGContinuedProcessingTask else {
            box.task?.setTaskCompleted(success: false)
            return
        }
        // A turn that already ended, or a later turn's task.
        guard identifier == continuedID else {
            task.setTaskCompleted(success: false)
            return
        }
        continued = task
        task.expirationHandler = {
            Task { @MainActor in
                guard LedgerAgentBackgroundRun.shared.continuedID == identifier else { return }
                LedgerAgentBackgroundRun.shared.expire()
            }
        }
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = 0
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, let task = self.continued as? BGContinuedProcessingTask else { return }
                self.advanceProgress(task, by: 1)
            }
        }
    }

    /// Progress the loop cannot measure: it approaches the end over the
    /// turn's ten-minute limit and never stands still, and each step jumps
    /// it ahead a little.
    @available(iOS 26.0, *)
    private func advanceProgress(_ task: BGContinuedProcessingTask, by minimum: Int64) {
        let elapsed = Date().timeIntervalSince(startedAt)
        let target = Int64(950 * (1 - exp(-elapsed / 180)))
        let next = max(task.progress.completedUnitCount + minimum, target)
        task.progress.completedUnitCount = min(next, task.progress.totalUnitCount - 10)
    }

    /// Carries the task the launch handler gets to the main actor, where it
    /// is only ever used.
    private final class TaskBox: @unchecked Sendable {
        var task: BGTask?
    }

    // MARK: Live Activity (fallback)

    private func startActivity() {
        #if !targetEnvironment(macCatalyst)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = LedgerAgentActivityAttributes.ContentState(
            phase: .running, detail: String(localized: "正在思考"), steps: 0)
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(4 * 60))
        if let started = try? Activity.request(attributes: LedgerAgentActivityAttributes(startedAt: startedAt),
                                               content: content) {
            activity = ActivityHandle(activity: started)
        }
        #endif
    }

    private func updateActivity(_ state: LedgerAgentActivityAttributes.ContentState) {
        #if !targetEnvironment(macCatalyst)
        guard let activity else { return }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(4 * 60))
        Task { await activity.update(content) }
        #endif
    }

    private func endActivity(_ state: LedgerAgentActivityAttributes.ContentState?, immediately: Bool) {
        #if !targetEnvironment(macCatalyst)
        var handles = Activity<LedgerAgentActivityAttributes>.activities.map(ActivityHandle.init)
        if let activity, handles.isEmpty { handles.append(activity) }
        activity = nil
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        // A result the user has not seen stays on the Lock Screen until they
        // open the app, or for at most the system's four hours.
        let policy: ActivityUIDismissalPolicy = immediately ? .immediate : .default
        for handle in handles {
            Task { await handle.end(content, dismissalPolicy: policy) }
        }
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    /// ActivityKit's handle is not Sendable; it is only touched from here.
    private struct ActivityHandle: @unchecked Sendable {
        let activity: Activity<LedgerAgentActivityAttributes>
        func update(_ content: ActivityContent<LedgerAgentActivityAttributes.ContentState>) async {
            await activity.update(content)
        }
        func end(_ content: ActivityContent<LedgerAgentActivityAttributes.ContentState>?,
                 dismissalPolicy: ActivityUIDismissalPolicy) async {
            await activity.end(content, dismissalPolicy: dismissalPolicy)
        }
    }
    #endif

    // MARK: Wording

    struct Summary: Equatable {
        let title: String
        let body: String
        /// nil when there is nothing left to show, after a stop.
        let phase: LedgerAgentActivityAttributes.ContentState.Phase?
    }

    static func summary(_ ending: LedgerAgentTurnEnding, concealed: Bool) -> Summary {
        switch ending {
        case let .answered(reply):
            let body = concealed ? String(localized: "打开 App 查看回答") : snippet(reply)
            return .init(title: String(localized: "账本助手已回答"), body: body, phase: .answered)
        case let .changeReady(_, files):
            return .init(title: String(localized: "账本助手改好了草稿"),
                         body: String(localized: "\(files) 个文件的改动等你确认后写入账本"), phase: .review)
        case let .failed(message):
            let body = concealed ? String(localized: "打开 App 查看原因，问题还在输入框里") : snippet(message)
            return .init(title: String(localized: "账本助手没能完成"), body: body, phase: .failed)
        case .interrupted:
            return .init(title: String(localized: "账本助手被中断"),
                         body: String(localized: "App 在后台的时间用完了。回到 App 点重试即可继续，草稿里的改动会保留。"),
                         phase: .interrupted)
        case .stopped:
            return .init(title: String(localized: "账本助手已停止"), body: "", phase: nil)
        }
    }

    /// The first lines of a Markdown reply, as plain text that fits a banner.
    static func snippet(_ text: String, limit: Int = 140) -> String {
        let plain = text
            .split(whereSeparator: \.isNewline)
            .map { line in
                line.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#>-*| "))
                    .replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "`", with: "")
            }
            .filter { !$0.isEmpty && !$0.allSatisfy { "-:| ".contains($0) } }
            .joined(separator: " ")
        guard plain.count > limit else { return plain }
        return String(plain.prefix(limit)) + "…"
    }
}

/// Local notifications for turns that end off screen. The delegate is set at
/// launch so a tap that cold-starts the app still opens the Agent screen.
@MainActor
final class LedgerAgentNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LedgerAgentNotifications()
    nonisolated static let thread = "ledger-agent"

    /// Opens the Agent screen; set by the app once its session exists.
    var open: (() -> Void)? {
        didSet {
            guard pendingOpen, let open else { return }
            pendingOpen = false
            open()
        }
    }
    private var pendingOpen = false
    private var askedForAuthorization = false

    func requestAuthorizationIfNeeded() {
        guard !askedForAuthorization else { return }
        askedForAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = Self.thread
        let request = UNNotificationRequest(identifier: Self.thread + "." + UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    func clearDelivered() {
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let ids = delivered.filter { $0.request.content.threadIdentifier == Self.thread }.map(\.request.identifier)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    private func route() {
        if let open { open() } else { pendingOpen = true }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.threadIdentifier == Self.thread else { return }
        await MainActor.run { self.route() }
    }

    /// In the app but away from the Agent screen, the banner still shows.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
#endif
