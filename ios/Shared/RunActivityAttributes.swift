import ActivityKit
import AppIntents
import Foundation

/// The Live Activity for a run being recorded (#119): Lock Screen and Dynamic Island.
///
/// Lives in the existing `TempoWidgets` extension, so no new App ID. Started, updated and
/// ended only by the app (`RunLiveActivity`), locally: v1 has no APNs capability, so there are
/// no push updates. The clock ticks by itself (`Text(timerInterval:)`); everything else is at
/// most one update a second.
struct RunActivityAttributes: ActivityAttributes {
    typealias ContentState = RunActivityState

    /// The recording this activity belongs to (`WorkoutRecorder.recordingID`). After iOS kills
    /// Tempo mid-run, the activity outlives the process; the relaunched app adopts the one
    /// whose recording it picks back up and ends any other (`RunActivityPlan.reconcile`).
    let recordingID: UUID
}

// MARK: - The Lock Screen's buttons

/// Where the Lock Screen's Pause and Resume land: set by the app at launch to send the
/// command into its one `WorkoutRecorder`. Nil in the widget extension, which only draws the
/// buttons; a `LiveActivityIntent` is performed in the app's process.
@MainActor
enum RunActivityControl {
    static var handler: (@MainActor (RunActivityCommand) async -> Void)?
}

/// Pause, from the Lock Screen or the Dynamic Island. Arrives as
/// `.pause(.manual(.lockScreen), at:)`, which the reducer takes exactly like a tap on the live
/// screen.
struct PauseRunIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause run"
    static let description = IntentDescription("Pauses the run Tempo is recording.")
    /// A Lock Screen button, not a Shortcut: a run is only ever controlled from the run.
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await RunActivityControl.handler?(.pause)
        return .result()
    }
}

/// Resume, from the Lock Screen or the Dynamic Island. A pause he made, from either screen,
/// is lifted only by him; this is him.
struct ResumeRunIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Resume run"
    static let description = IntentDescription("Resumes the run Tempo is recording.")
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await RunActivityControl.handler?(.resume)
        return .result()
    }
}
