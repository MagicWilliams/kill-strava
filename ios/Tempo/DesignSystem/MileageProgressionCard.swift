import SwiftUI
import Charts

/// Twelve training weeks as one line — the trajectory the weekly counter above it can't show.
///
/// Drag along the chart and the readout follows your finger, week by week; let go and it
/// returns to this week. Strava's Progress chart is the model, and like the training wall
/// the readout is the only legible thing under a thumb, so each week crossed ticks a haptic.
///
/// All numbers come from `MileageProgression`; this view decides nothing about which runs
/// count or which week they land in.
struct MileageProgressionCard: View {
    let progression: MileageProgression.Progression

    /// Raw x under the finger, written by `chartXSelection`; nil when nothing is held.
    @State private var scrubDate: Date?
    /// The week that raw x snaps to. Kept separately so the haptic fires once per week
    /// crossed, not once per point of finger travel.
    @State private var scrubbed: MileageProgression.WeekPoint?

    private var weeks: [MileageProgression.WeekPoint] { progression.weeks }
    private var shown: MileageProgression.WeekPoint? { scrubbed ?? progression.current }

    var body: some View {
        Card {
            HStack {
                SectionLabel("Last 12 weeks")
                Spacer()
                if progression.average > 0 {
                    HStack(spacing: 5) {
                        averageGlyph
                        Text("AVG \(progression.average, specifier: "%.1f") MI")
                            .font(Tokens.Font.mono(10)).tracking(1.2)
                            .foregroundStyle(Tokens.Palette.textTertiary)
                    }
                }
            }
            readout
            // Re-keyed on whether there is anything to draw, so the draw-in plays when the
            // runs actually land rather than having already played over the empty line the
            // card shows while the archive loads.
            Drawn(to: 1) { reveal in
                chart(reveal: reveal)
            }
            .id(progression.isEmpty)
        }
        .onAppear { Haptics.warmUp() }
    }

    // MARK: - Readout

