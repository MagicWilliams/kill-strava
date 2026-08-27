import SwiftUI

/// Goal-trajectory hub (named ProgressScreen to avoid clashing with SwiftUI.ProgressView).
struct ProgressScreen: View {
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var router: TabRouter

    /// v1 beta: fixed race target until Goal Setup is wired.
    static let raceDate = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 11))!

    var body: some View {
        Screen(title: "Progress", subtitle: subtitle) {
            projected
            mileageTrend
            recentRuns
            block
        }
        .refreshable { await store.refresh() }
    }

    private var subtitle: String {
        let days = Calendar.current.dateComponents([.day], from: .now, to: Self.raceDate).day ?? 0
        let weeks = Int((Double(days) / 7.0).rounded(.up))
        return "\(weeks) weeks to Chicago"
    }

    @ViewBuilder private var projected: some View {
        let projection = store.plan?.projected_finish_s
        let goalTime = store.goal?.goalTimeSeconds
        // Tapping through is where the number stops being a verdict: the detail page shows
        // the single run it came from and how much it has bounced around getting here.
        Button {
            router.openProjection()
        } label: {
            Card(glow: true) {
                HStack {
                    SectionLabel("Projected finish", color: Tokens.Palette.volt)
                    Spacer()
                    if let projection, let goalTime {
                        if projection <= goalTime {
                            Tag(text: "on track")
                        } else {
                            Tag(text: "behind goal", fg: Tokens.Palette.warning, bg: Tokens.Palette.inset)
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.textTertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(projection.map(PaceModel.formatFinish) ?? "—:—:—")
                        .font(Tokens.Font.display(40))
                        .foregroundStyle(projection == nil ? Tokens.Palette.textTertiary : Tokens.Palette.textPrimary)
                    VStack(alignment: .leading, spacing: 1) {
                        SectionLabel("Goal")
                        Text(goalTime.map(PaceModel.formatFinish) ?? "3:15:00")
                            .font(Tokens.Font.mono(15)).foregroundStyle(Tokens.Palette.textSecondary)
                    }
                }
                Text(projectionCaption(projection: projection, goalTime: goalTime))
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                    .multilineTextAlignment(.leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
    }

    private func projectionCaption(projection: Int?, goalTime: Int?) -> String {
        guard store.plan != nil else {
            return "No plan yet — the coach assesses your history and proposes a goal to build from."
        }
        guard let projection, let goalTime else {
            return "Projection sharpens as runs land — updated after every sync."
        }
        let delta = goalTime - projection
        if delta >= 0 {
            return "Current fitness projects \(PaceModel.formatFinish(abs(delta))) under goal. Updated after every run."
        }
        return "Current fitness projects \(PaceModel.formatFinish(abs(delta))) over goal — the gap is the training block's job. Updated after every run."
    }

    /// Real weekly mileage, trailing 8 weeks. Current (in-progress) week is outlined.
    private var mileageTrend: some View {
        let weeks = store.weeklySummaries(8)
        let past = weeks.dropLast().map(\.miles)
        let current = weeks.last.map { [$0.miles] } ?? []
        return Card {
            HStack {
                SectionLabel("Weekly mileage")
                Spacer()
                if let top = weeks.map(\.miles).max(), top > 0 {
                    Text("PEAK \(top, specifier: "%.1f") MI")
                        .font(Tokens.Font.mono(10)).tracking(1.2)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                }
            }
            TrajectoryChart(actual: past, projected: current)
                .frame(height: 96)
            HStack {
                Text("8 WKS AGO").mono(10, Tokens.Palette.textTertiary)
                Spacer()
                Text("THIS WK · \(store.thisWeekMiles, specifier: "%.1f") MI").mono(10, Tokens.Palette.volt)
            }
        }
    }

    private var recentRuns: some View {
        let runs = store.recentRuns(days: 14)
        return Card {
            HStack {
                SectionLabel("Recent runs")
                Spacer()
                // The doorway to the archive. This card shows two weeks; the athlete has
                // 2,000+ runs, and until now there was no screen that could show them.
                Button {
                    router.openHistory()
                } label: {
                    HStack(spacing: 3) {
                        Text("ALL \(store.runs.count.formatted())")
                            .font(Tokens.Font.mono(10)).tracking(1.2)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Tokens.Palette.volt)
                }
                .buttonStyle(Pressable())
            }
            if runs.isEmpty {
                Text(store.phase == .loading ? "Reading Apple Health…" : "Nothing in the last two weeks.")
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textTertiary)
            }
            ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                if index > 0 {
                    Rectangle().fill(Tokens.Palette.divider).frame(height: 1)
                }
                Button {
                    router.openRun(run)
                } label: {
                    HStack(spacing: 8) {
                        Text(run.start.formatted(.dateTime.weekday(.abbreviated).month(.defaultDigits).day()))
                            .font(Tokens.Font.ui(13, .medium)).foregroundStyle(Tokens.Palette.textPrimary)
                        if run.corrected {
                            Tag(text: "edited", fg: Tokens.Palette.info, bg: Tokens.Palette.inset)
                        }
                        Spacer()
                        Text(run.metricsLine)
                            .font(Tokens.Font.mono(12)).foregroundStyle(Tokens.Palette.textSecondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                            .foregroundStyle(Tokens.Palette.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(Pressable())
            }
            if !runs.isEmpty {
                Rectangle().fill(Tokens.Palette.divider).frame(height: 1)
                Button {
                    router.openHistory()
                } label: {
                    HStack {
                        Text("Browse every run")
                            .font(Tokens.Font.ui(13, .medium))
                            .foregroundStyle(Tokens.Palette.volt)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Tokens.Palette.volt)
                    }
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(Pressable())
            }
        }
    }

    @ViewBuilder private var block: some View {
        Card {
            HStack {
                SectionLabel("Training block")
                Spacer()
                if let week = store.currentPlanWeek, let plan = store.plan {
                    Text("Week \(week) of \(plan.weeks)")
                        .font(Tokens.Font.mono(13)).foregroundStyle(Tokens.Palette.textPrimary)
                }
            }
            if store.plan != nil, !store.planWeeks.isEmpty {
                phaseBar
                if let phase = store.currentPhase {
                    Text("\(phase.capitalized) phase — \(weeksLeftInPhase) week\(weeksLeftInPhase == 1 ? "" : "s") left in it.")
                        .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
                }
            } else {
                Text("Base → Build → Peak → Taper segments light up here once your plan exists.")
                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
            }
        }
    }

    /// Phase segments sized by week count, filled by progress through the block.
    private var phaseBar: some View {
        let phases = phaseSpans
        let total = CGFloat(store.plan?.weeks ?? 1)
        let currentIdx = (store.currentPlanWeek ?? 1) - 1
        return GeometryReader { geo in
            HStack(spacing: 4) {
                ForEach(Array(phases.enumerated()), id: \.offset) { _, span in
                    let width = geo.size.width * CGFloat(span.weeks) / total - 3
                    let fill: CGFloat = {
                        if currentIdx >= span.start + span.weeks { return 1 }
                        if currentIdx < span.start { return 0 }
                        return CGFloat(currentIdx - span.start) / CGFloat(span.weeks)
                    }()
                    phaseSeg(width: max(width, 8), fill: fill)
                }
            }
        }
        .frame(height: 8)
    }

    private var phaseSpans: [(phase: String, start: Int, weeks: Int)] {
        var spans: [(String, Int, Int)] = []
        for week in store.planWeeks.sorted(by: { $0.week_index < $1.week_index }) {
            if var last = spans.last, last.0 == week.phase {
                last.2 += 1
                spans[spans.count - 1] = last
            } else {
                spans.append((week.phase, week.week_index, 1))
            }
        }
        return spans.map { (phase: $0.0, start: $0.1, weeks: $0.2) }
    }

    private var weeksLeftInPhase: Int {
        let currentIdx = (store.currentPlanWeek ?? 1) - 1
        guard let span = phaseSpans.first(where: { currentIdx >= $0.start && currentIdx < $0.start + $0.weeks }) else { return 0 }
        return span.start + span.weeks - currentIdx
    }

    private func phaseSeg(width: CGFloat, fill: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Tokens.Palette.divider)
            Capsule().fill(Tokens.Palette.volt).frame(width: max(0, width * fill))
        }
        .frame(width: max(0, width))
    }
}

/// Banked (solid) vs in-progress/projected (outlined) bars.
struct TrajectoryChart: View {
    let actual: [Double]
    let projected: [Double]

    var body: some View {
        let all = actual + projected
        let mx = max(all.max() ?? 1, 1)
        GeometryReader { geo in
            let gap: CGFloat = 4
            let count = max(all.count, 1)
            let bw = (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(all.enumerated()), id: \.offset) { index, value in
                    let h = geo.size.height * CGFloat(value / mx)
                    let proj = index >= actual.count
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Tokens.Palette.volt.opacity(proj ? 0.16 : 1))
                        .overlay {
                            if proj {
                                RoundedRectangle(cornerRadius: 2)
                                    .strokeBorder(Tokens.Palette.volt.opacity(0.45), lineWidth: 1)
                            }
                        }
                        .frame(width: bw, height: max(2, h))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

#Preview {
    ProgressScreen().environmentObject(RunStore()).preferredColorScheme(.dark)
}
