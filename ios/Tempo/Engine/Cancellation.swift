import Foundation

/// "Was this failure just the caller walking away?"
///
/// `RunStore.refresh()` is one long sequential pass, entered from `.task` and `.refreshable`
/// on four screens. When the task driving it is cancelled — a `.task` re-running as the root
/// view re-renders at launch, a pull-to-refresh superseded by another, a screen dismissed
/// mid-load — every Supabase call still ahead of it throws. On 2026-10-13 that one benign
/// cancellation landed in `app_events` as four brand-new *named* error events in 115 ms
/// (`sync.runs_unreadable`, `sync.insert_failed`, `takeaway.latest_unreadable`,
/// `block.past_unreadable`), all `CancellationError()`, and it recurred on 2026-10-15 (#155).
/// To a triage pass reading the table cold, that is the exact shape of a new regression.
///
/// Two spellings mean the same thing here:
///  - Swift's `CancellationError`, thrown by structured concurrency itself.
///  - `URLError(.cancelled)` (NSURLErrorDomain −999), which is what a URLSession data task
///    under a cancelled task can surface instead — the Supabase client sits on URLSession.
///    An `NSError` in that domain bridges to `URLError`, so it is caught by the same check.
///
/// Deliberately narrow: a timeout, a lost connection or a Postgrest error is a real failure
/// and must keep reporting exactly as before. This is about not misnaming cancellation, not
/// about swallowing errors.
enum Cancellation {

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        return false
    }
}
