import Foundation

/// Every `recorder.*` line Tempo reports about a recording, built from the recorder's own types
/// and nothing else (#131).
///
/// "Works" is a claim only David can make, and he makes it with the phone in a pocket and his
/// mind on the run. When a recording goes wrong the first question is the one Chicago left
/// unanswered — Strava paused itself mid-marathon, and nobody could say when, or why. These
/// lines are how the EM answers it from `app_events` the morning after, without asking him to
/// remember: when the run started, every stop and who made it, every interruption and whether
/// it cost the recording, and what the save did.
///
/// One place for the names and the keys. `Event` and `Key` are the vocabulary; the builders
/// below are the only code that pairs them, so a renamed key is a failing test here rather than
/// a trend line that silently splits in two across app versions.
///
/// Pure: the builders read states, events and counts, never a clock, a location or a network.
/// The service (#114) dispatches an event to `RecorderState.reduce`, hands the before, the
/// event and the after to `lines(from:on:to:)`, and sends what comes back.
///
/// **No coordinates, no notes.** Nothing here takes a `TrackMath.Fix` or a journal entry, so
/// neither can reach a line by accident: the fix verdict counts are tallies, the target is its
/// session type and never its title. Distance and duration go on `recorder.saved` only, as
/// whole numbers — the same shape `recorder.run_too_short` already reports.
enum RecorderTelemetry {

    // MARK: - Vocabulary

    enum Event: String, CaseIterable {
        /// The countdown finished and both clocks started.
        case started = "recorder.started"
        case paused = "recorder.paused"
        case resumed = "recorder.resumed"
        /// A call, a revoked permission, a failed session, a killed app. `stops_recording` says
        /// which of them cost the recorder its hold on the run.
        case interrupted = "recorder.interrupted"
        /// Crash recovery got the run back / could not (#115). Named here so the vocabulary is
        /// whole; the lines themselves are built where the recovery outcome is decided, since
        /// only that code knows *which* outcome it was. See `lines(from:on:to:)`.
        case recovered = "recorder.recovered"
        case recoveryFailed = "recorder.recovery_failed"
        /// In Apple Health, with what happened to its Tempo row alongside.
        case saved = "recorder.saved"
        case saveFailed = "recorder.save_failed"
        /// The athlete threw the run away. Deliberate, but still a run that was lost, and a
        /// discard straight out of `.recovering` is a recovery that did not work.
        case discarded = "recorder.discarded"
    }

    enum Key: String, CaseIterable {
        /// `outdoor` · `treadmill` · `race`
        case kind
        /// The session target at start: `shown` · `hidden` (he chose to run free) · `none`
        case target
        /// The plan's session type ("easy", "tempo", …) or `none`. Never the title.
        case sessionType = "session_type"
        /// `on` · `off`
        case autoPause = "auto_pause"
        /// `manual` · `auto`
        case trigger
        /// Where a manual tap came from: `live_screen` · `lock_screen`. Absent for auto.
        case control
        /// For a resume, what kind of pause it lifted: `manual` · `auto` · `recovery_gap`
        case pauseReason = "pause_reason"
        /// Seconds the lifted pause lasted.
        case pausedS = "paused_s"
        /// Wall-clock seconds since the countdown finished, at the moment of the event.
        case elapsedS = "elapsed_s"
        /// `phone_call` · `location_revoked` · `session_failed` · `app_terminated`
        case reason
        /// `true` when the interruption sent the run to `.recovering`.
        case stopsRecording = "stops_recording"
        /// The phase the event landed in: `countdown` · `running` · `paused` · `review` ·
        /// `saving` · `save_failed` · `recovering`
        case phase
        case distanceM = "distance_m"
        /// Wall clock, start to end.
        case durationS = "duration_s"
        case movingS = "moving_s"
        /// Every GPS fix the track was handed, used or not. 0 on a treadmill.
        case fixCount = "fix_count"
        /// Whole percent of fixes that contributed nothing (every verdict but `accepted`), or
        /// `none` when there were no fixes to judge.
        case filteredFixPct = "filtered_fix_pct"
        /// Per-verdict tallies behind `filtered_fix_pct`, always all five.
        case fixesAwaitingLock = "fixes_awaiting_lock"
        case fixesInaccurate = "fixes_inaccurate"
        case fixesStale = "fixes_stale"
        case fixesOutOfOrder = "fixes_out_of_order"
        case fixesTooFast = "fixes_too_fast"
        /// Milliseconds from Save to Health and Tempo both having answered.
        case saveLatencyMs = "save_latency_ms"
        /// What `RecordedRunSaver` did with the row: `saved` · `too_short` · `queued` · `dropped`
        case tempoOutcome = "tempo_outcome"
        case pauses
        case autoPauses = "auto_pauses"
        case interruptions
        /// Crash recovery (#115): the recovery outcome, the gap Tempo was gone for, the points
        /// on the snapshot's distance curve, whether the session itself was paused.
        case outcome
        case gapS = "gap_s"
        case curvePoints = "curve_points"
        case sessionPaused = "session_paused"
    }

