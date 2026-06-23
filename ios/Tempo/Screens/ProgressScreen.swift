import SwiftUI

/// Goal-trajectory hub (named ProgressScreen to avoid clashing with SwiftUI.ProgressView).
struct ProgressScreen: View {
    var body: some View {
        Screen(title: "Progress", subtitle: "16 weeks to Chicago") {
            projected
            trajectory
            block
            consistency
        }
    }

    private var projected: some View {
        Card(glow: true) {
            HStack {
                SectionLabel("Projected finish", color: Tokens.Palette.volt)
                Spacer()
                Tag(text: "on track")
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("3:13:42").font(Tokens.Font.display(40)).foregroundStyle(Tokens.Palette.textPrimary)
                VStack(alignment: .leading, spacing: 1) {
                    SectionLabel("Goal")
                    Text("3:15:00").font(Tokens.Font.mono(15)).foregroundStyle(Tokens.Palette.textSecondary)
                }
            }
            Text("Recent paces project ~80s under goal. Hold consistency and the margin grows.")
                .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
        }
    }

    private var trajectory: some View {
        Card {
            SectionLabel("Fitness trajectory")
            TrajectoryChart(actual: [34, 38, 42, 46], projected: [50, 55, 60, 65, 70, 75, 80, 86])
                .frame(height: 96)
            HStack {
                Text("NOW · WK 4").mono(10, Tokens.Palette.volt)
                Spacer()
                Text("RACE DAY").mono(10, Tokens.Palette.textTertiary)
            }
        }
    }

    private var block: some View {
        Card {
            HStack {
                SectionLabel("Training block")
                Spacer()
                Text("Week 4 of 16").font(Tokens.Font.mono(13)).foregroundStyle(Tokens.Palette.textPrimary)
            }
            GeometryReader { geo in
                HStack(spacing: 4) {
                    phaseSeg(width: geo.size.width * 6 / 16 - 3, fill: 4.0 / 6.0)
                    phaseSeg(width: geo.size.width * 5 / 16 - 3, fill: 0)
                    phaseSeg(width: geo.size.width * 3 / 16 - 3, fill: 0)
                    phaseSeg(width: geo.size.width * 2 / 16 - 3, fill: 0)
                }
            }
            .frame(height: 8)
            Text("2 weeks left in your base block.")
                .font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
        }
    }

    private func phaseSeg(width: CGFloat, fill: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Tokens.Palette.divider)
            Capsule().fill(Tokens.Palette.volt).frame(width: max(0, width * fill))
        }
        .frame(width: max(0, width))
    }

    private var consistency: some View {
        Card {
            HStack {
                SectionLabel("Consistency")
                Spacer()
                Text("5-week streak").font(Tokens.Font.ui(12, .semibold)).foregroundStyle(Tokens.Palette.volt)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("92%").font(Tokens.Font.display(32)).foregroundStyle(Tokens.Palette.textPrimary)
                Text("33 of 36 sessions completed").font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
            }
        }
    }
}

/// Banked (solid) vs projected (outlined) fitness, rising toward the goal ceiling.
struct TrajectoryChart: View {
    let actual: [Double]
    let projected: [Double]

    var body: some View {
        let all = actual + projected
        let mx = all.max() ?? 1
        GeometryReader { geo in
            let gap: CGFloat = 4
            let count = all.count
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
        }
    }
}

#Preview {
    ProgressScreen().preferredColorScheme(.dark)
}