    /// Always the same three lines, so scrubbing onto an empty week doesn't make the card jump.
    @ViewBuilder private var readout: some View {
        if let week = shown {
            VStack(alignment: .leading, spacing: 3) {
                Text(rangeLabel(week))
                    .font(Tokens.Font.mono(11)).tracking(1.2)
                    .foregroundStyle(week.isCurrent ? Tokens.Palette.accentText : Tokens.Palette.textSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(week.miles, specifier: "%.1f")").display(30)
                    Text("mi").font(Tokens.Font.mono(14)).foregroundStyle(Tokens.Palette.textSecondary)
                    Spacer()
                    versusAverage(week)
                }
                Text(detailLine(week))
                    .font(Tokens.Font.mono(11))
                    .foregroundStyle(Tokens.Palette.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    /// Neutral on purpose. A week above average isn't good news and one below isn't bad —
    /// that depends on whether it was a build or a cutback, which this card can't know. And
    /// early in the current week the gap is mostly the calendar.
    @ViewBuilder private func versusAverage(_ week: MileageProgression.WeekPoint) -> some View {
        let delta = week.miles - progression.average
        if progression.average > 0, abs(delta) >= 0.1 {
            Tag(
                text: String(format: "%+.1f vs avg", delta),
                fg: Tokens.Palette.textSecondary,
                bg: Tokens.Palette.inset
            )
        }
    }

    private func detailLine(_ week: MileageProgression.WeekPoint) -> String {
        guard week.runCount > 0 else { return week.isCurrent ? "No runs yet" : "No runs" }
        let runs = week.runCount == 1 ? "1 run" : "\(week.runCount) runs"
        return runs + String(format: " · longest %.1f mi", week.longestRunMiles)
    }

    /// "THIS WEEK", or "JUL 13 – 19" / "JUN 29 – JUL 5" for a scrubbed week.
    private func rangeLabel(_ week: MileageProgression.WeekPoint) -> String {
        if week.isCurrent { return "THIS WEEK" }
        let cal = RunHistory.calendar
        let start = week.weekStart.formatted(.dateTime.month(.abbreviated).day())
        let sameMonth = cal.component(.month, from: week.weekStart) == cal.component(.month, from: week.weekEnd)
        let end = sameMonth
            ? week.weekEnd.formatted(.dateTime.day())
            : week.weekEnd.formatted(.dateTime.month(.abbreviated).day())
        return "\(start) – \(end)".uppercased()
    }

    // MARK: - Chart

    private func chart(reveal: Double) -> some View {
        let completed = weeks.filter { !$0.isCurrent }
        // The last banked week and the current one, as their own series: the segment into
        // a week still being run is drawn differently from the ones already closed.
        let tail = Array(weeks.suffix(2))

        return Chart {
            ForEach(weeks) { week in
                AreaMark(
                    x: .value("Week", week.weekStart),
                    y: .value("Miles", week.miles)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Tokens.Palette.voltMark.opacity(0.22), Tokens.Palette.voltMark.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }

            if progression.average > 0 {
                RuleMark(y: .value("Average", progression.average))
                    .foregroundStyle(Tokens.Palette.textTertiary.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }

            ForEach(completed) { week in
                LineMark(
                    x: .value("Week", week.weekStart),
                    y: .value("Miles", week.miles),
                    series: .value("Stretch", "banked")
                )
                .foregroundStyle(Tokens.Palette.textSecondary)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            if tail.count == 2 {
                ForEach(tail) { week in
                    LineMark(
                        x: .value("Week", week.weekStart),
                        y: .value("Miles", week.miles),
                        series: .value("Stretch", "current")
                    )
                    .foregroundStyle(Tokens.Palette.voltMark)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 3]))
                }
            }

            if let scrubbed {
                RuleMark(x: .value("Week", scrubbed.weekStart))
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }

            ForEach(weeks) { week in
                PointMark(
                    x: .value("Week", week.weekStart),
                    y: .value("Miles", week.miles)
                )
                .foregroundStyle(pointColor(week))
                .symbolSize(pointSize(week))
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...yTop)
        .chartXAxis {
            // Every 4th week, oldest first, labels hanging right of their tick so the first
            // one isn't clipped by the card edge. The current week is named by the readout.
            AxisMarks(values: stride(from: 0, to: weeks.count, by: 4).map { weeks[$0].weekStart }) { _ in
                AxisTick(length: 3).foregroundStyle(Tokens.Palette.divider)
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(), anchor: .topLeading)
                    .font(Tokens.Font.mono(9)).foregroundStyle(Tokens.Palette.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Tokens.Palette.divider.opacity(0.6))
                AxisValueLabel {
                    if let miles = value.as(Double.self) {
                        Text("\(Int(miles))").font(Tokens.Font.mono(9)).foregroundStyle(Tokens.Palette.textTertiary)
                    }
                }
            }
        }
        // The plot area wipes in left to right; the axes are there from the start, so the
        // line reads as being drawn onto a frame rather than the whole card fading up.
        // The mask overhangs the plot because a week of zero sits *on* its bottom edge, and
        // a mask cut exactly to the plot halves that point — the one week the chart most
        // needs to show plainly.
        .chartPlotStyle { plot in
            plot.mask(alignment: .leading) {
                Rectangle()
                    .padding(-12)
                    .scaleEffect(x: reveal, anchor: .leading)
            }
        }
        .chartXSelection(value: $scrubDate)
        .onChange(of: scrubDate) { _, date in
            let week = date.flatMap(nearestWeek)
            guard week != scrubbed else { return }
            scrubbed = week
            if week != nil { Haptics.select() }
        }
        .frame(height: 140)
        .accessibilityLabel("Weekly mileage, last 12 weeks")
        .accessibilityValue(accessibilitySummary)
    }

    private func pointColor(_ week: MileageProgression.WeekPoint) -> Color {
        if week.id == scrubbed?.id { return Tokens.Palette.textPrimary }
        return week.isCurrent ? Tokens.Palette.voltMark : Tokens.Palette.textSecondary
    }

    private func pointSize(_ week: MileageProgression.WeekPoint) -> CGFloat {
        if week.id == scrubbed?.id { return 70 }
        return week.isCurrent ? 64 : 18
    }

    private func nearestWeek(to date: Date) -> MileageProgression.WeekPoint? {
        weeks.min { abs($0.weekStart.timeIntervalSince(date)) < abs($1.weekStart.timeIntervalSince(date)) }
    }

    /// Half a week of air either side, so the end points aren't sliced by the plot edge
    /// and the oldest and newest weeks are as easy to land a finger on as the rest.
    private var xDomain: ClosedRange<Date> {
        let first = weeks.first?.weekStart ?? .now
        let last = weeks.last?.weekStart ?? .now
        let pad: TimeInterval = 3.5 * 86_400
        return first.addingTimeInterval(-pad)...last.addingTimeInterval(pad)
    }

    /// Headroom over the peak (and the average, which can't exceed it but can equal it),
    /// with a floor so an empty or tiny window draws a flat line at the bottom of a sensible
    /// axis instead of a 0–1 scale that makes half a mile look like a mountain.
    private var yTop: Double {
        max(progression.peak, progression.average, 10) * 1.15
    }

    private var accessibilitySummary: String {
        let this = progression.current?.miles ?? 0
        return String(format: "This week %.1f miles. Average of completed weeks %.1f miles.", this, progression.average)
    }

    /// A short dashed stroke matching the average rule, so "AVG" is legible as the legend
    /// for the dashed line without a separate key.
    private var averageGlyph: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 1))
            p.addLine(to: CGPoint(x: 12, y: 1))
        }
        .stroke(Tokens.Palette.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        .frame(width: 12, height: 2)
    }
}

#Preview("Light — history") {
    MileageProgressionCard(progression: .preview)
        .padding(20)
        .background(Tokens.Palette.canvas)
        .preferredColorScheme(.light)
}

#Preview("Dark — empty") {
    MileageProgressionCard(progression: MileageProgression.progression(runs: []))
        .padding(20)
        .background(Tokens.Palette.canvas)
        .preferredColorScheme(.dark)
}

private extension MileageProgression.Progression {
    /// A build with a missed week in it, for previews.
    static var preview: Self {
        let miles: [Double] = [22, 25, 27, 18, 29, 31, 0, 26, 33, 35, 30, 11]
        let runs = miles.enumerated().flatMap { index, total -> [RunSummary] in
            guard total > 0 else { return [] }
            let back = miles.count - 1 - index
            let day = Calendar.current.date(byAdding: .weekOfYear, value: -back, to: .now) ?? .now
            return [0.45, 0.3, 0.25].map { share in
                RunSummary(id: UUID(), start: day, distanceM: Int(total * share * 1609.34), durationS: 3_000, avgHR: nil)
            }
        }
        return MileageProgression.progression(runs: runs)
    }
}