    /// One report, ready for `Telemetry.log(_:)`. Equatable so a test can pin it whole.
    struct Line: Equatable {
        let event: Event
        let level: Telemetry.Level
        /// Free-form detail for a human reading the row. Never athlete-typed.
        var detail: String? = nil
        let context: [String: String]
    }

    // MARK: - Transitions

    /// What one reducer step is worth reporting. Empty when the event changed nothing — an
    /// auto-pause with auto-pause off, a Lock Screen "end", a late tap on a finished run — so
    /// the table carries what the recorder *did*, not everything it was asked.
    ///
    /// An `AutoPause.Decision` arrives here as its `event`, so auto pauses are reported exactly
    /// like manual ones, with `trigger: auto`.
    ///
    /// `.recovered` is deliberately not reported here. Recovery is reported once, by the code
    /// that decides it (#115), with the outcome only that code knows; reporting the reducer step
    /// too would put two `recorder.recovered` rows on every recovery.
    static func lines(from before: RecorderState, on event: RecorderEvent, to after: RecorderState) -> [Line] {
        guard before != after else { return [] }

        switch event {
        case .countdownDone:
            guard after.phase == .running else { return [] }
            return [Line(event: .started, level: .info, context: [
                Key.kind.rawValue: after.kind.rawValue,
                Key.target.rawValue: targetLabel(after),
                Key.sessionType.rawValue: after.target?.type ?? "none",
                Key.autoPause.rawValue: after.autoPauseEnabled ? "on" : "off",
            ])]

        case .pause(let trigger, _):
            guard let pause = after.openPause else { return [] }
            var context = triggerContext(trigger)
            context[Key.elapsedS.rawValue] = whole(after.elapsed(at: pause.start))
            context[Key.pauses.rawValue] = String(after.pauses.count)
            return [Line(event: .paused, level: .info, context: context)]

        case .resume(let trigger, _):
            guard let lifted = before.openPause, let closed = after.pauses.last,
                  let end = closed.end else { return [] }
            var context = triggerContext(trigger)
            context[Key.pauseReason.rawValue] = label(lifted.reason)
            context[Key.pausedS.rawValue] = whole(end.timeIntervalSince(closed.start))
            context[Key.elapsedS.rawValue] = whole(after.elapsed(at: end))
            return [Line(event: .resumed, level: .info, context: context)]

        case .interrupted(let kind, let at):
            // Read off the state that was interrupted: an interruption during the countdown
            // resets to idle, and the reset state has neither a start nor a phase to report.
            return [Line(
                event: .interrupted,
                level: kind.stopsRecording ? .warn : .info,
                context: [
                    Key.reason.rawValue: label(kind),
                    Key.stopsRecording.rawValue: kind.stopsRecording ? "true" : "false",
                    Key.phase.rawValue: label(before.phase),
                    Key.kind.rawValue: before.kind.rawValue,
                    Key.elapsedS.rawValue: whole(before.elapsed(at: at)),
                ]
            )]

        case .saveFailed(let reason):
            return [Line(event: .saveFailed, level: .error, detail: String(reason.prefix(300)), context: [
                Key.kind.rawValue: before.kind.rawValue,
                Key.elapsedS.rawValue: whole(before.elapsed(at: before.endedAt ?? .distantPast)),
            ])]

        case .discard:
            guard after.phase == .discarded else { return [] }
            var context = [
                Key.phase.rawValue: label(before.phase),
                Key.kind.rawValue: before.kind.rawValue,
                Key.pauses.rawValue: String(before.pauses.count),
                Key.interruptions.rawValue: String(before.interruptions.count),
            ]
            if let through = lastKnownInstant(before) {
                context[Key.elapsedS.rawValue] = whole(before.elapsed(at: through))
            }
            return [Line(event: .discarded, level: .info, context: context)]

        case .start, .endRequested, .endConfirmed, .saveSucceeded, .recovered, .setTargetVisible:
            // `.saveSucceeded` is reported by `saved(…)` once the Tempo row has answered too —
            // one line per save, carrying both halves of it.
            return []
        }
    }

    // MARK: - The save

