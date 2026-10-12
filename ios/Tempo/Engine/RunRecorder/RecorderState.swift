import Foundation

/// The one authoritative answer to "what state is this run in?" (#111).
///
/// Chicago, 11 Oct 2026: Strava silently paused during the race, and the recording of the
/// marathon a whole block had been built toward was lost to a recorder that stopped. Every
/// rule in this file is a guard against some version of that afternoon:
///
///  - **Only the athlete ends a run.** Auto-pause, an interruption, a crash and the Lock Screen
///    can all touch a run; none of them can finish or discard it. There is no automatic path
///    into `.ending`, `.saved` or `.discarded`, and the tests walk every one to prove it.
///  - **Auto-pause is opt-in** (David, 2026-10-12). With it off, `.pause(.auto)` is ignored.
///  - **The athlete's word outranks the math.** Auto-resume only lifts a pause auto-pause put
///    there. A pause he asked for stays until he asks to resume.
///  - **An illegal event is a no-op, never a crash.** Events arrive from HealthKit callbacks,
///    a Live Activity intent, a timer and a finger, in whatever order iOS delivers them. A
///    late "pause" landing on a run that already ended must change nothing.
///
/// Pure value type with no clock of its own: every event carries its instant, and the clocks
/// are read *at* a moment. The service (#114) dispatches events and acts on the transitions;
/// crash recovery (#115) persists this whole struct as its snapshot, which is why it is
/// `Codable` down to the last nested enum.
struct RecorderState: Codable, Equatable {

    // MARK: - What is being recorded

    /// Chosen on the pre-run sheet. Race is outdoor with a different ending: it saves itself.
    enum RunKind: String, Codable {
        case outdoor, treadmill, race
    }

    /// Today's session as the athlete saw it when he pressed Start — a copy, not a reference.
    /// The plan can be regenerated mid-run; what the run is judged against must not move with it.
    struct SessionTarget: Codable, Equatable {
        var sessionID: UUID?
        /// The plan's session type: "easy", "tempo", "long", ….
        var type: String
        var title: String?
        var distanceM: Int?
        /// Seconds per mile, the unit of `SessionInfo.target_pace_sec`.
        var paceSecPerMile: Int?
    }

    /// The pre-run sheet's answers. `showTarget` is the "run free" toggle; `autoPause` the
    /// You-tab setting, off unless he turned it on.
    struct Setup: Equatable {
        var kind: RunKind
        var target: SessionTarget?
        var showTarget: Bool = true
        var autoPause: Bool = false
    }

    // MARK: - Who is asking

    /// Where a tap came from. The Lock Screen (Live Activity, Dynamic Island) is reachable
    /// through a pocket, so it may pause and resume but never end or discard (David, #125).
    enum Control: String, Codable {
        case liveScreen, lockScreen
    }

    /// Who wants the clock stopped or started: the athlete, or auto-pause (#113).
    enum Trigger: Equatable {
        case manual(Control)
        case auto
    }

    enum PauseReason: String, Codable {
        /// The athlete paused.
        case manual
        /// Auto-pause decided he had stopped. Only these may be lifted by auto-resume.
        case auto
        /// The time between a crash and relaunch, when the workout session itself was paused
        /// (#115). Only he can resume it — we were not there to see him start running again.
        case recoveryGap
    }

    /// One stop. `end == nil` while the run is still paused.
    struct Pause: Codable, Equatable {
        var start: Date
        var end: Date?
        var reason: PauseReason
    }

    // MARK: - Interruptions

    enum Interruption: String, Codable {
        /// A call came in. The run keeps recording through it, the way the clock on a race
        /// course does; it is logged, not paused.
        case phoneCall
        /// Location access was revoked mid-run. Time keeps counting; distance is the service's
        /// problem, and the log tells the save screen why the route has a hole.
        case locationRevoked
        /// The `HKWorkoutSession` failed underneath us.
        case sessionFailed
        /// iOS killed the app. Dispatched on relaunch against the rehydrated snapshot, stamped
        /// with the snapshot's last-saved instant — the last moment we know the run was fine.
        case appTerminated

        /// Whether the recorder lost hold of the run and must go through `.recovering`.
        var stopsRecording: Bool {
            switch self {
            case .phoneCall, .locationRevoked: false
            case .sessionFailed, .appTerminated: true
            }
        }
    }

    struct InterruptionRecord: Codable, Equatable {
        var kind: Interruption
        var at: Date
    }

    // MARK: - Phase

    /// Where `.ending` is: the save screen, a write in flight, or a write that failed and kept
    /// everything so it can be tried again.
    enum SaveStep: Codable, Equatable {
        case review
        case saving
        case failed(reason: String)
    }

