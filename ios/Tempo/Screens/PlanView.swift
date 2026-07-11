import SwiftUI

/// The adaptive plan: race countdown, phase progress, and the week list —
/// current + next week in full detail, further weeks as an honest sketch
/// that crystallizes as it approaches (spec: "2 wks firm, rest sketch").
struct PlanView: View {
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var router: TabRouter

    var body: some View {
        Screen(title: title, subtitle: subtitle) {
            if store.plan == nil {
                noPlan
            } else {
                countdown
                phaseChips
                weeksList
            }
        }
        .refreshable {
            await store.loadPlan()
            await store.refresh()
        }
    }

    private var title: String {
        store.plan.map { "\($0.weeks)-Week Plan" } ?? "Plan"
    }

    private var subtitle: String? {
        guard let goal = store.goal else { return "No plan yet" }
        let time = goal.goalTimeSeconds.map { " · goal " + PaceModel.formatFinish($0) } ?? ""
        return (goal.raceName ?? "Race") + time
    }

    private var noPlan: some View {
        Card(glow: true) {
            SectionLabel("Your plan", color: Tokens.Palette.volt)
            Text("Built from your data, not a template")
                .font(Tokens.Font.display(22)).foregroundStyle(Tokens.Palette.textPrimary)
            Text("The coach assesses your real running history, proposes a goal, and generates a schedule anchored on what you actually do — phases emerge from what's missing.")
                .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
            PrimaryButton(title: "Start with the Coach") { router.showCoach() }
        }
    }

