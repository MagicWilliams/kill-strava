import CoreLocation
import Foundation
import HealthKit
import Observation

// MARK: - Seams

/// The workout session underneath a recording: on device, an `HKWorkoutSession` with its
/// `HKLiveWorkoutBuilder` and route builder (`HealthWorkoutSession`); in tests, a fake that
/// records what it was asked to do. The recorder talks to nothing in HealthKit except
/// through this, which is what lets the whole lifecycle be tested without HealthKit.
///
/// One instance is one recording. The recorder makes it at the countdown and drops it when
/// the run is saved or discarded.
@MainActor
protocol WorkoutSessionDriving: AnyObject {
    /// HealthKit reporting back: heart rate, treadmill distance, a failure. Set by the
    /// recorder before `prepare`.
    var onSignal: ((WorkoutSessionSignal) -> Void)? { get set }

    /// Countdown started: get the sensors ready. Records nothing.
    func prepare() throws
    /// Countdown done: start the activity and collection at `date`, tagged with `metadata`.
    func begin(at date: Date, metadata: [String: Any]) async throws
    func pause(at date: Date)
    func resume(at date: Date)
    /// The athlete ended the run: stop the activity and end collection at `date`. The
    /// session is not ended yet; that happens in `finish` or `discard`.
    func stop(at date: Date) async throws
    /// Append GPS fixes to the workout's route.
    func addRoute(_ locations: [CLLocation]) async throws
    /// Add one stretch of distance to the workout (outdoor runs; see `DistanceChunks`).
    func addDistance(meters: Double, from start: Date, to end: Date) async throws
    /// Save the workout to Health, with `metadata` added, and end the session.
    func finish(metadata: [String: Any]) async throws -> FinishedWorkout
    /// Throw the workout away and end the session.
    func discard() async
}

/// Something the workout session reported.
enum WorkoutSessionSignal {
    /// From a paired Watch or chest strap, when there is one.
    case heartRate(bpm: Double, at: Date)
    /// HealthKit's own running total. Only used on a treadmill, where there is no GPS.
    case distance(totalMeters: Double, at: Date)
    /// The session failed underneath the run.
    case failed(reason: String)
}

/// A workout HealthKit has saved.
struct FinishedWorkout {
    let id: UUID
    /// Always present from HealthKit; nil only from a test double, which can't make one.
    let workout: HKWorkout?
}

/// Where GPS fixes come from: `RunLocationStream` on device, a fake in tests.
@MainActor
protocol RunLocationStreaming: AnyObject {
    var onLocations: (([CLLocation]) -> Void)? { get set }
    /// Permission changed — the athlete turned location off mid-run.
    var onAccess: ((LocationAccess) -> Void)? { get set }
    func start()
    func stop()
}

// MARK: - Hand-offs

/// A run that is in Health, handed to whatever writes it into Tempo (#122) the moment the
/// save lands. Health is the source of truth; this is the copy for the app.
struct RecordedRun {
    let workoutID: UUID
    /// The saved workout, for the ingest mapping #122 shares with `HealthService`.
    let workout: HKWorkout?
    let recordingID: UUID
    let kind: RecorderState.RunKind
    let target: RecorderState.SessionTarget?
    let startedAt: Date
    let endedAt: Date
    let clocks: TimeAccounting.Clocks
    let distanceM: Double
    let splits: [TrackMath.Split]
    let units: Units
}

/// The minimum kill recovery (#115) needs to persist, emitted on every state change and
/// every `WorkoutRecorder.checkpointIntervalS` while a run is live. #115 owns where it goes
/// and what else it adds; the recorder only says when.
struct RecorderCheckpoint: Codable, Equatable {
    let recordingID: UUID
    let state: RecorderState
    let distanceM: Double
    let savedAt: Date
}

// MARK: - The recorder

