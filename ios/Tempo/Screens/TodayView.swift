import SwiftUI

struct TodayView: View {
    private let paces = Mock.paces

    var body: some View {
        Screen(title: "Today", subtitle: "Tuesday, June 24") {
            readiness
            session
            week
            lastRun
        }
    }

    private var readiness: some View {
        Card {
            HStack(spacing: 16) {
                ReadinessRing(value: 0.82)
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel("Readiness", color: Tokens.Palette.volt)
                    Text("Primed").font(Tokens.Font.display(22)).foregroundStyle(Tokens.Palette.textPrimary)
                    Text("Sleep and HRV look good — green light for quality.")
                        .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var session: some View {
        Card(glow: true) {
            HStack {
                SectionLabel("Today's session", color: Tokens.Palette.volt)
                Spacer()
                Tag(text: "quality", fg: Tokens.Palette.onVolt, bg: Tokens.Palette.volt)
            }
            Text(Mock.today.title).font(Tokens.Font.display(24)).foregroundStyle(Tokens.Palette.textPrimary)
            Text(Mock.today.detail).font(Tokens.Font.mono(14)).foregroundStyle(Tokens.Palette.textSecondary)
            HStack(spacing: 18) {
                metric("DISTANCE", "5.0 mi")
                metric("TARGET", PaceModel.format(paces.threshold) + " /mi")
                metric("RPE", "7")
            }
            PrimaryButton(title: "Start session")
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(label)
            Text(value).font(Tokens.Font.ui(16, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
        }
    }

    private var week: some View {
        Card {
            SectionLabel("This week · base")
            HStack(spacing: 8) {
                ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { index, day in
                    let done = index < 2
                    VStack(spacing: 6) {
                        Text(day).font(Tokens.Font.ui(11, .medium)).foregroundStyle(Tokens.Palette.textTertiary)
                        Circle()
                            .fill(done ? Tokens.Palette.volt : Tokens.Palette.elevated)
                            .frame(width: 10, height: 10)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var lastRun: some View {
        Card {
            SectionLabel("Last run")
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Easy run").font(Tokens.Font.ui(15, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
                    Text("5.1 mi · 9:10 /mi · 138 bpm").font(Tokens.Font.mono(12)).foregroundStyle(Tokens.Palette.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Tokens.Palette.textTertiary)
            }
        }
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
    TodayView().preferredColorScheme(.dark)
}
