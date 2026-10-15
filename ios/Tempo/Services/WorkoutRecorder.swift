import CoreLocation
import Foundation
import HealthKit
import Observation
import UIKit

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
    /// HealthKit reporting back: heart rate, a failure. Set by the recorder before `prepare`.
    var onSignal: ((WorkoutSessionSignal) -> Void)? { get set }

    /// Countdown started: get the sensors ready. Records nothing.
    func prepare() throws
    /// Countdown done: start the activity and collection at `date`, tagged with `metadata`.
    func begin(at date: Date, metadata: [String: Any]) async throws
    func pause(at date: Date)
    func resume(at date: Date)
    /// The athlete ended the run: stop the activity and end collection at `date`. The
    /// session is not ended yet; that happens in `finish` or `discard`. Indoors, collection
    /// may end in `finish` instead, at this same `date`, so the treadmill's distance — only
    /// written at Save (#116) — lands while the builder is still collecting.
    func stop(at date: Date) async throws
    /// Append GPS fixes to the workout's route.
    func addRoute(_ locations: [CLLocation]) async throws
    /// Add one stretch of distance to the workout (see `DistanceChunks`): outdoors as the
    /// run goes, on a treadmill all at once at Save.
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
    /// The session failed underneath the run.
    case failed(reason: String)
}

/// A workout HealthKit has saved, read the way ingest reads every workout
/// (`WorkoutRow.Workout(_ hkWorkout:)`), so the row the save path writes matches the one the
/// sync would have written.
struct FinishedWorkout {
    let id: UUID
    let row: WorkoutRow.Workout
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

/// Step-based speed for auto-pause: `RunPedometerStream` (Core Motion) on device, a fake in
/// tests. Only started when auto-pause is on.
@MainActor
protocol RunMotionStreaming: AnyObject {
    var onSample: ((AutoPause.Sample) -> Void)? { get set }
    func start(from date: Date)
    func stop()
}

/// A treadmill run's distance (#116): Core Motion's cumulative step distance since `start`,
/// `RunStepDistanceStream` on device, a fake in tests. Started for treadmill runs only.
@MainActor
protocol RunStepDistanceStreaming: AnyObject {
    /// `(metres since start(from:), when)`.
    var onDistance: ((Double, Date) -> Void)? { get set }
    func start(from date: Date)
    func stop()
}

/// No step distance: for a recorder that never records a treadmill run.
@MainActor
final class NoStepDistance: RunStepDistanceStreaming {
    var onDistance: ((Double, Date) -> Void)?
    func start(from date: Date) {}
    func stop() {}
}

/// The voice (#118): `CueSpeaker` on device, a fake in tests. One per run.
@MainActor
protocol RunCueSpeaking: AnyObject {
    /// The voice-cues setting. Nothing is said when it is off.
    var isEnabled: Bool { get }
    func speakSplit(_ split: TrackMath.Split, averagePaceS: Double?, units: Units)
    func speak(_ decision: AutoPause.Decision)
    func speakRaceDistance(meters: Double, elapsedS: Double, averagePaceS: Double?, units: Units)
    /// Cut off anything being said and give the audio back.
    func stop()
}

extension CueSpeaker: RunCueSpeaking {}

// MARK: - Hand-offs

/// Writes the in-progress run (#115) to disk, or clears it (`nil`), in the order asked.
///
/// One serial queue, off the main thread: a marathon's snapshot is tens of kilobytes every
/// ten seconds, and the order is load-bearing. A write that lands after the clear that
/// followed it leaves a snapshot behind for a run already in Health, and the next launch
/// offers to rescue a run that was saved, which turns one run into two.
enum InProgressRunWriter {
    private static let queue = DispatchQueue(label: "studio.delight.tempo.in-progress-run", qos: .utility)

    static func persist(_ snapshot: InProgressRun?) {
        queue.async {
            if let snapshot { InProgressRunStore.save(snapshot) } else { InProgressRunStore.clear() }
        }
    }
}

/// A workout session `HKHealthStore.recoverActiveWorkoutSession` handed back after a kill
/// (#115), as the recorder needs it: something to drive, and what it says about itself.
struct RecoveredSession {
    let driver: WorkoutSessionDriving
    /// The Tempo recording it belongs to, from its builder's metadata. Nil if the kill came
    /// before the metadata was written.
    let recordingID: UUID?
    let info: InProgressRun.SessionRecovery
}

/// Where kill recovery (#115) reads from at launch: on device, the snapshot file and
/// HealthKit; in tests, fakes. Each is a seam so the launch path is a test, not a force-quit.
struct RecoverySources {
    /// The in-progress snapshot on disk (`InProgressRunStore.load`).
    var loadSnapshot: () -> InProgressRun?
    /// The workout session that was running when Tempo died (`HealthWorkoutSession.recoverActive`).
    var recoverSession: @MainActor () async -> RecoveredSession?
    /// A workout to save a run into when no session survived ("save what we have"):
    /// `RescuedWorkout` on device. Nil if one can't be made.
    var rescue: @MainActor (RecorderState) -> WorkoutSessionDriving?
    /// The workout a recording already became in Health, if it did — see
    /// `HealthWorkoutSession.savedWorkout(recordingID:store:)`.
    var savedWorkout: @MainActor (UUID) async -> FinishedWorkout?

