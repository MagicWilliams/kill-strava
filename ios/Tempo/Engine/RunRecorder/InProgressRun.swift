import Foundation

/// The snapshot that lets a run survive the app being killed mid-stride (#115).
///
/// Chicago, 11 Oct 2026: the recording of the marathon a whole block had been built toward
/// stopped and the run was lost. iOS can and will terminate a backgrounded app — low memory,
/// a watchdog, a crash in a frame we never see — and when it does, everything the recorder
/// held in memory goes with it. The only defence is to have already written it down.
///
/// So the recorder writes this every `saveInterval` and on every state change, and on launch
/// `recover` decides what to do with what it finds. Both halves are pure: the snapshot is
/// `Codable` with no I/O (the file lives in `InProgressRunStore`) and the recovery decision is
/// `(snapshot, session, now) -> Recovery`, so the whole decision table is a test rather than
/// something only a force-quit on a real phone can exercise.
///
/// ## What is written down, and what is not
///
/// The cumulative distance curve, not a distance and a split table. `TrackMath.splits` is a
/// pure function of the curve, so carrying both would be two sources of truth for the same
/// number — and this engine layer has a history of one of those two silently winning. Splits
/// after a recovery are recomputed from the spliced curve.
///
/// The curve is the one thing here that is not small: two flat `[Double]` arrays rather than
/// an array of objects, rounded at construction to 0.1 s and 0.1 m (finer than any GPS fix is
/// true to), which puts a marathon at roughly 70 KB — one write per ten seconds, off the main
/// thread. Cheap, next to losing the marathon.
///
/// Not carried: the route polyline (it is in the `HKWorkoutRouteBuilder` the session hands
/// back, and every fix of it would be megabytes) and the smoothed altitude curve. Only the
/// tail of the fixes survives, for the live map to pick up where it left off, and elevation
/// comes back as the running gain/loss totals — so the first climb after a recovery is
/// under-counted by at most one `TrackMath.elevationHysteresisM`, and the splits recorded
/// before the kill come back without their elevation delta. Both are cosmetic; the distance,
/// the clocks and the pause list are not.
struct InProgressRun: Codable, Equatable {

    /// Bumped when a field changes meaning. `InProgressRunStore` treats a snapshot from
    /// another schema as unreadable rather than guessing at it: a half-understood run is
    /// worse than an honest "save what we have".
    static let currentSchema = 1

    /// How often a live run is written down, between state changes.
    ///
    /// Ten seconds is the most a crash can cost, and what it costs is the tail of the curve —
    /// distance the session still has, because HealthKit kept collecting. It is not ten
    /// seconds of the clock: `savedAt` is the last instant we *know* the run was recording,
    /// and the wall clock is reconstructed from `startedAt`, not from the snapshot's age.
    static let saveInterval: TimeInterval = 10

    /// A snapshot last written longer ago than this is not a run in progress any more.
    ///
    /// A long run is five hours; noticing hours later and still wanting it saved is real, so
    /// the line is well past both. Past twelve hours it is litter from a build that died —
    /// handed back as `.expired` rather than offered as a run he is standing in the street
    /// waiting for, and still never dropped on the floor.
    static let maxRescueAge: TimeInterval = 12 * 3600

    /// Accepted fixes kept, newest last. Enough to re-establish a smoothed position
    /// (`TrackMath.positionSmoothingFixes`) with room to spare; not a route.
    static let maxCarriedFixes = 10

    // MARK: - Pieces

    /// A cumulative (seconds, metres) curve as two parallel arrays.
    ///
    /// `BestEfforts.Point` is the shape every other part of the app reads this curve as, and
    /// `points` hands it back as exactly that. The flat form is only how it is written down:
    /// `[{"t":1.2,"m":4.3}, …]` is three times the bytes of `[1.2, …]` and `[4.3, …]` for the
    /// same numbers, over eight thousand points on a marathon.
    struct DistanceCurve: Codable, Equatable {
        var t: [Double]
        var m: [Double]

        init(_ points: [BestEfforts.Point]) {
            // Rounded here rather than in the codec, so a snapshot round-trips exactly and
            // nothing downstream has to wonder which copy is the authoritative one.
            t = points.map { ($0.t * 10).rounded() / 10 }
            m = points.map { ($0.m * 10).rounded() / 10 }
        }

        /// Pairs up to the shorter array: a truncated write can never produce a point with a
        /// time and no distance.
        var points: [BestEfforts.Point] {
            (0..<min(t.count, m.count)).map { BestEfforts.Point(t: t[$0], m: m[$0]) }
        }

        var lastMeters: Double { m.last ?? 0 }
        var isEmpty: Bool { t.isEmpty || m.isEmpty }
    }

