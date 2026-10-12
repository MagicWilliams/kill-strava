import Foundation

/// The bridge from what the engine already counts in miles to what the athlete reads (#109).
///
/// `Units` itself takes metres and seconds. Most of the app's aggregates predate it and are
/// in miles: `RunSummary.miles`, `WeekSummary.miles`, `BlockReview.totalMiles`, the plan's
/// `target_mileage`, every pace as whole seconds per mile (`TrainingPaces`, `avg_pace_sec`).
/// Rewriting those to metres would touch every engine and its tests for no change in a
/// single number, so screens hand them through here instead.
///
/// The no-rounding rule still holds. Each of those mile figures was made by dividing metres
/// by `metersPerMile` and never rounded, so multiplying back by the same constant is exact
/// to the last bit that matters, and the one rounding is still the one in the string.
/// Paces stored as whole seconds per mile are the exception: there is no unrounded source
/// for a plan target, so a km athlete's target can sit a fraction of a second from the
/// exact conversion. Where a run's metres and seconds exist, `runPace` uses them instead.
///
/// Compiled into the widget extension as well (see `project.yml`), which renders the
/// snapshot's mile figures in the snapshot's unit.
extension Units {

    // MARK: - Miles in

    /// A mile figure in this unit. 26.2188 mi is 42.195 km.
    func distance(miles: Double) -> Double {
        distance(meters: miles * Self.metersPerMile)
    }

    /// "34.2 mi" / "55.0 km", from a figure the engine holds in miles.
    func formatDistance(miles: Double, decimals: Int = 1) -> String {
        formatDistance(meters: miles * Self.metersPerMile, decimals: decimals)
    }

    /// "34.2" / "55.0": the number alone, for the places that set the label in its own
    /// type next to it (Today's week total, the 12-week card).
    func number(miles: Double, decimals: Int = 1) -> String {
        Self.fixed(distance(miles: miles), decimals: decimals)
    }

    /// "8.05": the number alone, from metres.
    func number(meters m: Double, decimals: Int = 1) -> String {
        Self.fixed(distance(meters: m), decimals: decimals)
    }

    // MARK: - Paces in seconds per mile

    /// "7:00 /mi" / "4:21 /km", from a pace held as seconds per mile.
    func formatPace(secondsPerMile: Double) -> String {
        formatPace(pace(secondsPerMile: secondsPerMile))
    }

    func formatPace(secondsPerMile: Int) -> String {
        formatPace(secondsPerMile: Double(secondsPerMile))
    }

    /// "7:00" / "4:21": a seconds-per-mile pace in this unit, with no label.
    func clock(secondsPerMile: Double) -> String {
        Self.clock(pace(secondsPerMile: secondsPerMile))
    }

    func clock(secondsPerMile: Int) -> String {
        clock(secondsPerMile: Double(secondsPerMile))
    }

    /// A run's moving pace, in seconds per this unit, under the same rule as
    /// `TimeAccounting.paceSecPerMile` (nothing under 0.05 mi gets a pace).
    ///
    /// In miles it is exactly that function's whole-second figure, the one the records rank
    /// on, so a mile athlete reads the number he always has. In kilometres it comes from
    /// the run's metres and seconds directly: converting the already-truncated mile pace
    /// would put a second of error on a km label for no reason.
    ///
    /// The rule is restated rather than called because the widget extension compiles this
    /// file without `TimeAccounting`; `UnitsDisplayTests` pins the two to each other.
    func runPace(movingSeconds: Int, meters: Int) -> Double? {
        let miles = Double(meters) / Self.metersPerMile
        guard miles > 0.05, movingSeconds > 0 else { return nil }
        switch self {
        case .mi: return Double(Int(Double(movingSeconds) / miles))
        case .km: return pace(seconds: Double(movingSeconds), meters: Double(meters))
        }
    }

    /// "8:45 /mi" / "5:26 /km" for a run, or "—" with no pace.
    func formatRunPace(movingSeconds: Int, meters: Int) -> String {
        runPace(movingSeconds: movingSeconds, meters: meters).map { formatPace($0) } ?? Self.missing
    }

    // MARK: - Words

    /// The unit as a tile label: "miles" / "km". "Kilometers" is spelled out by
    /// `name(plural:)` for speech, but it does not fit a third of the screen in caps.
    var tileName: String {
        switch self {
        case .mi: return name(plural: true)
        case .km: return abbreviation
        }
    }

    /// The heading over a weekly-volume chart. "Mileage" is a unit word; a km athlete's
    /// chart is not of miles.
    var weeklyVolumeTitle: String {
        switch self {
        case .mi: return "Weekly mileage"
        case .km: return "Weekly distance"
        }
    }

    // MARK: - Thresholds

    /// The long-run threshold as the athlete thinks of it: 20 in miles, 32 in kilometres.
    ///
    /// Not a conversion. 20 mi is 32.19 km, and nobody calls a long run "32.19+ km". 32 km
    /// is the round figure km athletes use for the same run, and it is what the label says.
    /// The count underneath is unchanged (`BlockReview.twentyMileMeters`): one number is
    /// counted, only its name differs by unit.
    var longRunThresholdLabel: String {
        switch self {
        case .mi: return "20+ mi"
        case .km: return "32+ km"
        }
    }

    // MARK: -

    /// Fixed-locale, the same as `formatDistance`: "." decimal, ASCII digits.
    static func fixed(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(max(decimals, 0))f", value)
    }
}
