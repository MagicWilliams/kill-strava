import Foundation

/// Opt-in auto-pause (#113): watches speed and decides when the athlete has stopped and when
/// he has started again. It never touches the run itself — it only proposes `.pause(.auto)`
/// and `.resume(.auto)` to `RecorderState.reduce`, which already ignores both unless auto-pause
/// is on and already refuses to let auto-resume lift a pause he made himself.
///
/// Chicago, 11 Oct 2026: Strava decided he had stopped in the middle of a marathon, and the
/// race was lost. The rules here are what "decided he had stopped" has to survive:
///
///  - **Silence is not stopping.** Downtown canyons, Lower Wacker and every bridge underpass
///    are GPS dropouts, and a dropout delivers *no* samples (or ones with an invalid speed).
///    Only a continuous stream of slow readings counts as evidence; any gap longer than
///    `maxSampleGap` throws the evidence away and starts over. A run that loses its GPS keeps
///    running.
///  - **Any source saying "moving" wins.** GPS and the pedometer are read together, and the
///    effective speed is the fastest fresh reading. A GPS fix stuck on a building cannot pause
///    a runner whose pedometer is still counting strides.
///  - **Hysteresis, both ways.** Below 0.5 m/s for 8 s pauses; above 1.2 m/s for 3 s resumes.
///    The band between is a walk: it neither confirms a stop nor ends one, so shuffling
///    through an aid station doesn't flicker the clock.
///  - **It cannot end a run.** `Decision` has two cases and neither is `end`. That is a type,
///    not a promise.
///
/// Both decisions are stamped at the first sample of the streak that confirmed them, not at
/// the moment of confirmation: the 8 s he stood at the light before we were sure were not
/// moving time, and the 3 s he ran before we were sure were. The reducer clamps the instant so
/// a backdated event can never reach before something it already recorded.
///
/// Pure value type with no clock: every sample carries its instant. The service (#114) feeds
/// it samples and dispatches what comes back; each decision is also where the spoken + haptic
/// cue (#118) fires, so an auto pause is never silent.
struct AutoPause: Equatable {

    struct Thresholds: Equatable {
        /// Below this, he is standing. 0.5 m/s is a 53:38/mi "pace" — nobody runs it.
        var stopBelow: Double = 0.5
        /// How long he must stay below `stopBelow` before the clock stops.
        var stopAfter: TimeInterval = 8
        /// Above this, he is running again. 1.2 m/s is a brisk walk, 22:21/mi.
        var moveAbove: Double = 1.2
        /// How long he must stay above `moveAbove` before the clock restarts.
        var moveAfter: TimeInterval = 3
        /// The longest silence between samples that still counts as one continuous reading.
        /// GPS delivers at ~1 Hz and the pedometer every couple of seconds; anything longer is
        /// a dropout, and a dropout is not evidence of anything.
        var maxSampleGap: TimeInterval = 5
        /// A source's last reading stays in the "fastest fresh reading" for this long.
        var freshness: TimeInterval = 5
    }

    enum Source: String, Equatable {
        case gps, pedometer
    }

    /// One speed reading. A negative or non-finite speed is how Core Location says "I don't
    /// know" — it is treated as no reading at all, never as zero.
    struct Sample: Equatable {
        var at: Date
        /// Metres per second.
        var speed: Double
        var source: Source
    }

    /// What auto-pause wants the recorder to do. Deliberately only these two.
    enum Decision: Equatable {
        case pause(at: Date)
        case resume(at: Date)

        /// The reducer event this decision becomes — always one #111 already defines.
        var event: RecorderEvent {
            switch self {
            case .pause(let at): .pause(.auto, at: at)
            case .resume(let at): .resume(.auto, at: at)
            }
        }
    }

    var thresholds: Thresholds

    /// The latest valid reading from each source.
    private var latest: [Source: Sample] = [:]
    /// The latest valid sample from any source, for gap detection.
    private var lastSampleAt: Date?
    /// Start of the current unbroken run of samples that point the way a decision would go.
    private var streakStart: Date?

    init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
    }

    /// Feeds one reading. Returns a decision only when the recorder is in a state that would
    /// accept it: auto-pause on and running, or paused by auto-pause. Otherwise the evidence is
    /// dropped, so a stop that began during a manual pause or a countdown can't fire the moment
    /// the run resumes.
    mutating func ingest(_ sample: Sample, recorder: RecorderState) -> Decision? {
        guard sample.speed.isFinite, sample.speed >= 0 else { return nil }
        // A pedometer update can land a beat behind the GPS fix it describes. Take it, but
        // never older than what that source already said, and never let it move time back.
        if let previous = latest[sample.source], sample.at <= previous.at { return nil }

        let gapped = lastSampleAt.map { sample.at.timeIntervalSince($0) > thresholds.maxSampleGap } ?? true
        if gapped {
            // A dropout: nothing from before it may count toward a decision.
            latest = [:]
            streakStart = nil
        }
        let now = max(sample.at, lastSampleAt ?? sample.at)
        lastSampleAt = now
        latest[sample.source] = sample

        guard let watching = Watching(recorder) else {
            streakStart = nil
            return nil
        }

        let speed = effectiveSpeed(at: now)
        let pointsOnward: Bool
        let dwell: TimeInterval
        switch watching {
        case .forStop:
            pointsOnward = speed < thresholds.stopBelow
            dwell = thresholds.stopAfter
        case .forMove:
            pointsOnward = speed > thresholds.moveAbove
            dwell = thresholds.moveAfter
        }

        guard pointsOnward else {
            streakStart = nil
            return nil
        }
        let start = streakStart ?? now
        streakStart = start
        guard now.timeIntervalSince(start) >= dwell else { return nil }

        streakStart = nil
        return watching == .forStop ? .pause(at: start) : .resume(at: start)
    }

    // MARK: - Private

    private enum Watching: Equatable {
        case forStop, forMove

        /// Which way the recorder could go next on auto-pause's say-so, if at all.
        init?(_ recorder: RecorderState) {
            guard recorder.autoPauseEnabled else { return nil }
            switch recorder.phase {
            case .running:
                self = .forStop
            case .paused where recorder.openPause?.reason == .auto:
                self = .forMove
            default:
                // A manual or recovery pause is his to lift; every other phase is not live.
                return nil
            }
        }
    }

    /// The fastest reading any source gave within `freshness` of `now`.
    private func effectiveSpeed(at now: Date) -> Double {
        latest.values
            .filter { now.timeIntervalSince($0.at) <= thresholds.freshness }
            .map(\.speed)
            .max() ?? 0
    }
}
