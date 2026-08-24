import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var router: TabRouter

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
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Tokens.Palette.warning)
                Text(warning)
                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Tokens.Palette.inset)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// Real readiness from the load model — taps into the full breakdown.
    private var readiness: some View {
        Button { router.openReadiness() } label: {
            Card {
                HStack(spacing: 16) {
                    ReadinessRing(value: Double(store.fitness?.readiness ?? 50) / 100)
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel("Readiness", color: Tokens.Palette.volt)
                        Text(store.fitness?.label ?? "Warming up")
                            .font(Tokens.Font.display(22)).foregroundStyle(Tokens.Palette.textPrimary)
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
            Card(padding: 14) {
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

    private var noPlanCard: some View {
        Card(glow: true) {
            SectionLabel("Today's session", color: Tokens.Palette.volt)
            Text("No plan yet").font(Tokens.Font.display(24)).foregroundStyle(Tokens.Palette.textPrimary)
            Text("Your coach reads your real history first, proposes a goal, and the plan builds from what the data supports.")
                .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
            PrimaryButton(title: "Talk to Coach") { router.showCoach() }
        }
    }

    private var restCard: some View {
        Card {
            SectionLabel("Today's session")
            Text("Rest day").font(Tokens.Font.display(24)).foregroundStyle(Tokens.Palette.textPrimary)
            Text("Recovery is training. Tomorrow's session banks what today absorbs.")
                .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
        }
    }

    private func sessionCard(_ s: SessionInfo) -> some View {
        Card(glow: s.isQuality) {
            HStack {
                SectionLabel("Today's session", color: Tokens.Palette.volt)
                Spacer()
                sessionTag(s)
            }
            Text(s.title ?? s.type.capitalized)
                .font(Tokens.Font.display(24)).foregroundStyle(Tokens.Palette.textPrimary)
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
    }

    private func sessionTag(_ s: SessionInfo) -> Tag {
        if s.isQuality { return Tag(text: "quality", fg: Tokens.Palette.onVolt, bg: Tokens.Palette.volt) }
        if s.type == "long" { return Tag(text: "long run", fg: Tokens.Palette.info, bg: Tokens.Palette.inset) }
        return Tag(text: s.type, fg: Tokens.Palette.success, bg: Tokens.Palette.inset)
    }

    private func needsCheckIn(_ s: SessionInfo) -> Bool {
        (s.isQuality || s.type == "long") && s.status == "planned" && store.todayCheckIn == nil
    }

    /// Two-tap trust mechanism before hard sessions (spec: agency decision #4).
    private var checkInRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Before this one — feeling okay? Nothing hurting?")
                .font(Tokens.Font.ui(13, .medium)).foregroundStyle(Tokens.Palette.textPrimary)
            HStack(spacing: 8) {
                Button {
                    Task { await store.submitCheckIn(feelsOk: true) }
                } label: {
                    Text("Good to go")
                        .font(Tokens.Font.ui(13, .bold)).foregroundStyle(Tokens.Palette.onVolt)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Tokens.Palette.volt).clipShape(Capsule())
                }
                .buttonStyle(Pressable())
                Button {
                    Task {
                        await store.submitCheckIn(feelsOk: false)
                        router.showCoach()
                    }
                } label: {
                    Text("Something's off")
                        .font(Tokens.Font.ui(13, .medium)).foregroundStyle(Tokens.Palette.textSecondary)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Tokens.Palette.surface).clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Tokens.Palette.elevated, lineWidth: 1))
                }
                .buttonStyle(Pressable())
            }
        }
        .padding(.top, 2)
    }

    /// The coach's cached read of the completed run, right on the home page.
    @ViewBuilder private func takeawayPreview(_ s: SessionInfo) -> some View {
        if let takeaway = store.todayTakeaway {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Coach's read", color: Tokens.Palette.volt)
                Text(takeaway)
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(3)
                    .lineSpacing(2)
                if let run = store.matchedRun(for: s) {
                    Button { router.openRun(run) } label: {
                        Text("Full analysis").font(Tokens.Font.ui(12, .semibold)).foregroundStyle(Tokens.Palette.volt)
                    }
                    .buttonStyle(Pressable())
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Palette.inset)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if let run = store.matchedRun(for: s) {
            Button { router.openRun(run) } label: {
                HStack(spacing: 6) {
                    Text("Get the coach's read on this run")
                        .font(Tokens.Font.ui(13, .semibold)).foregroundStyle(Tokens.Palette.volt)
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.volt)
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
                Button { router.openRun(run) } label: {
                    Text("View run").font(Tokens.Font.ui(12, .semibold)).foregroundStyle(Tokens.Palette.volt)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(label)
            Text(value).font(Tokens.Font.ui(16, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
        }
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
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(store.thisWeekMiles, specifier: "%.1f")")
                    .font(Tokens.Font.display(40)).foregroundStyle(Tokens.Palette.textPrimary)
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
                bg: Tokens.Palette.inset
            )
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
                        .fill(ran ? Tokens.Palette.volt : Tokens.Palette.elevated)
                        .frame(width: 10, height: 10)
                        .overlay {
                            if isToday {
                                Circle()
                                    .strokeBorder(Tokens.Palette.volt.opacity(0.5), lineWidth: 1.5)
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
                        router.openRun(run)
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
                }
            case .empty:
                Text("No runs in Apple Health yet.\nGarmin Connect → Settings → Apple Health → allow writing workouts, then pull to refresh.")
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
            case .unavailable:
                Text("Health access is off. Settings → Privacy & Security → Health → Tempo.")
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.warning)
            }
        }
    }

    /// "Today", "Yesterday", or "Saturday · Jul 5".
    private func relativeDay(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide)) + " · " + date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Circular readiness gauge.
struct ReadinessRing: View {
    let value: Double

    var body: some View {
        ZStack {
            Circle().stroke(Tokens.Palette.elevated, lineWidth: 7)
            Circle()
                .trim(from: 0, to: value)
                .stroke(Tokens.Palette.volt, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(value * 100))").font(Tokens.Font.display(20)).foregroundStyle(Tokens.Palette.textPrimary)
        }
        .frame(width: 64, height: 64)
    }
}

#Preview {
    TodayView().environmentObject(RunStore()).preferredColorScheme(.dark)
}
