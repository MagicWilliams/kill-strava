import SwiftUI

/// The live run screen (#127, Figma "02 · Live run", frames 4a–4d).
///
/// A fixed layout, read at arm's length mid-stride: TIME big, DISTANCE and CURRENT PACE under
/// it, then average pace, heart rate (or the last split) and vs-target small. Every number
/// comes from `WorkoutRecorder.snapshot` through `LiveRunDisplay`, and every tap goes back
/// through `send`: this view never decides anything about the run, it only shows it and
/// passes his hands on.
///
/// The contract with the Start flow (#126, PR #169): `LiveRunView()` with no arguments,
/// reading the app's one recorder from the environment. It is shown full-screen by
/// `runRecorder(...)` whenever the recorder's phase calls for the live screen, so no swipe can
/// leave a live run, and it goes away when the recorder is reset.
struct LiveRunView: View {
    @Environment(WorkoutRecorder.self) private var recorder

    var body: some View {
        let snapshot = recorder.snapshot
        let display = LiveRunDisplay(snapshot)
        ZStack {
            Tokens.Palette.canvas.ignoresSafeArea()
            switch display.stage {
            case .countdown, .running:
                LiveRunLayout(display: display, snapshot: snapshot, send: { recorder.send($0) })
            case .paused:
                // #128 replaces this branch with frame 5a (paused, with discard).
                LiveRunLayout(display: display, snapshot: snapshot, send: { recorder.send($0) })
            case .recovering:
                // #128 replaces this branch with the "We kept your run" prompt (#115).
                LiveRunLayout(display: display, snapshot: snapshot, send: { recorder.send($0) })
            case .over:
                // #129 replaces this with the save screen.
                RunEndedHandOff()
            }
        }
    }
}

// MARK: - The layout

/// Frame 4a, driven by values only, so it previews without a recorder.
struct LiveRunLayout: View {
    let display: LiveRunDisplay
    let snapshot: RecorderSnapshot
    let send: @MainActor (RecorderEvent) -> Void

