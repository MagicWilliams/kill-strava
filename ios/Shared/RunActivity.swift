import Foundation

/// What the Lock Screen and the Dynamic Island know about the run in progress (#119): the
/// `ContentState` of `RunActivityAttributes`, sent from the app by `RunLiveActivity`.
///
/// The normal case is a phone in a pocket or an armband, so this is the screen he reads pace
/// from mid-run more often than the app itself. It holds raw numbers, not strings, and
/// `RunActivityDisplay` turns them into what is drawn, with the live screen's own rules
/// (`RunActivityTests` pins the two against each other). A glance at the Lock Screen that
/// disagrees with the app by a hundredth would make him trust neither.
///
/// Compiled into both targets, like `WidgetSnapshot`. Pure: Foundation and `Units` only.
struct RunActivityState: Codable, Hashable, Sendable {

    /// What the run is doing, and so which button the Lock Screen draws.
    enum Stage: String, Codable, Hashable, Sendable {
        /// Pause.
        case running
        /// Resume.
        case paused
        /// The recorder lost hold of the run (the workout session failed) and only the app can
        /// save or discard it. No button: neither would be accepted (`RecorderState.reduce`).
        case interrupted
        /// He ended it and the save screen is up. The clock is stopped; no button.
        case ended
    }

    var stage: Stage
    /// The instant the countdown finished. The clock counts from here.
    var startedAt: Date
    /// Set once he has ended the run; the clock stops here.
    var endedAt: Date?
    var distanceM: Double
    /// Seconds per `units`. Nil when there is no current pace: paused, or GPS still finding him.
    var currentPaceS: Double?
    /// Today's target pace in seconds per `units`. Nil running free, or with no target pace.
    var targetPaceS: Double?
    /// Average moving pace minus `targetPaceS`: positive is slower than target.
    var vsTargetS: Double?
    /// Fixed at the countdown, like the recorder's: a run is read in the unit it started in.
    var units: Units
}

/// A Lock Screen button, as the app receives it. The Live Activity can pause and resume and
/// nothing else (David, #125): there is deliberately no case for ending or discarding.
enum RunActivityCommand: String, Codable, Sendable {
    case pause, resume
}

/// Every string the Live Activity draws, from one `RunActivityState`.
struct RunActivityDisplay: Equatable {

    enum Trend: Equatable { case ahead, onPace, behind, unknown }

    let stage: RunActivityState.Stage
    /// The elapsed clock's interval, for `Text(timerInterval:pauseTime:)`: it ticks on the
    /// Lock Screen by itself, with no update from the app.
    let clock: ClosedRange<Date>
    /// Where the clock is frozen, once the run has ended. Nil while it ticks.
    let clockStoppedAt: Date?
    /// "3.42", hundredths rounded down, as on the live screen.
    let distance: String
    /// "mi" / "km".
    let distanceUnit: String
    /// "7:41", or "—".
    let pace: String
    /// "/mi" / "/km".
    let paceSuffix: String
    /// "+0:12", "-0:08", "on pace", "—"; nil with no target pace, or running free.
    let vsTarget: String?
    let trend: Trend
    /// The line by the logo: "Running", "Paused", …
    let status: String
    /// How far through the current mile or kilometre, 0 up to 0.99: the minimal Dynamic
    /// Island's ring. Taken from the same floored hundredths as `distance`, so the ring and
    /// the number roll over together, on the metre the split cue fires.
    let splitProgress: Double
    let offersPause: Bool
    let offersResume: Bool

    /// - Parameter isStale: ActivityKit's flag that the app stopped updating past the stale
    ///   date (`RunActivityPlan.staleAfterS`). The numbers on screen are then old, and the
    ///   status says so rather than passing them off as live.
    init(_ state: RunActivityState, isStale: Bool = false) {
        let units = state.units
        stage = state.stage
        let end = state.endedAt.map { max($0, state.startedAt) }
        clock = state.startedAt...(end ?? .distantFuture)
        clockStoppedAt = end
        let floored = Self.flooredHundredths(meters: state.distanceM, units: units)
        distance = Units.fixed(Double(floored) / 100, decimals: 2)
        distanceUnit = units.abbreviation
        splitProgress = Double(floored % 100) / 100
        pace = state.stage == .running ? (state.currentPaceS.map(Units.clock) ?? Units.missing) : Units.missing
        paceSuffix = units.paceSuffix
        (vsTarget, trend) = Self.vsTarget(paceS: state.targetPaceS, deltaS: state.vsTargetS)
        status = Self.status(state.stage, isStale: isStale)
        offersPause = state.stage == .running
        offersResume = state.stage == .paused
    }

    /// The distance in hundredths of `units`, rounded down.
    ///
    /// The live screen's rule, restated because the widget extension compiles this file
    /// without `LiveRunDisplay`: whole units and hundredths floored separately, so the whole
    /// part is the same division `Units.completedSplits` does and the Lock Screen can't read
    /// "1.00" while the voice is still waiting to say "Mile one". `RunActivityTests` pins it
    /// to `LiveRunDisplay.distance`.
    static func flooredHundredths(meters: Double, units: Units) -> Int {
        guard meters.isFinite, meters > 0 else { return 0 }
        let d = units.distance(meters: meters)
        let whole = d.rounded(.down)
        let hundredths = min(99, ((d - whole) * 100).rounded(.down))
        return Int(whole) * 100 + Int(hundredths)
    }

    /// The live screen's vs-target rule (`LiveRunDisplay.vsTarget`): within half a second
    /// either way is "on pace", which a whole-second display would show as "+0:00" anyway.
    /// A target with no pace has nothing to compare on a glance, and shows nothing.
    static func vsTarget(paceS: Double?, deltaS: Double?) -> (String?, Trend) {
        guard paceS != nil else { return (nil, .unknown) }
        guard let delta = deltaS, delta.isFinite else { return (Units.missing, .unknown) }
        if abs(delta) < 0.5 { return ("on pace", .onPace) }
        return ((delta > 0 ? "+" : "-") + Units.clock(abs(delta)), delta > 0 ? .behind : .ahead)
    }

    static func status(_ stage: RunActivityState.Stage, isStale: Bool) -> String {
        switch stage {
        case .ended: return "Run ended · save in Tempo"
        case _ where isStale: return "Open Tempo"
        case .running: return "Running"
        case .paused: return "Paused"
        case .interrupted: return "Open Tempo"
        }
    }
}