    /// One accepted GPS fix, flattened. Mirrors `TrackMath.Fix`, which is `Equatable` but
    /// deliberately not `Codable` — nothing in the pure track layer should know it is stored.
    struct CarriedFix: Codable, Equatable {
        var at: Date
        var latitude: Double
        var longitude: Double

        init(_ fix: TrackMath.Fix) {
            at = fix.timestamp
            latitude = fix.latitude
            longitude = fix.longitude
        }
    }

    // MARK: - The snapshot

    var schema: Int = InProgressRun.currentSchema
    /// The last instant we know the run was being recorded — the stamp on the `appTerminated`
    /// interruption, and the `since` of the `.recovering` phase.
    var savedAt: Date
    var state: RecorderState
    /// The `HKWorkoutSession`'s id, so a recovered session can be matched to this run rather
    /// than assumed to be it.
    var workoutSessionID: UUID?
    var curve: DistanceCurve
    var movingS: Double = 0
    var elevationGainM: Double = 0
    var elevationLossM: Double = 0
    /// The tail of the accepted fixes, newest last. See the note on what is not carried.
    var lastFixes: [CarriedFix] = []

    init(
        savedAt: Date,
        state: RecorderState,
        workoutSessionID: UUID? = nil,
        curve: DistanceCurve = DistanceCurve([]),
        movingS: Double = 0,
        elevationGainM: Double = 0,
        elevationLossM: Double = 0,
        lastFixes: [CarriedFix] = []
    ) {
        self.savedAt = savedAt
        self.state = state
        self.workoutSessionID = workoutSessionID
        self.curve = curve
        self.movingS = movingS
        self.elevationGainM = elevationGainM
        self.elevationLossM = elevationLossM
        self.lastFixes = Array(lastFixes.suffix(InProgressRun.maxCarriedFixes))
    }

    var distanceM: Double { curve.lastMeters }

    /// Whether this snapshot describes a run that could still be got back. A run already in
    /// Health, discarded, or never started is not one.
    var isRecoverable: Bool {
        switch state.phase {
        case .idle, .saved, .discarded: false
        default: true
        }
    }

    // MARK: - When to write

    /// Whether the recorder should write a snapshot now: on any change to the state machine,
    /// and otherwise every `saveInterval` while the run is still rescuable.
    ///
    /// Only the state is compared, not the curve — the curve moves with every credited step
    /// and comparing eight thousand points to decide whether to write them would cost more
    /// than the write.
    static func shouldSave(last: InProgressRun?, state: RecorderState, now: Date) -> Bool {
        guard !shouldClear(state) else { return false }
        guard let last else { return true }
        if last.state != state { return true }
        return now.timeIntervalSince(last.savedAt) >= saveInterval
    }

    /// Whether the snapshot on disk should be deleted: the run reached a resting place and
    /// there is nothing left to recover. Saving and discarding both end here; a failed save
    /// does not, because the run is still only in Tempo's hands.
    static func shouldClear(_ state: RecorderState) -> Bool {
        switch state.phase {
        case .idle, .saved, .discarded: true
        default: false
        }
    }

    // MARK: - Recovery

    /// What `HKHealthStore.recoverActiveWorkoutSession` handed back, as plain values.
    struct SessionRecovery: Equatable {
        var id: UUID?
        /// The one thing that decides whether the gap was a stop: the session's own state.
        /// We were not there; if it says it was running, it was running (#115).
        var isPaused: Bool
        /// The session's cumulative distance in metres, if the builder had a statistic for
        /// it. This is what tells us how far he got while Tempo was dead.
        var distanceM: Double?

        init(id: UUID? = nil, isPaused: Bool, distanceM: Double? = nil) {
            self.id = id
            self.isPaused = isPaused
            self.distanceM = distanceM
        }
    }

    /// What launch should do. Every case but `.nothing` hands back a run; none of them
    /// silently drops one.
    enum Recovery: Equatable {
        /// Nothing was recording when the app died.
        case nothing
        /// The session came back and so did the run: `state` is `.running` or `.paused` and
        /// the live screen goes straight back up. #128's prompt says "we kept your run".
        case resume(RecorderState)
        /// A snapshot with no session behind it. `state` is `.recovering`, and the only ways
        /// out are the two #128 offers: "Save what we have" (which ends the run at the last
        /// instant we know it was recording) or "Discard".
        case rescue(RecorderState)
        /// The same, from a snapshot older than `maxRescueAge`. Handed back so the prompt can
        /// word it differently and so it is never dropped unseen, but it is not a live run.
        case expired(RecorderState)
        /// The app died on the save screen or part-way through the write. Nothing was being
        /// recorded, so nothing was lost: the run is whole and `state` is back on the save
        /// screen with a Retry. `RecorderState.reduce` decides this, not us.
        case unfinished(RecorderState)
        /// HealthKit kept a workout session Tempo has no snapshot for. We know a run happened
        /// and nothing about what it was for. What to do with it is the service's call (#114);
        /// what this engine refuses to do is pretend it isn't there.
        case orphanSession