    /// Pocket lock (frame 4d). The screen's own, not the run's: locking changes nothing about
    /// the recording, it only stops a thigh from pressing Pause.
    @State private var locked = false
    @State private var banner: LiveRunDisplay.SplitBanner?
    /// Splits the screen has already announced, so coming back to it doesn't replay one.
    @State private var seenSplits: Int?
    @State private var bannerTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.bottom, Tokens.Space.lg)
            numbers
                .allowsHitTesting(false)
            Spacer(minLength: Tokens.Space.lg)
            controls
        }
        .padding(.horizontal, Tokens.Space.xl)
        .padding(.top, Tokens.Space.sm)
        .padding(.bottom, Tokens.Space.xl2)
        .overlay(alignment: .top) { bannerView }
        .onAppear { seenSplits = snapshot.completedSplits }
        .onChange(of: snapshot.completedSplits) { _, _ in raiseBannerIfNew() }
        .onDisappear { bannerTask?.cancel() }
        .motion(Motion.reveal, value: locked)
        .motion(Motion.reveal, value: display.targetChip)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: Tokens.Space.sm) {
            StatusPill(status: display.status)
            if display.stage == .paused { Tag(text: "Paused", fg: Tokens.Palette.warning, bg: Tokens.Well.warning.insetFill) }
            Spacer()
            if !locked, let visible = display.targetChip.toggled {
                TargetChipButton(shown: display.targetChip == .shown) {
                    Haptics.select()
                    send(.setTargetVisible(visible))
                }
            }
            if !locked {
                RoundIconButton(symbol: "lock.fill", label: "Lock screen") {
                    Haptics.select()
                    locked = true
                }
            }
        }
        .frame(minHeight: 44)
    }

    // MARK: Numbers

    private var numbers: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xl) {
            if let line = display.targetLine {
                Text(line)
                    .font(Tokens.Font.ui(15, .semibold))
                    .foregroundStyle(Tokens.Palette.accentText)
                    .lineLimit(1)
                    .transition(.opacity)
            }

            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                SectionLabel("Time")
                BigNumber(display.time, size: 92)
                    .accessibilityLabel("Time \(display.time)")
            }

            HStack(alignment: .top, spacing: Tokens.Space.lg) {
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    SectionLabel("Distance")
                    BigNumber(display.distance, size: 56)
                    Text(display.distanceUnit)
                        .font(Tokens.Font.ui(13, .medium))
                        .foregroundStyle(Tokens.Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    SectionLabel("Current pace")
                    BigNumber(display.currentPace, size: 56)
                    Text(display.paceSuffix)
                        .font(Tokens.Font.ui(13, .medium))
                        .foregroundStyle(Tokens.Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }

            HStack(spacing: Tokens.Space.sm) {
                MetricTile(tile: LiveRunDisplay.Tile(label: "Avg pace", value: display.averagePace,
                                                     detail: display.paceSuffix))
                MetricTile(tile: display.secondary)
                if let vs = display.vsTarget {
                    MetricTile(tile: vs.tile, valueColor: color(for: vs.trend))
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Ahead is good news and behind is information, not an alarm: warning, never danger.
    private func color(for trend: LiveRunDisplay.VsTarget.Trend) -> Color {
        switch trend {
        case .ahead, .onPace: Tokens.Palette.success
        case .behind: Tokens.Palette.warning
        case .unknown: Tokens.Palette.textPrimary
        }
    }

    // MARK: Controls

    /// Big targets for sweaty hands. Locked, the only live control is the one that unlocks,
    /// and it takes a hold, for the same pocket.
    @ViewBuilder private var controls: some View {
        if locked {
            VStack(spacing: Tokens.Space.sm) {
                HoldButton(symbol: "lock.open.fill", label: "Hold to unlock",
                           duration: LiveRunDisplay.holdToUnlockS,
                           fill: Tokens.Palette.surface, ink: Tokens.Palette.textPrimary,
                           ring: Tokens.Palette.voltMark) {
                    locked = false
                }
                Text("Screen locked")
                    .font(Tokens.Font.ui(13, .medium))
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity)
        } else {
            // What is offered is what the reducer accepts (`LiveRunDisplay.Stage`).
            HStack(spacing: Tokens.Space.xl4) {
                if display.stage.offersPause { pauseButton }
                if display.stage.offersResume { resumeButton }
                if display.stage.offersHoldToEnd { endButton }
            }
            .frame(maxWidth: .infinity, minHeight: HoldButton.diameter + 28)
        }
    }

    private var pauseButton: some View {
        ControlButton(symbol: "pause.fill", label: "Pause",
                      fill: Tokens.Palette.volt, ink: Tokens.Palette.onVolt) {
            send(.pause(.manual(.liveScreen), at: Date()))
        }
    }

    private var resumeButton: some View {
        ControlButton(symbol: "play.fill", label: "Resume",
                      fill: Tokens.Palette.volt, ink: Tokens.Palette.onVolt) {
            send(.resume(.manual(.liveScreen), at: Date()))
        }
    }

    /// Hold-to-end, on the live screen itself (David, #125 question 6). The Lock Screen can
    /// only pause and resume; this is the one place a run ends.
    private var endButton: some View {
        VStack(spacing: Tokens.Space.sm) {
            HoldButton(symbol: "stop.fill", label: "Hold to end",
                       duration: LiveRunDisplay.holdToEndS,
                       fill: Tokens.Well.danger.fill, ink: Tokens.Palette.danger,
                       ring: Tokens.Palette.danger) {
                send(.endRequested(.liveScreen, at: Date()))
            }
            Text("Hold to end")
                .font(Tokens.Font.ui(13, .medium))
                .foregroundStyle(Tokens.Palette.textSecondary)
        }
    }

    // MARK: Split banner (frame 4c)

    @ViewBuilder private var bannerView: some View {
        if let banner {
            HStack(spacing: Tokens.Space.md) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tokens.Palette.onVolt)
                Text(banner.title)
                    .font(Tokens.Font.ui(15, .bold))
                    .foregroundStyle(Tokens.Palette.onVolt)
                Spacer(minLength: Tokens.Space.sm)
                Text(banner.pace)
                    .font(Tokens.Font.mono(15))
                    .foregroundStyle(Tokens.Palette.onVolt)
                if let average = banner.average {
                    Text(average)
                        .font(Tokens.Font.mono(13))
                        .foregroundStyle(Tokens.Palette.onVolt.opacity(0.75))
                }
            }
            .padding(.horizontal, Tokens.Space.lg)
            .padding(.vertical, Tokens.Space.md)
            .background(Tokens.Palette.volt)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
            .padding(.horizontal, Tokens.Space.lg)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .onTapGesture { dismissBanner() }
        }
    }

    private func raiseBannerIfNew() {
        let seen = seenSplits ?? 0
        seenSplits = snapshot.completedSplits
        guard let next = LiveRunDisplay.splitBanner(seenSplits: seen, snapshot: snapshot) else { return }
        withAnimation(Motion.reveal) { banner = next }
        bannerTask?.cancel()
        bannerTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(LiveRunDisplay.splitBannerS))
            guard !Task.isCancelled else { return }
            dismissBanner()
        }
    }

    private func dismissBanner() {
        withAnimation(Motion.reveal) { banner = nil }
    }
}