    /// Nothing to recover from and nothing to save into.
    static func none() -> RecoverySources {
        RecoverySources(loadSnapshot: { nil }, recoverSession: { nil }, rescue: { _ in nil }, savedWorkout: { _ in nil })
    }

    /// The real thing.
    static func device(store: HKHealthStore) -> RecoverySources {
        RecoverySources(
            loadSnapshot: { InProgressRunStore.load() },
            recoverSession: {
                do {
                    guard let session = try await HealthWorkoutSession.recoverActive(store: store) else { return nil }
                    return RecoveredSession(driver: session, recordingID: session.recordingID, info: session.recovery)
                } catch {
                    Telemetry.error("recorder.session_recover_error", error)
                    return nil
                }
            },
            rescue: { state in RescuedWorkout(store: store, state: state) },
            savedWorkout: { id in await HealthWorkoutSession.savedWorkout(recordingID: id, store: store) }
        )
    }
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
/// **Saving is Health, then Tempo** (#122). The workout is finished in HealthKit first —
/// Health is the source of truth — and only then handed to `RecordedRunSaver`, which writes
/// the `runs` row the sync would have written, and the journal with it. Its outcome is what
/// the state machine hears (`saveEvent(for:workoutID:)`). A finished workout is kept, so a
/// Retry after Tempo refused the row never finishes the HealthKit workout a second time.
///
/// **Kill recovery (#115).** This file writes the run down as it goes, and reads it back at
/// launch (`recoverAtLaunch`, then `adopt`):
/// - An `InProgressRun` snapshot is written on every state change and every
///   `InProgressRun.saveInterval` while the run is rescuable (`InProgressRun.shouldSave`),
///   and cleared once it is in Health or discarded (`shouldClear`). Its `workoutSessionID` is
///   this recording's id.
/// - The same id and the target are written into the workout builder's metadata when
///   collection begins, so the session `HKHealthStore.recoverActiveWorkoutSession` hands
///   back after a relaunch identifies itself (`HealthWorkoutSession.recoverActive`, whose
///   `recordingID` matches `workoutSessionID`).
/// - Ending a run stops the session's activity but does not end the session until the save
///   or the discard, so a kill on the save screen leaves a session to recover.
/// - Distance samples and the route go into the builder as the run goes, not at the end.
/// - At launch, `adopt` takes the snapshot and whatever session HealthKit gives back, lets
///   `InProgressRun.recover` decide, and picks the run up: the live screen again if the
///   session survived, "save what we have" through a `RescuedWorkout` if it did not, the
///   save screen if it died there. `recovered` is what the UI reads to say so.
///
/// **Auto-pause (#113), when he has turned it on**, is fed every GPS fix's speed and, from
/// Core Motion, his step speed. What it decides goes through `applyAutoPause`, the single
/// place a decision becomes an event, and the place the spoken cue (#118) hooks in
/// (`onAutoPause`). Decisions are backdated to the start of the stop or the restart, so
/// the moving clock can step back a few seconds when one lands; that is expected (#127).
///
/// **A treadmill run (#116)** has no GPS: its curve is his step distance from Core Motion
/// (`TreadmillDistance.Steps`), and none of it goes into the workout while he runs. At Save
/// the save screen hands over what the console said (`confirmSave(…, treadmillConsoleM:)`),
/// the curve is rescaled to it (`TreadmillDistance.rescaled`), and only then written —
/// HealthKit can never take a sample back, so writing as he ran would have made a phone that
/// over-counted impossible to correct. The workout is finished with the correction in its
/// metadata, which is what marks the `runs` row corrected (`WorkoutRow.corrected`).
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
    /// What happened when the run was written to Tempo, once it has been tried.
    private(set) var saveOutcome: RecordedRunSaver.Outcome?
    /// The `runs` row the recorded run became. For a race, what the result links to
    /// (`goals.race_run_id`, #117).
    var savedRunID: UUID? {
        if case .saved(let runID) = saveOutcome { return runID }
        return nil
    }
    /// What launch found when iOS had killed Tempo mid-run (#115), until the athlete has
    /// seen it: the "We kept your run" prompt (#128, Figma frame 10) is up while this is set.
    /// `.resume` is a run going again; `.rescue` / `.expired` a run waiting for "Save what we
    /// have" or "Discard"; `.unfinished` a run back on the save screen. Never `.nothing` or
    /// `.orphanSession` — neither has a run to show.
    private(set) var recovered: InProgressRun.Recovery?
    /// An auto-pause decision the run accepted: where the spoken + haptic cue (#118) fires,
    /// so an auto pause is never silent.
    @ObservationIgnored var onAutoPause: ((AutoPause.Decision) -> Void)?
    /// Distance moved on, `(previous, current)` metres, once a second while running. The
    /// race-distance cue (#117) hangs off this: `CueText.crossed(raceM, …)` then
    /// `cues?.speakRaceDistance`.
    @ObservationIgnored var onDistanceAdvanced: ((Double, Double) -> Void)?
    /// This run's voice. Made at the countdown and kept after the run ends, until the next
    /// run replaces it: a speaker let go mid-cue would never hand the audio back, and the
    /// music would stay ducked.
    @ObservationIgnored private(set) var cues: RunCueSpeaking?

