import SwiftUI

@main
struct TempoApp: App {
    @StateObject private var runs: RunStore
    @StateObject private var router = TabRouter()
    /// The one recorder (#114), for the life of the app: a run outlives every screen, tab
    /// switch and sheet. Built on the same store the save path writes into. The same
    /// instance recovers a killed run at launch (#115) and drives the live screen, so a
    /// recovered session is never adopted by a recorder the screens can't see.
    @State private var recorder: WorkoutRecorder

    init() {
        let runs = RunStore()
        let recorder = WorkoutRecorder(store: runs)
        _runs = StateObject(wrappedValue: runs)
        _recorder = State(initialValue: recorder)
        // Kill recovery (#115) starts with the process, not with a view: when iOS relaunches
        // Tempo for a workout session it killed, there may be no scene on screen to run a
        // `.task`, and the session is waiting to be picked back up either way. What it finds
        // is shown by `.runRecorder(...)`, the one place recorder screens are presented.
        //
        // The Live Activity (#119) follows every refresh, from the countdown's end to the
        // save or the discard, a recovered run included. One sync after recovery settles
        // ends a Lock Screen activity left over from a run that was not picked back up.
        let liveActivity = RunLiveActivity()
        recorder.onRefresh = { state, snapshot, recordingID in
            liveActivity.sync(state: state, snapshot: snapshot, recordingID: recordingID)
        }
        let recovery = Task { @MainActor in
            await recorder.recoverAtLaunch()
            liveActivity.sync(state: recorder.state, snapshot: recorder.snapshot, recordingID: recorder.recordingID)
        }
        // Pause / Resume on the Lock Screen. A tap can relaunch a Tempo that iOS killed, so
        // it waits for recovery to pick the run back up; sent to an idle recorder it would
        // be dropped. The reducer decides what a Lock Screen tap may do (#111).
        RunActivityControl.handler = { command in
            await recovery.value
            recorder.send(command.event(at: .now))
        }
    }

    var body: some Scene {
        WindowGroup {
            // No `.preferredColorScheme` here: the app follows system appearance (design
            // system v3, decision 1). A dark pin left over from the first shell sat on this
            // line through build 10 and kept the light theme from ever appearing (#80).
            RootTabView()
                .environmentObject(runs)
                .environmentObject(router)
                .environment(recorder)
                // Every distance and pace below reads this (#109). Flipping it on the You tab
                // re-renders the whole tree in the new unit.
                .environment(\.units, runs.units)
                .task { await runs.start() }
                // Widget taps (#76): Week opens Today, Coach opens the Coach tab.
                .onOpenURL { url in
                    switch WidgetLink(url: url) {
                    case .today: router.show(.today)
                    case .coach: router.show(.coach)
                    case nil: break
                    }
                }
        }
    }
}