// MARK: - Run over

/// The minimum between the end of a run and the save screen (#129), so a run that reaches it
/// before #129 lands is never stranded: Save puts it in Health with no journal, which is what
/// a race does anyway. #129 replaces this view wholesale.
private struct RunEndedHandOff: View {
    @Environment(WorkoutRecorder.self) private var recorder

    var body: some View {
        let snapshot = recorder.snapshot
        let display = LiveRunDisplay(snapshot)
        VStack(spacing: Tokens.Space.xl) {
            Spacer()
            Text("Run ended").display(30)
            HStack(spacing: Tokens.Space.xl2) {
                StatTile(value: display.time, label: "Time")
                StatTile(value: display.distance, label: display.distanceUnit)
            }
            Spacer()
            switch snapshot.phase {
            case .ending(.review):
                PrimaryButton(title: "Save to Apple Health") { recorder.send(.endConfirmed) }
            case .ending(.saving):
                PrimaryButton(title: "Saving\u{2026}", loading: true)
            case .ending(.failed(let reason)):
                Text(reason)
                    .font(Tokens.Font.ui(14))
                    .foregroundStyle(Tokens.Palette.danger)
                    .multilineTextAlignment(.center)
                PrimaryButton(title: "Try again") { recorder.send(.endConfirmed) }
            default:
                // Back to idle closes the cover (#126's contract).
                PrimaryButton(title: "Done") { recorder.reset() }
            }
        }
        .padding(Tokens.Space.xl2)
    }
}

// MARK: - Parts

/// A live number in Roboto Mono: every digit the same width, so a ticking clock doesn't
/// jitter (#125, question 1). Scales down rather than wrapping when a marathon's "3:05:42"
/// meets a narrow phone.
private struct BigNumber: View {
    let text: String
    let size: CGFloat

    init(_ text: String, size: CGFloat) {
        self.text = text
        self.size = size
    }

    var body: some View {
        Text(text)
            .font(Tokens.Font.mono(size))
            .foregroundStyle(Tokens.Palette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .contentTransition(.numericText())
    }
}

/// The small tiles under the big numbers.
private struct MetricTile: View {
    let tile: LiveRunDisplay.Tile
    var valueColor: Color = Tokens.Palette.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            SectionLabel(tile.label)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(tile.value)
                .font(Tokens.Font.mono(24))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(tile.detail ?? " ")
                .font(Tokens.Font.ui(12))
                .foregroundStyle(Tokens.Palette.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.md)
        .background(Tokens.Well.neutral.fill)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct StatusPill: View {
    let status: LiveRunDisplay.Status

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 8, height: 8)
            Text(status.text)
                .font(Tokens.Font.ui(13, .semibold))
                .foregroundStyle(Tokens.Palette.textPrimary)
        }
        .padding(.horizontal, Tokens.Space.md)
        .padding(.vertical, 7)
        .background(Tokens.Palette.surface)
        .clipShape(Capsule())
    }

    private var dot: Color {
        switch status.tone {
        case .good: Tokens.Palette.success
        case .waiting: Tokens.Palette.warning
        case .neutral: Tokens.Palette.textTertiary
        }
    }
}

