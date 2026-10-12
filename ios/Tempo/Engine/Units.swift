import Foundation

/// The athlete's distance unit (#108), and the only place in the app that knows how long one
/// is or how to print a distance or pace in it.
///
/// Everything upstream stays in SI: HealthKit, the `runs` table and the recorder all count
/// metres and seconds, and nothing is stored converted. `Units` is the edge. Hand it metres
/// and seconds, get back a number or a string in the athlete's unit.
///
///     let u: Units = store.units
///     u.formatDistance(meters: 8_046.7)              // "5.00 mi"  /  "8.05 km"
///     u.formatPace(seconds: 2_100, meters: 8_046.7)  // "7:00 /mi" /  "4:21 /km"
///     u.splitMeters                                  // 1609.34    /  1000
///     u.completedSplits(meters: 3_300)               // 2          /  3
///
/// Two rules every function here keeps, because breaking either one changes a number on
/// screen without crashing:
///
/// - **Never round before converting.** Metres go in as `Double` and are divided exactly
///   once. Rounding happens only when a string is built. Rounding first, to whole metres or
///   to 0.01 mi then into km, compounds into a split that lands in the wrong place, or a
///   total that disagrees with the sum of its splits.
/// - **Round the whole pace, then split it.** 419.6 s is 7:00, not 6:60. Formatting `m:ss`
///   from an unrounded value is how a pace ends up showing sixty seconds.
///
/// Strings are fixed-locale (`.` decimal, ASCII digits) to match `ChangeLedger.Format`, so a
/// line reads the same in a test as on the phone.
enum Units: String, CaseIterable, Codable, Sendable {
    case mi, km

    /// The app's mile. It's 1609.34 rather than the statute 1609.344 because every
    /// existing mile figure (`RaceRecap.metersPerMile`, `RunSummary.miles`, the 20-mile
    /// long-run threshold) already uses 1609.34. Changing it in one place would split the
    /// app in two. The 4 mm gap is 0.1 m over a marathon.
    static let metersPerMile = 1609.34
    static let metersPerKilometer = 1000.0

    /// What a profile with no readable preference gets: no row yet, a null, a value this
    /// build doesn't know. Matches the column default in migration 0015.
    static let fallback: Units = .mi

    /// The stored `profiles.units` value, read leniently. Anything unrecognised is miles
    /// rather than an error, because a bad unit string must not stop the app from launching.
    init(stored: String?) {
        self = stored.flatMap { Units(rawValue: $0.lowercased()) } ?? Self.fallback
    }

    // MARK: - Lengths

    /// Metres in one of this unit. This is also the split length: the recorder announces
    /// a split every `splitMeters`.
    var meters: Double {
        switch self {
        case .mi: return Self.metersPerMile
        case .km: return Self.metersPerKilometer
        }
    }

    /// Split length in metres: 1609.34 for miles, 1000 for kilometres. Same value as
    /// `meters`, with a name that says what the recorder uses it for.
    var splitMeters: Double { meters }

    // MARK: - Conversions (no rounding, ever)

    /// Metres to this unit: 1609.34 m is 1.0 mi.
    func distance(meters m: Double) -> Double { m / meters }

    /// This unit back to metres: 1.0 mi is 1609.34 m. The inverse of `distance(meters:)`.
    func meters(distance d: Double) -> Double { d * meters }

    /// Seconds per one of this unit, over `meters` covered in `seconds`. Nil when no distance
    /// has been covered, because "no pace yet" is different from a pace of zero.
    func pace(seconds: Double, meters m: Double) -> Double? {
        guard m > 0, seconds >= 0, m.isFinite, seconds.isFinite else { return nil }
        return seconds / distance(meters: m)
    }

    /// Re-express a seconds-per-mile pace (how the engine and the plan store every pace,
    /// see `TrainingPaces`) in this unit. 7:00 /mi is about 4:21 /km.
    func pace(secondsPerMile: Double) -> Double {
        secondsPerMile * meters / Self.metersPerMile
    }

    /// How many whole splits are complete at `meters` covered. The recorder's voice cue
    /// fires when this ticks up, so a split lands exactly on its boundary: 1609.34 m is
    /// split 1 done, 1609.33 m is not.
    func completedSplits(meters m: Double) -> Int {
        guard m > 0, m.isFinite else { return 0 }
        return Int((m / splitMeters).rounded(.down))
    }

    // MARK: - Labels

    /// "mi" / "km": the label after a number.
    var abbreviation: String { rawValue }

    /// "/mi" / "/km": the label after a pace.
    var paceSuffix: String { "/" + rawValue }

    /// Spoken name, for voice cues: "mile"/"miles", "kilometer"/"kilometers".
    func name(plural: Bool) -> String {
        switch self {
        case .mi: return plural ? "miles" : "mile"
        case .km: return plural ? "kilometers" : "kilometer"
        }
    }

    // MARK: - Formatting

    /// "5.00 mi". Metres in, converted, rounded only here.
    func formatDistance(meters m: Double, decimals: Int = 2) -> String {
        String(format: "%.\(max(decimals, 0))f %@", distance(meters: m), abbreviation)
    }

    /// "7:00 /mi". A pace already in seconds per this unit.
    func formatPace(_ secondsPerUnit: Double) -> String {
        let clock = Self.clock(secondsPerUnit)
        return clock == Self.missing ? clock : clock + " " + paceSuffix
    }

    /// "7:00 /mi". The pace of `meters` covered in `seconds`, or "—" before any distance.
    func formatPace(seconds: Double, meters m: Double) -> String {
        pace(seconds: seconds, meters: m).map { formatPace($0) } ?? Self.missing
    }

    /// "m:ss" with no unit, rounded to the whole second before it is split into minutes
    /// and seconds. 59.5 is "1:00". Minutes are not wrapped into hours, since a pace is never
    /// that slow. "—" for a negative or non-finite value.
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return missing }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// What a pace or distance reads as when there isn't one.
    static let missing = "—"
}
