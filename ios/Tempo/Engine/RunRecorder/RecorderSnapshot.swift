import Foundation

/// Everything the live run screen and the Live Activity read, at one instant (#114).
///
/// One value, rebuilt once a second from the state machine (#111), the distance curve
/// (#112) and the last heart-rate reading, so the screen, the Lock Screen and the Dynamic
/// Island can never disagree about a number. Read-only by construction: nothing a view does
/// with it reaches back into the run.
///
/// All paces are seconds per `units` (per mile or per km) and all distances metres. Format
/// with `Units` at the edge, like everything else.
struct RecorderSnapshot: Equatable {

    /// The small tile next to average pace (#125). David's call, 2026-10-12: with no heart
    /// rate, swap in another number rather than show "—" or hide the tile, and the number is
    /// the last split.
    enum Secondary: Equatable {
        case heartRate(bpm: Int)
        case lastSplit(TrackMath.Split)
        /// No heart rate and no split finished yet: the first mile of a run without a strap.
        case none
    }

    /// The split being run now. Its pace is nil until it is long enough to mean anything.
    struct CurrentSplit: Equatable {
        /// 1-based.
        let index: Int
        let meters: Double
        let durationS: Double
        let paceS: Double?
    }

    /// Today's target as the strip shows it. Present only while the target is on screen.
    struct Target: Equatable {
        let title: String?
        let type: String
        let distanceM: Int?
        /// Target pace in `units`, converted from the plan's seconds per mile.
        let paceS: Double?
        /// Average moving pace minus target pace: positive is slower than target, negative
        /// faster. Nil without both numbers.
        let deltaS: Double?
    }

    var phase: RecorderState.Phase
    var kind: RecorderState.RunKind
    var units: Units
    /// Wall clock and moving time, whole seconds, from the state machine's pause list.
    var elapsedS: Int
    var movingS: Int
    var distanceM: Double
    var currentPaceS: Double?
    /// Over moving time: what "average pace" means everywhere else in Tempo.
    var averagePaceS: Double?
    /// The latest heart rate, only while it is fresh. Never required.
    var heartRateBPM: Int?
    var secondary: Secondary
    var currentSplit: CurrentSplit?
    var lastSplit: TrackMath.Split?
    /// Whole splits finished. The split voice cue (#118) fires when this ticks up.
    var completedSplits: Int
    var target: Target?
    /// Outdoor only: whether GPS has locked, so the screen can say "finding GPS".
    var gpsLocked: Bool

    static let idle = RecorderSnapshot(
        phase: .idle, kind: .outdoor, units: .fallback, elapsedS: 0, movingS: 0,
        distanceM: 0, currentPaceS: nil, averagePaceS: nil, heartRateBPM: nil,
        secondary: .none, currentSplit: nil, lastSplit: nil, completedSplits: 0,
        target: nil, gpsLocked: false
    )

    // MARK: - Heart rate

    /// A reading from a paired Watch or strap, and when it was taken.
    struct HeartRate: Equatable {
        let bpm: Double
        let at: Date
    }

    /// A reading older than this is not shown. A strap that drops out mid-run must not leave
    /// its last number on screen as if it were live; straps report about once a second, so
    /// half a minute of silence means it has gone, not that the heart has held still.
    static let heartRateStaleS = 30.0

    // MARK: - Building one

    /// The snapshot at `now`.
    ///
    /// - `timeline`: cumulative (seconds since `state.startedAt`, metres). Outdoors it is
    ///   `TrackMath.Track.timeline`; on a treadmill it is built from HealthKit's distance.
    static func make(
        state: RecorderState,
        at now: Date,
        timeline: [BestEfforts.Point],
        units: Units,
        heartRate: HeartRate?,
        gpsLocked: Bool
    ) -> RecorderSnapshot {
        let clocks = state.clocks(at: now)
        let unitM = units.splitMeters
        let distance = timeline.last?.m ?? 0
        let t = state.elapsed(at: now)

        // Current pace is a running number. Paused, ended or lost: blank, not the last one.
        let current: Double? = state.phase == .running
            ? TrackMath.currentPace(timeline: timeline, at: t, unitMeters: unitM)
            : nil
        let average = TrackMath.averagePace(meters: distance, seconds: Double(clocks.movingS), unitMeters: unitM)

        let splits = TrackMath.splits(timeline: timeline, splitMeters: unitM)
        let full = splits.filter { !$0.isPartial }
        let completed = full.count
        let last = full.last
        let inProgress: CurrentSplit? = state.startedAt == nil ? nil : {
            if let partial = splits.last, partial.isPartial {
                return CurrentSplit(index: partial.index, meters: partial.meters,
                                    durationS: partial.durationS, paceS: partial.paceS)
            }
            // Under 5 % into the split, or none run yet: it exists, it just has no pace.
            let boundaryM = Double(completed) * unitM
            let boundaryT = completed == 0 ? 0 : (TrackMath.time(atMeters: boundaryM, in: timeline) ?? t)
            return CurrentSplit(index: completed + 1, meters: max(0, distance - boundaryM),
                                durationS: max(0, t - boundaryT), paceS: nil)
        }()

        let hr: Int? = heartRate.flatMap { reading in
            let age = now.timeIntervalSince(reading.at)
            guard age <= heartRateStaleS, reading.bpm > 0, reading.bpm.isFinite else { return nil }
            return Int(reading.bpm.rounded())
        }

        return RecorderSnapshot(
            phase: state.phase,
            kind: state.kind,
            units: units,
            elapsedS: clocks.elapsedS,
            movingS: clocks.movingS,
            distanceM: distance,
            currentPaceS: current,
            averagePaceS: average,
            heartRateBPM: hr,
            secondary: secondary(heartRateBPM: hr, lastSplit: last),
            currentSplit: inProgress,
            lastSplit: last,
            completedSplits: completed,
            target: target(state: state, averagePaceS: average, units: units),
            gpsLocked: gpsLocked
        )
    }

    /// Heart rate when there is one, else the last split, else nothing (#125).
    static func secondary(heartRateBPM: Int?, lastSplit: TrackMath.Split?) -> Secondary {
        if let heartRateBPM { return .heartRate(bpm: heartRateBPM) }
        if let lastSplit { return .lastSplit(lastSplit) }
        return .none
    }

    /// The target strip, or nil when there is no target or he has hidden it ("run free").
    static func target(state: RecorderState, averagePaceS: Double?, units: Units) -> Target? {
        guard state.showsTarget, let target = state.target else { return nil }
        let pace = target.paceSecPerMile.map { units.pace(secondsPerMile: Double($0)) }
        let delta: Double? = {
            guard let pace, let averagePaceS else { return nil }
            return averagePaceS - pace
        }()
        return Target(title: target.title, type: target.type, distanceM: target.distanceM,
                      paceS: pace, deltaS: delta)
    }
}
