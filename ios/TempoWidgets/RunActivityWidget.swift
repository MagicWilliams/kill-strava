import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The run on the Lock Screen and in the Dynamic Island (#119, Figma "03 · Lock Screen +
/// Dynamic Island", frames 6a–6c).
///
/// Display only, like the other widgets: every string comes from `RunActivityDisplay`, and the
/// one control is Pause or Resume, sent to the app as a `LiveActivityIntent`. There is no End
/// and no Discard here, by design (David, #125): this screen is reachable through a pocket.
///
/// Digit sizes are the ones David asked for after review (all Roboto Mono Medium): 22 pt for
/// time, distance and pace on the Lock Screen; 20 pt time and distance and 34 pt current pace
/// in the expanded island. Labels 11 pt, units 12 pt.
struct RunActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RunActivityAttributes.self) { context in
            RunLockScreenView(display: RunActivityDisplay(context.state, isStale: context.isStale))
                .activityBackgroundTint(Tokens.Palette.canvas)
                .activitySystemActionForegroundColor(Tokens.Palette.textPrimary)
        } dynamicIsland: { context in
            let display = RunActivityDisplay(context.state, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        RunLabel("Time")
                        RunClock(display: display, size: 20)
                    }
                    .padding(.leading, 4)
                    .island()
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        RunLabel("Distance")
                        RunNumber(value: display.distance, unit: display.distanceUnit, size: 20)
                    }
                    .padding(.trailing, 4)
                    .island()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .bottom, spacing: Tokens.Space.md) {
                        VStack(alignment: .leading, spacing: 2) {
                            RunLabel(display.offersResume ? "Paused" : "Current pace",
                                     color: display.offersResume ? Tokens.Palette.warning : Tokens.Palette.textTertiary)
                            RunNumber(value: display.pace, unit: display.paceSuffix, size: 34)
                            if let vs = display.vsTarget {
                                VsTargetText(value: vs, trend: display.trend)
                            } else if display.stage == .ended || display.stage == .interrupted {
                                Text(display.status)
                                    .font(Tokens.Font.ui(12, .medium))
                                    .foregroundStyle(Tokens.Palette.textSecondary)
                            }
                        }
                        Spacer(minLength: 0)
                        RunControl(display: display)
                    }
                    .padding(.horizontal, 4)
                    .island()
                }
            } compactLeading: {
                Image(systemName: display.offersResume ? "pause.fill" : "figure.run")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Tokens.Palette.voltMark)
                    .island()
            } compactTrailing: {
                // Current pace, not the clock (#125, question 5): the clock is on his wrist and
                // in the expanded view; pace is what he glances down for.
                Text(display.pace)
                    .font(Tokens.Font.mono(14))
                    .foregroundStyle(display.offersPause ? Tokens.Palette.accentText : Tokens.Palette.textSecondary)
                    .contentTransition(.numericText())
                    .island()
            } minimal: {
                SplitRing(progress: display.splitProgress, paused: display.offersResume)
                    .island()
            }
            .keylineTint(Tokens.Palette.volt)
        }
    }
}

// MARK: - Lock Screen (6a running, 6b paused)

struct RunLockScreenView: View {
    let display: RunActivityDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.md) {
            HStack(spacing: 6) {
                Image(systemName: "figure.run")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Tokens.Palette.accentText)
                RunLabel("Tempo", color: Tokens.Palette.accentText)
                RunLabel("· " + display.status, color: statusColor)
                    .lineLimit(1)
                Spacer(minLength: Tokens.Space.sm)
                if let vs = display.vsTarget {
                    HStack(spacing: 4) {
                        RunLabel("Vs target")
                        VsTargetText(value: vs, trend: display.trend)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: Tokens.Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    RunLabel("Time")
                    RunClock(display: display, size: 22)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    RunLabel("Distance")
                    RunNumber(value: display.distance, unit: display.distanceUnit, size: 22)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    RunLabel("Pace")
                    RunNumber(value: display.pace, unit: display.paceSuffix, size: 22)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                RunControl(display: display)
            }
        }
        .padding(Tokens.Space.lg)
    }

    /// Paused is information, not an alarm: warning, never danger — as on the live screen.
    private var statusColor: Color {
        switch display.stage {
        case .paused: Tokens.Palette.warning
        case .running: Tokens.Palette.textSecondary
        case .interrupted, .ended: Tokens.Palette.textPrimary
        }
    }
}

