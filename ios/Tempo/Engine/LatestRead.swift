import Foundation

/// What the "Coach's read" card on the just-running Today shows (#101).
///
/// In training mode Today previews the takeaway for *today's session*, and only once the
/// matcher has tied a run to it. With no plan there is no session, so that preview could
/// never appear — the coach's reads were still being written on every opened run, and the
/// home screen had no way to show one. This card shows the newest read there is, the way
/// the widget carries its coach line forward, and says which run it is about.
///
/// It does not generate one. A takeaway is a Claude call, and the training path only spends
/// it on a run that fulfilled a planned session; between blocks the athlete opts in by
/// opening the run, which is where generation already lives.
enum LatestRead {

    struct Read: Equatable {
        let runID: UUID
        let runStart: Date
        let text: String
    }

    enum State: Equatable {
        /// No runs and no reads: nothing to say, and the card stays out of the way.
        case none
        /// Runs exist, but the coach hasn't read any of them yet.
        case invite(lastRun: UUID)
        /// The newest read is about the newest run.
        case current(Read)
        /// The newest read is about an earlier run; the last run is still unread. Shown, but
        /// dated, so last Tuesday's read is never mistaken for one about this morning.
        case behind(Read, lastRun: UUID)
    }

    /// - Parameters:
    ///   - lastRunID: `RunStore.lastRun?.id`.
    ///   - latest: the newest run with a cached `coach_takeaway`, if any.
    static func state(lastRunID: UUID?, latest: Read?) -> State {
        // An empty or whitespace takeaway is no takeaway; the column has held both.
        let read = latest.flatMap { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        switch (read, lastRunID) {
        case (nil, nil):
            return .none
        case (nil, let last?):
            return .invite(lastRun: last)
        case (let read?, nil):
            // Reads but no runs on screen: Health unavailable and the DB list empty. The
            // read is still true; show it.
            return .current(read)
        case (let read?, let last?):
            return read.runID == last ? .current(read) : .behind(read, lastRun: last)
        }
    }
}
