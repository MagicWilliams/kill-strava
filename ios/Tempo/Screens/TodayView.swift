import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var router: TabRouter
    @Environment(\.zoomNamespace) private var zoom

    var body: some View {
        Screen(title: "Today", subtitle: Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day())) {
            dataWarning
            readiness
            session
            tomorrow
            week
            lastRun
        }
        .refreshable { await store.refresh() }
    }

    /// Says out loud when the numbers below aren't the corrected record — a fallback to raw
    /// Health data changes distances the athlete already fixed, and used to do it silently.
    @ViewBuilder private var dataWarning: some View {
        if let warning = store.dataWarning {
            Card(padding: 12, well: .warning) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(Tokens.Palette.warning)
                    Text(warning)
                        .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
            .motion(Motion.reveal, value: warning)
        }
    }

    /// Real readiness from the load model — taps into the full breakdown.
    private var readiness: some View {
        Button { router.openReadiness() } label: {
            Card {
                HStack(spacing: 16) {
                    ReadinessRing(value: Double(store.fitness?.readiness ?? 50) / 100)
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel("Readiness", color: Tokens.Palette.accentText)
                        Text(store.fitness?.label ?? "Warming up").display(22)
                        Text(store.fitness?.caption ?? "Syncing your training history…")
                            .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(Tokens.Palette.textTertiary)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(Pressable())
    }

    /// Once today is banked (or a rest day), tomorrow gets a preview.
    @ViewBuilder private var tomorrow: some View {
        let todayDone = store.todaySession?.status == "done" || (store.plan != nil && store.todaySession == nil)
        if todayDone,
           let tomorrowDate = RunStore.cal.date(byAdding: .day, value: 1, to: .now),
           let next = store.sessions.first(where: { $0.date == PlanDates.day.string(from: tomorrowDate) && $0.type != "rest" }) {
            Card(padding: 14, well: well(for: next)) {
                HStack {
                    SectionLabel("Tomorrow")
                    Spacer()
                    sessionTag(next)
                }
                Text(next.title ?? next.type.capitalized)
                    .font(Tokens.Font.ui(16, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
                if let detail = next.detail {
                    Text(detail).font(Tokens.Font.mono(12)).foregroundStyle(Tokens.Palette.textSecondary)
                }
            }
        }
    }

    @ViewBuilder private var session: some View {
        if store.plan == nil {
            noPlanCard
        } else if let s = store.todaySession {
            sessionCard(s)
        } else {
            restCard
        }
    }

    /// What a day costs you, as a colour. Scanning down the screen — or later, down the Plan
    /// list — the tint tells you the shape of the week before you read a word of it.
    private func well(for s: SessionInfo) -> Tokens.Well {
        if s.status == "done" { return .success }
        if s.isQuality { return .warm }
        if s.type == "long" { return .cool }
        return .neutral
    }

    private var noPlanCard: some View {
        Card(well: .accent) {
            SectionLabel("Today's session", color: Tokens.Palette.accentText)
            Text("No plan yet").display(24)
            Text("Your coach reads your real history first, proposes a goal, and the plan builds from what the data supports.")
                .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
            PrimaryButton(title: "Talk to Coach") { router.showCoach() }
        }
    }

    private var restCard: some View {
        Card(well: .calm) {
            SectionLabel("Today's session")
            Text("Rest day").display(24)
            Text("Recovery is training. Tomorrow's session banks what today absorbs.")
                .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
        }
    }

    private func sessionCard(_ s: SessionInfo) -> some View {
        Card(well: well(for: s)) {
            HStack {
                SectionLabel("Today's session", color: Tokens.Palette.accentText)
                Spacer()
                sessionTag(s)
            }
            Text(s.title ?? s.type.capitalized).display(24)
            if let detail = s.detail {
                Text(detail).font(Tokens.Font.mono(14)).foregroundStyle(Tokens.Palette.textSecondary)
            }
            if s.adapted, let note = s.adaptation_note {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11)).foregroundStyle(Tokens.Palette.info)
                    Text(note).font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.info)
                }
            }
            HStack(spacing: 18) {
                if let miles = s.targetMiles { metric("DISTANCE", String(format: "%.1f mi", miles)) }
                if let pace = s.target_pace_sec { metric("TARGET", PaceModel.format(pace) + " /mi") }
            }
            if s.status == "done" {
                doneRow(s)
                takeawayPreview(s)
            } else if needsCheckIn(s) {
                checkInRow
            } else if store.todayCheckIn?.feelsOk == false {
                Text("You flagged something's off today — the coach knows. Adjust or skip guilt-free.")
                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.warning)
            }
        }
        .motion(Motion.reveal, value: s.status)
    }

    private func sessionTag(_ s: SessionInfo) -> Tag {
        if s.isQuality { return Tag(text: "quality", fg: Tokens.Palette.onVolt, bg: Tokens.Palette.volt) }
        if s.type == "long" { return Tag(text: "long run", fg: Tokens.Palette.info, bg: Tokens.Well.cool.insetFill) }
        return Tag(text: s.type, fg: Tokens.Palette.success, bg: Tokens.Well.success.insetFill)
    }

    private func needsCheckIn(_ s: SessionInfo) -> Bool {
        (s.isQuality || s.type == "long") && s.status == "planned" && store.todayCheckIn == nil
    }

    /// Two-tap trust mechanism before hard sessions (spec: agency decision #4).
    ///
    /// The two answers get deliberately different haptics. Saying you're good commits you to
    /// a hard session; flagging something is a warning the app is about to act on. Those are
    /// not the same event, and the hand should be able to tell them apart without the eyes.
    private var checkInRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Before this one — feeling okay? Nothing hurting?")
                .font(Tokens.Font.ui(13, .medium)).foregroundStyle(Tokens.Palette.textPrimary)
            HStack(spacing: 8) {
                Button {
                    Haptics.commit()
                    Task { await store.submitCheckIn(feelsOk: true) }
                } label: {
                    Text("Good to go")
                        .font(Tokens.Font.ui(13, .bold)).foregroundStyle(Tokens.Palette.onVolt)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Tokens.Palette.volt).clipShape(Capsule())
                }
                .buttonStyle(Pressable(haptic: false))
                Button {
                    Haptics.warn()
                    Task {
                        await store.submitCheckIn(feelsOk: false)
                        router.showCoach()
                    }
                } label: {
                    Text("Something's off")
                        .font(Tokens.Font.ui(13, .medium)).foregroundStyle(Tokens.Palette.textSecondary)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Tokens.Well.warm.insetFill).clipShape(Capsule())
                }
                .buttonStyle(Pressable(haptic: false))
            }
        }
        .padding(.top, 2)
    }

    /// The coach's cached read of the completed run, right on the home page.
    @ViewBuilder private func takeawayPreview(_ s: SessionInfo) -> some View {
        if let takeaway = store.todayTakeaway {
            InsetWell {
                SectionLabel("Coach's read", color: Tokens.Palette.accentText)
                Text(takeaway)
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(3)
                    .lineSpacing(2)
                if let run = store.matchedRun(for: s) {
                    Button { openRun(run) } label: {
                        Text("Full analysis")
                            .font(Tokens.Font.ui(12, .semibold)).foregroundStyle(Tokens.Palette.accentText)
                    }
                    .buttonStyle(Pressable())
                }
            }
            .transition(.opacity)
            .motion(Motion.reveal, value: takeaway)
        } else if let run = store.matchedRun(for: s) {
            Button { openRun(run) } label: {
                HStack(spacing: 6) {
                    Text("Get the coach's read on this run")
                        .font(Tokens.Font.ui(13, .semibold)).foregroundStyle(Tokens.Palette.accentText)
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.accentText)
                }
            }
            .buttonStyle(Pressable())
        }
    }

    private func doneRow(_ s: SessionInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Tokens.Palette.success)
            Text(store.matchedRun(for: s).map { String(format: "Done — %.1f mi logged", $0.miles) } ?? "Done")
                .font(Tokens.Font.ui(13, .semibold)).foregroundStyle(Tokens.Palette.success)
            Spacer()
            if let run = store.matchedRun(for: s) {
                Button { openRun(run) } label: {
                    Text("View run")
                        .font(Tokens.Font.ui(12, .semibold)).foregroundStyle(Tokens.Palette.accentText)
                }
                .buttonStyle(Pressable())
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(label)
            Text(value).font(Tokens.Font.ui(16, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
        }
    }

    /// Opening a run is a change of place, not a change of state — the heavier haptic is the
    /// one that reads as arriving somewhere rather than as a button accepting a press.
    private func openRun(_ run: RunSummary) {
        Haptics.land()
        router.openRun(run)
    }

    /// Weekly mileage counter — real miles from HealthKit, Mon–Sun week.
    private var week: some View {
        Card {
            HStack {
                SectionLabel("This week")
                Spacer()
                if store.phase == .loading {
                    ProgressView().controlSize(.small).tint(Tokens.Palette.textTertiary)
                } else {
                    Text("LAST WK \(store.lastWeekMiles, specifier: "%.1f")")
                        .font(Tokens.Font.mono(11)).tracking(1.2)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                        .rolling(store.lastWeekMiles)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // The number rolls rather than snapping. A pull-to-refresh that changed
                // nothing and one that never landed look identical when digits just swap.
                Text("\(store.thisWeekMiles, specifier: "%.1f")")
                    .display(38)
                    .rolling(store.thisWeekMiles)
                Text("mi").font(Tokens.Font.mono(15)).foregroundStyle(Tokens.Palette.textSecondary)
                Spacer()
                weekDelta
            }
            dayDots
        }
    }

    @ViewBuilder private var weekDelta: some View {
        let delta = store.thisWeekMiles - store.lastWeekMiles
        if store.phase == .ready, abs(delta) >= 0.1 {
            Tag(
                text: String(format: "%+.1f vs last wk", delta),
                fg: delta >= 0 ? Tokens.Palette.success : Tokens.Palette.warning,
                bg: delta >= 0 ? Tokens.Well.success.insetFill : Tokens.Well.warning.insetFill
            )
            .transition(.scale(scale: 0.85).combined(with: .opacity))
            .motion(Motion.settle, value: delta)
        }
    }

    private var dayDots: some View {
        HStack(spacing: 8) {
            ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { index, day in
                let ran = store.runDaysThisWeek.contains(index)
                let isToday = index == store.todayIndex
                VStack(spacing: 6) {
                    Text(day)
                        .font(Tokens.Font.ui(11, isToday ? .semibold : .medium))
                        .foregroundStyle(isToday ? Tokens.Palette.textSecondary : Tokens.Palette.textTertiary)
                    Circle()
                        .fill(ran ? Tokens.Palette.voltMark : Tokens.Palette.elevated)
                        .frame(width: 10, height: 10)
                        // A day flipping to "ran" is the smallest good news the app has to
                        // give. It gets to pop.
                        .scaleEffect(ran ? 1 : 0.8)
                        .motion(Motion.settle, value: ran)
                        .overlay {
                            if isToday {
                                Circle()
                                    .strokeBorder(Tokens.Palette.voltMark.opacity(0.5), lineWidth: 1.5)
                                    .frame(width: 16, height: 16)
                            }
                        }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder private var lastRun: some View {
        Card {
            SectionLabel("Last run")
            switch store.phase {
            case .idle, .loading:
                Text("Reading Apple Health…")
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textTertiary)
            case .ready:
                if let run = store.lastRun {
                    Button {
                        openRun(run)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(relativeDay(run.start))
                                    .font(Tokens.Font.ui(15, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
                                Text(run.metricsLine)
                                    .font(Tokens.Font.mono(12)).foregroundStyle(Tokens.Palette.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Tokens.Palette.textTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(Pressable())
                    .zoomSource(run.id, in: zoom)
                }
            case .empty:
                Text("No runs in Apple Health yet.\nGarmin Connect → Settings → Apple Health → allow writing workouts, then pull to refresh.")
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
            case .unavailable:
                Text("Health access is off. Settings → Privacy & Security → Health → Tempo.")
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.warning)
            }
        }
        .motion(Motion.reveal, value: store.phase)
    }

    /// "Today", "Yesterday", or "Saturday · Jul 5".
    private func relativeDay(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide)) + " · " + date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Circular readiness gauge. Sweeps up from zero the first time you see it, and animates
/// between values after that — so a readiness that moved overnight is something you watch
/// move, rather than a number you had to have memorised yesterday to notice.
struct ReadinessRing: View {
    let value: Double

    var body: some View {
        Drawn(to: value) { shown in
            ZStack {
                Circle().stroke(Tokens.Palette.elevated, lineWidth: 7)
                Circle()
                    .trim(from: 0, to: shown)
                    .stroke(Tokens.Palette.voltMark, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(shown * 100))").display(20)
            }
        }
        .frame(width: 64, height: 64)
    }
}

#Preview("Light") {
    TodayView()
        .environmentObject(RunStore())
        .environmentObject(TabRouter())
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    TodayView()
        .environmentObject(RunStore())
        .environmentObject(TabRouter())
        .preferredColorScheme(.dark)
}
