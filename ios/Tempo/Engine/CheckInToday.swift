import Foundation

/// Whether the check-in we hold is actually *today's*, and what a read of `check_ins` means
/// for the one we hold.
///
/// `RunStore.todayCheckIn` lives as long as the app process does, and the app survives
/// midnight whenever iOS lets it. Nothing compared the stored `date` to today, so Tuesday's
/// answer stood in for Wednesday's (#226): Today printed "Checked in, good to go", the prompt
/// before a hard session stayed suppressed so the athlete was never asked, readiness stayed
/// shaped by a stale boolean, and the coach was handed yesterday's state as `check_in_today`.
/// Nothing crashed and nothing on screen said the answer was a day old, which is the whole
/// problem: it is invisible from the athlete's side.
///
/// The read half carries its own scar. `loadPlan()` is non-destructive on failure by design,
/// because a network blip must not blank the screen, and until #224 the check-in read used
/// `try?` over a `.single()`, which made "no check-in today" and "couldn't ask" the same
/// `nil`. Clearing on that `nil` would have re-prompted the athlete every time the network
/// hiccuped. So the two answers have to stay apart: an empty array is a definitive no and
/// clears, a thrown error says nothing and keeps what is held.
///
/// Both decisions are pure comparisons, extracted here rather than mocked against Supabase,
/// the same move as `Engine/RunDedupe.swift`.
enum CheckInToday {

    /// The held check-in, but only when it is today's.
    ///
    /// `today` is the same `PlanDates.todayString` the query filters on, so the accessor and
    /// the read agree on where the day boundary falls, and both follow the device if its
    /// timezone or date changes.
    static func forToday(held: CheckInInfo?, today: String) -> CheckInInfo? {
        guard let held, held.date == today else { return nil }
        return held
    }

    /// What a read of today's `check_ins` rows came back with.
    enum Response {
        /// The server answered. Empty means there is genuinely no check-in today.
        case rows([CheckInInfo])
        /// The read threw. It says nothing either way about whether a check-in exists.
        case unreachable
    }

    /// What `todayCheckIn` should hold after a read.
    ///
    /// On `.unreachable` this deliberately keeps a value that may be yesterday's: the stored
    /// property is allowed to hold a stale check-in, and `forToday` is what stops it reaching
    /// a screen or the coach. Keeping it is what makes a failed read non-destructive.
    static func resolve(_ response: Response, held: CheckInInfo?) -> CheckInInfo? {
        switch response {
        case .rows(let rows):  return rows.first
        case .unreachable:     return held
        }
    }
}
