import Foundation

// What a recorded run writes into Apple Health, decided purely (#114). The service owns the
// HealthKit calls; these decide *which* fixes go into the route, *which* distance samples
// go into the workout, and *what* metadata it carries, so each can be pinned by a test.

// MARK: - Route

/// Which fixes become the route on the map in Health.
///
/// The route is the same fixes the distance came from — nothing `TrackMath` rejected, so the
/// map can't show the 300 m spike under a building that the distance correctly ignored. The
/// one subtlety is the lock: the first `lockFixCount - 1` fixes come back `.awaitingLock`
/// and are only credited when the next one completes the lock, so they are held here and
/// released together. Generic over the item so the service can hand it `CLLocation`s and a
/// test can hand it numbers.
struct RouteGate<Item> {
    /// The most recent lock candidates. When the lock completes, the candidates `TrackMath`
    /// uses are exactly the last `lockFixCount - 1` fixes that were `.awaitingLock` plus the
    /// one that locked it: any reset in between (a bad fix, a disagreeing one) leaves fewer
    /// than that many since it, or it could not have locked.
    private var pending: [Item] = []

    init() {}

    /// What to append to the route for one fix, given `TrackMath`'s verdict on it and
    /// whether the track was locked before it.
    mutating func admit(_ item: Item, verdict: TrackMath.Verdict, wasLocked: Bool) -> [Item] {
        switch verdict {
        case .accepted:
            guard !wasLocked else { return [item] }
            let released = pending + [item]
            pending.removeAll()
            return released
        case .awaitingLock:
            pending.append(item)
            if pending.count > TrackMath.lockFixCount - 1 { pending.removeFirst() }
            return []
        case .inaccurate, .stale, .outOfOrder, .tooFast:
            return []
        }
    }

    /// The track was broken (resumed after a pause): nothing held belongs to the new lock.
    mutating func reset() { pending.removeAll() }
}

// MARK: - Distance samples

/// How an outdoor run's distance reaches Health.
///
/// Outdoors, the distance in Health must be the distance the athlete watched tick up — not
/// a second opinion from the phone's pedometer — so the recorder turns off HealthKit's own
/// distance collection and writes `TrackMath`'s instead, as one sample per stretch of the
/// curve. Short stretches, because `RunDetailLoader` builds splits and best efforts back out
/// of these samples by interpolating inside each one: a ten-second sample puts a mile split
/// within a second or two of where it was run. Written as the run goes rather than all at
/// the end, so the workout builder already holds them if the app is killed (#115).
enum DistanceChunks {
    /// Seconds of curve per sample, at least. Ten seconds is about 1,000 samples for a
    /// marathon — the order of what a watch writes — and fine enough for splits.
    static let minSpanS = 10.0

    struct Chunk: Equatable {
        let from: BestEfforts.Point
        let to: BestEfforts.Point
        var meters: Double { to.m - from.m }
    }

    /// The next sample to write, from the end of the last one written (`flushed`) to the end
    /// of the curve. Nil until it spans `minSpanS`, unless `final` (the run has ended and
    /// whatever is left must go). A chunk with no distance (a pause, a stop) still comes
    /// back so the caller can move `flushed` past it; the caller writes only `meters > 0`.
    ///
    /// Closing a track can credit its last metres at the same instant as the point before
    /// them, so a final chunk may have no duration. It is still returned: HealthKit takes a
    /// sample whose end equals its start, and dropping it would leave Health a few metres
    /// short of the screen.
    static func next(timeline: [BestEfforts.Point], flushed: BestEfforts.Point, final: Bool) -> Chunk? {
        guard let last = timeline.last, last.t > flushed.t || last.m > flushed.m else { return nil }
        guard final || last.t - flushed.t >= minSpanS else { return nil }
        return Chunk(from: flushed, to: last)
    }
}

// MARK: - Workout metadata

