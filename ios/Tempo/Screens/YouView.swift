import SwiftUI

/// Profile: goal hero, real year stats, bests from actual runs, and the
/// chat-mutable training settings (everything here changes via the Coach).
struct YouView: View {
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var router: TabRouter
    @Environment(\.units) private var units

    var body: some View {
        Screen(title: "You", subtitle: countdown.subtitle(), compactSubtitle: countdown.subtitle(.compact)) {
            goal
            pastBlocks
            yearStats
            bests
            ShoesCard()
            settings
        }
        .refreshable { await store.refresh() }
    }

    /// The same state Plan and Progress read (#230). This header used to count from `.now`
    /// and then floor into weeks, which on 15 Oct made You say "6 weeks out" to Progress's
    /// "7 weeks" about the same 27 Nov race — two lost days, one from counting off the
    /// current instant and one from the floor.
    ///
    /// You is the only header that prints the race's role, so it is the only one that asks
    /// for it: "Turkey Trot · 5K · tune-up · 43 days · 7 weeks" (#238).
    private var countdown: RaceCountdown.State {
        RaceCountdown.state(goal: store.goal, now: .now, units: units, includingRole: true)
    }

    @ViewBuilder private var goal: some View {
        Card(glow: true) {
            HStack {
                SectionLabel("Your goal", color: Tokens.Palette.accentText)
                Spacer()
                if let role = store.goal?.raceRole.label {
                    Tag(text: role)
                }
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
                            metric("TARGET", GoalLine.targetPace(goal: g, units: units))
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

    /// Closed training blocks, newest first (#100). Hidden until there is one.
    private var pastBlocks: some View {
        PastBlocksCard()
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
                    StatTile(value: units.number(miles: miles, decimals: 0), label: units.tileName.capitalized)
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
                bestRow("Longest run", units.formatDistance(meters: Double(longest.distanceM), decimals: 1), longest.start, run: longest)
            }
            if let (run, _) = fastest,
               let pace = units.runPace(movingSeconds: run.durationS, meters: run.distanceM) {
                bestRow("Fastest pace (\(RunHistory.Band.threeMile.label(units)))", units.formatPace(pace), run.start, run: run)
            }
            if let biggestWeek, biggestWeek.miles > 0 {
                bestRow("Biggest week", units.formatDistance(miles: biggestWeek.miles), biggestWeek.weekStart, run: nil)
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
            unitsRow
        }
    }

    /// The one setting here that doesn't go through the Coach: a display preference, not a
    /// training decision (#108). Written straight to the profile.
    private var unitsRow: some View {
        HStack {
            Text("Units").font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
            Spacer()
            Picker("Units", selection: Binding(
                get: { store.units },
                set: { new in Task { await store.setUnits(new) } }
            )) {
                Text("mi").tag(Units.mi)
                Text("km").tag(Units.km)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 96)
        }
        .frame(minHeight: 24)
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