/// Records a run on the iPhone (#114): a native `HKWorkoutSession` (iOS 26+, Tempo's
/// minimum), GPS into `TrackMath` and the workout's route, and one live `snapshot` for the
/// run screen and the Live Activity.
///
/// **The reducer drives; this file only does what it is told.** Every input — a tap, a
/// Lock Screen intent, a HealthKit failure, location being revoked — becomes a
/// `RecorderEvent` passed to `send`. `send` reduces it (`RecorderState.reduce`, #111), asks
/// `RecorderEffect.between` what the transition requires, and performs exactly that. There
/// is no other path to pausing, stopping, saving or discarding a session, so the rule the
/// reducer pins — only the athlete ends a run — holds for HealthKit too.
///
/// HealthKit work is asynchronous, and order matters (distance before end of collection,
/// end of collection before finish), so every HealthKit call goes through one serial queue.
/// Results come back as events: a save that lands is `.saveSucceeded`, one that fails is
/// `.saveFailed` and leaves everything in place for a retry.
///
/// **Kill recovery (#115) is built on this, not in it.** The hooks it needs:
/// - `onCheckpoint` fires on every state change and every ten seconds while live.
/// - The recording id and target are written into the workout builder's metadata when
///   collection begins, so the session `HKHealthStore.recoverActiveWorkoutSession` hands
///   back after a relaunch identifies itself (`HealthWorkoutSession.recoverActive`).
/// - Ending a run stops the session's activity but does not end the session until the save
///   or the discard, so a kill on the save screen leaves a session to recover.
/// - Distance samples and the route go into the builder as the run goes, not at the end.
@MainActor
@Observable
final class WorkoutRecorder {

    /// The run, as the state machine sees it.
    private(set) var state = RecorderState()
    /// The live numbers. Rebuilt once a second and on every event.
    private(set) var snapshot = RecorderSnapshot.idle
    /// The last HealthKit failure, for the pre-run sheet or the save screen to show.
    private(set) var lastFailure: String?
    /// This recording's id; nil when nothing is being recorded.
    private(set) var recordingID: UUID?

    /// Called once the workout is in Health. #122 writes the run row from it.
    @ObservationIgnored var onSaved: ((RecordedRun) -> Void)?
    /// See `RecorderCheckpoint`.
    @ObservationIgnored var onCheckpoint: ((RecorderCheckpoint) -> Void)?

    static let checkpointIntervalS = 10.0
    /// Route fixes are written in batches of about this many — a few seconds of running.
    static let routeBatchSize = 10

    // Collaborators
    private let makeSession: (RecorderState.RunKind) throws -> WorkoutSessionDriving
    private let location: RunLocationStreaming
    private let unitsSource: () -> Units
    private let clock: () -> Date
    private let tickInterval: Duration?
    private let log: (String, [String: String]) -> Void

    // One recording's working state
    @ObservationIgnored private var session: WorkoutSessionDriving?
    /// Fixed at the countdown: a run is split in the unit it started in, whatever the
    /// setting does mid-run.
    @ObservationIgnored private var units: Units = .fallback
    @ObservationIgnored private var track: TrackMath.Track?
    /// Treadmill distance curve, from HealthKit's running total.
    @ObservationIgnored private var treadmill: [BestEfforts.Point] = []
    @ObservationIgnored private var routeGate = RouteGate<CLLocation>()
    @ObservationIgnored private var routeBatch: [CLLocation] = []
    @ObservationIgnored private var distanceFlushed = BestEfforts.Point(t: 0, m: 0)
    @ObservationIgnored private var heartRate: RecorderSnapshot.HeartRate?
    @ObservationIgnored private var lastCheckpoint: Date?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var queued = 0

    /// - Parameters:
    ///   - makeSession: builds the session for a run of the given kind, at the countdown.
    ///   - units: read once per run, at the countdown.
    ///   - tickInterval: how often the snapshot refreshes; nil for none (tests drive it).
    init(
        makeSession: @escaping (RecorderState.RunKind) throws -> WorkoutSessionDriving,
        location: RunLocationStreaming,
        units: @escaping () -> Units,
        clock: @escaping () -> Date = Date.init,
        tickInterval: Duration? = .seconds(1),
        log: @escaping (String, [String: String]) -> Void = { Telemetry.info($0, context: $1) }
    ) {
        self.makeSession = makeSession
        self.location = location
        self.unitsSource = units
        self.clock = clock
        self.tickInterval = tickInterval
        self.log = log
        location.onLocations = { [weak self] in self?.receiveLocations($0) }
        location.onAccess = { [weak self] in self?.accessChanged($0) }
    }

    /// The real thing: HealthKit and Core Location.
    convenience init(units: @escaping () -> Units) {
        let store = HKHealthStore()
        self.init(
            makeSession: { kind in try HealthWorkoutSession(store: store, kind: kind) },
            location: RunLocationStream(),
            units: units
        )
    }

    // MARK: - Input

    /// The only way anything happens to a run.
    func send(_ event: RecorderEvent) {
        let old = state
        let new = RecorderState.reduce(old, event)
        guard new != old else { return }
        state = new
        for effect in RecorderEffect.between(old, new) { perform(effect) }
        refresh()
        checkpoint(force: true)
    }