    enum Phase: Codable, Equatable {
        case idle
        case countdown(startedAt: Date)
        case running
        /// Why, and since when, lives on `openPause`.
        case paused
        /// The clock has stopped (`endedAt` is set); the run is not yet in Health.
        case ending(SaveStep)
        case saved(workoutID: UUID?)
        case discarded
        /// The recorder lost the run (crash, failed session) and has not got it back. `since`
        /// is the last instant we know it was being recorded. Wall time keeps counting.
        case recovering(since: Date)
    }

    // MARK: - State

    var phase: Phase = .idle
    var kind: RunKind = .outdoor
    var target: SessionTarget?
    /// Stored independently of `target` so hiding it is reversible mid-run (David, #125).
    var targetVisible: Bool = false
    var autoPauseEnabled: Bool = false
    /// The instant the countdown finished: the start of both clocks.
    var startedAt: Date?
    var endedAt: Date?
    /// Every stop, in order, at most one open. This is what moving time is made from.
    var pauses: [Pause] = []
    var interruptions: [InterruptionRecord] = []

    init() {}

    // MARK: - Reading it

    /// The pause in progress, if the run is stopped.
    var openPause: Pause? {
        guard let last = pauses.last, last.end == nil else { return nil }
        return last
    }

    /// Started and not yet ending: the live screen is up.
    var isLive: Bool {
        switch phase {
        case .countdown, .running, .paused, .recovering: true
        case .idle, .ending, .saved, .discarded: false
        }
    }

    /// Whether the target strip is on screen right now.
    var showsTarget: Bool { target != nil && targetVisible }

    /// Whether `event` would change anything. The UI asks this to decide what to offer —
    /// hold-to-end is drawn only where `.endRequested(.liveScreen, …)` is accepted.
    func accepts(_ event: RecorderEvent) -> Bool {
        RecorderState.reduce(self, event) != self
    }

    // MARK: - Clocks