    /// Route fixes are written in batches of about this many — a few seconds of running.
    static let routeBatchSize = 10
    /// Fixes held while paused, in case auto-resume backdates the restart into them. Its
    /// streak is 3 s; this is that with room to spare.
    static let heldFixesS = 15.0

    /// Every fix written to the workout's route, kept for the save screen's map (#129). The
    /// route is already in the builder by then, but `HKWorkoutRoute` can't be read back until
    /// the workout is saved, which is the one thing the save screen comes before. Not
    /// observed: it grows once a fix, and is only read once the run has ended.
    @ObservationIgnored private(set) var route: [CLLocation] = []

    /// The run's splits, in the unit it started in, for the save screen (#129). Off the same
    /// timeline the live numbers and the voice cues read, so the table can't disagree with
    /// what he heard at each split.
    var splits: [TrackMath.Split] {
        TrackMath.splits(timeline: timeline, altitudes: track?.altitudes ?? [], splitMeters: units.splitMeters)
    }

    // Collaborators
    private let makeSession: (RecorderState.RunKind) throws -> WorkoutSessionDriving
    private let location: RunLocationStreaming
    private let motion: RunMotionStreaming
    private let steps: RunStepDistanceStreaming
    private let makeCues: () -> RunCueSpeaking
    private let unitsSource: () -> Units
    private let clock: () -> Date
    private let tickInterval: Duration?
    /// The #131 vocabulary: one line per transition, one per save.
    private let report: ([RecorderTelemetry.Line]) -> Void
    /// Diagnostics outside that vocabulary: which HealthKit call failed, and how.
    private let log: (String, [String: String]) -> Void
    private let persist: (InProgressRun?) -> Void
    private let recovery: RecoverySources
    private let saveToTempo: (WorkoutRow.Workout, RunJournalEntry, UIImage?) async -> RecordedRunSaver.Outcome

    // One recording's working state
    @ObservationIgnored private var session: WorkoutSessionDriving?
    /// Fixed at the countdown: a run is split in the unit it started in, whatever the
    /// setting does mid-run.
    @ObservationIgnored private var units: Units = .fallback
    @ObservationIgnored private var track: TrackMath.Track?
    /// Treadmill distance curve, from Core Motion's step distance (#116).
    @ObservationIgnored private var treadmill: [BestEfforts.Point] = []
    @ObservationIgnored private var stepCredit = TreadmillDistance.Steps()
    /// What the treadmill console said, from the save screen; nil to keep the step count.
    @ObservationIgnored private var consoleM: Double?
    /// The correction the workout was written with. Settled at the first Save: from then on
    /// samples are in Health, and a Retry must finish the same run, not a re-corrected one.
    @ObservationIgnored private var treadmillCorrection: TreadmillDistance.Correction?
    @ObservationIgnored private var treadmillSettled = false
    @ObservationIgnored private var routeGate = RouteGate<CLLocation>()
    @ObservationIgnored private var routeBatch: [CLLocation] = []
    @ObservationIgnored private var distanceFlushed = BestEfforts.Point(t: 0, m: 0)
    @ObservationIgnored private var heartRate: RecorderSnapshot.HeartRate?
    /// The last snapshot written, for `InProgressRun.shouldSave`.
    @ObservationIgnored private var lastSnapshot: InProgressRun?
    /// Whether the snapshot on disk has been cleared for a run that came to rest.
    @ObservationIgnored private var snapshotCleared = true
    /// The newest fixes the track used, for the snapshot's `lastFixes`.
    @ObservationIgnored private var usedFixes: [InProgressRun.CarriedFix] = []
    /// Whether this recording writes its own distance samples: an outdoor run (HealthKit's
    /// own collection is off), or any run rebuilt after a kill, where HealthKit has none.
    @ObservationIgnored private var writesDistance = false
    @ObservationIgnored private var recoveryAttempted = false
    /// The workout once HealthKit has it. Set at most once per recording.
    @ObservationIgnored private var finished: FinishedWorkout?
    /// What the athlete wrote on the save screen, for the save in flight.
    @ObservationIgnored private var journal = RunJournalEntry()
    @ObservationIgnored private var photo: UIImage?
    @ObservationIgnored private var autoPause = AutoPause()
    @ObservationIgnored private var lastPedometerAt: Date?
    /// Distance at the last split check, for `CueText.splitToAnnounce`.
    @ObservationIgnored private var announcedThroughM = 0.0
    /// Fixes that arrived while paused, newest `heldFixesS` only.
    @ObservationIgnored private var heldFixes: [CLLocation] = []
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var queued = 0