// MARK: - Pieces

/// The 11 pt mono eyebrow over each number, the live screen's `SectionLabel`.
private struct RunLabel: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color = Tokens.Palette.textTertiary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(Tokens.Font.mono(11))
            .tracking(1.5)
            .foregroundStyle(color)
    }
}

/// The elapsed clock. Ticks by itself on the Lock Screen; frozen once the run has ended.
private struct RunClock: View {
    let display: RunActivityDisplay
    let size: CGFloat

    var body: some View {
        Text(timerInterval: display.clock, pauseTime: display.clockStoppedAt, countsDown: false, showsHours: true)
            .font(Tokens.Font.mono(size))
            .foregroundStyle(Tokens.Palette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// A number with its unit after it at 12 pt.
private struct RunNumber: View {
    let value: String
    let unit: String
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(Tokens.Font.mono(size))
                .foregroundStyle(Tokens.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(unit)
                .font(Tokens.Font.ui(12, .medium))
                .foregroundStyle(Tokens.Palette.textSecondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// Ahead and on pace are good news; behind is information. The live screen's tints.
private struct VsTargetText: View {
    let value: String
    let trend: RunActivityDisplay.Trend

    var body: some View {
        Text(value)
            .font(Tokens.Font.mono(12))
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private var color: Color {
        switch trend {
        case .ahead, .onPace: Tokens.Palette.success
        case .behind: Tokens.Palette.warning
        case .unknown: Tokens.Palette.textSecondary
        }
    }
}

/// Pause or Resume, whichever the reducer would accept from this screen; nothing otherwise.
private struct RunControl: View {
    let display: RunActivityDisplay

    var body: some View {
        if display.offersPause {
            Button(intent: PauseRunIntent()) { face("pause.fill") }
                .buttonStyle(.plain)
                .accessibilityLabel("Pause")
        } else if display.offersResume {
            Button(intent: ResumeRunIntent()) { face("play.fill") }
                .buttonStyle(.plain)
                .accessibilityLabel("Resume")
        }
    }

    /// Volt fill with `onVolt` on top: the live screen's Pause and Resume, smaller.
    private func face(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(Tokens.Palette.onVolt)
            .frame(width: 44, height: 44)
            .background(Circle().fill(Tokens.Palette.volt))
    }
}

/// The minimal island: a ring that fills through each mile or kilometre and empties at the
/// split, around the run's state.
private struct SplitRing: View {
    let progress: Double
    let paused: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Tokens.Palette.elevated, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Tokens.Palette.voltMark, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: paused ? "pause.fill" : "figure.run")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(paused ? Tokens.Palette.warning : Tokens.Palette.voltMark)
        }
        .frame(width: 22, height: 22)
    }
}

private extension View {
    /// The island is black in both appearances, so the palette resolves its dark values
    /// there whatever the phone is set to.
    func island() -> some View { environment(\.colorScheme, .dark) }
}

// MARK: - Previews

private extension RunActivityState {
    static func sample(_ stage: Stage) -> RunActivityState {
        RunActivityState(stage: stage, startedAt: .now.addingTimeInterval(-2_843), endedAt: nil,
                         distanceM: 9_013, currentPaceS: stage == .running ? 461 : nil,
                         targetPaceS: 450, vsTargetS: 8, units: .mi)
    }
}

#Preview("Lock Screen", as: .content, using: RunActivityAttributes(recordingID: UUID())) {
    RunActivityWidget()
} contentStates: {
    RunActivityState.sample(.running)
    RunActivityState.sample(.paused)
}

#Preview("Island expanded", as: .dynamicIsland(.expanded), using: RunActivityAttributes(recordingID: UUID())) {
    RunActivityWidget()
} contentStates: {
    RunActivityState.sample(.running)
    RunActivityState.sample(.paused)
}

#Preview("Island compact", as: .dynamicIsland(.compact), using: RunActivityAttributes(recordingID: UUID())) {
    RunActivityWidget()
} contentStates: {
    RunActivityState.sample(.running)
}

#Preview("Island minimal", as: .dynamicIsland(.minimal), using: RunActivityAttributes(recordingID: UUID())) {
    RunActivityWidget()
} contentStates: {
    RunActivityState.sample(.running)
}
