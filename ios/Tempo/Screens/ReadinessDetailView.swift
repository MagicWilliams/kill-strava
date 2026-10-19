import SwiftUI
import Charts

/// Where readiness comes from: the load model's fitness/fatigue/form, the trailing
/// fitness curve, today's check-in, and an honest note about how it's computed.
struct ReadinessDetailView: View {
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var router: TabRouter
    @Environment(\.dismiss) private var dismiss

    /// Reports whose Clear is in flight. A tap that leaves the row looking live is how the
    /// same report gets cleared twice.
    @State private var clearing: Set<UUID> = []
    @State private var clearError: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let m = store.fitness {
                        hero(m)
                        numbers(m)
                        fitnessCurve(m)
                        checkInCard
                        bodyCard
                        howItWorks
                    } else {
                        Card {
                            Text("Readiness needs run history — sync a few runs and this comes alive.")
                                .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                        }
                    }
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Readiness").font(Tokens.Font.display(28)).foregroundStyle(Tokens.Palette.textPrimary)
            Text("Fitness vs fatigue, from your actual runs")
                .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
        }
    }

    private func hero(_ m: FitnessMetrics) -> some View {
        Card(glow: true) {
            HStack(spacing: 20) {
                ReadinessRing(value: Double(m.readiness) / 100)
                    .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.label).font(Tokens.Font.display(26)).foregroundStyle(Tokens.Palette.textPrimary)
                    Text(m.caption)
                        .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func numbers(_ m: FitnessMetrics) -> some View {
        HStack(spacing: 10) {
            StatTile(value: String(format: "%.1f", m.ctl), label: "Fitness")
            StatTile(value: String(format: "%.1f", m.atl), label: "Fatigue")
            StatTile(value: String(format: "%+.1f", m.form), label: "Form")
        }
    }

    private func fitnessCurve(_ m: FitnessMetrics) -> some View {
        Card {
            HStack {
                SectionLabel("Fitness · trailing 8 weeks")
                Spacer()
                Text("CTL").mono(10, Tokens.Palette.textTertiary)
            }
            Chart {
                ForEach(Array(m.ctlSeries.enumerated()), id: \.offset) { _, point in
                    AreaMark(x: .value("Day", point.date), y: .value("CTL", point.ctl))
                        .foregroundStyle(
                            LinearGradient(colors: [Tokens.Palette.voltMark.opacity(0.3), Tokens.Palette.voltMark.opacity(0.02)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Day", point.date), y: .value("CTL", point.ctl))
                        .foregroundStyle(Tokens.Palette.accentText)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .font(Tokens.Font.mono(9)).foregroundStyle(Tokens.Palette.textTertiary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisValueLabel().font(Tokens.Font.mono(9)).foregroundStyle(Tokens.Palette.textTertiary)
                    AxisGridLine().foregroundStyle(Tokens.Palette.divider.opacity(0.5))
                }
            }
            .frame(height: 110)
            Text("Rising line = the aerobic engine growing. Dips follow down-weeks; that's the rhythm, not a problem.")
                .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textTertiary)
        }
    }

    @ViewBuilder private var checkInCard: some View {
        Card {
            SectionLabel("Today's check-in")
            if let checkIn = store.todayCheckIn {
                HStack(spacing: 8) {
                    Image(systemName: checkIn.feelsOk ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(checkIn.feelsOk ? Tokens.Palette.success : Tokens.Palette.warning)
                    // "The numbers stand" would be a lie sitting directly above a Body
                    // section that is holding readiness at 40 (#89).
                    Text(checkIn.feelsOk
                         ? (BodyReports.capsReadiness(store.bodyReports.reports)
                            ? "Feeling okay — but an open body report is holding readiness down. See Body, below."
                            : "Feeling okay — the numbers stand.")
                         : "You flagged something's off — readiness is capped and the coach knows.")
                        .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textPrimary)
                }
            } else {
                Text("No check-in yet today. Your word outranks the math — hard sessions ask first.")
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
            }
            Button { router.showCoach() } label: {
                Text("Talk it through with Coach")
                    .font(Tokens.Font.ui(13, .semibold)).foregroundStyle(Tokens.Palette.accentText)
            }
            .buttonStyle(Pressable())
        }
    }

    /// The Body section (#89): what the athlete has told the coach about their body, and what
    /// it is doing to the number above.
    ///
    /// It lives on this screen because this is where the app answers "why is readiness 40?",
    /// beside the check-in card that answers the same question the other way. The Coach's
    /// read screen the mockups put it on is #90's, and not built yet — when it lands, this
    /// section is the thing to move or mirror.
    ///
    /// Hidden entirely until migration 0020 is applied: a Clear button that cannot save is
    /// worse than no section at all.
    @ViewBuilder private var bodyCard: some View {
        let live = BodyReports.live(store.bodyReports.reports)
        let resolved = BodyReports.cleared(store.bodyReports.reports)
        if store.bodyReportsAvailable && !(live.isEmpty && resolved.isEmpty) {
            Card {
                SectionLabel("Body")
                if live.isEmpty {
                    Text("Nothing open. Tell the coach if something starts to niggle.")
                        .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                }
                ForEach(live) { report in
                    liveReportRow(report)
                }
                if let error = clearError {
                    Text(error).font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.danger)
                }
                ForEach(resolved.prefix(3)) { report in
                    Text("Resolved: \(report.summaryLine)\(Self.resolvedDates(report))")
                        .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textTertiary)
                }
            }
        }
    }

    private func liveReportRow(_ report: BodyReport) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(report.summaryLine)
                    .font(Tokens.Font.ui(14, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
                Text("Since \(Self.day.string(from: report.openedAt)) · \(BodyReports.readinessEffect(severity: report.severity))")
                    .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
            }
            Spacer(minLength: 0)
            if clearing.contains(report.id) {
                ProgressView().controlSize(.small).tint(Tokens.Palette.textTertiary)
            } else {
                Button { clear(report) } label: {
                    Text("Clear")
                        .font(Tokens.Font.ui(13, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Tokens.Palette.surface)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Tokens.Palette.elevated, lineWidth: 1))
                }
                .buttonStyle(Pressable())
            }
        }
    }

    /// Clearing from here writes the same row the coach's `clear_body` card writes, so
    /// readiness recovers the same way by either route. Nothing on screen moves until the
    /// write lands — a report that only *looks* cleared comes back next launch.
    private func clear(_ report: BodyReport) {
        clearing.insert(report.id)
        clearError = nil
        Task {
            do {
                try await store.clearBodyReport(report.id)
            } catch {
                clearError = "That didn't save — tap Clear again, or tell the coach."
            }
            clearing.remove(report.id)
        }
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static func resolvedDates(_ report: BodyReport) -> String {
        guard let cleared = report.clearedAt else { return "" }
        return " (\(day.string(from: report.openedAt)) – \(day.string(from: cleared)))"
    }

    private var howItWorks: some View {
        Card {
            SectionLabel("How this works")
            Text("Every run scores training load from distance and pace relative to your own recent baseline. Fitness is the 42-day trend of that load; fatigue is the 7-day trend; form is the gap. Readiness reads form against fitness — and your own word always overrules it: a check-in saying something's off, or a body report you rated \(BodyReports.capSeverity) or worse, caps it until you clear it. Honest caveat: it's pace-based for now; heart-rate weighting lands when HR flows reliably from Garmin.")
                .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
                .lineSpacing(3)
        }
    }
}

#Preview {
    NavigationStack {
        ReadinessDetailView()
            .environmentObject(RunStore())
            .environmentObject(TabRouter())
    }
    .preferredColorScheme(.dark)
}