        var state: RecorderState? {
            switch self {
            case .resume(let s), .rescue(let s), .expired(let s), .unfinished(let s): s
            case .nothing, .orphanSession: nil
            }
        }
    }

    /// The decision table: session recovered × snapshot present × snapshot age.
    ///
    /// The transitions themselves belong to #111 and are not re-derived here — this dispatches
    /// `.interrupted(.appTerminated, at: savedAt)` and then `.recovered(sessionPaused:)` into
    /// `RecorderState.reduce`, which is where "wall time keeps counting" and "the gap is a
    /// pause only if the session was paused" already live. One copy of those rules.
    static func recover(snapshot: InProgressRun?, session: SessionRecovery?, now: Date) -> Recovery {
        guard let snapshot, snapshot.isRecoverable else {
            return session == nil ? .nothing : .orphanSession
        }

        // The kill, stamped at the last moment we know the run was fine — not at the moment
        // he reopened the app, which is where a naive `Date()` would put it and would charge
        // him for however long his phone sat in his pocket.
        let lost = RecorderState.reduce(snapshot.state, .interrupted(.appTerminated, at: snapshot.savedAt))

        guard case .recovering = lost.phase else {
            // A countdown that died recorded nothing and reduces to idle.
            return lost.phase == .idle ? .nothing : .unfinished(lost)
        }
        guard let session else {
            let age = now.timeIntervalSince(snapshot.savedAt)
            return age > maxRescueAge ? .expired(lost) : .rescue(lost)
        }
        return .resume(RecorderState.reduce(lost, .recovered(sessionPaused: session.isPaused)))
    }

    // MARK: - The merge after a gap

    /// Splice what was recorded after a recovery onto the curve the snapshot carried.
    ///
    /// The service restarts its `TrackMath.Track` with the *original* run start, so the new
    /// curve's times are already run-relative and only its metres need shifting. What it
    /// cannot know is the gap: the athlete kept running while Tempo was dead, and the only
    /// record of those metres is the session's own cumulative distance. We know the total and
    /// not the shape, so they are credited as a single step at the instant recording came
    /// back — honest about where our knowledge resumes, and it keeps the curve monotone.
    ///
    /// Monotone is the invariant that matters. Every number the live screen shows is read off
    /// this curve, and a distance that goes *down* mid-run is the kind of silently wrong
    /// number this whole engine layer exists to make impossible.
    static func splice(
        carried: DistanceCurve,
        after: DistanceCurve,
        gapMetersM: Double,
        resumedAtS: Double
    ) -> DistanceCurve {
        // A `Track` always opens at (0, 0) — the clock runs from the press of Start, lock or
        // no lock — and `TrackMath.splits` measures the first split from `timeline[0].t`.
        var points = carried.points.isEmpty ? [BestEfforts.Point(t: 0, m: 0)] : carried.points
        let carriedM = points.last?.m ?? 0
        let base = carriedM + max(0, gapMetersM.isFinite ? gapMetersM : 0)

        /// Extends the curve, or raises the last point when the new one lands on the same
        /// instant. Strictly increasing in time, never decreasing in distance — both ends,
        /// always, whatever order the inputs arrive in.
        func add(_ t: Double, _ meters: Double) {
            let m = max(meters, points.last?.m ?? 0)
            if let last = points.last, t <= last.t {
                points[points.count - 1] = BestEfforts.Point(t: last.t, m: m)
            } else {
                points.append(BestEfforts.Point(t: t, m: m))
            }
        }

        if base > carriedM || resumedAtS > (points.last?.t ?? 0) {
            add(max(resumedAtS, points.last?.t ?? 0), base)
        }
        // A fresh track opens at (0, 0), which carries no metres and no information.
        for p in after.points where p.m > 0 { add(p.t, base + p.m) }
        return DistanceCurve(points)
    }

    /// Metres the session covered while Tempo was gone: whatever it has beyond what we wrote
    /// down. Never negative — a session reporting less than our own curve is a session whose
    /// distance statistic we trust less than the curve, not a reason to take metres away.
    static func gapMeters(carried: DistanceCurve, session: SessionRecovery?) -> Double {
        guard let reported = session?.distanceM, reported.isFinite else { return 0 }
        return max(0, reported - carried.lastMeters)
    }

    // MARK: - Picking the run back up

