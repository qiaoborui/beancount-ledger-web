#if os(iOS)
import SwiftUI

/// The waveform of the 账本助手's voice input: a history of bars that
/// slides left continuously, the newest growing out of the right edge.
/// Quiet stretches are rows of small dots and speech swells them into bars,
/// so the strip is never empty before anything is said.
///
/// It redraws itself on every frame from the level history, which is a
/// reference the recorder fills from the audio thread; nothing here goes
/// through SwiftUI state, so the rest of the composer does not re-render
/// at 60 fps.
struct LedgerVoiceStrip: View {
    let levels: LedgerAgentVoiceRecorder.VoiceLevels
    var bar: Color = BalancedPalette.ink
    var dot: Color = BalancedPalette.ruleStrong
    var height: CGFloat = 24
    /// Bars and the gaps between them, in points.
    var barWidth: CGFloat = 2
    var pitch: CGFloat = 4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Reduce Motion keeps the level history but redraws at the sampling
        // rate, so the strip steps instead of gliding.
        TimelineView(.animation(minimumInterval: reduceMotion ? LedgerVoiceWaveform.interval : nil)) { _ in
            Canvas { context, size in
                draw(context: &context, size: size, now: ProcessInfo.processInfo.systemUptime)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func draw(context: inout GraphicsContext, size: CGSize, now: TimeInterval) {
        let span = size.width / pitch * LedgerVoiceWaveform.interval + LedgerVoiceWaveform.interval
        let bars = levels.snapshot().bars(at: now, span: span)
        let midY = size.height / 2
        var oldestSlots = -1.0
        for entry in bars {
            oldestSlots = entry.slots
            let x = size.width - entry.slots * pitch - barWidth / 2
            guard x > -barWidth else { continue }
            let barHeight = max(barWidth, entry.height * size.height)
            let rect = CGRect(x: x - barWidth / 2, y: midY - barHeight / 2, width: barWidth, height: barHeight)
            // A bar that has not grown past a dot is drawn as one.
            let isDot = barHeight <= barWidth * 1.5
            context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(isDot ? dot : bar))
        }
        // Before the first level the strip is dots all the way across, on the
        // same grid as the bars, so the history scrolls over them.
        var slots = oldestSlots + 1
        while true {
            let x = size.width - slots * pitch - barWidth / 2
            if x < -barWidth { break }
            let rect = CGRect(x: x - barWidth / 2, y: midY - barWidth / 2, width: barWidth, height: barWidth)
            context.fill(Path(ellipseIn: rect), with: .color(dot))
            slots += 1
        }
    }
}

/// The recording timer, ticking from the moment the microphone opened.
struct LedgerVoiceClock: View {
    let recorder: LedgerAgentVoiceRecorder
    var color: Color = BalancedPalette.meta

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let elapsed = recorder.phase == .idle ? 0 : ProcessInfo.processInfo.systemUptime - recorder.startedUptime
            Text(LedgerVoiceTranscript.clock(recorder.startedUptime == 0 ? 0 : elapsed))
                .balancedFont(size: 14)
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }
}

/// The red dot that says the microphone is open.
struct LedgerVoiceDot: View {
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle().fill(Color.red).frame(width: 7, height: 7)
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

/// The dock's second row while a tapped recording runs: cancel, timer and
/// waveform, and confirm. The send circle is the dock's own, pinned over the
/// row's trailing corner, so the row leaves room for it.
struct LedgerVoiceBar: View {
    @ObservedObject var recorder: LedgerAgentVoiceRecorder
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onCancel) {
                Image(systemName: "xmark").font(.system(size: 15, weight: .medium))
                    .foregroundStyle(BalancedPalette.secondary)
                    .frame(width: 36, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消语音输入")
            .accessibilityIdentifier("ledger-agent-voice-cancel")

            HStack(spacing: 6) {
                LedgerVoiceDot()
                LedgerVoiceClock(recorder: recorder)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("正在录音")

            LedgerVoiceStrip(levels: recorder.levels)
                .frame(maxWidth: .infinity)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08)],
                                     startPoint: .leading, endPoint: .trailing))

            Button(action: onConfirm) {
                Image(systemName: "checkmark").font(.system(size: 16, weight: .medium))
                    .foregroundStyle(BalancedPalette.ink)
                    .frame(width: 36, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("完成，文字放进输入框")
            .accessibilityIdentifier("ledger-agent-voice-confirm")
        }
        .padding(.leading, 4)
        .padding(.trailing, 44)
    }
}

/// The floating pill over the dock while the microphone button is held.
/// It is dark in both appearances, like the system's own recording cues.
struct LedgerVoicePill: View {
    @ObservedObject var recorder: LedgerAgentVoiceRecorder

    var body: some View {
        HStack(spacing: 10) {
            LedgerVoiceDot()
            LedgerVoiceStrip(levels: recorder.levels, bar: .white, dot: .white.opacity(0.32), height: 20)
                .frame(width: 96)
            LedgerVoiceClock(recorder: recorder, color: .white.opacity(0.72))
            Text("松开插入").balancedFont(size: 14).foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
        .background(Capsule().fill(Color(red: 0.08, green: 0.06, blue: 0.05)))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在录音，松开后文字放进输入框")
        .accessibilityIdentifier("ledger-agent-voice-pill")
    }
}
#endif
