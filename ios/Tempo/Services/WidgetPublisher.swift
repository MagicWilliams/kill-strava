import Foundation
import WidgetKit

/// Writes the widget snapshot from `RunStore` state and asks WidgetKit to redraw (#76).
///
/// The adapter only: every decision — which runs count toward which week, which session is
/// "next", what happens to the coach line — is in `WidgetSnapshot.build`, which is pure and
/// tested. This file just maps app models onto its inputs.
extension RunStore {

    /// Called at the end of a successful refresh and when a coach takeaway lands. Cheap
    /// enough to call more often than needed: one encode, one defaults write.
    func publishWidgetSnapshot() {
        let now = Date.now
        let snapshot = WidgetSnapshot.build(
            now: now,
            runs: runs.map { WidgetSnapshot.RunInput(start: $0.start, miles: $0.miles) },
            sessions: sessions.map {
                WidgetSnapshot.SessionInput(
                    day: $0.day, type: $0.type, title: $0.title, status: $0.status,
                    targetMiles: $0.targetMiles, targetPaceSec: $0.target_pace_sec, detail: $0.detail
                )
            },
            weekTargetMiles: planTargetMiles(at: now),
            nextWeekTargetMiles: Self.cal.date(byAdding: .weekOfYear, value: 1, to: now).flatMap(planTargetMiles(at:)),
            coachLine: todayTakeawayLine,
            previous: WidgetSnapshotStore.load(),
            calendar: Self.cal
        )
        WidgetSnapshotStore.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// The takeaway Today is showing, dated to the session it reads.
    private var todayTakeawayLine: WidgetSnapshot.CoachLine? {
        guard let text = todayTakeaway, let session = todaySession else { return nil }
        return WidgetSnapshot.CoachLine(text: text, day: session.day)
    }

    /// The plan's weekly mileage target for the plan week containing `date` — the same week
    /// arithmetic as `currentPlanWeek`, so the gauge measures against the number the coach
    /// is given as `week_target_mi`.
    private func planTargetMiles(at date: Date) -> Double? {
        guard let plan else { return nil }
        let days = Self.cal.dateComponents([.day], from: Self.cal.startOfDay(for: plan.startDate),
                                           to: Self.cal.startOfDay(for: date)).day ?? 0
        guard days >= 0 else { return nil }
        let week = days / 7 + 1
        guard (1...plan.weeks).contains(week) else { return nil }
        return planWeeks.first { $0.week_index == week - 1 }?.target_mileage
    }
}
