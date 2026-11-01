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
/// iOS gives an app that moves to the background about 30 seconds, and a turn
/// can take minutes. Three things hold it, strongest first:
///
/// - Silent audio (`LedgerAgentKeepAlive`, on unless the user turns it off):
///   an app that plays audio is not suspended, so the turn runs to the end
///   with the phone locked. A call can interrupt it; it comes back after.
/// - On iOS 26, a `BGContinuedProcessingTask`: the user started the turn, so
///   the system shows its progress on the Lock Screen and in the Dynamic
///   Island. The system expires a task that stops reporting progress, so a
///   heartbeat moves it along between the loop's own steps.
/// - The ordinary background grace time, with a Live Activity of our own
///   where the continued task is unavailable or was expired.
///
/// When everything holding the turn is gone, the turn is interrupted rather
/// than left to fail on a dead connection: the question returns, the draft
/// keeps what was already changed, and the Agent screen sends it again when
/// the user comes back. The heartbeat also notices when iOS froze the app
/// anyway, so a request that died with the freeze counts as an interruption
/// too.
///
/// A turn that ends while the Agent screen is not in front of the user posts
/// a local notification; tapping it opens the screen.
@MainActor
final class LedgerAgentBackgroundRun: LedgerAgentLifecycle {
    static let shared = LedgerAgentBackgroundRun()

    /// Continued tasks are registered per turn under this wildcard prefix,
    /// which Info.plist permits.
    static let taskPrefix = "com.qiaoborui.ledger.mobile.agent."
    /// A heartbeat later than this means the app was frozen in between.
    static let suspensionGap: TimeInterval = 20
    /// After a freeze, a turn that reports nothing for this long is taken to
    /// have lost its connection, and is interrupted so it can start again
    /// instead of waiting out the network timeout.
    static let signOfLifeLimit: TimeInterval = 45

    /// Set from the ledger's privacy protection: the Lock Screen and
    /// notifications then say only that the assistant is working or done.
    var concealsContent = false
    /// Set from the assistant's settings: hold turns with silent audio.
    var keepsAwake = true
    /// Why the last turn was interrupted, for the screen and the
    /// notification; nil when it was not.
    private(set) var interruptionCause: String?
    /// Whether iOS froze the app at some point during the running turn.
    private(set) var turnWasSuspended = false

    private weak var conversation: LedgerAgentConversation?
    /// From a turn's start to its end.
    private var running = false
    private var grace: UIBackgroundTaskIdentifier = .invalid
    private var startedAt = Date()
    private var steps = 0
    private var heartbeat: Task<Void, Never>?
    /// When the heartbeat found the app had been frozen, until the turn
    /// reports a step again.
    private var thawedAt: Date?
    private var continued: AnyObject?
    private var continuedID: String?
    private let keepAlive = LedgerAgentKeepAlive.shared
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
        interruptionCause = nil
        turnWasSuspended = false
        thawedAt = nil
        LedgerAgentNotifications.shared.requestAuthorizationIfNeeded()
        // Started here, while the app is in front: iOS does not start new
        // playback for an app already in the background.
        if keepsAwake {
            keepAlive.onLost = { [weak self] in self?.keepAliveLost() }
            keepAlive.onRegained = nil
            keepAlive.start()
        }
        holdGrace()
        startHeartbeat()
        let subtitle = concealsContent ? String(localized: "正在处理你的问题") : question
        if #available(iOS 26.0, *), submitContinued(subtitle: subtitle) { return }
        startActivity()
    }

    func turnStepped(_ step: LedgerAgentStep, count: Int) {
        steps = count
        thawedAt = nil
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
        if ending == .interrupted, interruptionCause == nil {
            interruptionCause = String(localized: "App 在后台的时间用完了")
        }
        let summary = Self.summary(ending, concealed: concealsContent, cause: interruptionCause)
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

    /// Whatever is left of the background grace time. Asked again when the
    /// silent audio is lost in the background, which leaves only this.
    private func holdGrace() {
        guard grace == .invalid else { return }
        grace = UIApplication.shared.beginBackgroundTask(withName: "ledger.agent-turn") { [weak self] in
            MainActor.assumeIsolated { self?.graceExpired() }
        }
    }

    /// The grace time is spent. Silent audio or a continued task keeps the
    /// app running on its own, so only a turn without either has to stop.
    private func graceExpired() {
        if grace != .invalid {
            UIApplication.shared.endBackgroundTask(grace)
            grace = .invalid
        }
        guard running, continued == nil, !keepAlive.isHolding else { return }
        expire(String(localized: "App 在后台的时间用完了"))
    }

    /// A call or another app took the audio session.
    private func keepAliveLost() {
        guard running else { return }
        if continued == nil { holdGrace() }
        interruptionCause = String(localized: "后台保活被来电或其他 App 的声音打断")
        keepAlive.onRegained = { [weak self] in
            // Back in time: the turn never stopped.
            guard let self, self.running else { return }
            self.interruptionCause = nil
        }
    }

    /// The system wants the background time back.
    private func expire(_ cause: String) {
        if interruptionCause == nil { interruptionCause = cause }
        if let conversation, conversation.isRunning {
            conversation.interrupt()
        } else {
            finishHolding()
        }
    }

    /// Ticks every two seconds while a turn runs: it keeps a continued task's
    /// progress moving, and a tick that comes far too late means iOS froze the
    /// app in between, whatever was meant to hold it.
    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.running, !Task.isCancelled else { return }
                let now = Date()
                if now.timeIntervalSince(last) > Self.suspensionGap {
                    self.turnWasSuspended = true
                    self.thawedAt = now
                    if self.interruptionCause == nil {
                        self.interruptionCause = String(localized: "App 在后台被系统暂停，连接断开了")
                    }
                }
                last = now
                if let thawed = self.thawedAt, now.timeIntervalSince(thawed) > Self.signOfLifeLimit {
                    self.thawedAt = nil
                    self.expire(String(localized: "App 在后台被系统暂停，连接断开了"))
                    return
                }
                if #available(iOS 26.0, *), let task = self.continued as? BGContinuedProcessingTask {
                    self.advanceProgress(task, by: 1)
                }
            }
        }
    }

    private func finishHolding() {
        heartbeat?.cancel()
        heartbeat = nil
        keepAlive.onLost = nil
        keepAlive.onRegained = nil
        keepAlive.stop()
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
                LedgerAgentBackgroundRun.shared.continuedExpired()
            }
        }
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = 0
    }

    /// The system ended the continued task early. With the silent audio
    /// still playing the turn goes on, shown by a Live Activity instead.
    @available(iOS 26.0, *)
    private func continuedExpired() {
        guard running else { return }
        guard keepAlive.isHolding else {
            expire(String(localized: "系统收回了后台处理时间"))
            return
        }
        (continued as? BGContinuedProcessingTask)?.setTaskCompleted(success: false)
        continued = nil
        continuedID = nil
        startActivity()
        updateActivity(.init(phase: .running, detail: String(localized: "正在后台继续处理"), steps: steps))
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

    static func summary(_ ending: LedgerAgentTurnEnding, concealed: Bool, cause: String? = nil) -> Summary {
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
            let reason = cause ?? String(localized: "App 在后台的时间用完了")
            return .init(title: String(localized: "账本助手被中断"),
                         body: reason + String(localized: "。回到 App 会自动接着做，草稿里的改动会保留。"),
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
