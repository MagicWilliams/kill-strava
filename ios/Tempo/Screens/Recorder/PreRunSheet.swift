import SwiftUI

/// The pre-run sheet (#126): run type, what goes on screen, GPS, then Start. Frames 2a
/// (Outdoor, target on), 2b (location explainer) and 2c (Treadmill, target hidden) of the
/// signed-off "01 · Start → countdown" page.
///
/// Start hands a `RecorderState.Setup` to `onStart` and nothing else: the sheet never touches
/// the recorder. The root presentation (`runRecorder`) sends `.start` once the sheet is gone,
/// so the countdown is never presented on top of a sheet that is still leaving.
struct PreRunSheet: View {
    let request: PreRun.Request
    let onStart: (RecorderState.Setup) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.units) private var units
    @Environment(WorkoutRecorder.self) private var recorder

    @StateObject private var permission = LocationPermission()
    @StateObject private var gps = GPSSignalWatcher()

    @State private var kind: RecorderState.RunKind = .outdoor
    /// Default on when there is a session (#126).
    @State private var showTarget = true
    @State private var starting = false
    @AppStorage(CueSpeaker.enabledKey) private var voiceCues = true
    @AppStorage(PreRun.autoPauseKey) private var autoPause = false

    private var gate: PreRun.Gate { PreRun.gate(kind: kind, access: permission.access) }

    var body: some View {
        Group {
            if gate == .explain {
                LocationExplainer(
                    allow: { Task { await permission.request() } },
                    treadmill: { withAnimation(Motion.reveal) { kind = .treadmill } }
                )
            } else {
                setup
            }
        }
        .padding(.horizontal, Tokens.Space.xl)
        .padding(.top, Tokens.Space.xl2)
        .padding(.bottom, Tokens.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents(gate == .explain ? [.height(580)] : [.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Tokens.Radius.xl2)
        .presentationBackground(Tokens.Palette.surface)
        .onChange(of: permission.access, initial: true) { _, access in gps.start(access: access) }
        .onDisappear { gps.stop() }
    }

    // MARK: - Frame 2a / 2c

    private var setup: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.lg) {
            header
            SectionLabel("Run type")
            typePicker
            SectionLabel("On screen")
            settings
            if kind == .treadmill {
                indoorNote
            } else {
                gpsRow
            }
            if let failure = recorder.lastFailure {
                Text("The last start didn't take: \(failure)")
                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.warning)
            }
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                PrimaryButton(title: "Start", loading: starting, icon: "play.fill") { start() }
                    .disabled(!canStart)
                    .opacity(canStart ? 1 : 0.5)
                Text("3-2-1, then go. Tap the countdown to skip it.")
                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textTertiary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(PreRun.sheetTitle(request.target, units: units)).display(24)
                Text(subtitle).font(Tokens.Font.mono(12)).foregroundStyle(Tokens.Palette.textSecondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Tokens.Palette.elevated, in: Circle())
            }
            .buttonStyle(Pressable())
            .accessibilityLabel("Close")
        }
    }

    /// "Monday · 6 mi @ 7:45 /mi".
    private var subtitle: String {
        let day = Date.now.formatted(.dateTime.weekday(.wide))
        return [day, PreRun.targetLine(request.target, units: units)].compactMap { $0 }.joined(separator: " · ")
    }

    private var typePicker: some View {
        HStack(spacing: Tokens.Space.sm) {
            ForEach(PreRun.kinds(raceEligible: request.raceEligible), id: \.self) { option in
                TypeTile(kind: option, selected: option == kind) {
                    Haptics.select()
                    withAnimation(Motion.reveal) { kind = option }
                }
            }
        }
    }

    private var settings: some View {
        VStack(spacing: 0) {
            if let target = request.target {
                SettingRow(
                    icon: showTarget ? "scope" : "eye.slash",
                    title: "Show today's target",
                    detail: PreRun.targetToggleDetail(target, shown: showTarget, units: units),
                    isOn: $showTarget
                )
                divider
            }
            SettingRow(
                icon: "speaker.wave.2.fill",
                title: "Voice cue every \(units.name(plural: false))",
                detail: request.target != nil && showTarget ? "Split time and pace vs target" : "Split time and average pace",
                isOn: $voiceCues
            )
            divider
            SettingRow(
                icon: "pause.fill",
                title: "Auto-pause",
                detail: autoPause ? "On. Pauses when you stop, picks up when you run." : "Off. Pause yourself at lights.",
                isOn: $autoPause
            )
        }
        .background(Tokens.Palette.inset, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
    }

    private var divider: some View {
        Rectangle().fill(Tokens.Palette.divider).frame(height: 1)
    }

    @ViewBuilder private var gpsRow: some View {
        if case .blocked(let reason) = gate {
            VStack(alignment: .leading, spacing: Tokens.Space.sm) {
                GPSPill(signal: .off)
                Text(reason).font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let signal = gps.signal(access: permission.access, now: context.date)
                HStack(spacing: 10) {
                    GPSPill(signal: signal)
                    Text(signal.caption).font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var indoorNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "figure.run.treadmill").font(.system(size: 15))
            Text("Indoors, distance comes from the phone's motion sensors. At the end you can type in what the treadmill said.")
                .font(Tokens.Font.ui(12))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Tokens.Palette.info)
        .padding(.vertical, 12).padding(.horizontal, 14)
        .background(Tokens.Well.cool.insetFill, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
    }

    // MARK: - Start

    private var canStart: Bool {
        if case .blocked = gate { return false }
        return !starting
    }

    /// Health's write prompt comes here, the first time, when the reason is obvious (#110):
    /// HealthKit shows a sheet only for types not yet decided, so on every later run this is
    /// a no-op. A refusal doesn't stop the run — the recorder reports a session it can't
    /// save as `lastFailure`, which this sheet shows when it comes back.
    private func start() {
        starting = true
        Task {
            let health = HealthService()
            if !health.canSaveWorkouts { try? await health.requestRecorderAuthorization() }
            let setup = RecorderState.Setup(
                kind: kind,
                target: request.target,
                showTarget: showTarget,
                autoPause: autoPause
            )
            Haptics.commit()
            starting = false
            onStart(setup)
        }
    }
}

// MARK: - Frame 2b

/// Before iOS asks (#110). The system prompt appears once, ever; "Don't Allow" on a prompt
/// that came out of nowhere can only be undone in Settings. So the reason comes first, and
/// Continue is what fires the prompt.
private struct LocationExplainer: View {
    let allow: () -> Void
    let treadmill: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.lg) {
            Image(systemName: "location.fill")
                .font(.system(size: 26))
                .foregroundStyle(Tokens.Palette.accentText)
                .frame(width: 64, height: 64)
                .background(Tokens.Well.accent.insetFill, in: Circle())
            Text("Map your runs").display(24)
            Text("Tempo uses your location only while you're recording, to measure distance and draw the route.")
                .font(Tokens.Font.ui(15, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                point("checkmark", "Only during a run. Never in the background otherwise.")
                point("heart.fill", "Routes save to Apple Health on this phone.")
                point("lock.fill", "Change it any time in Settings \u{2192} Tempo.")
            }
            Spacer(minLength: 0)
            VStack(spacing: Tokens.Space.xs) {
                PrimaryButton(title: "Continue", action: allow)
                QuietButton(title: "Run on a treadmill instead", action: treadmill)
            }
        }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Tokens.Palette.success)
                .frame(width: 16)
            Text(text).font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
        }
    }
}

