import Foundation

/// Which slice of `coach_messages` the Coach tab opens on, and in what order it reads.
///
/// Pure because the thing that broke was a *direction*. The read was
/// `.order("created_at").limit(200)`, and PostgREST's `order` defaults to ascending —
/// ascending plus a limit returns the **oldest** 200 rows. Once the history passed 200
/// messages a relaunch opened on the start of the conversation and simply never loaded
/// anything said since (#93). Worse than the scroll position: `messages.suffix(24)` is the
/// window handed to the coach, so the model was being briefed on the opening of a
/// conversation it was supposedly continuing, and nothing in the app said so.
///
/// The read therefore asks for the *newest* page — `created_at` descending, `id` descending
/// to break ties the same way `ChangeLedgerService` does — and the device puts that page
/// back into reading order here.
enum ChatHistory {

    /// How many messages a launch reads.
    ///
    /// Scroll-back for the athlete, not memory for the coach: the model still only ever
    /// sees `suffix(24)`, and threads (#87) are what will eventually make the whole archive
    /// reachable. 200 is "enough transcript to scroll through", nothing more principled.
    static let pageSize = 200

    /// Turn the newest-first page the server returns into reading order: oldest first,
    /// newest last — what the transcript renders top-to-bottom, and what `suffix(24)` has
    /// to mean for the coach's window to be the recent end of the conversation.
    ///
    /// A sort rather than a bare `reversed()`, over a flipped page: the result is right even
    /// if the `order` clauses are ever rearranged, and it is 200 rows, not 2,000. Rows
    /// sharing a `created_at` to the microsecond hold their flipped arrival order, so the
    /// output is a function of the page rather than of Swift's sort internals.
    static func inReadingOrder<Row>(newestFirst page: [Row], by date: (Row) -> Date) -> [Row] {
        page.reversed().enumerated()
            .sorted { a, b in
                let (first, second) = (date(a.element), date(b.element))
                return first == second ? a.offset < b.offset : first < second
            }
            .map(\.element)
    }
}
