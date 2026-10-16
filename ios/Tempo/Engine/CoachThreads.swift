import Foundation

/// Coach conversations as threads, and the decisions a thread list has to make (#87).
///
/// The Coach tab was one endless scroll, and the coach's own window on it is
/// `messages.suffix(24)` — so a race plan agreed in March was unreachable to the model in
/// April while sitting right there on screen. Threads give a conversation an end, a recap
/// and a title; `coach_memory` carries the facts that must not end with it.
///
/// Everything here is a decision, which is why it is here and not in the store: which
/// thread the list shows first, what a thread with no summary yet is allowed to claim,
/// which threads are owed a summary, what the "Picking up from" note says. Each one is a
/// sentence of text on screen or a round trip to the model, and each one used to be a
/// candidate for being written inline in a view and never thought about again.
///
/// Pure and deterministic: no clock, no locale, no network. `now` is always passed in.
enum CoachThreads {

    /// How long a conversation sits untouched before it counts as finished and is owed its
    /// summary.
    ///
    /// Six hours, from the issue, and deliberately generous: summarizing a thread the
    /// athlete is still in the middle of would put "Picking up from" at the top of the
    /// conversation it is summarizing. The other trigger — starting a new chat — is
    /// immediate, because that one *is* the athlete saying the last one is done.
    static let idleWindow: TimeInterval = 6 * 3600

    /// A row of `coach_threads`, as the app reads it.
    struct Row: Equatable, Identifiable {
        let id: UUID
        /// Written by the summarize pass; nil while the thread is live.
        let title: String?
        /// The two-line recap on the list, same provenance as `title`.
        let summary: String?
        let startedAt: Date
        /// Touched on every message, so this is "when was this conversation last alive".
        let lastMessageAt: Date
        /// Messages in the thread, when the caller has counted them. Nil means "not
        /// counted", which is not the same as zero — an empty thread is one the athlete
        /// opened and never typed in.
        var messageCount: Int? = nil
    }

    /// What the Coach tab shows for one thread.
    struct Tag: Equatable, Identifiable {
        let kind: ChangeLedger.Kind
        /// "Plan · Session changed", or "Plan · 2 changes" once there is more than one.
        let label: String
        var id: String { "\(kind.rawValue)|\(label)" }
    }

    // MARK: - The list

    /// The recap a row actually has, or nil.
    ///
    /// One definition, used by everything that asks "has this been written up yet" — the
    /// list, the summary queue, and the thread that picks up from it. A whitespace-only
    /// summary is no summary: `summary.ts` will not return one, but a row that somehow held
    /// one would otherwise be treated as written up by the queue and as blank by the list,
    /// and the thread would never get a real recap.
    static func recapText(_ row: Row) -> String? {
        guard let summary = row.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else { return nil }
        return summary
    }

    /// Newest conversation first.
    ///
    /// By `lastMessageAt`, not `startedAt`: a thread opened on Monday and replied to on
    /// Thursday belongs at the top on Thursday. Ties fall back to `startedAt` and then to
    /// the id, so the order is a function of the rows and not of Swift's sort — the same
    /// reason `ChatHistory.inReadingOrder` breaks its ties explicitly (#93).
    static func inListOrder(_ rows: [Row]) -> [Row] {
        rows.sorted { a, b in
            if a.lastMessageAt != b.lastMessageAt { return a.lastMessageAt > b.lastMessageAt }
            if a.startedAt != b.startedAt { return a.startedAt > b.startedAt }
            return a.id.uuidString > b.id.uuidString
        }
    }

    /// The thread a message sent right now belongs to: the newest one, if it is still the
    /// conversation the athlete is in.
    ///
    /// Nil means "start a new one" — there are no threads at all, or the newest has gone
    /// quiet long enough to be summarized, at which point continuing it would reopen a
    /// conversation that has already been written up.
    static func active(in rows: [Row], now: Date) -> Row? {
        guard let newest = inListOrder(rows).first else { return nil }
        return isIdle(newest, now: now) ? nil : newest
    }

    /// Whether this thread has been quiet long enough to count as finished.
    static func isIdle(_ row: Row, now: Date) -> Bool {
        now.timeIntervalSince(row.lastMessageAt) >= idleWindow
    }

