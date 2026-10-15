import ActivityKit
import Foundation

/// The run's Live Activity (#119), driven from the recorder: does what `RunActivityPlan`
/// decides, through ActivityKit, and nothing else.
///
/// `TempoApp` hands it every recorder refresh (`WorkoutRecorder.onRefresh`): every event, and
/// once a second while a run is recorded. Locally only; there are no push updates in v1.
/// ActivityKit calls are asynchronous and their order matters (an update landing after the
/// end would be dropped, an end landing before the last update would show stale numbers in
/// the dismissal), so they go through one serial queue, like the recorder's HealthKit calls.
@MainActor
final class RunLiveActivity {

    private var activity: Activity<RunActivityAttributes>?
    private var shown: RunActivityPlan.Shown?
    private var lastStartAttempt: Date?
    /// A recording whose activity he swiped off the Lock Screen. It is not put back.
    private var declined: UUID?
    private var reconciled = false
    private var queue: Task<Void, Never>?

    func sync(state: RecorderState, snapshot: RecorderSnapshot, recordingID: UUID?, now: Date = .now) {
        var want = RunActivityPlan.content(state: state, snapshot: snapshot)
        if recordingID == nil || recordingID == declined { want = nil }

        if !reconciled {
            reconciled = true
            adoptOrEndExisting(recordingID: recordingID, wanted: want != nil)
        }
        if let current = activity {
            switch current.activityState {
            case .dismissed, .ended:
                // Gone from under us: he swiped it away. Respect that for this run.
                declined = current.attributes.recordingID
                activity = nil
                shown = nil
                if recordingID == declined { want = nil }
            default:
                // Another recording's activity (a new run began before this one was ended):
                // end it, and start this run's below.
                if current.attributes.recordingID != recordingID {
                    end(current)
                    activity = nil
                    shown = nil
                }
            }
        }

        switch RunActivityPlan.step(want: want, shown: shown, lastStartAttempt: lastStartAttempt, now: now) {
        case .none:
            break
        case .start(let content):
            guard let recordingID else { return }
            start(content, recordingID: recordingID, now: now)
        case .update(let content):
            guard let activity else { return }
            shown = .init(content: content, at: now)
            let update = ActivityContent(state: content, staleDate: RunActivityPlan.staleDate(for: content, at: now))
            enqueue { await activity.update(update) }
        case .end:
            if let activity { end(activity) }
            activity = nil
            shown = nil
        }
    }

    // MARK: - Private

    private func start(_ content: RunActivityState, recordingID: UUID, now: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastStartAttempt = now
            return
        }
        do {
            activity = try Activity.request(
                attributes: RunActivityAttributes(recordingID: recordingID),
                content: ActivityContent(state: content, staleDate: RunActivityPlan.staleDate(for: content, at: now)),
                pushType: nil
            )
            shown = .init(content: content, at: now)
            lastStartAttempt = nil
        } catch {
            // Most often a relaunch in the background after a kill (#115): ActivityKit only
            // starts one from the foreground. Retried every `retryStartS`, so it appears once
            // he opens the app.
            lastStartAttempt = now
            Telemetry.warn("recorder.live_activity_start_failed", context: ["error_type": String(describing: type(of: error))])
        }
    }

    /// The first look in this process: keep the activity that belongs to the run the
    /// recorder holds (a run picked back up after a kill), end every other.
    private func adoptOrEndExisting(recordingID: UUID?, wanted: Bool) {
        let existing = Activity<RunActivityAttributes>.activities
        let plan = RunActivityPlan.reconcile(existing: existing.map(\.attributes.recordingID),
                                             recordingID: recordingID, wanted: wanted)
        if let keep = plan.keep {
            activity = existing[keep]
            shown = .init(content: nil, at: nil)
        }
        for index in plan.end { end(existing[index]) }
    }

    /// Off the Lock Screen at once: after a save the run is in Health, and after a discard
    /// there is nothing to show. A final card left up for hours would read as a run going on.
    private func end(_ activity: Activity<RunActivityAttributes>) {
        enqueue { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task {
            await previous?.value
            await work()
        }
    }
}
