import SwiftUI
import Charts

/// Where the projected finish comes from, and how it has moved.
///
/// The chart is not a log of numbers the app recorded — nothing was ever recorded. It is
/// `ProjectionHistory` replaying the same rule `recomputeProjection` runs, once a week,
/// back across the whole archive. Five years of trajectory on day one, and it stays correct
/// if the formula changes, because there is only one formula.
///
/// The hero number is the *stored* `plan.projected_finish_s`, so this screen and the
/// Progress card can never quote different figures. That value only rewrites when it moves
/// by more than 30 seconds, so it can sit a few seconds off the newest chart point —
/// "Recompute now" is what closes that gap.
struct ProjectionDetailView: View {
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var router: TabRouter
    @Environment(\.dismiss) private var dismiss

    @State private var range: Range = .all
    @State private var points: [ProjectionHistory.Point] = []
    @State private var recomputing = false

    /// How far back the chart looks. Two years is its own chip because that is the span
    /// the athlete can actually check against his own memory of the training.
    enum Range: String, CaseIterable, Identifiable {
        case oneYear, twoYears, all

        var id: String { rawValue }

        var label: String {
            switch self {
            case .oneYear:  return "1Y"
            case .twoYears: return "2Y"
            case .all:      return "All"
            }
        }

        var days: Int? {
            switch self {
            case .oneYear:  return 365
            case .twoYears: return 730
            case .all:      return nil
            }
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    hero
                    spread
                    chartCard
                    settingRunCard
                    howItWorks
                }
                .padding(.horizontal, 20)
                .padding(.top, 56)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)

            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(Pressable())
            .padding(.horizontal, 16)
        }
        .background(Tokens.Palette.canvas)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: store.runs.count) { rebuild() }
        .task(id: range) { rebuild() }
    }

    // MARK: - Data

    private func rebuild() {
        let now = Date.now
        let from = range.days
            .flatMap { ProjectionHistory.calendar.date(byAdding: .day, value: -$0, to: now) }
            ?? .distantPast
        points = ProjectionHistory.series(runs: store.runs, from: from, to: now)
    }

    private var goalTime: Int? { store.goal?.goalTimeSeconds }

    /// Live value first, falling back to the stored one, so the card still reads when a run
    /// has landed but the plan row hasn't been rewritten yet.
    private var current: (run: RunSummary, finishS: Int)? {
        ProjectionHistory.projection(store.runs, asOf: .now)
    }

    private var displayedFinish: Int? { store.plan?.projected_finish_s ?? current?.finishS }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Projected finish").font(Tokens.Font.display(28)).foregroundStyle(Tokens.Palette.textPrimary)
            Text("One recent effort, scaled to 26.2 — and how it has moved")
                .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        Card(glow: true) {
            HStack {
                SectionLabel("Now", color: Tokens.Palette.accentText)
                Spacer()
                if let projection = displayedFinish, let goal = goalTime {
                    if projection <= goal {
                        Tag(text: "on track")
                    } else {
                        Tag(text: "behind goal", fg: Tokens.Palette.warning, bg: Tokens.Palette.inset)
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(displayedFinish.map(PaceModel.formatFinish) ?? "—:—:—")
                    .font(Tokens.Font.display(40))
                    .foregroundStyle(displayedFinish == nil ? Tokens.Palette.textTertiary : Tokens.Palette.textPrimary)
                VStack(alignment: .leading, spacing: 1) {
                    SectionLabel("Goal")
                    Text(goalTime.map(PaceModel.formatFinish) ?? "—:—:—")
                        .font(Tokens.Font.mono(15)).foregroundStyle(Tokens.Palette.textSecondary)
                }
            }
            Text(heroCaption)
                .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)

            Rectangle().fill(Tokens.Palette.divider).frame(height: 1)
            recomputeButton
        }
    }

    private var heroCaption: String {
        guard let projection = displayedFinish else {
            return "No qualifying effort in the last six weeks — the projection needs a run of at least 2.5 miles to extrapolate from."
        }
        guard let goal = goalTime else {
            return "Set a goal time and the gap to it shows up here."
        }
        let delta = goal - projection
        if delta >= 0 {
            return "Current fitness projects \(PaceModel.formatFinish(delta)) under goal."
        }
        return "Current fitness projects \(PaceModel.formatFinish(-delta)) over goal — the gap is the training block's job."
    }

    private var recomputeButton: some View {
        Button {
            Task {
                recomputing = true
                await store.recomputeProjection()
                rebuild()
                recomputing = false
            }
        } label: {
            HStack(spacing: 7) {
                if recomputing {
                    ProgressView().controlSize(.small).tint(Tokens.Palette.accentText)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold))
                }
                Text(recomputing ? "Recomputing…" : "Recompute now")
                    .font(Tokens.Font.ui(13, .semibold))
                Spacer()
            }
            .foregroundStyle(Tokens.Palette.accentText)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .disabled(recomputing)
    }

    // MARK: - Spread

    /// Best, swing and gap over the visible range. Swing is here on purpose: seeing that
    /// the number routinely moves by double-digit minutes is the fastest way to stop
    /// reading a single bad week as fitness falling apart.
    private var spread: some View {
        let finishes = points.map(\.projectedFinishS)
        let best = finishes.min()
        let worst = finishes.max()
        return HStack(spacing: 10) {
            StatTile(value: best.map(PaceModel.formatFinish) ?? "—", label: "Best")
            StatTile(
                value: (best != nil && worst != nil) ? "\((worst! - best!) / 60) min" : "—",
                label: "Swing"
            )
            StatTile(value: gapValue, label: "Vs goal")
        }
    }

    private var gapValue: String {
        guard let projection = displayedFinish, let goal = goalTime else { return "—" }
        let delta = projection - goal
        return (delta > 0 ? "+" : "−") + PaceModel.formatFinish(abs(delta))
    }

    // MARK: - Chart

    private var chartCard: some View {
        Card {
            HStack {
                SectionLabel("Projection over time")
                Spacer()
                Text("LOWER IS FASTER").mono(9, Tokens.Palette.textTertiary).tracking(1)
            }
            rangeRow

            if points.count < 2 {
                Text(points.isEmpty
                     ? "Nothing to plot in this range — no six-week window held a qualifying run."
                     : "One reading so far. The line appears once there are two.")
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textTertiary)
                    .frame(height: 60)
            } else {
                chart
                HStack {
                    legendDot(Tokens.Palette.accentText, "PROJECTED")
                    legendDot(Tokens.Palette.textTertiary, "GOAL")
                    Spacer()
                    Text("\(points.count) WEEKLY READINGS").mono(9, Tokens.Palette.textTertiary).tracking(1)
                }
            }
        }
    }

    private var rangeRow: some View {
        HStack(spacing: 8) {
            ForEach(Range.allCases) { r in
                let active = r == range
                Button { range = r } label: {
                    Text(r.label)
                        .font(Tokens.Font.ui(12, active ? .semibold : .medium))
                        .foregroundStyle(active ? Tokens.Palette.onVolt : Tokens.Palette.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(active ? Tokens.Palette.volt : Tokens.Palette.inset)
                        .clipShape(Capsule())
                }
                .buttonStyle(Pressable())
            }
            Spacer()
        }
    }

    private var chart: some View {
        Chart {
            if let goal = goalTime {
                RuleMark(y: .value("Goal", Double(goal)))
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            // One LineMark series per contiguous stretch. A single series would join across
            // the gaps, drawing exactly the interpolation the engine refuses to invent.
            ForEach(Array(ProjectionHistory.segments(points).enumerated()), id: \.offset) { index, stretch in
                ForEach(stretch) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Projected", Double(point.projectedFinishS)),
                        series: .value("Stretch", index)
                    )
                    .foregroundStyle(Tokens.Palette.accentText)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            if let last = points.last {
                PointMark(
                    x: .value("Date", last.date),
                    y: .value("Projected", Double(last.projectedFinishS))
                )
                .foregroundStyle(Tokens.Palette.accentText)
                .symbolSize(36)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits))
                    .font(Tokens.Font.mono(9)).foregroundStyle(Tokens.Palette.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel {
                    if let seconds = value.as(Double.self) {
                        Text(hoursMinutes(Int(seconds)))
                            .font(Tokens.Font.mono(9)).foregroundStyle(Tokens.Palette.textTertiary)
                    }
                }
                AxisGridLine().foregroundStyle(Tokens.Palette.divider.opacity(0.5))
            }
        }
        .frame(height: 150)
    }

    /// Padded to keep the goal line inside the plot — a reference line you cannot see is
    /// not a reference.
    private var yDomain: ClosedRange<Double> {
        var values = points.map { Double($0.projectedFinishS) }
        if let goal = goalTime { values.append(Double(goal)) }
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let pad = max((high - low) * 0.12, 120)
        return (low - pad)...(high + pad)
    }

    private func hoursMinutes(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 3600, (seconds % 3600) / 60)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).mono(9, Tokens.Palette.textTertiary).tracking(1)
        }
    }

    // MARK: - The run behind the number

    @ViewBuilder private var settingRunCard: some View {
        if let current {
            Card {
                SectionLabel("Set by this run")
                Button {
                    router.openRun(current.run)
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(current.run.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                                .font(Tokens.Font.ui(14, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
                            Text(current.run.metricsLine)
                                .mono(12, Tokens.Palette.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11)).foregroundStyle(Tokens.Palette.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(Pressable())

                Text("The whole projection is this one effort scaled up. When it ages past six weeks, the next-fastest run takes over and the number steps — that step is the window moving, not your fitness.")
                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textTertiary)
                    .lineSpacing(3)
            }
        }
    }

    // MARK: - Honesty

    private var howItWorks: some View {
        Card {
            SectionLabel("How this works")
            Text("Every week on the chart is the same rule re-run against the runs on file that day: the fastest run of 2.5 miles or more in the previous six weeks, extrapolated to marathon distance by Riegel (t₂ = t₁ × (d₂/d₁)^1.06). Nothing was stored month by month — it is all recomputed from your archive, so it stays correct if the formula ever changes.\n\nThat also makes it deliberately jumpy. One fast parkrun drops it by minutes; six weeks later the same run leaves the window and it climbs back, with no change in fitness either way. Read the trend, not the step. Where the line breaks, no run in that six-week window went far enough to extrapolate from — nothing is drawn rather than a number nobody earned.")
                .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
                .lineSpacing(3)
        }
    }
}

#Preview {
    NavigationStack {
        ProjectionDetailView()
            .environmentObject(RunStore())
            .environmentObject(TabRouter())
    }
    .preferredColorScheme(.dark)
}