    /// The threads owed a summary round trip, oldest first so the one the athlete just left
    /// is summarized after any older backlog and the list settles in reading order.
    ///
    /// A thread qualifies when it has no summary yet and is finished — either a newer thread
    /// exists (the athlete started a new chat, which ends the previous one) or it has been
    /// idle past `idleWindow`. An empty thread is skipped: a conversation with nothing in it
    /// has nothing to summarize, and asking the model anyway would produce a title for a
    /// chat that never happened.
    static func awaitingSummary(_ rows: [Row], now: Date) -> [Row] {
        let ordered = inListOrder(rows)
        let qualifying = ordered.enumerated().filter {
            let row = $0.element
            guard recapText(row) == nil else { return false }
            guard (row.messageCount ?? 1) > 0 else { return false }
            // Index 0 is the newest thread: anything behind it has been superseded by a
            // newer conversation, which is the "next one starts" trigger.
            return $0.offset > 0 || isIdle(row, now: now)
        }
        return Array(qualifying.map { $0.element }.reversed())
    }

    /// The conversation a thread picks up from: the most recent one written up *before* it
    /// started.
    ///
    /// Not merely "the newest thread with a summary". Reopening a conversation from the
    /// archive would then show a note about one that happened after it — a recap of the
    /// future, presented as what the coach is carrying in. The ordering is by the
    /// predecessor's last message against this thread's start, which is the only pair of
    /// timestamps that says "that one had finished when this one began".
    ///
    /// A thread the caller cannot find a row for (the setup interview, which resolves its
    /// thread without reading the list) falls back to the newest written-up conversation
    /// that is not itself: there is nothing better to compare against, and the interview is
    /// always the newest conversation anyway.
    static func predecessor(of id: UUID?, in rows: [Row]) -> Row? {
        let written = inListOrder(rows).filter { $0.id != id && recapText($0) != nil }
        guard let mine = rows.first(where: { $0.id == id }) else { return written.first }
        return written.first { $0.lastMessageAt <= mine.startedAt }
    }

    // MARK: - What a thread row says

    /// The title on the list.
    ///
    /// A thread with no title has not been summarized yet, so this stands in rather than
    /// showing a blank row. "This conversation" and not an invented topic: the only thing
    /// the app knows about an unsummarized thread is that it exists.
    static func displayTitle(_ row: Row) -> String {
        guard let title = row.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return row.messageCount == 0 ? "Empty chat" : "This conversation"
        }
        return title
    }

    /// The two-line recap under the title.
    ///
    /// Three honest states, and the distinction matters: the thread the athlete is in right
    /// now is *not* waiting on anything, while an older one with no summary means the
    /// summarize round trip hasn't landed (or failed). Neither is allowed to read like a
    /// recap of what was said.
    static func recap(_ row: Row, isActive: Bool) -> String {
        if let summary = recapText(row) { return summary }
        if row.messageCount == 0 { return "Nothing said yet." }
        return isActive ? "Still going." : "Recap not written yet."
    }

    /// The change tags on a thread row, from the actions actually applied inside it.
    ///
    /// Built on `ChangeLedger` rather than re-reading `proposed_action` here: that file
    /// already decides which kind of change an action type is, and two places deciding that
    /// is how a tag ends up disagreeing with the ledger it links to. One tag per kind,
    /// in `Kind.allCases` order so the row reads the same way every time.
    ///
    /// A single change of a kind names itself ("Plan · Session changed"); several are
    /// counted, because three titles in one pill is not a summary.
    ///
    /// The ledger's default units are fine here: a tag says *what kind* of change happened
    /// and how many, never a distance or a pace, so nothing in it reads differently in km.
    static func tags(from records: [ChangeLedger.Record]) -> [Tag] {
        let entries = ChangeLedger.entries(from: records)
        return ChangeLedger.Kind.allCases.compactMap { kind in
            let matching = entries.filter { $0.kind == kind }
            guard let first = matching.first else { return nil }
            let detail = matching.count == 1 ? first.title : "\(matching.count) changes"
            return Tag(kind: kind, label: "\(kind.label) · \(detail)")
        }
    }

    // MARK: - Picking up from

    /// The note at the top of a thread: what the coach is carrying into it.
    ///
    /// Nil when there is nothing to carry — a first-ever conversation, with no previous
    /// recap and no memory. An empty "Picking up from" card would be worse than none: it
    /// would claim continuity the coach does not have.
    ///
    /// `previousDayLabel` is formatted by the caller ("Tue", "Oct 5"): the day a date reads
    /// as depends on the athlete's calendar and locale, which is exactly what a pure
    /// function must not reach for.
    static func pickingUpNote(
        previousSummary: String?,
        previousDayLabel: String?,
        memoryCount: Int
    ) -> String? {
        var parts: [String] = []
        if let summary = previousSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            if let day = previousDayLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
               !day.isEmpty {
                parts.append("\(day): \(summary)")
            } else {
                parts.append(summary)
            }
        }
        if memoryCount > 0 {
            parts.append(
                memoryCount == 1
                    ? "Coach is carrying 1 thing it knows about you."
                    : "Coach is carrying \(memoryCount) things it knows about you."
            )
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