// MARK: - Parts

/// One option in the run-type picker. Volt fill marks the choice.
private struct TypeTile: View {
    let kind: RecorderState.RunKind
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
                    .frame(height: 24)
                Text(title).font(Tokens.Font.ui(13, .semibold))
                Text(detail).font(Tokens.Font.mono(10)).opacity(selected ? 0.7 : 1)
                    .foregroundStyle(selected ? Tokens.Palette.onVolt : Tokens.Palette.textTertiary)
            }
            .foregroundStyle(selected ? Tokens.Palette.onVolt : Tokens.Palette.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14).padding(.horizontal, 8)
            .background(selected ? Tokens.Palette.volt : Tokens.Palette.inset,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(haptic: false))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var symbol: String {
        switch kind {
        case .outdoor: "location.fill"
        case .treadmill: "figure.run.treadmill"
        case .race: "flag.fill"
        }
    }

    private var title: String {
        switch kind {
        case .outdoor: "Outdoor"
        case .treadmill: "Treadmill"
        case .race: "Race"
        }
    }

    private var detail: String {
        switch kind {
        case .outdoor: "GPS"
        case .treadmill: "Motion"
        case .race: "Race day"
        }
    }
}

/// A row in the "On screen" group: icon, title, one line of why, toggle.
private struct SettingRow: View {
    let icon: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: Tokens.Space.md) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(isOn ? Tokens.Palette.textSecondary : Tokens.Palette.textTertiary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Tokens.Font.ui(15, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
                    Text(detail).font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(Tokens.Palette.voltMark)
        .padding(.vertical, 12).padding(.horizontal, 14)
        .sensoryFeedback(.selection, trigger: isOn)
    }
}

/// Component "GPS pill": three bars and a word, tinted by state.
struct GPSPill: View {
    let signal: PreRun.Signal

    var body: some View {
        HStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < signal.bars ? ink : Tokens.Palette.elevated)
                        .frame(width: 3, height: CGFloat(5 + i * 3))
                }
            }
            Text(signal.label).font(Tokens.Font.ui(12, .semibold)).foregroundStyle(ink)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(well.insetFill, in: Capsule())
        .motion(Motion.reveal, value: signal.bars)
        .accessibilityElement(children: .combine)
    }

    private var ink: Color {
        switch signal {
        case .strong: Tokens.Palette.success
        case .weak, .searching: Tokens.Palette.warning
        case .off: Tokens.Palette.danger
        }
    }

    private var well: Tokens.Well {
        switch signal {
        case .strong: .success
        case .weak, .searching: .warning
        case .off: .danger
        }
    }
}

extension RecorderState.SessionTarget {
    /// Today's session as a run carries it: a copy taken at the tap, so a plan regenerated
    /// mid-run can't move what the run is judged against (`SessionTarget`).
    init(_ session: SessionInfo) {
        self.init(
            sessionID: session.id,
            type: session.type,
            title: session.title,
            distanceM: session.target_distance_m,
            paceSecPerMile: session.target_pace_sec
        )
    }
}