    private var countdown: some View {
        Card(glow: true) {
            HStack {
                SectionLabel(store.goal?.raceName ?? "Race", color: Tokens.Palette.volt)
                Spacer()
                if let day = store.goal?.raceDay {
                    Text(day.formatted(.dateTime.month(.abbreviated).day()))
                        .font(Tokens.Font.ui(13, .semibold)).foregroundStyle(Tokens.Palette.textSecondary)
                }
            }
            if let day = store.goal?.raceDay {
                let days = max(Calendar.current.dateComponents([.day], from: .now, to: day).day ?? 0, 0)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(days)").font(Tokens.Font.display(46)).foregroundStyle(Tokens.Palette.textPrimary)
                    Text("days to go").font(Tokens.Font.ui(14)).foregroundStyle(Tokens.Palette.textSecondary)
                }
            }
            if let week = store.currentPlanWeek, let plan = store.plan {
                Text("Week \(week) of \(plan.weeks) · \(store.currentPhase?.capitalized ?? "—") phase · \(Int(Double(week - 1) / Double(max(plan.weeks, 1)) * 100))% complete")
                    .font(Tokens.Font.ui(13)).foregroundStyle(Tokens.Palette.textSecondary)
            }
        }
    }

    private var phaseChips: some View {
        let phases = orderedPhases
        return HStack(spacing: 8) {
            ForEach(phases, id: \.self) { phase in
                let active = phase == store.currentPhase
                Text(phase.capitalized)
                    .font(Tokens.Font.ui(13, active ? .semibold : .medium))
                    .foregroundStyle(active ? Tokens.Palette.onVolt : Tokens.Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(active ? Tokens.Palette.volt : Tokens.Palette.surface)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(active ? Color.clear : Tokens.Palette.elevated, lineWidth: 1))
            }
        }
    }

    private var orderedPhases: [String] {
        var seen: [String] = []
        for w in store.planWeeks where !seen.contains(w.phase) { seen.append(w.phase) }
        return seen
    }

    @ViewBuilder private var weeksList: some View {
        let current = (store.currentPlanWeek ?? 1) - 1   // 0-based
        ForEach(store.planWeeks) { week in
            if week.week_index == current || week.week_index == current + 1 {
                firmWeek(week)
            } else {
                sketchWeek(week, past: week.week_index < current)
            }
        }
    }

    /// Fully-prescribed week (current + next).
    private func firmWeek(_ week: PlanWeekInfo) -> some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Week \(week.week_index + 1) · \(week.phase.capitalized)")
                        .font(Tokens.Font.ui(15, .semibold)).foregroundStyle(Tokens.Palette.textPrimary)
                    if let focus = week.focus {
                        Text(focus).font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
                    }
                }
                Spacer()
                if let target = week.target_mileage {
                    Text(String(format: "%.0f mi", target)).font(Tokens.Font.mono(13)).foregroundStyle(Tokens.Palette.volt)
                }
            }
            Rectangle().fill(Tokens.Palette.divider).frame(height: 1)
            ForEach(sessions(inWeek: week.week_index)) { s in
                sessionRow(s)
            }
        }
    }

    private func sessions(inWeek index: Int) -> [SessionInfo] {
        guard let plan = store.plan else { return [] }
        guard let start = Calendar.current.date(byAdding: .day, value: index * 7, to: plan.startDate),
              let end = Calendar.current.date(byAdding: .day, value: 7, to: start) else { return [] }
        let s = PlanDates.day.string(from: start)
        let e = PlanDates.day.string(from: end)
        return store.sessions.filter { $0.date >= s && $0.date < e }
    }

    private func sessionRow(_ s: SessionInfo) -> some View {
        let isToday = s.date == PlanDates.todayString
        let missed = s.status == "planned" && s.date < PlanDates.todayString
        return HStack(spacing: 10) {
            Text(s.day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(Tokens.Font.mono(10)).tracking(1)
                .foregroundStyle(isToday ? Tokens.Palette.volt : Tokens.Palette.textTertiary)
                .frame(width: 32, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(s.title ?? s.type.capitalized)
                        .font(Tokens.Font.ui(13, isToday ? .semibold : .medium))
                        .foregroundStyle(s.status == "skipped" ? Tokens.Palette.textTertiary : Tokens.Palette.textPrimary)
                        .strikethrough(s.status == "skipped", color: Tokens.Palette.textTertiary)
                    if s.adapted {
                        Tag(text: "adapted", fg: Tokens.Palette.info, bg: Tokens.Palette.inset)
                    }
                }
                if let note = s.adaptation_note, s.adapted {
                    Text(note).font(Tokens.Font.ui(10)).foregroundStyle(Tokens.Palette.info.opacity(0.8))
                        .lineLimit(2)
                } else if let detail = s.detail {
                    Text(detail).font(Tokens.Font.mono(11)).foregroundStyle(Tokens.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if s.status == "done" {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Tokens.Palette.success)
            } else if s.status == "skipped" || missed {
                Image(systemName: "minus.circle").font(.system(size: 14)).foregroundStyle(Tokens.Palette.textTertiary)
            } else if s.isQuality {
                Circle().fill(Tokens.Palette.volt).frame(width: 7, height: 7)
            }
        }
        .frame(minHeight: 26)
    }

    /// Sketch week: phase, focus, target — crystallizes as it approaches.
    private func sketchWeek(_ week: PlanWeekInfo, past: Bool) -> some View {
        Card(padding: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Week \(week.week_index + 1) · \(week.phase.capitalized)")
                        .font(Tokens.Font.ui(14, .medium)).foregroundStyle(Tokens.Palette.textPrimary)
                    if let focus = week.focus {
                        Text(focus).font(Tokens.Font.ui(12)).foregroundStyle(Tokens.Palette.textSecondary)
                    }
                }
                Spacer()
                if let target = week.target_mileage {
                    Text(String(format: "%.0f mi", target)).font(Tokens.Font.mono(13)).foregroundStyle(Tokens.Palette.textSecondary)
                }
            }
        }
        .opacity(past ? 0.45 : 0.8)
    }
}

#Preview {
    PlanView()
        .environmentObject(RunStore())
        .environmentObject(TabRouter())
        .preferredColorScheme(.dark)
}
