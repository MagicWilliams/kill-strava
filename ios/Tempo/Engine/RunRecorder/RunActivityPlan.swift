import Foundation

/// When the Live Activity (#119) starts, updates and ends, decided from the recorder's state.
///
/// `RunLiveActivity` asks this on every recorder refresh — every event and once a second —
/// and does what it says through ActivityKit. Kept pure for the usual reason: none of it can
/// be watched without a phone in a pocket, and every rule here is one that, broken, would
/// leave a number on the Lock Screen that isn't the run's.
///
/// - **The activity's life is the run's.** It starts when the countdown finishes and ends
///   when the run is saved or discarded. It stays through the save screen, clock stopped, so
///   a run he ended with the phone already back in his pocket still says it needs saving.
/// - **At most about one update a second**, and only when something drawn would change. The
///   clock needs none at all. A change of stage (he paused) goes at once: the button he just
///   pressed has to flip.
/// - **A Live Activity that stops hearing from the app says so.** Each update carries a stale
///   date `staleAfterS` ahead, and a quiet stretch (a long pause changes nothing drawn) is
///   refreshed every `keepAliveS`. If iOS kills Tempo, the Lock Screen goes stale and reads
///   "Open Tempo" instead of showing a clock for a run nobody is recording.
enum RunActivityPlan {

    /// The ticker is one second; this leaves room for its jitter without letting an event
    /// and a tick double up.
    static let minUpdateS = 0.9
    static let keepAliveS = 30.0
    static let staleAfterS = 90.0
    /// A start that failed (activities turned off, or a relaunch in the background, where
    /// ActivityKit refuses to start one) is tried again no sooner than this.
    static let retryStartS = 10.0

    /// The Lock Screen's content for this run now, or nil when there should be no activity:
    /// before the countdown has finished, and once the run is saved or discarded.
    static func content(state: RecorderState, snapshot: RecorderSnapshot) -> RunActivityState? {
        guard let startedAt = state.startedAt else { return nil }
        let stage: RunActivityState.Stage
        switch state.phase {
        case .running: stage = .running
        case .paused: stage = .paused
        case .recovering: stage = .interrupted
        case .ending: stage = .ended
        case .idle, .countdown, .saved, .discarded: return nil
        }
        return RunActivityState(
            stage: stage,
            startedAt: startedAt,
            endedAt: state.endedAt,
            distanceM: snapshot.distanceM,
            currentPaceS: snapshot.currentPaceS,
            targetPaceS: snapshot.target?.paceS,
            vsTargetS: snapshot.target?.deltaS,
            units: snapshot.units
        )
    }

    /// What the activity on screen was last sent. `content` is nil for one adopted from a
    /// previous process, whose content this process never saw.
    struct Shown: Equatable {
        var content: RunActivityState?
        var at: Date?
    }

    enum Step: Equatable {
        case none
        case start(RunActivityState)
        case update(RunActivityState)
        case end
    }

    /// - Parameters:
    ///   - want: `content(state:snapshot:)` now.
    ///   - shown: the activity on screen, if there is one.
    ///   - lastStartAttempt: when a start was last tried without one appearing.
    static func step(want: RunActivityState?, shown: Shown?, lastStartAttempt: Date?, now: Date) -> Step {
        guard let want else { return shown == nil ? .none : .end }
        guard let shown else {
            if let last = lastStartAttempt, now.timeIntervalSince(last) < retryStartS { return .none }
            return .start(want)
        }
        guard let was = shown.content, let at = shown.at else { return .update(want) }
        if was.stage != want.stage { return .update(want) }
        let since = now.timeIntervalSince(at)
        if since < minUpdateS { return .none }
        if RunActivityDisplay(was) != RunActivityDisplay(want) { return .update(want) }
        if want.stage != .ended, since >= keepAliveS { return .update(want) }
        return .none
    }

    /// When an update stops counting as live. None once the run has ended: the save screen's
    /// numbers are final and don't go stale.
    static func staleDate(for content: RunActivityState, at now: Date) -> Date? {
        content.stage == .ended ? nil : now.addingTimeInterval(staleAfterS)
    }

    /// The activities already on screen when this process first looks, by their recording
    /// id: which one to keep (an index), and which to end. Only the one belonging to the run
    /// the recorder holds survives; anything else is a run that is no longer being recorded
    /// (saved or discarded in a process that died before ending it), and left up it would
    /// tick on the Lock Screen indefinitely.
    static func reconcile(existing: [UUID], recordingID: UUID?, wanted: Bool) -> (keep: Int?, end: [Int]) {
        let keep = wanted ? recordingID.flatMap { id in existing.firstIndex(of: id) } : nil
        return (keep, existing.indices.filter { $0 != keep })
    }
}

extension RunActivityCommand {
    /// The recorder event a Lock Screen button sends. `.lockScreen`, so the reducer applies
    /// its one rule for that surface: pause and resume, never end or discard.
    func event(at date: Date) -> RecorderEvent {
        switch self {
        case .pause: .pause(.manual(.lockScreen), at: date)
        case .resume: .resume(.manual(.lockScreen), at: date)
        }
    }
}
