#if os(iOS)
@preconcurrency import AVFoundation
import Foundation

/// Keeps the app running while a 账本助手 turn works in the background.
///
/// iOS suspends a backgrounded app once its grace time runs out, and the
/// continued-processing task of iOS 26 can be expired whenever the system
/// wants the resources back. An app that is playing audio is never
/// suspended, so for the length of a turn this plays silence through a
/// session that mixes with other apps: music keeps playing, nothing shows in
/// Now Playing, and the session is let go as soon as the turn ends. This is
/// the same trade the Minis agent app makes, and the user can turn it off in
/// the assistant's settings.
///
/// A phone call or an app that takes the audio session exclusively can still
/// interrupt it. When the interruption ends the silence resumes; until then
/// `isHolding` is false, and `onLost` tells the caller so it can fall back on
/// the time iOS grants.
@MainActor
final class LedgerAgentKeepAlive {
    static let shared = LedgerAgentKeepAlive()

    /// True while the silence is playing.
    private(set) var isHolding = false
    /// Told when the session was taken away mid-turn.
    var onLost: (@MainActor () -> Void)?
    /// Told when the session came back after an interruption.
    var onRegained: (@MainActor () -> Void)?

    private var wanted = false
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var observers: [NSObjectProtocol] = []

    /// Starts holding; false when the audio session could not be had. Call
    /// it while the app is in front: iOS does not start new playback for a
    /// backgrounded app.
    @discardableResult
    func start() -> Bool {
        wanted = true
        if observers.isEmpty { observe() }
        guard !isHolding else { return true }
        return resume()
    }

    func stop() {
        wanted = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        tearDown()
        if isHolding || engine != nil {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        isHolding = false
    }

    // MARK: Playback

    private func resume() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            try play()
            isHolding = true
            return true
        } catch {
            tearDown()
            isHolding = false
            return false
        }
    }

    /// A one-second buffer of zeros, looped. The engine must really be
    /// rendering for iOS to count the app as playing, so the volume stays up
    /// and the samples stay silent.
    private func play() throws {
        tearDown()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else {
            throw CocoaError(.featureUnsupported)
        }
        buffer.frameLength = buffer.frameCapacity
        if let channel = buffer.floatChannelData?[0] {
            channel.initialize(repeating: 0, count: Int(buffer.frameLength))
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        self.engine = engine
        self.player = player
    }

    private func tearDown() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }

    // MARK: Interruptions

    private func observe() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                                            queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            MainActor.assumeIsolated { self?.interrupted(began: began) }
        })
        // A new route (headphones, CarPlay) or a restarted media server stops
        // the engine without an interruption.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        })
    }

    private func interrupted(began: Bool) {
        guard wanted else { return }
        if began {
            tearDown()
            if isHolding {
                isHolding = false
                onLost?()
            }
        } else {
            restart()
        }
    }

    private func restart() {
        guard wanted else { return }
        let was = isHolding
        if resume() {
            if !was { onRegained?() }
        } else if was {
            onLost?()
        }
    }
}
#endif
