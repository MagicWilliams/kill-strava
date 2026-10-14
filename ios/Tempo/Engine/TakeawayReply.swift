import Foundation

/// Which coach replies are fit to sit in `runs.coach_takeaway` (#137).
///
/// A takeaway is generated once and cached for good: `TakeawayService` never regenerates a
/// run that already has one. So the one thing it must never cache is a non-answer. Before
/// #137 the coach answered an empty completion, after one retry, with "Lost my train of
/// thought there — ask me that again." — in takeaway mode too — and that sentence became the
/// run's permanent read on Today and on Run Detail. In the Sonnet 5 thinking-budget incident
/// every completion came back empty, so every run opened then could have been stamped with it.
///
/// The coach no longer sends that line for a takeaway, but the app does not take the
/// server's word for it: the edge function is deployed separately from the app, and an
/// older coach can still be live when this build is. Rows written before the fix are
/// cleared by `0018_clear_fallback_takeaways.sql`, not here.
enum TakeawayReply {

    /// The opening of the coach's empty-completion line (`supabase/functions/coach`). Matched
    /// as a prefix — the same test `0018_clear_fallback_takeaways.sql` uses — so a reworded
    /// tail ("— ask me that again.") doesn't let it back in.
    static let fallbackPrefix = "Lost my train of thought"

    /// The text to cache or show, or nil when the reply is no takeaway at all: empty,
    /// whitespace, or the coach's fallback line.
    static func usable(_ reply: String?) -> String? {
        guard let text = reply?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix(fallbackPrefix) { return nil }
        return text
    }
}