    /// - Parameters:
    ///   - makeSession: builds the session for a run of the given kind, at the countdown.
    ///   - steps: a treadmill run's distance. Nil counts nothing.
    ///   - units: read once per run, at the countdown.
    ///   - saveToTempo: writes the saved workout into Tempo — `RecordedRunSaver.save`.
    ///   - tickInterval: how often the snapshot refreshes; nil for none (tests drive it).
    init(
        makeSession: @escaping (RecorderState.RunKind) throws -> WorkoutSessionDriving,
        location: RunLocationStreaming,
        motion: RunMotionStreaming,
        steps: RunStepDistanceStreaming? = nil,
        cues: @escaping () -> RunCueSpeaking,
        units: @escaping () -> Units,
        saveToTempo: @escaping (WorkoutRow.Workout, RunJournalEntry, UIImage?) async -> RecordedRunSaver.Outcome,
        clock: @escaping () -> Date = Date.init,
        tickInterval: Duration? = .seconds(1),
        report: @escaping ([RecorderTelemetry.Line]) -> Void = { Telemetry.log($0) },
        log: @escaping (String, [String: String]) -> Void = { Telemetry.warn($0, context: $1) },
        persist: @escaping (InProgressRun?) -> Void = InProgressRunWriter.persist,
        recovery: RecoverySources = .none()
    ) {
        self.makeSession = makeSession
        self.location = location
        self.motion = motion
        self.steps = steps ?? NoStepDistance()
        self.makeCues = cues
        self.unitsSource = units
        self.saveToTempo = saveToTempo
        self.clock = clock
        self.tickInterval = tickInterval
        self.report = report
        self.log = log
        self.persist = persist
        self.recovery = recovery
        location.onLocations = { [weak self] in self?.receiveLocations($0) }
        location.onAccess = { [weak self] in self?.accessChanged($0) }
        motion.onSample = { [weak self] in self?.receivePedometer($0) }
        self.steps.onDistance = { [weak self] in self?.receiveSteps(totalM: $0, at: $1) }
    }

    /// The real thing: HealthKit, Core Location, and the save path into Tempo.
    convenience init(store: RunStore) {
        let health = HKHealthStore()
        self.init(
            makeSession: { kind in try HealthWorkoutSession(store: health, kind: kind) },
            location: RunLocationStream(),
            motion: RunPedometerStream(),
            steps: RunStepDistanceStream(),
            cues: { CueSpeaker() },
            units: { [weak store] in store?.units ?? .fallback },
            saveToTempo: { [weak store] workout, journal, photo in
                // No store means no app to show it in; the sync ingests it from Health.
                guard let store else { return .queued }
                return await RecordedRunSaver.save(workout, journal: journal, photo: photo, store: store)
            },
            recovery: .device(store: health)
        )
    }

    // MARK: - Input

    /// The only way anything happens to a run.
    func send(_ event: RecorderEvent) {
        let old = state
        let new = RecorderState.reduce(old, event)
        guard new != old else { return }
        state = new
        report(RecorderTelemetry.lines(from: old, on: event, to: new))
        for effect in RecorderEffect.between(old, new) { perform(effect) }
        refresh()
        writeSnapshot()
    }

    /// Save on the post-run screen (or Retry after a failed save), with what he wrote there.
    /// A race saves itself at the finish with no journal; his notes can follow (#125).
    ///
    /// `treadmillConsoleM`: on a treadmill, the distance the console showed (#130), or nil to
    /// keep the step count. Read at the first Save only; see `treadmillCorrection`.
    func confirmSave(journal: RunJournalEntry = RunJournalEntry(), photo: UIImage? = nil,
                     treadmillConsoleM: Double? = nil) {
        self.journal = journal
        self.photo = photo
        if !treadmillSettled { consoleM = treadmillConsoleM }
        send(.endConfirmed)
    }

    /// What the state machine hears from the Tempo half of a save. The run is in Health by
    /// the time this is asked, so only a refusal is a failure:
    /// - `.saved`: in Tempo.
    /// - `.tooShort`: a blip, kept in Health only, by the same rule ingest applies.
    /// - `.queued`: no signal. It is on disk and lands on the next refresh by itself.
    /// - `.dropped`: the server refused the row. The sync will still ingest the workout,
    ///   but the journal would be lost, so the save screen stays up with Retry.
    static func saveEvent(for outcome: RecordedRunSaver.Outcome, workoutID: UUID) -> RecorderEvent {
        switch outcome {
        case .saved, .tooShort, .queued:
            return .saveSucceeded(workoutID: workoutID)
        case .dropped:
            return .saveFailed(reason: "Saved to Apple Health, but Tempo couldn't store it")
        }
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
        saveOutcome = nil
        finished = nil
        journal = RunJournalEntry()
        photo = nil
        route = []
        track = nil
        treadmill = []
        resetTreadmill()
        heartRate = nil
        heldFixes = []
        lastPedometerAt = nil
        writesDistance = false
        usedFixes = []
        recovered = nil
    }

