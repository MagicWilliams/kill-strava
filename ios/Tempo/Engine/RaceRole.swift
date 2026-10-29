import Foundation

/// What a race is for: the one a block is built toward, or a tune-up on the way to it (#238).
///
/// On 15 Oct the athlete told the coach the Turkey Trot was a tune-up. Nothing could hold that,
/// so the coach saved `goal_type: "unsure"`, and the app had no way to say "tune-up" anywhere
/// (#231). David's call on #232 (1A): it lives in `goals.preferences.race_role`, set by the
/// coach's create_plan card. That column is already jsonb, so it needed no migration. It is
/// kept apart from `goal_type` on purpose. One says what the race is for, the other how it is
/// measured, and a tune-up can still be a time goal.
///
/// **Missing means `.goal`.** Every goal before #238 has no role, and each one was the race its
/// block was built for.
enum RaceRole: String, Equatable, CaseIterable {
    case goal
    case tuneUp = "tune_up"

    /// A stored or proposed value, or nil when it isn't one. Read leniently, the same way the
    /// `plan` function reads it (`goal.ts raceRole`): "tune-up" and "Tune up" are one answer.
    init?(wire: String?) {
        let slug = (wire ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z]+", with: "_", options: .regularExpression)
        switch slug {
        case "goal":              self = .goal
        case "tune_up", "tuneup": self = .tuneUp
        default:                  return nil
        }
    }

    /// The role a goal's preferences record; `.goal` when they record none.
    static func of(_ preferences: GoalPreferences?) -> RaceRole {
        RaceRole(wire: preferences?.race_role) ?? .goal
    }

    /// The word the You card, the confirm card and the plan narration print. Nil for an
    /// ordinary goal race: "goal" on a goal would be noise.
    var label: String? {
        switch self {
        case .goal:   return nil
        case .tuneUp: return "tune-up"
        }
    }
}

extension GoalInfo {
    /// What this goal's race is for (#238).
    var raceRole: RaceRole { RaceRole.of(preferences) }
}