    /// The `recorder.saved` line, sent once both halves of a save have answered: the workout in
    /// Apple Health (`.saved` on `state`), and its Tempo row from `RecordedRunSaver`.
    ///
    /// - Parameters:
    ///   - distanceM: the distance the workout was saved with. `TrackMath.Track.distanceM`
    ///     outdoors; whatever the session measured on a treadmill.
    ///   - fixes: `TrackMath.Track.verdicts` — empty on a treadmill.
    ///   - saveLatency: seconds from Save to both answers.
    static func saved(
        _ state: RecorderState,
        distanceM: Double?,
        fixes: [TrackMath.Verdict: Int],
        tempo: RecordedRunSaver.Outcome,
        saveLatency: TimeInterval
    ) -> Line {
        let clocks = state.clocks(at: state.endedAt ?? .distantPast)
        var context: [String: String] = [
            Key.kind.rawValue: state.kind.rawValue,
            Key.distanceM.rawValue: distanceM.map(whole) ?? "none",
            Key.durationS.rawValue: String(clocks.elapsedS),
            Key.movingS.rawValue: String(clocks.movingS),
            Key.saveLatencyMs.rawValue: String(Int((max(0, saveLatency) * 1000).rounded())),
            Key.tempoOutcome.rawValue: label(tempo),
            Key.pauses.rawValue: String(state.pauses.count),
            Key.autoPauses.rawValue: String(state.pauses.filter { $0.reason == .auto }.count),
            Key.interruptions.rawValue: String(state.interruptions.count),
            Key.autoPause.rawValue: state.autoPauseEnabled ? "on" : "off",
        ]
        context.merge(fixContext(fixes)) { _, new in new }
        return Line(event: .saved, level: .info, context: context)
    }

    /// Fix tallies and the filtered share, from `TrackMath.Track.verdicts`.
    ///
    /// "Filtered" is every verdict but `accepted` — the fixes that moved nothing. Lock
    /// candidates count: a run that spent its first minute waiting for a lock is exactly the
    /// kind of run this number is here to flag.
    static func fixContext(_ verdicts: [TrackMath.Verdict: Int]) -> [String: String] {
        let total = verdicts.values.reduce(0, +)
        let filtered = total - verdicts[.accepted, default: 0]
        return [
            Key.fixCount.rawValue: String(total),
            Key.filteredFixPct.rawValue: total > 0
                ? String(Int((Double(filtered) / Double(total) * 100).rounded()))
                : "none",
            Key.fixesAwaitingLock.rawValue: String(verdicts[.awaitingLock, default: 0]),
            Key.fixesInaccurate.rawValue: String(verdicts[.inaccurate, default: 0]),
            Key.fixesStale.rawValue: String(verdicts[.stale, default: 0]),
            Key.fixesOutOfOrder.rawValue: String(verdicts[.outOfOrder, default: 0]),
            Key.fixesTooFast.rawValue: String(verdicts[.tooFast, default: 0]),
        ]
    }

    // MARK: - Labels

    /// snake_case, like every other value in `app_events`; the enums' raw values are camelCase
    /// because they are also persisted in the crash snapshot, and must not move for telemetry.
    static func label(_ interruption: RecorderState.Interruption) -> String {
        switch interruption {
        case .phoneCall:       "phone_call"
        case .locationRevoked: "location_revoked"
        case .sessionFailed:   "session_failed"
        case .appTerminated:   "app_terminated"
        }
    }

    static func label(_ reason: RecorderState.PauseReason) -> String {
        switch reason {
        case .manual:      "manual"
        case .auto:        "auto"
        case .recoveryGap: "recovery_gap"
        }
    }

    static func label(_ phase: RecorderState.Phase) -> String {
        switch phase {
        case .idle:              "idle"
        case .countdown:         "countdown"
        case .running:           "running"
        case .paused:            "paused"
        case .ending(.review):   "review"
        case .ending(.saving):   "saving"
        case .ending(.failed):   "save_failed"
        case .saved:             "saved"
        case .discarded:         "discarded"
        case .recovering:        "recovering"
        }
    }

    static func label(_ outcome: RecordedRunSaver.Outcome) -> String {
        switch outcome {
        case .saved:    "saved"
        case .tooShort: "too_short"
        case .queued:   "queued"
        case .dropped:  "dropped"
        }
    }

    // MARK: - Private

    private static func targetLabel(_ state: RecorderState) -> String {
        guard state.target != nil else { return "none" }
        return state.targetVisible ? "shown" : "hidden"
    }

    private static func triggerContext(_ trigger: RecorderState.Trigger) -> [String: String] {
        switch trigger {
        case .auto:
            return [Key.trigger.rawValue: "auto"]
        case .manual(let control):
            return [Key.trigger.rawValue: "manual",
                    Key.control.rawValue: control == .lockScreen ? "lock_screen" : "live_screen"]
        }
    }

    /// The last instant a run is known to have been recorded through, for a discard (which
    /// carries no instant of its own).
    private static func lastKnownInstant(_ state: RecorderState) -> Date? {
        switch state.phase {
        case .recovering(let since): since
        case .paused:                state.openPause?.start
        case .ending:                state.endedAt
        default:                     nil
        }
    }

    /// Whole units, rounded. Used for seconds and metres alike.
    private static func whole(_ value: Double) -> String {
        String(Int(max(0, value).rounded()))
    }
}
