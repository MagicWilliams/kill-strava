import SwiftUI

/// Profile: goal hero, real year stats, bests from actual runs, and the
/// chat-mutable training settings (everything here changes via the Coach).
struct YouView: View {
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var router: TabRouter

    var body: some View {
        Screen(title: "You", subtitle: subtitle) {
            goal
            yearStats
            bests
            settings
        }
        .refreshable { await store.refresh() }
    }

    private var subtitle: String? {
        guard let goal = store.goal, let day = goal.raceDay else { return "No goal yet" }
        let weeks = max((Calendar.current.dateComponents([.day], from: .now, to: day).day ?? 0) / 7, 0)
        return "\(goal.raceName ?? "Race") · \(weeks) weeks out"
    }

    @ViewBuilder private var goal: some View {
        Card(glow: true) {
            HStack {
                SectionLabel("Your goal", color: Tokens.Palette.accentText)
                Spacer()
                if let projected = store.plan?.projected_finish_s,
                   let target = store.goal?.goalTimeSeconds {
                    if projected <= target {
                        Tag(text: "on track")
                    } else {
                        Tag(text: "chasing it", fg: Tokens.Palette.warning, bg: Tokens.Palette.inset)
                    }
                }
            }
            if let g = store.goal, let t = g.goalTimeSeconds {
                Button { router.show(.plan) } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(PaceModel.formatFinish(t)) · \(g.raceName ?? "Race")")
                            .font(Tokens.Font.display(23)).foregroundStyle(Tokens.Palette.textPrimary)
                        HStack(spacing: 18) {
                            metric("TARGET", PaceModel.format(PaceModel.paces(for: .marathon, goalSeconds: Double(t)).marathon) + " /mi")
                            if let day = g.raceDay {
                                metric("RACE", day.formatted(.dateTime.month(.abbreviated).day()))
                            }
                            if let projected = store.plan?.projected_finish_s {
                                metric("PROJECTED", PaceModel.formatFinish(projected))
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(Pressable())
            } else {
                Text("No goal yet").font(Tokens.Font.display(23)).foregroundStyle(Tokens.Palette.textPrimary)
                Text("The coach proposes one from your data — the plan builds from there.")
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                PrimaryButton(title: "Talk to Coach") { router.showCoach() }
            }
        }
    }

    private var yearStats: some View {
        let year = Calendar.current.component(.year, from: .now)
        let thisYear = store.runs.filter { Calendar.current.component(.year, from: $0.start) == year }
        let miles = thisYear.reduce(0.0) { $0 + $1.miles }
        let hours = thisYear.reduce(0) { $0 + $1.durationS } / 3600
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel("\(String(year)) so far")
            Button { router.show(.progress) } label: {
                HStack(spacing: 10) {
                    StatTile(value: String(format: "%.0f", miles), label: "Miles")
                    StatTile(value: "\(thisYear.count)", label: "Runs")
                    StatTile(value: "\(hours)h", label: "Time")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(Pressable())
        }
    }

    @ViewBuilder private var bests: some View {
        let longest = store.runs.max { $0.miles < $1.miles }
        let fastest = store.runs
            .filter { $0.miles >= 3 }
            .compactMap { run in run.paceSecPerMile.map { (run, $0) } }
            .min { $0.1 < $1.1 }
        let biggestWeek = store.weeklySummaries(52).max { $0.miles < $1.miles }
        Card {
            SectionLabel("Bests")
            if let longest {
                bestRow("Longest run", String(format: "%.1f mi", longest.miles), longest.start, run: longest)
            }
            if let (run, pace) = fastest {
                bestRow("Fastest pace (3 mi+)", PaceModel.format(pace) + " /mi", run.start, run: run)
            }
            if let biggestWeek, biggestWeek.miles > 0 {
                bestRow("Biggest week", String(format: "%.1f mi", biggestWeek.miles), biggestWeek.weekStart, run: nil)
            }
            if longest == nil {
                Text("Bests appear once runs sync in.")
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textTertiary)
            }
        }
    }

    /// Best rows open the run that earned them (biggest week goes to Progress).
    private func bestRow(_ label: String, _ value: String, _ date: Date, run: RunSummary?) -> some View {
        Button {
            if let run { router.openRun(run) } else { router.show(.progress) }
        } label: {
            HStack {
                Text(label).font(Tokens.Font.ui(13, .medium)).foregroundStyle(Tokens.Palette.textPrimary)
                Spacer()
                Text(value).font(Tokens.Font.mono(13)).foregroundStyle(Tokens.Palette.accentText)
                Text(date.formatted(.dateTime.month(.abbreviated).day()))
                    .font(Tokens.Font.mono(11)).foregroundStyle(Tokens.Palette.textTertiary)
                    .frame(width: 52, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10)).foregroundStyle(Tokens.Palette.textTertiary)
            }
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
    }

    private var settings: some View {
        Card {
            HStack {
                SectionLabel("Training settings")
                Spacer()
                Button { router.showCoach() } label: {
                    Text("Change via Coach")
                        .font(Tokens.Font.ui(12, .semibold)).foregroundStyle(Tokens.Palette.accentText)
                }
                .buttonStyle(Pressable())
            }
            settingRow("Run days / week", "\(store.daysPerWeek)")
            settingRow("Long run day", Calendar.current.weekdaySymbols[store.longRunDay])
            settingRow("Risk tolerance", store.riskTolerance.capitalized)
            settingRow("Max HR", "\(store.effectiveMaxHR) bpm" + (store.maxHRIsMeasured ? "" : " (est.)"))
            settingRow("Data source", "Apple Health")
        }
    }

    private func settingRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
            Spacer()
            Text(value).font(Tokens.Font.mono(13)).foregroundStyle(Tokens.Palette.textPrimary)
        }
        .frame(minHeight: 24)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(label)
            Text(value).font(Tokens.Font.ui(16, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
        }
    }
}

#Preview {
    YouView()
        .environmentObject(RunStore())
        .environmentObject(TabRouter())
        .preferredColorScheme(.dark)
}
