#if os(iOS)
import AVFoundation
import Foundation
import os
import Speech

/// The microphone behind the 账本助手's voice input: records, writes the
/// levels the waveform draws, and turns speech into text as it is spoken.
/// Recognition runs on the device whenever the language has an on-device
/// model, so what is said about money does not leave the phone; for a
/// language without one the system's own recognizer is used.
///
/// Nothing is kept: the audio goes to the recognizer and is dropped, and only
/// the text reaches the composer, where it is edited before it is sent.
@MainActor
final class LedgerAgentVoiceRecorder: ObservableObject {
    enum Phase: Equatable { case idle, starting, recording, finishing }

    enum Failure: Equatable {
        case microphoneDenied
        case speechDenied
        case unavailable
        case engine

        var message: String {
            switch self {
            case .microphoneDenied: String(localized: "没有麦克风权限，请在系统设置里允许 Ledger 使用麦克风")
            case .speechDenied: String(localized: "没有语音识别权限，请在系统设置里允许 Ledger 使用语音识别")
            case .unavailable: String(localized: "这台设备暂时无法识别语音")
            case .engine: String(localized: "无法开始录音，请稍后再试")
            }
        }

        /// The fix is in Settings, so the message offers to open it.
        var opensSettings: Bool { self == .microphoneDenied || self == .speechDenied }
    }

    @Published private(set) var phase: Phase = .idle
    /// What the recognizer has heard so far, the whole recording's text.
    @Published private(set) var transcript = ""
    @Published private(set) var failure: Failure?

    /// Read by the waveform's own 60 fps timeline; not published, so a new
    /// level redraws the strip and nothing else.
    let levels = VoiceLevels()
    /// `systemUptime` when recording began.
    private(set) var startedUptime: TimeInterval = 0

    var isActive: Bool { phase != .idle }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var gotFinal = false
    private var interruption: NSObjectProtocol?

    /// A level history shared with the audio thread.
    final class VoiceLevels: @unchecked Sendable {
        private let storage = OSAllocatedUnfairLock(initialState: LedgerVoiceWaveform())

        func append(level: Double, at time: TimeInterval) {
            storage.withLock { $0.append(level: level, at: time) }
        }

        func reset() { storage.withLock { $0.reset() } }

        func snapshot() -> LedgerVoiceWaveform { storage.withLock { $0 } }
    }

    // MARK: Start

    /// Begins recording; `failure` says why it could not. A no-op while a
    /// recording is already under way.
    func start() async {
        guard phase == .idle else { return }
        phase = .starting
        failure = nil
        transcript = ""
        gotFinal = false
        levels.reset()
        if let denied = await Self.authorize() {
            fail(denied)
            return
        }
        // The user let go or cancelled while the permission sheet was up.
        guard phase == .starting else { return }
        guard let recognizer = Self.recognizer(), recognizer.isAvailable else {
            fail(.unavailable)
            return
        }
        do {
            try begin(recognizer: recognizer)
            phase = .recording
        } catch {
            teardown()
            fail(.engine)
        }
    }

    private func begin(recognizer: SFSpeechRecognizer) throws {
        let audio = AVAudioSession.sharedInstance()
        // Not .measurement: that switches off the input's gain control, which
        // leaves speech too quiet for the waveform to move.
        try audio.setCategory(.record, mode: .default, options: [.duckOthers])
        try audio.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request

        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(for: self))

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw CocoaError(.featureUnsupported) }
        input.installTap(onBus: 0, bufferSize: 1024, format: format,
                         block: Self.tapBlock(Tap(request: request, levels: levels)))
        engine.prepare()
        try engine.start()
        startedUptime = ProcessInfo.processInfo.systemUptime
        interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: audio, queue: .main) { [weak self] _ in
            // A call or Siri took the microphone: keep what was heard.
            Task { @MainActor in _ = await self?.finish() }
        }
    }

    // MARK: Finish

    /// Ends the recording and returns its text, waiting a moment for the
    /// recognizer to settle the last words.
    func finish() async -> String {
        guard phase == .recording || phase == .starting else { return transcript }
        if phase == .starting {
            // Still waiting on a permission sheet: nothing was recorded.
            phase = .idle
            return transcript
        }
        phase = .finishing
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        let deadline = Date().addingTimeInterval(1.2)
        while !gotFinal, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        let text = transcript
        teardown()
        return text
    }

    /// Drops the recording and its text.
    func cancel() {
        guard phase != .idle else { return }
        if phase == .recording || phase == .finishing {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        task?.cancel()
        transcript = ""
        teardown()
    }

    func dismissFailure() { failure = nil }

    private func fail(_ failure: Failure) {
        self.failure = failure
        phase = .idle
    }

    private func teardown() {
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        interruption = nil
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        phase = .idle
    }

    private func received(text: String?, final: Bool) {
        // A cancelled task still reports once; its text is not wanted.
        guard phase == .recording || phase == .finishing else { return }
        if let text { transcript = text }
        if final { gotFinal = true }
    }

    // MARK: Off the main actor
    //
    // The audio thread and the recognizer's queue call back here. Closures
    // formed inside a main-actor method would be main-actor isolated and trap
    // when called from there, so every callback is built in a nonisolated
    // function.

    /// Feeds the recognizer and the waveform from the audio thread.
    private final class Tap: @unchecked Sendable {
        private let request: SFSpeechAudioBufferRecognitionRequest
        private let levels: VoiceLevels
        private var peak = 0.0
        private var last = ProcessInfo.processInfo.systemUptime

        init(request: SFSpeechAudioBufferRecognitionRequest, levels: VoiceLevels) {
            self.request = request
            self.levels = levels
        }

        func handle(_ buffer: AVAudioPCMBuffer) {
            request.append(buffer)
            guard let channel = buffer.floatChannelData?[0] else { return }
            let level = LedgerVoiceWaveform.level(
                samples: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            peak = max(peak, level)
            let now = ProcessInfo.processInfo.systemUptime
            if now - last >= LedgerVoiceWaveform.interval {
                levels.append(level: peak, at: now)
                peak = 0
                last = now
            }
        }
    }

    private nonisolated static func tapBlock(_ tap: Tap) -> AVAudioNodeTapBlock {
        { buffer, _ in tap.handle(buffer) }
    }

    private nonisolated static func resultHandler(
        for recorder: LedgerAgentVoiceRecorder
    ) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak recorder] result, error in
            let text = result?.bestTranscription.formattedString
            // An error ends the task as surely as a final result: a silent
            // recording ends with "no speech detected".
            let final = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in recorder?.received(text: text, final: final) }
        }
    }

    private nonisolated static func requestSpeech() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    /// Asks for what is missing, one permission at a time; nil when both are
    /// granted.
    private nonisolated static func authorize() async -> Failure? {
        var speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .notDetermined { speech = await requestSpeech() }
        guard speech == .authorized else { return .speechDenied }
        var microphone = AVAudioApplication.shared.recordPermission
        if microphone == .undetermined {
            microphone = await AVAudioApplication.requestRecordPermission() ? .granted : .denied
        }
        return microphone == .granted ? nil : .microphoneDenied
    }

    /// The app's language first: a Chinese interface listens for Mandarin
    /// whatever region the phone is set to.
    private static func recognizer() -> SFSpeechRecognizer? {
        let app = Bundle.main.preferredLocalizations.first ?? "zh-Hans"
        let wanted = app.hasPrefix("zh") ? Locale(identifier: "zh-CN") : Locale.current
        return SFSpeechRecognizer(locale: wanted) ?? SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    }
}
#endif
