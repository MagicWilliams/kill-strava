import SwiftUI

/// Profile: goal hero, real year stats, bests from actual runs, and the
/// chat-mutable training settings (everything here changes via the Coach).
struct YouView: View {
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var router: TabRouter
    @Environment(\.units) private var units

    var body: some View {
        Screen(title: "You", subtitle: subtitle) {
            goal
            pastBlocks
            yearStats
            bests
            ShoesCard()
            settings
        }
        .refreshable { await store.refresh() }
    }

    private var subtitle: String? {
        guard let goal = store.goal, let day = goal.raceDay else { return "No goal yet" }
        let weeks = max((Calendar.current.dateComponents([.day], from: .now, to: day).day ?? 0) / 7, 0)
        let role = goal.raceRole.label.map { " · \($0)" } ?? ""
        return "\(goal.raceName ?? "Race")\(role) · \(weeks) weeks out"
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
            // A goal with no target time is still a goal (#231). This used to branch on
            // `goalTimeSeconds`, so the 27 Nov tune-up — a real goal, deliberately untimed —
            // got the empty state, offering to set a goal the subtitle above it was already
            // naming. `GoalLine.State` keeps "no goal" and "no target time" apart (#44); the
            // card now reads it instead of re-deciding.
            switch store.goalLine {
            case .noGoal:
                Text("No goal yet").font(Tokens.Font.display(23)).foregroundStyle(Tokens.Palette.textPrimary)
                Text("The coach proposes one from your data — the plan builds from there.")
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                PrimaryButton(title: "Talk to Coach") { router.showCoach() }
            case .untimed:
                goalCard(
                    title: raceLabel,
                    detail: GoalLine.untimedLine(goalType: store.goal?.goal_type, on: raceDayLabel),
                    target: nil
                )
            case .timed(_, _, let seconds):
                goalCard(
                    title: "\(PaceModel.formatFinish(seconds)) · \(raceLabel)",
                    detail: nil,
                    target: GoalLine.targetPace(goal: store.goal, units: units)
                )
            }
        }
    }

    /// The race named once, with its distance (#231). The fallback is unreachable from the
    /// two cases that use it — `raceLabel` is nil only when there is no goal at all.
    private var raceLabel: String {
        GoalLine.raceLabel(goal: store.goal, units: units) ?? GoalLine.unnamedRace
    }

    /// Race day as the RACE metric prints it, so the two lines of the card can't disagree
    /// about the date they are both showing.
    private var raceDayLabel: String? {
        store.goal?.raceDay?.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The tappable goal card: title, an optional second line, and the metric row. Both the
    /// timed and the untimed goal use it, so tapping either opens Plan.
    ///
    /// A nil `target` leaves TARGET out of the row rather than printing a dash in it. A dash
    /// under a column heading reads as a number that failed to load; this one was never set.
    private func goalCard(title: String, detail: String?, target: String?) -> some View {
        Button { router.show(.plan) } label: {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(Tokens.Font.display(23)).foregroundStyle(Tokens.Palette.textPrimary)
                    if let detail {
                        Text(detail)
                            .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
                    }
                }
                HStack(spacing: 18) {
                    if let target {
                        metric("TARGET", target)
                    }
                    if let day = raceDayLabel {
                        metric("RACE", day)
                    }
                    if let projected = store.plan?.projected_finish_s {
                        metric("PROJECTED", PaceModel.formatFinish(projected))
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
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