    /// Back to idle once the post-run screen is dismissed, ready for the next run. Only
    /// from a run that is over: a live run can't be reset away.
    func reset() {
        switch state.phase {
        case .saved, .discarded: break
        default: return
        }
        state = RecorderState()
        snapshot = .idle
        lastFailure = nil
        recordingID = nil
        track = nil
        treadmill = []
        heartRate = nil
    }

    /// Rebuild the snapshot for now.
    func refresh() {
        snapshot = RecorderSnapshot.make(
            state: state, at: clock(), timeline: timeline, units: units,
            heartRate: heartRate, gpsLocked: track?.isLocked ?? false
        )
    }

    /// Waits for every queued HealthKit call, including any queued by the ones before it.
    func settled() async {
        var seen = -1
        while seen != queued {
            seen = queued
            await queue?.value
        }
    }

    // MARK: - Effects

    private func perform(_ effect: RecorderEffect) {
        switch effect {
        case .prepare:
            prepare()

        case .begin(let at):
            if state.kind == .treadmill {
                treadmill = [BestEfforts.Point(t: 0, m: 0)]
            } else {
                track = TrackMath.Track(start: at)
            }
            distanceFlushed = BestEfforts.Point(t: 0, m: 0)
            routeGate.reset()
            let metadata = RecordingMetadata.atBegin(
                recordingID: recordingID ?? UUID(), kind: state.kind, target: state.target)
            enqueue { session in
                try await session.begin(at: at, metadata: metadata)
            } onError: { [weak self] error in
                self?.sessionFailed("begin", error)
            }
            log("recorder.started", ["kind": state.kind.rawValue])

        case .pause(let at):
            session?.pause(at: at)

        case .resume(let at):
            session?.resume(at: at)
            track?.resumeAfterPause(at: at)
            routeGate.reset()

        case .stop(let at):
            location.stop()
            track?.close()
            flushRoute()
            flushDistance(final: true)
            enqueue { session in
                try await session.stop(at: at)
            } onError: { [weak self] error in
                // Collection may not have ended cleanly; the save will say if it matters.
                self?.lastFailure = String(describing: error)
                self?.log("recorder.stop_failed", ["error_type": String(describing: type(of: error))])
            }

        case .save:
            let metadata = RecordingMetadata.atSave(state: state)
            enqueue { [weak self] session in
                let finished = try await session.finish(metadata: metadata)
                self?.saved(finished)
            } onError: { [weak self] error in
                self?.lastFailure = String(describing: error)
                self?.log("recorder.save_failed", ["error_type": String(describing: type(of: error))])
                self?.send(.saveFailed(reason: "Couldn't save to Apple Health"))
            }

        case .discard:
            location.stop()
            enqueue { session in await session.discard() }
            log("recorder.discarded", ["kind": state.kind.rawValue])

        case .tearDown:
            location.stop()
            ticker?.cancel()
            ticker = nil
            // After whatever is still queued for this session, not before it.
            let previous = queue
            queued += 1
            queue = Task { [weak self] in
                await previous?.value
                self?.session = nil
            }
        }
    }

    private func prepare() {
        units = unitsSource()
        recordingID = UUID()
        lastFailure = nil
        do {
            let session = try makeSession(state.kind)
            session.onSignal = { [weak self] in self?.receiveSignal($0) }
            try session.prepare()
            self.session = session
        } catch {
            // Back to idle through the reducer, not around it: the countdown can't continue
            // without a session.
            sessionFailed("prepare", error)
            return
        }
        // GPS gets the countdown to settle. Fixes from before the clock starts are not used
        // (`TrackMath` calls them stale); the point is that the receiver is warm.
        if state.kind != .treadmill { location.start() }
        startTicker()
    }

    private func saved(_ finished: FinishedWorkout) {
        let ended = state.endedAt ?? clock()
        let run = RecordedRun(
            workoutID: finished.id,
            workout: finished.workout,
            recordingID: recordingID ?? finished.id,
            kind: state.kind,
            target: state.target,
            startedAt: state.startedAt ?? ended,
            endedAt: ended,
            clocks: state.clocks(at: ended),
            distanceM: timeline.last?.m ?? 0,
            splits: TrackMath.splits(timeline: timeline, altitudes: track?.altitudes ?? [],
                                     splitMeters: units.splitMeters),
            units: units
        )
        log("recorder.saved", ["kind": state.kind.rawValue])
        send(.saveSucceeded(workoutID: finished.id))
        onSaved?(run)
    }

