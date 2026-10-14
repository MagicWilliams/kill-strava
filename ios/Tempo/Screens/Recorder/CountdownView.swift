import SwiftUI

/// 3-2-1 (#126, frame 3). The recorder is already in `.countdown`: the workout session is
/// prepared and GPS is warming. This screen only decides *when* the clock starts — at zero,
/// or at the first tap — by sending `.countdownDone`. Cancel sends `.discard`, which the
/// reducer turns back into idle with nothing recorded.
struct CountdownView: View {
    let startedAt: Date
    /// Cancel: the root presentation re-opens the pre-run sheet once this cover is gone.
    let onCancel: () -> Void

    @Environment(WorkoutRecorder.self) private var recorder
    @Environment(\.units) private var units
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var permission = LocationPermission()
    @StateObject private var gps = GPSSignalWatcher()
    @State private var count = PreRun.Countdown.seconds

    var body: some View {
        ZStack {
            Tokens.Palette.canvas.ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer(minLength: 0)
                if let eyebrow {
                    SectionLabel(eyebrow, color: Tokens.Palette.accentText)
                        .multilineTextAlignment(.center)
                }
                dial
                if recorder.state.kind != .treadmill {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        GPSPill(signal: gps.signal(access: permission.access, now: context.date))
                    }
                }
                Text("Tap anywhere to start now")
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Tokens.Space.xl2)
        }
        .contentShape(Rectangle())
        .onTapGesture { go() }
        .safeAreaInset(edge: .bottom) {
            QuietButton(title: "Cancel") { onCancel() }
                .padding(.horizontal, Tokens.Space.xl)
                .padding(.bottom, Tokens.Space.lg)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: count)
        .task(id: startedAt) { await tick() }
        .onChange(of: permission.access, initial: true) { _, access in gps.start(access: access) }
        .onDisappear { gps.stop() }
        .accessibilityAction(named: "Start now") { go() }
    }

    /// "6 MI TEMPO · TARGET 7:45 /MI" when the target is on; the run type otherwise.
    private var eyebrow: String? {
        let state = recorder.state
        if state.showsTarget, let target = state.target {
            let name = PreRun.name(of: target, units: units)
            guard let pace = target.paceSecPerMile, pace > 0 else { return name }
            return name + " · target " + units.formatPace(secondsPerMile: pace)
        }
        switch state.kind {
        case .outdoor: return "Outdoor run"
        case .treadmill: return "Treadmill"
        case .race: return "Race"
        }
    }

    private var dial: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            let shown = max(1, PreRun.Countdown.showing(elapsed: elapsed))
            ZStack {
                Circle().stroke(Tokens.Palette.elevated, lineWidth: 9)
                Circle()
                    .trim(from: 0, to: reduceMotion ? 1 : PreRun.Countdown.sweep(elapsed: elapsed))
                    .stroke(Tokens.Palette.voltMark, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle().fill(Tokens.Palette.volt).padding(24)
                Text("\(shown)")
                    .font(Tokens.Font.display(180))
                    .tracking(-4)
                    .foregroundStyle(Tokens.Palette.onVolt)
                    .contentTransition(.numericText(countsDown: true))
                    .accessibilityLabel("\(shown)")
            }
            .padding(4.5)
            .frame(width: 300, height: 300)
        }
    }

    /// One haptic per number, then go. Sleeps to whole seconds after `startedAt` rather than
    /// for a second at a time, so a slow frame never stretches the countdown.
    private func tick() async {
        for step in 0..<PreRun.Countdown.seconds {
            count = PreRun.Countdown.seconds - step
            let next = startedAt.addingTimeInterval(Double(step + 1))
            let wait = next.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if Task.isCancelled { return }
        }
        go()
    }

    /// The clock starts now. A second call is a no-op: the reducer only takes
    /// `.countdownDone` from `.countdown`.
    private func go() {
        guard case .countdown = recorder.state.phase else { return }
        count = 0
        Haptics.commit()
        recorder.send(.countdownDone(at: .now))
    }
}