    /// Wall-clock seconds since the countdown finished, frozen at `endedAt`.
    func elapsed(at now: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    /// Seconds spent paused. An open pause runs to `endedAt`, else to `now`.
    func stopped(at now: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        let horizon = endedAt ?? now
        return pauses.reduce(0) { total, p in
            let from = max(p.start, startedAt)
            let to = min(p.end ?? horizon, horizon)
            return total + max(0, to.timeIntervalSince(from))
        }
    }

    /// Both clocks in whole seconds, through the same reconciliation every stored run goes
    /// through, so a recorded run and an imported one can never disagree about what "moving"
    /// means. Stopped time is rounded once and subtracted, so `stoppedS` is the pause list's
    /// sum exactly rather than the difference of two independently rounded numbers.
    func clocks(at now: Date) -> TimeAccounting.Clocks {
        let elapsedS = Int(elapsed(at: now).rounded())
        let stoppedS = min(elapsedS, Int(stopped(at: now).rounded()))
        return TimeAccounting.resolve(movingS: elapsedS - stoppedS, elapsedS: elapsedS)
    }

    // MARK: - The reducer

    /// `(State, Event) -> State`. Anything not listed is a no-op and returns `state` unchanged.
    static func reduce(_ state: RecorderState, _ event: RecorderEvent) -> RecorderState {
        var next = state

        switch (state.phase, event) {

        // ── Starting ────────────────────────────────────────────────────────────────────
        case (.idle, .start(let setup, let at)):
            next = RecorderState()
            next.kind = setup.kind
            next.target = setup.target
            next.targetVisible = setup.target != nil && setup.showTarget
            next.autoPauseEnabled = setup.autoPause
            next.phase = .countdown(startedAt: at)

        case (.countdown(let began), .countdownDone(let at)):
            next.startedAt = max(at, began)
            next.phase = .running

        // Nothing has been recorded during a countdown, so cancelling it, or losing the app
        // during it, goes back to idle rather than to a "discarded" run that never existed.
        case (.countdown, .discard(.liveScreen)):
            return RecorderState()
        case (.countdown, .interrupted(let kind, _)) where kind.stopsRecording:
            return RecorderState()

        // ── Pause / resume ──────────────────────────────────────────────────────────────
        case (.running, .pause(let trigger, let at)):
            if trigger == .auto && !state.autoPauseEnabled { return state }
            let reason: PauseReason = trigger == .auto ? .auto : .manual
            next.pauses.append(Pause(start: state.clamp(at), end: nil, reason: reason))
            next.phase = .paused

        case (.paused, .resume(let trigger, let at)):
            guard let open = state.openPause else { return state }
            // Auto-resume lifts only what auto-pause put down. If he paused, he resumes.
            if trigger == .auto && open.reason != .auto { return state }
            next.closeOpenPause(at: state.clamp(at))
            next.phase = .running

        // ── Ending: the athlete's call, from the live screen only ────────────────────────
        case (.running, .endRequested(.liveScreen, let at)),
             (.paused, .endRequested(.liveScreen, let at)):
            let end = state.clamp(at)
            next.closeOpenPause(at: end)
            next.endedAt = end
            next.phase = .ending(state.kind == .race ? .saving : .review)

        // "Save what we have" after a crash the session did not survive: the run ends at the
        // last instant we know it was recorded, not at the moment he reopened the app.
        case (.recovering(let since), .endRequested(.liveScreen, _)):
            next.closeOpenPause(at: since)
            next.endedAt = since
            next.phase = .ending(state.kind == .race ? .saving : .review)

        case (.ending(.review), .endConfirmed),
             (.ending(.failed), .endConfirmed):
            next.phase = .ending(.saving)

        case (.ending(.saving), .saveSucceeded(let workoutID)):
            next.phase = .saved(workoutID: workoutID)

        case (.ending(.saving), .saveFailed(let reason)):
            next.phase = .ending(.failed(reason: reason))

        // ── Discard: deliberate, from the live screen, never mid-stride ─────────────────
        // Not from `.running` — he pauses first (frame 5b) — and not while a save is in
        // flight, where it would race the write.
        case (.paused, .discard(.liveScreen)),
             (.ending(.review), .discard(.liveScreen)),
             (.ending(.failed), .discard(.liveScreen)),
             (.recovering, .discard(.liveScreen)):
            next.phase = .discarded

        // ── Interruptions: logged, sometimes recovering, never ending ───────────────────
        case (_, .interrupted(let kind, let at)) where state.isInFlight:
            let when = state.clamp(at)
            next.interruptions.append(InterruptionRecord(kind: kind, at: when))
            guard kind.stopsRecording else { break }
            switch state.phase {
            case .running, .paused:
                // An open pause stays open: whether the gap was a stop is decided on recovery.
                next.phase = .recovering(since: when)
            case .ending(.saving):
                // Killed mid-write: we don't know if it landed. Keep the run and let him retry.
                next.phase = .ending(.failed(reason: "Tempo closed while saving"))
            default:
                // Already recovering (keep the earliest `since`), or on the save screen with
                // the clock stopped: nothing was lost.
                break
            }

        case (.recovering(let since), .recovered(let sessionPaused)):
            // The workout session kept the truth while we were gone. The gap counts as a pause
            // only if the session itself was paused (#115).
            if sessionPaused {
                if state.openPause == nil {
                    next.pauses.append(Pause(start: since, end: nil, reason: .recoveryGap))
                }
                next.phase = .paused
            } else {
                // Paused in our snapshot but running in the session: he resumed from somewhere
                // we couldn't hear. The session wins; the pause ends where our knowledge does.
                next.closeOpenPause(at: since)
                next.phase = .running
            }

        // ── Target: hide and show mid-run ───────────────────────────────────────────────
        case (_, .setTargetVisible(let visible)) where state.isLive && state.target != nil:
            next.targetVisible = visible

        default:
            return state
        }

        return next
    }

    // MARK: - Private

    /// Started and not finished: anything an interruption could still matter to.
    private var isInFlight: Bool {
        switch phase {
        case .idle, .saved, .discarded: false
        default: true
        }
    }

    /// The latest instant this state already knows about.
    private var latestInstant: Date? {
        var instants: [Date] = []
        if case .countdown(let began) = phase { instants.append(began) }
        if case .recovering(let since) = phase { instants.append(since) }
        if let startedAt { instants.append(startedAt) }
        for p in pauses {
            instants.append(p.start)
            if let end = p.end { instants.append(end) }
        }
        instants += interruptions.map(\.at)
        return instants.max()
    }

    /// Events can arrive stamped out of order (a HealthKit callback queued behind a tap).
    /// Never let one reach back before something already recorded: a resume stamped before
    /// its pause would make moving time *longer* than elapsed.
    private func clamp(_ at: Date) -> Date {
        guard let latest = latestInstant else { return at }
        return max(at, latest)
    }

    private mutating func closeOpenPause(at end: Date) {
        guard let i = pauses.indices.last, pauses[i].end == nil else { return }
        pauses[i].end = max(end, pauses[i].start)
    }
}

/// Everything that can happen to a run. Each carries the instant it happened, where time matters.
enum RecorderEvent: Equatable {
    case start(RecorderState.Setup, at: Date)
    case countdownDone(at: Date)
    case pause(RecorderState.Trigger, at: Date)
    case resume(RecorderState.Trigger, at: Date)
    /// Hold-to-end completed (or End tapped on the paused screen).
    case endRequested(RecorderState.Control, at: Date)
    /// Save on the post-run screen, or Retry after a failed save.
    case endConfirmed
    /// Already confirmed twice in the UI (#128).
    case discard(RecorderState.Control)
    case saveSucceeded(workoutID: UUID?)
    case saveFailed(reason: String)
    case interrupted(RecorderState.Interruption, at: Date)
    /// `HKHealthStore.recoverActiveWorkoutSession` got the session back (#115).
    case recovered(sessionPaused: Bool)
    case setTargetVisible(Bool)
}