    private func sessionFailed(_ step: String, _ error: Error) {
        lastFailure = String(describing: error)
        log("recorder.session_failed", ["step": step, "error_type": String(describing: type(of: error))])
        send(.interrupted(.sessionFailed, at: clock()))
    }

    /// Run `work` against this recording's session after everything already queued.
    private func enqueue(
        _ work: @escaping @MainActor (WorkoutSessionDriving) async throws -> Void,
        onError: @escaping @MainActor (Error) -> Void = { _ in }
    ) {
        guard let session else { return }
        let previous = queue
        queued += 1
        queue = Task {
            await previous?.value
            do { try await work(session) } catch { onError(error) }
        }
    }

    // MARK: - Signals in

    private func receiveSignal(_ signal: WorkoutSessionSignal) {
        switch signal {
        case .heartRate(let bpm, let at):
            heartRate = RecorderSnapshot.HeartRate(bpm: bpm, at: at)
        case .distance(let meters, let at):
            guard state.kind == .treadmill, let start = state.startedAt,
                  let last = treadmill.last, meters > last.m else { return }
            treadmill.append(BestEfforts.Point(t: max(last.t, at.timeIntervalSince(start)), m: meters))
        case .failed(let reason):
            lastFailure = reason
            log("recorder.session_failed", ["step": "running"])
            send(.interrupted(.sessionFailed, at: clock()))
        }
    }

    /// GPS fixes. Only a running run is measured: not the countdown, not a pause, not a run
    /// the recorder has lost hold of.
    private func receiveLocations(_ locations: [CLLocation]) {
        guard state.phase == .running, var track else { return }
        for location in locations {
            let wasLocked = track.isLocked
            let verdict = track.ingest(TrackMath.Fix(location))
            routeBatch += routeGate.admit(location, verdict: verdict, wasLocked: wasLocked)
        }
        self.track = track
        if routeBatch.count >= Self.routeBatchSize { flushRoute() }
    }

    private func accessChanged(_ access: LocationAccess) {
        guard state.isLive, state.kind != .treadmill, !access.canRecordOutdoors else { return }
        // Logged, not stopped: the clock keeps running and the save screen knows why the
        // route has a hole (#111).
        send(.interrupted(.locationRevoked, at: clock()))
    }

    // MARK: - Writing as the run goes

    private var timeline: [BestEfforts.Point] {
        state.kind == .treadmill ? treadmill : (track?.timeline ?? [])
    }

    private func flushRoute() {
        guard !routeBatch.isEmpty else { return }
        let batch = routeBatch
        routeBatch.removeAll()
        enqueue { session in try await session.addRoute(batch) } onError: { [weak self] error in
            self?.log("recorder.route_failed", ["error_type": String(describing: type(of: error))])
        }
    }

    /// Outdoor distance into the workout, a chunk at a time (see `DistanceChunks`).
    private func flushDistance(final: Bool) {
        guard state.kind != .treadmill, let track, let start = state.startedAt,
              let chunk = DistanceChunks.next(timeline: track.timeline, flushed: distanceFlushed, final: final)
        else { return }
        distanceFlushed = chunk.to
        guard chunk.meters > 0 else { return }
        let from = start.addingTimeInterval(chunk.from.t)
        let to = start.addingTimeInterval(chunk.to.t)
        enqueue { session in
            try await session.addDistance(meters: chunk.meters, from: from, to: to)
        } onError: { [weak self] error in
            self?.log("recorder.distance_failed", ["error_type": String(describing: type(of: error))])
        }
    }

    // MARK: - The clock

    /// Once a second while a run is being recorded: refresh the numbers, write distance as
    /// it accrues, and checkpoint.
    func tick() {
        refresh()
        switch state.phase {
        case .running, .paused: flushDistance(final: false)
        default: break
        }
        checkpoint(force: false)
    }

    private func startTicker() {
        guard let tickInterval else { return }
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tickInterval)
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    private func checkpoint(force: Bool) {
        guard let recordingID, let onCheckpoint else { return }
        let now = clock()
        if !force, let last = lastCheckpoint, now.timeIntervalSince(last) < Self.checkpointIntervalS { return }
        lastCheckpoint = now
        onCheckpoint(RecorderCheckpoint(recordingID: recordingID, state: state,
                                        distanceM: timeline.last?.m ?? 0, savedAt: now))
    }
}

extension TrackMath.Fix {
    /// One `CLLocation`, as is. `TrackMath` does all the filtering.
    init(_ location: CLLocation) {
        self.init(
            timestamp: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            altitude: location.altitude,
            verticalAccuracy: location.verticalAccuracy
        )
    }
}
