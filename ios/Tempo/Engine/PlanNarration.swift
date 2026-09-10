import Foundation

/// The lines the app writes into the transcript after the plan engine runs.
///
/// This exists because of *where* those lines used to be written from.
/// `ChatStore.invokePlanEngine` appended "Plan is live: 16 weeks…" itself, from inside the
/// switch that executes a confirmed card — which runs before `confirm` appends the
/// "Confirmed — …" turn that caused it. The transcript told the story backwards: the coach
/// announcing the result above the tap that asked for it (#39).
///
/// Returning the line instead of writing it takes that choice away from the write path. The
/// apply path can no longer decide where its narration lands; only `ChatStore.apply` can, and
/// it puts it after the confirmation. That is the actual fix — the ordering is structural now
/// rather than a line of code someone has to keep in the right place.
///
/// Pure, so the wording can be pinned. Every way this regresses is a sentence that reads
/// wrong — a plan announced as "0 weeks", a stray "base_build" with the underscore still in
/// it — rather than anything that crashes.
enum PlanNarration {

    /// What the `plan` Edge Function reported, in the shape the transcript cares about.
    struct PlanResult: Equatable {
        var weeks: Int?
        var archetype: String?
        var rationale: String?
        var projectedFinishSeconds: Int?
        var startWeeklyMiles: Double?
        var peakWeeklyMiles: Double?
    }

    /// The "Plan is live…" line, or nothing.
    ///
    /// No week count means the engine came back without a plan to announce; a half-sentence
    /// about volume with no plan behind it is worse than saying nothing, and the athlete
    /// already has the card's own state to read.
    static func planIsLive(_ result: PlanResult) -> String? {
        guard let weeks = result.weeks else { return nil }
        var lines = ["Plan is live: \(weeks) weeks (\((result.archetype ?? "custom").replacingOccurrences(of: "_", with: " ")))."]
        if let start = result.startWeeklyMiles, let peak = result.peakWeeklyMiles {
            lines.append("Volume runs \(String(format: "%.0f", start)) → \(String(format: "%.0f", peak)) mi/wk.")
        }
        if let projection = result.projectedFinishSeconds {
            lines.append("Projection today: \(PaceModel.formatFinish(projection)).")
        }
        if let why = result.rationale { lines.append(why) }
        return lines.joined(separator: " ")
    }

    /// Structure changed, but there is no plan to rebuild with it yet. Said out loud because
    /// the alternative is a Confirm that saves something and then appears to do nothing.
    static let settingsSavedWithoutPlan =
        "Settings saved. No active plan to rebuild yet — they'll shape the plan when we create it."
}
