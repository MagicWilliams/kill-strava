import Foundation

/// What the recorder service has to *do* when the run changes state (#114).
///
/// `RecorderState.reduce` decides what state a run is in; it never touches HealthKit, GPS or
/// a timer. This table is the other half: given the state before and after one event, the
/// side effects the service must perform, in order. Keeping it pure is what lets the whole
/// lifecycle be pinned without HealthKit, and it keeps the reducer's central rule intact
/// on the I/O side too: the only effects that finish or throw away a workout come from the
/// transitions the reducer only allows the athlete to cause.
///
/// The service (`WorkoutRecorder`) dispatches an event, reduces, asks this table, and runs
/// the effects through one serial queue. It never decides on its own to stop a session.
enum RecorderEffect: Equatable {
    /// idle → countdown. Build the workout session and prepare it, and wake GPS so it has a
    /// few seconds to settle before the clock starts. Nothing is recorded yet.
    case prepare
    /// countdown → running. Start the session's activity and the builder's collection at
    /// the instant the countdown finished, and start measuring the track from it.
    case begin(at: Date)
    /// running → paused. Pause the session, so HealthKit's own duration excludes the stop.
    case pause(at: Date)
    /// paused → running. Resume the session, and break the GPS track so whatever happened
    /// while paused is not credited as distance.
    case resume(at: Date)
    /// The athlete ended the run. Stop the session's activity and the builder's collection,
    /// stop GPS, and close the track. The session itself stays alive (stopped, not ended)
    /// until the workout is saved or discarded, so a kill on the save screen is still
    /// recoverable (#115).
    case stop(at: Date)
    /// Write the workout to Health: final metadata, `finishWorkout`, end the session.
    case save
    /// Throw the workout away and end the session. Only ever reached from `.discarded` or a
    /// cancelled countdown, both of which the reducer allows only from the live screen.
    case discard
    /// The run is over one way or another: stop GPS and the clock, let go of the session.
    case tearDown
}

extension RecorderEffect {

    /// The effects of going from `old` to `new`. Empty when nothing outside the state needs
    /// to change — including every transition into and out of `.recovering`, which belongs
    /// to kill recovery (#115) and is deliberately left to it.
    static func between(_ old: RecorderState, _ new: RecorderState) -> [RecorderEffect] {
        switch (old.phase, new.phase) {

        case (.idle, .countdown):
            return [.prepare]

        // Cancelled during the countdown, or lost the app during it. Nothing was recorded.
        case (.countdown, .idle):
            return [.discard, .tearDown]

        case (.countdown, .running):
            guard let at = new.startedAt else { return [] }
            return [.begin(at: at)]

        case (.running, .paused):
            guard let pause = new.openPause else { return [] }
            return [.pause(at: pause.start)]

        case (.paused, .running):
            guard let resumed = new.pauses.last?.end else { return [] }
            return [.resume(at: resumed)]

        // The athlete ended it. A race goes straight to `.saving`; everything else stops on
        // the save screen until he confirms.
        case (.running, .ending(let step)), (.paused, .ending(let step)), (.recovering, .ending(let step)):
            guard let end = new.endedAt else { return [] }
            return step == .saving ? [.stop(at: end), .save] : [.stop(at: end)]

        case (.ending(.review), .ending(.saving)), (.ending(.failed), .ending(.saving)):
            return [.save]

        case (.ending(.saving), .saved):
            return [.tearDown]

        case (_, .discarded) where old.phase != .discarded:
            return [.discard, .tearDown]

        default:
            return []
        }
    }
}