    /// Whether a recovered session is this snapshot's run.
    ///
    /// The recording id goes into the workout builder's metadata at `begin`, a moment after
    /// collection starts, so a session killed in that moment comes back without one — and
    /// a snapshot written before `prepare` has none either. Either side missing is not a
    /// mismatch; both present and different is: that session is some other run, and
    /// grafting it onto this one would splice two runs into one.
    static func matches(snapshot: InProgressRun, sessionRecordingID: UUID?) -> Bool {
        guard let ours = snapshot.workoutSessionID, let theirs = sessionRecordingID else { return true }
        return ours == theirs
    }

    /// Where the recorder picks a run up after a kill: the curve to carry on from, and how
    /// much of it the workout in Health already holds.
    struct Resumption: Equatable {
        /// The carried curve, plus the gap the session covered, ending at the instant
        /// recording came back. `TrackMath.Track(start:resuming:…)` takes it as its history.
        var curve: DistanceCurve
        /// How far along `curve` the workout's own distance samples already reach, so the
        /// recorder writes the rest and not the whole run a second time (`DistanceChunks`).
        var inHealth: BestEfforts.Point
    }

    /// The curve and the distance-in-Health bookmark for a run coming back from `snapshot`.
    ///
    /// `resumedAt` is when recording came back — launch, for a session that survived — and
    /// nil when it did not: a run being rescued or one already on the save screen ends where
    /// our knowledge does and gains nothing.
    ///
    /// **What Health already has** is the one judgement here. Outdoors the session's distance
    /// statistic is exactly the samples Tempo wrote (HealthKit's own collection is off), so
    /// it is the bookmark, and when it is *ahead* of the snapshot — the last chunk landed
    /// after the last write — the difference is real running and `gapMeters` credits it.
    /// With no session behind the run, Health has nothing and everything is written. With a
    /// session but no statistic, we cannot tell, and the bookmark goes at the end of the
    /// carried curve: writing it all again would double the distance in Health, and under-
    /// writing costs at most the ten seconds between snapshots. A short run is the honest
    /// failure of the two.
    static func resumption(snapshot: InProgressRun, session: SessionRecovery?, resumedAt: Date?) -> Resumption {
        let carried = snapshot.curve
        let resumedAtS = resumedAt.flatMap { at in snapshot.state.startedAt.map { at.timeIntervalSince($0) } } ?? 0
        let curve = splice(
            carried: carried,
            after: DistanceCurve([]),
            gapMetersM: gapMeters(carried: carried, session: session),
            resumedAtS: resumedAtS
        )
        let points = curve.points
        let origin = BestEfforts.Point(t: 0, m: 0)
        guard let session, let end = points.last else { return Resumption(curve: curve, inHealth: origin) }

        let carriedEnd = carried.points.last ?? origin
        guard let reported = session.distanceM, reported.isFinite else {
            return Resumption(curve: curve, inHealth: carriedEnd)
        }
        // The curve is rounded to 0.1 m and the samples are not: a statistic within that of
        // the end is the end, not a sliver of a metre still to write.
        let m = end.m - reported < 0.1 ? end.m : max(0, reported)
        let t = m == end.m ? end.t : TrackMath.time(atMeters: m, in: points) ?? end.t
        return Resumption(curve: curve, inHealth: BestEfforts.Point(t: t, m: m))
    }

    // MARK: - Telemetry

    /// The `recorder.recovered` / `recorder.recovery_failed` line for an outcome (#115, #131),
    /// built here so what gets reported is pinned by the same tests as the decision.
    ///
    /// Counts, durations and enum-ish strings only — `Telemetry`'s rule. No distance: how far
    /// he ran is health data, and the recovery report does not need it to be useful.
    static func telemetry(
        for recovery: Recovery,
        snapshot: InProgressRun?,
        session: SessionRecovery?,
        now: Date
    ) -> (event: String, context: [String: String])? {
        guard recovery != .nothing else { return nil }
        var context: [String: String] = ["outcome": recovery.label]
        if let snapshot {
            context["gap_s"] = String(Int(max(0, now.timeIntervalSince(snapshot.savedAt)).rounded()))
            context["kind"] = snapshot.state.kind.rawValue
            context["curve_points"] = String(snapshot.curve.t.count)
        }
        if let session { context["session_paused"] = session.isPaused ? "true" : "false" }
        switch recovery {
        case .resume: return ("recorder.recovered", context)
        case .rescue, .expired, .unfinished, .orphanSession: return ("recorder.recovery_failed", context)
        case .nothing: return nil
        }
    }
}

extension InProgressRun.Recovery {
    /// A stable string for telemetry. Not `String(describing:)`, which would change the moment
    /// a case gains an associated value.
    var label: String {
        switch self {
        case .nothing: "nothing"
        case .resume: "resumed"
        case .rescue: "rescue_offered"
        case .expired: "expired"
        case .unfinished: "unfinished"
        case .orphanSession: "orphan_session"
        }
    }
}