/// "Target" on, "Run free" off: one tap either way, mid-run (#125).
private struct TargetChipButton: View {
    let shown: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: shown ? "scope" : "eye.slash")
                    .font(.system(size: 13, weight: .semibold))
                Text(shown ? "Target" : "Run free")
                    .font(Tokens.Font.ui(13, .semibold))
            }
            .foregroundStyle(shown ? Tokens.Palette.onVolt : Tokens.Palette.textPrimary)
            .padding(.horizontal, Tokens.Space.md)
            .frame(minHeight: 44)
            .background(shown ? Tokens.Palette.volt : Tokens.Palette.surface)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(Pressable(haptic: false))
        .accessibilityLabel(shown ? "Hide target" : "Show target")
    }
}

private struct RoundIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Tokens.Palette.textPrimary)
                .frame(width: 44, height: 44)
                .background(Tokens.Palette.surface)
                .clipShape(Circle())
        }
        .buttonStyle(Pressable(haptic: false))
        .accessibilityLabel(label)
    }
}

/// Pause and Resume: one tap, because pausing early is never the expensive mistake.
private struct ControlButton: View {
    let symbol: String
    let label: String
    let fill: Color
    let ink: Color
    let action: () -> Void

    var body: some View {
        VStack(spacing: Tokens.Space.sm) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(ink)
                    .frame(width: HoldButton.diameter, height: HoldButton.diameter)
                    .background(fill)
                    .clipShape(Circle())
            }
            .buttonStyle(Pressable())
            .accessibilityLabel(label)
            Text(label)
                .font(Tokens.Font.ui(13, .medium))
                .foregroundStyle(Tokens.Palette.textSecondary)
                .accessibilityHidden(true)
        }
    }
}

/// A round button that acts only after being held for `duration`, with a ring that fills
/// while the finger is down and a haptic at both ends: one when the hold starts, so he knows
/// it registered, and a heavier one when it lands. Lifting early drains the ring and does
/// nothing.
///
/// The ring animates under Reduce Motion too. It isn't decoration: it is the only way to see
/// how much longer to hold.
struct HoldButton: View {
    static let diameter: CGFloat = 92

    let symbol: String
    let label: String
    let duration: Double
    let fill: Color
    let ink: Color
    let ring: Color
    let action: () -> Void

    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            Circle().fill(fill)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(ring, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(3)
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(ink)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .contentShape(Circle())
        .onLongPressGesture(minimumDuration: duration, maximumDistance: 40) {
            Haptics.commit()
            action()
        } onPressingChanged: { pressing in
            if pressing {
                Haptics.tap()
                withAnimation(.linear(duration: duration)) { progress = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        // VoiceOver can't hold; its activate is already a deliberate double-tap.
        .accessibilityAction { action() }
    }
}

// MARK: - Previews

#Preview("Running, target on") {
    LiveRunLayout(display: LiveRunDisplay(.preview()), snapshot: .preview(), send: { _ in })
        .background(Tokens.Palette.canvas)
        .preferredColorScheme(.dark)
}

#Preview("Running free, light") {
    LiveRunLayout(display: LiveRunDisplay(.preview(targetShown: false, heartRate: nil)),
                  snapshot: .preview(targetShown: false, heartRate: nil), send: { _ in })
        .background(Tokens.Palette.canvas)
        .preferredColorScheme(.light)
}

private extension RecorderSnapshot {
    /// 3.42 mi into the tempo on frame 4a.
    static func preview(targetShown: Bool = true, heartRate: Int? = 158) -> RecorderSnapshot {
        let split = TrackMath.Split(index: 3, meters: Units.mi.splitMeters, durationS: 461,
                                    paceS: 461, elevationDeltaM: nil, isPartial: false)
        var snap = RecorderSnapshot.idle
        snap.phase = .running
        snap.elapsedS = 1_642
        snap.movingS = 1_642
        snap.distanceM = Units.mi.meters(distance: 3.42)
        snap.currentPaceS = 452
        snap.averagePaceS = 468
        snap.heartRateBPM = heartRate
        snap.secondary = RecorderSnapshot.secondary(heartRateBPM: heartRate, lastSplit: split)
        snap.lastSplit = split
        snap.completedSplits = 3
        snap.hasTarget = true
        snap.target = targetShown
            ? Target(title: "6 mi tempo", type: "tempo", distanceM: 9_656, paceS: 450, deltaS: 18)
            : nil
        snap.gpsLocked = true
        return snap
    }
}