/// What a recorded workout carries in Health besides its numbers.
///
/// Written when the workout begins, not when it is saved, so a session recovered after a
/// kill (#115) already says which Tempo recording it is and what it was run against. The
/// target is a copy of what the athlete saw at Start; the plan can be regenerated mid-run.
///
/// Keys are strings so this stays free of HealthKit; `indoorKey` is pinned to
/// `HKMetadataKeyIndoorWorkout` by a test. Values are `Bool`, `Int`, `String`: all three
/// bridge to the `NSNumber`/`NSString` HealthKit accepts.
enum RecordingMetadata {
    /// `HKMetadataKeyIndoorWorkout`.
    static let indoorKey = "HKIndoorWorkout"
    /// This recording. Matches a recovered session to its saved snapshot (#115), and the
    /// workout to the run row the save path writes (#122).
    static let recordingIDKey = "TempoRecordingID"
    static let raceKey = "TempoRace"
    /// The plan session the run was started against, when there was one.
    static let planSessionIDKey = "TempoPlanSessionID"
    static let targetTypeKey = "TempoTargetType"
    static let targetTitleKey = "TempoTargetTitle"
    static let targetDistanceMKey = "TempoTargetDistanceM"
    static let targetPaceKey = "TempoTargetPaceSecPerMile"
    /// Whether the target strip was on screen when the run ended, or he was running free.
    /// Added at save; everything else is added at begin.
    static let targetShownKey = "TempoTargetShown"

    /// Everything known when the run begins.
    static func atBegin(recordingID: UUID, kind: RecorderState.RunKind,
                        target: RecorderState.SessionTarget?) -> [String: Any] {
        var m: [String: Any] = [
            indoorKey: kind == .treadmill,
            recordingIDKey: recordingID.uuidString,
            raceKey: kind == .race,
        ]
        if let target {
            m[targetTypeKey] = target.type
            if let id = target.sessionID { m[planSessionIDKey] = id.uuidString }
            if let title = target.title { m[targetTitleKey] = title }
            if let d = target.distanceM { m[targetDistanceMKey] = d }
            if let p = target.paceSecPerMile { m[targetPaceKey] = p }
        }
        return m
    }

    /// What only the end of the run knows.
    static func atSave(state: RecorderState) -> [String: Any] {
        guard state.target != nil else { return [:] }
        return [targetShownKey: state.targetVisible]
    }
}

// MARK: - Auto-pause on a treadmill

/// What a quiet pedometer means on a treadmill, for auto-pause (#113).
///
/// `AutoPause` treats silence as "don't know", never as "stopped": outdoors a silent GPS is
/// an underpass, and pausing for it is how Chicago was lost. On a treadmill there is no GPS,
/// and Core Motion simply stops reporting when the steps stop. Without a reading, a
/// treadmill run with auto-pause on could never pause. So on a treadmill, and only there,
/// a pedometer that has gone quiet is read as standing still.
///
/// Two guards keep that from pausing someone who is running:
/// - Only after the pedometer has reported at least once this run. No reading at all
///   (Motion & Fitness denied, a phone sat on the console from the start) proves nothing,
///   and filling zeros from the first second would pause him before he began.
/// - Only once it has been quiet for longer than `AutoPause.Thresholds.freshness`. Until
///   then its last real reading is still current, and a zero would overwrite it: the
///   pedometer reports every few seconds even mid-stride.
enum PedometerSilence {
    /// Quiet for longer than this reads as stopped. Five seconds is `freshness`, so the
    /// filler only ever replaces a reading `AutoPause` has already stopped trusting.
    static let quietAfterS = 5.0

    /// A zero-speed pedometer sample to feed at `now`, or nil.
    static func filler(lastReadingAt: Date?, now: Date) -> AutoPause.Sample? {
        guard let lastReadingAt, now.timeIntervalSince(lastReadingAt) > quietAfterS else { return nil }
        return AutoPause.Sample(at: now, speed: 0, source: .pedometer)
    }
}