    /// A new recording's treadmill state: no steps counted, no console reading, nothing written.
    private func resetTreadmill() {
        stepCredit = TreadmillDistance.Steps()
        consoleM = nil
        treadmillCorrection = nil
        treadmillSettled = false
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

    // MARK: - Kill recovery (#115)

    /// Launch: read back whatever was recording when iOS killed Tempo, and pick it up. Once
    /// per process; a second call (a scene reconnecting) does nothing.
    func recoverAtLaunch() async {
        guard !recoveryAttempted else { return }
        recoveryAttempted = true
        let snapshot = recovery.loadSnapshot()
        let session = await recovery.recoverSession()
        await adopt(snapshot: snapshot, session: session)
    }

    /// The adopt entry point: take a snapshot from disk and the session HealthKit recovered,
    /// either or both possibly missing, and make them this recorder's run.
    ///
    /// `InProgressRun.recover` decides (one copy of the decision table), and the recorder
    /// reaches the state it decided the way it reaches every state: the snapshot's own state,
    /// then `.interrupted(.appTerminated)` stamped at the snapshot's last write, then — if the
    /// session came back — `.recovered(sessionPaused:)`, all through `send`. The recovery
    /// itself is reported once, as `recorder.recovered` or `recorder.recovery_failed`.
    ///
    /// Does nothing if a run is already under way in this process: nothing on disk outranks
    /// the run in front of him.
    func adopt(snapshot: InProgressRun?, session: RecoveredSession?) async {
        guard state.phase == .idle else { return }
        let now = clock()

        // A session that is some other recording's is not grafted onto this one: that would
        // splice two runs into one. It is let go below, and this snapshot is rescued alone.
        var ours = session
        var strays: [RecoveredSession] = []
        if let snapshot, let session, !InProgressRun.matches(snapshot: snapshot, sessionRecordingID: session.recordingID) {
            ours = nil
            strays.append(session)
            log("recorder.recovery_failed", ["outcome": "session_mismatch"])
        }

        let outcome = InProgressRun.recover(snapshot: snapshot, session: ours?.info, now: now)
        if let found = InProgressRun.telemetry(for: outcome, snapshot: snapshot, session: ours?.info, now: now),
           let event = RecorderTelemetry.Event(rawValue: found.event) {
            report([RecorderTelemetry.Line(event: event, level: event == .recovered ? .info : .warn, context: found.context)])
        }

        switch outcome {
        case .resume, .rescue, .expired, .unfinished:
            if let snapshot { await pickUp(outcome, from: snapshot, session: ours, now: now) }
        case .nothing, .orphanSession:
            // A countdown that died, or a snapshot of a run that had already come to rest:
            // nothing to rescue, and left on disk it would be asked about on every launch.
            if snapshot != nil { persist(nil) }
            if let ours { strays.append(ours) }
        }

        // A session with no run of ours behind it. The only way Tempo leaves one is dying
        // between clearing the snapshot and ending the session — the athlete had already
        // saved or discarded that run — so it is ended, not saved. Left running, it would
        // hold the phone's one workout session and block the next run.
        for stray in strays { await stray.driver.discard() }
    }

    /// The prompt has been seen. The run itself is untouched: a rescue still waits for
    /// "Save what we have" or "Discard", and its snapshot stays on disk until then.
    func acknowledgeRecovery() {
        recovered = nil
    }

    /// Rebuild a recording's working state from its snapshot and become that run.
    private func pickUp(_ outcome: InProgressRun.Recovery, from snapshot: InProgressRun,
                        session: RecoveredSession?, now: Date) async {
        let resuming: Bool
        if case .resume = outcome { resuming = true } else { resuming = false }
        let seed = InProgressRun.resumption(snapshot: snapshot, session: session?.info,
                                            resumedAt: resuming ? now : nil)
        let start = snapshot.state.startedAt ?? snapshot.savedAt
        let kind = snapshot.state.kind

        // Read at recovery: the snapshot does not carry the unit the run started in.
        units = unitsSource()
        recordingID = snapshot.workoutSessionID ?? session?.recordingID ?? UUID()
        lastFailure = nil
        saveOutcome = nil
        finished = nil
        journal = RunJournalEntry()
        photo = nil
        heartRate = nil
        autoPause = AutoPause()
        lastPedometerAt = nil
        heldFixes = []
        routeGate.reset()
        routeBatch = []
        usedFixes = snapshot.lastFixes
        lastSnapshot = nil
        snapshotCleared = false
        resetTreadmill()
        if kind == .treadmill {
            track = nil
            treadmill = seed.curve.points
        } else {
            track = TrackMath.Track(start: start, resuming: seed.curve.points, movingS: snapshot.movingS,
                                    elevationGainM: snapshot.elevationGainM,
                                    elevationLossM: snapshot.elevationLossM)
            treadmill = []
        }
        // A treadmill run has written nothing yet, whatever the session says: its distance
        // goes in at Save, all of it.
        distanceFlushed = kind == .treadmill ? BestEfforts.Point(t: 0, m: 0) : seed.inHealth
        announcedThroughM = seed.curve.lastMeters
        writesDistance = kind != .treadmill

        // Something to finish the run through: the session that survived; else, for a run
        // that died on the save screen, the workout Health may already have; else a
        // workout rebuilt from the snapshot.
        if let session {
            session.driver.onSignal = { [weak self] in self?.receiveSignal($0) }
            self.session = session.driver
        } else if case .unfinished = outcome, let id = snapshot.workoutSessionID,
                  let saved = await recovery.savedWorkout(id) {
            finished = saved
        } else if let rescue = recovery.rescue(snapshot.state) {
            rescue.onSignal = { [weak self] in self?.receiveSignal($0) }
            self.session = rescue
            // HealthKit has none of this run: every metre of the curve is written — outdoors
            // at the stop, on a treadmill at Save like any treadmill run.
            writesDistance = kind != .treadmill
            distanceFlushed = BestEfforts.Point(t: 0, m: 0)
            let metadata = RecordingMetadata.atBegin(
                recordingID: recordingID ?? UUID(), kind: kind, target: snapshot.state.target)
            enqueue { session in
                try await session.begin(at: start, metadata: metadata)
            } onError: { [weak self] error in
                self?.lastFailure = String(describing: error)
                self?.log("recorder.session_error", ["step": "rescue_begin",
                                                     "error_type": String(describing: type(of: error))])
            }
        } else {
            log("recorder.recovery_failed", ["outcome": "no_workout_to_save_into"])
        }

        state = snapshot.state
        send(.interrupted(.appTerminated, at: snapshot.savedAt))
        if resuming, let session { send(.recovered(sessionPaused: session.info.isPaused)) }

        switch state.phase {
        case .running, .paused:
            // Back on the live screen: GPS, the voice and the clock pick up where they were.
            cues = makeCues()
            // A treadmill counts from its last snapshot: Core Motion kept counting while
            // Tempo was gone, and what it counted since then is the gap, credited if he is
            // running.
            if kind != .treadmill { location.start() } else { steps.start(from: snapshot.savedAt) }
            if state.autoPauseEnabled { motion.start(from: now) }
            startTicker()
        case .ending:
            // Died on the save screen. The run had already stopped; make sure the workout
            // holds all of it, and that its collection has ended, before Save is offered.
            if finished == nil, let end = state.endedAt {
                flushDistance(final: true)
                enqueue { session in try await session.stop(at: end) } onError: { [weak self] error in
                    self?.log("recorder.stop_failed", ["error_type": String(describing: type(of: error))])
                }
            }
        default:
            // `.recovering`: waiting on "Save what we have" or "Discard". Nothing runs.
            break
        }

        recovered = outcome
        refresh()
    }

    // MARK: - Effects

    private func perform(_ effect: RecorderEffect) {
        switch effect {
        case .prepare:
            prepare()

        case .begin(let at):
            if state.kind == .treadmill {
                treadmill = [BestEfforts.Point(t: 0, m: 0)]
                stepCredit = TreadmillDistance.Steps()
                steps.start(from: at)
            } else {
                track = TrackMath.Track(start: at)
            }
            distanceFlushed = BestEfforts.Point(t: 0, m: 0)
            writesDistance = state.kind != .treadmill
            routeGate.reset()
            autoPause = AutoPause()
            lastPedometerAt = nil
            heldFixes = []
            // Step speed only matters to auto-pause, so Motion & Fitness is only asked for
            // by someone who turned it on.
            if state.autoPauseEnabled { motion.start(from: at) }
            let metadata = RecordingMetadata.atBegin(
                recordingID: recordingID ?? UUID(), kind: state.kind, target: state.target)
            enqueue { session in
                try await session.begin(at: at, metadata: metadata)
            } onError: { [weak self] error in
                self?.sessionFailed("begin", error)
            }

        case .pause(let at):
            session?.pause(at: at)
            heldFixes = []

        case .resume(let at):
            session?.resume(at: at)
            track?.resumeAfterPause(at: at)
            routeGate.reset()
            // Auto-resume is backdated to when he started moving again; the fixes since
            // then arrived while still paused and are measured now.
            let since = heldFixes.filter { $0.timestamp >= at }
            heldFixes = []
            measure(since)

        case .stop(let at):
            cues?.stop()
            location.stop()
            motion.stop()
            steps.stop()
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
            // A treadmill run's console reading is settled at the first Save, before a metre
            // of it is in Health (#116).
            if state.kind == .treadmill, finished == nil, !treadmillSettled {
                treadmillCorrection = TreadmillDistance.correction(
                    consoleM: consoleM, estimateM: timeline.last?.m ?? 0, units: units)
                treadmillSettled = true
            }
            let treadmillCurve = state.kind == .treadmill
                ? TreadmillDistance.rescaled(timeline, by: treadmillCorrection, startedAt: state.startedAt,
                                             endedAt: state.endedAt, pauses: state.pauses)
                : nil
            let metadata = RecordingMetadata.atSave(state: state, correction: treadmillCorrection, units: units)
            let journal = journal, photo = photo
            let session = session
            // A run recovered after a kill can reach Save with nothing to save into: no
            // session survived and no rescue workout could be made. Say so and keep the
            // run, rather than sit on "saving" forever.
            guard session != nil || finished != nil else {
                send(.saveFailed(reason: "Couldn't reach Apple Health"))
                return
            }
            enqueueWork { [weak self] in
                guard let self else { return }
                // Health first, and only once: a retry after this point is Tempo's half.
                // A run already in Health before a kill (#115) arrives here with `finished` set.
                let workout: FinishedWorkout
                let began = clock()
                if let finished {
                    workout = finished
                } else if let session {
                    if let treadmillCurve { try await writeTreadmill(treadmillCurve, into: session) }
                    workout = try await session.finish(metadata: metadata)
                    finished = workout
                } else {
                    return
                }
                let outcome = await saveToTempo(workout.row, journal, photo)
                saveOutcome = outcome
                // One line per save, once both halves have answered (#131).
                report([RecorderTelemetry.saved(
                    state, distanceM: (treadmillCurve ?? timeline).last?.m, fixes: track?.verdicts ?? [:],
                    tempo: outcome, saveLatency: clock().timeIntervalSince(began))])
                send(Self.saveEvent(for: outcome, workoutID: workout.id))
            } onError: { [weak self] error in
                self?.lastFailure = String(describing: error)
                self?.log("recorder.health_save_error", ["error_type": String(describing: type(of: error))])
                self?.send(.saveFailed(reason: "Couldn't save to Apple Health"))
            }

        case .discard:
            cues?.stop()
            location.stop()
            motion.stop()
            steps.stop()
            // Already in Health (Tempo refused the row and he gave up): nothing to throw
            // away. It stays in Health, and the sync ingests it like any other workout.
            if finished == nil { enqueue { session in await session.discard() } }

        case .tearDown:
            location.stop()
            motion.stop()
            steps.stop()
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
        saveOutcome = nil
        finished = nil
        resetTreadmill()
        cues = makeCues()
        announcedThroughM = 0
        usedFixes = []
        lastSnapshot = nil
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

    private func sessionFailed(_ step: String, _ error: Error) {
        lastFailure = String(describing: error)
        log("recorder.session_error", ["step": step, "error_type": String(describing: type(of: error))])
        send(.interrupted(.sessionFailed, at: clock()))
    }

    /// Run `work` against this recording's session after everything already queued.
    private func enqueue(
        _ work: @escaping @MainActor (WorkoutSessionDriving) async throws -> Void,
        onError: @escaping @MainActor (Error) -> Void = { _ in }
    ) {
        guard let session else { return }
        enqueueWork({ try await work(session) }, onError: onError)
    }

    /// The same queue, for work that may not need a session.
    private func enqueueWork(
        _ work: @escaping @MainActor () async throws -> Void,
        onError: @escaping @MainActor (Error) -> Void = { _ in }
    ) {
        let previous = queue
        queued += 1
        queue = Task {
            await previous?.value
            do { try await work() } catch { onError(error) }
        }
    }

    // MARK: - Signals in

    private func receiveSignal(_ signal: WorkoutSessionSignal) {
        switch signal {
        case .heartRate(let bpm, let at):
            heartRate = RecorderSnapshot.HeartRate(bpm: bpm, at: at)
        case .failed(let reason):
            lastFailure = reason
            log("recorder.session_error", ["step": "running"])
            send(.interrupted(.sessionFailed, at: clock()))
        }
    }

    /// GPS fixes. Only a running run is measured: not the countdown, not a pause, not a run
    /// the recorder has lost hold of. Every fix's speed goes to auto-pause, paused or not —
    /// it is how a stop ends.
    private func receiveLocations(_ locations: [CLLocation]) {
        for location in locations {
            switch state.phase {
            case .running:
                measure([location])
            case .paused:
                heldFixes.append(location)
                heldFixes.removeAll { location.timestamp.timeIntervalSince($0.timestamp) > Self.heldFixesS }
            default:
                break
            }
            // Core Location's speed is negative when it doesn't know; AutoPause reads that
            // as no reading, never as standing still.
            feedAutoPause(AutoPause.Sample(at: location.timestamp, speed: location.speed, source: .gps))
        }
        if routeBatch.count >= Self.routeBatchSize { flushRoute() }
    }

    /// Fixes into the distance and, the ones it used, the route.
    private func measure(_ locations: [CLLocation]) {
        guard var track, !locations.isEmpty else { return }
        for location in locations {
            let wasLocked = track.isLocked
            let verdict = track.ingest(TrackMath.Fix(location))
            let used = routeGate.admit(location, verdict: verdict, wasLocked: wasLocked)
            routeBatch += used
            usedFixes = Array((usedFixes + used.map { InProgressRun.CarriedFix(TrackMath.Fix($0)) })
                .suffix(InProgressRun.maxCarriedFixes))
        }
        self.track = track
    }

    /// A treadmill's step distance: onto the curve while he is running, the baseline only
    /// while he is not (`TreadmillDistance.Steps`).
    private func receiveSteps(totalM: Double, at: Date) {
        guard state.kind == .treadmill, let start = state.startedAt, let last = treadmill.last else { return }
        let running = state.phase == .running
        if let point = stepCredit.credit(totalM: totalM, t: at.timeIntervalSince(start),
                                         running: running, after: last) {
            treadmill.append(point)
        }
    }

    private func receivePedometer(_ sample: AutoPause.Sample) {
        lastPedometerAt = sample.at
        feedAutoPause(sample)
    }

    private func feedAutoPause(_ sample: AutoPause.Sample) {
        guard let decision = autoPause.ingest(sample, recorder: state) else { return }
        applyAutoPause(decision)
    }

    /// The one place an auto-pause decision is applied. The reducer has the last word (off
    /// means off; it never lifts his own pause); the cue fires only if it took.
    private func applyAutoPause(_ decision: AutoPause.Decision) {
        let before = state
        send(decision.event)
        // Reported by `send`, as a pause or resume with `trigger: auto` (#131).
        guard state != before else { return }
        onAutoPause?(decision)
        if cues?.isEnabled == true { cues?.speak(decision) }
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
        route += batch
        enqueue { session in try await session.addRoute(batch) } onError: { [weak self] error in
            self?.log("recorder.route_failed", ["error_type": String(describing: type(of: error))])
        }
    }

    /// Distance into the workout, a chunk at a time (see `DistanceChunks`): outdoors as the
    /// run goes, and the whole curve for a run rebuilt after a kill.
    private func flushDistance(final: Bool) {
        guard writesDistance, let start = state.startedAt else { return }
        let chunks = final
            ? DistanceChunks.backlog(timeline: timeline, flushed: distanceFlushed)
            : DistanceChunks.next(timeline: timeline, flushed: distanceFlushed, final: false).map { [$0] } ?? []
        for chunk in chunks {
            distanceFlushed = chunk.to
            guard chunk.meters > 0 else { continue }
            let from = start.addingTimeInterval(chunk.from.t)
            let to = start.addingTimeInterval(chunk.to.t)
            enqueue { session in
                try await session.addDistance(meters: chunk.meters, from: from, to: to)
            } onError: { [weak self] error in
                self?.log("recorder.distance_failed", ["error_type": String(describing: type(of: error))])
            }
        }
    }

    /// A treadmill run's whole curve into the workout, at Save: `curve` is the step count
    /// rescaled to the console, or untouched when he left it alone. Same `DistanceChunks` an
    /// outdoor run writes, so splits read back out of Health the same way. `distanceFlushed`
    /// marks each chunk once it has landed, so a Retry after a failure part-way writes the
    /// rest and never a metre twice.
    private func writeTreadmill(_ curve: [BestEfforts.Point], into session: WorkoutSessionDriving) async throws {
        guard let start = state.startedAt else { return }
        for chunk in DistanceChunks.backlog(timeline: curve, flushed: distanceFlushed) {
            if chunk.meters > 0 {
                try await session.addDistance(meters: chunk.meters,
                                              from: start.addingTimeInterval(chunk.from.t),
                                              to: start.addingTimeInterval(chunk.to.t))
            }
            distanceFlushed = chunk.to
        }
    }

    // MARK: - The clock

    /// Once a second while a run is being recorded: refresh the numbers, write distance as
    /// it accrues, and write the recovery snapshot.
    func tick() {
        refresh()
        if state.phase == .running { announce() }
        switch state.phase {
        case .running, .paused: flushDistance(final: false)
        default: break
        }
        // A treadmill has no GPS to say he has stopped; a quiet pedometer does (see
        // `PedometerSilence` for why only here).
        if state.kind == .treadmill, state.autoPauseEnabled,
           let still = PedometerSilence.filler(lastReadingAt: lastPedometerAt, now: clock()) {
            feedAutoPause(still)
        }
        writeSnapshot()
    }

    /// The split cue (#118): once per finished split, said with the split's own pace and the
    /// average so far. Checked against the snapshot just refreshed, so the voice and the
    /// screen read the same numbers.
    private func announce() {
        let previous = announcedThroughM
        let current = snapshot.distanceM
        guard current > previous else { return }
        announcedThroughM = current
        onDistanceAdvanced?(previous, current)
        guard let cues, cues.isEnabled,
              let index = CueText.splitToAnnounce(previousMeters: previous, currentMeters: current, units: units),
              let split = TrackMath.splits(timeline: timeline, splitMeters: units.splitMeters)
                .first(where: { $0.index == index && !$0.isPartial })
        else { return }
        cues.speakSplit(split, averagePaceS: snapshot.averagePaceS, units: units)
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

    /// The kill-recovery snapshot (#115): written on every state change and every
    /// `InProgressRun.saveInterval` while the run could still be lost, cleared once it can't.
    private func writeSnapshot() {
        if InProgressRun.shouldClear(state) {
            if !snapshotCleared {
                persist(nil)
                snapshotCleared = true
                lastSnapshot = nil
            }
            return
        }
        let now = clock()
        guard InProgressRun.shouldSave(last: lastSnapshot, state: state, now: now) else { return }
        let snapshot = InProgressRun(
            savedAt: now,
            state: state,
            workoutSessionID: recordingID,
            curve: InProgressRun.DistanceCurve(timeline),
            movingS: track?.movingS ?? 0,
            elevationGainM: track?.elevationGainM ?? 0,
            elevationLossM: track?.elevationLossM ?? 0,
            lastFixes: usedFixes
        )
        persist(snapshot)
        lastSnapshot = snapshot
        snapshotCleared = false
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
