import SwiftUI
import Charts

/// Where readiness comes from: the load model's fitness/fatigue/form, the trailing
/// fitness curve, today's check-in, and an honest note about how it's computed.
struct ReadinessDetailView: View {
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var router: TabRouter
    @Environment(\.dismiss) private var dismiss

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
                            LinearGradient(colors: [Tokens.Palette.volt.opacity(0.3), Tokens.Palette.volt.opacity(0.02)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Day", point.date), y: .value("CTL", point.ctl))
                        .foregroundStyle(Tokens.Palette.volt)
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
                    Text(checkIn.feelsOk ? "Feeling okay — the numbers stand." : "You flagged something's off — readiness is capped and the coach knows.")
                        .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textPrimary)
                }
            } else {
                Text("No check-in yet today. Your word outranks the math — hard sessions ask first.")
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
            }
            Button { router.showCoach() } label: {
                Text("Talk it through with Coach")
                    .font(Tokens.Font.ui(13, .semibold)).foregroundStyle(Tokens.Palette.volt)
            }
            .buttonStyle(Pressable())
        }
    }

    private var howItWorks: some View {
        Card {
            SectionLabel("How this works")
            Text("Every run scores training load from distance and pace relative to your own recent baseline. Fitness is the 42-day trend of that load; fatigue is the 7-day trend; form is the gap. Readiness reads form against fitness — and your daily check-in can always overrule it. Honest caveat: it's pace-based for now; heart-rate weighting lands when HR flows reliably from Garmin.")
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
