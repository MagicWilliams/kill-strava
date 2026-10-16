import Foundation
import Supabase

/// The I/O half of coach threads and memory (#87): read `coach_threads` and `coach_memory`,
/// start a thread, touch one, and run the summarize round trip that gives a finished thread
/// its title and recap.
///
/// Every decision lives in `Engine/CoachThreads` — which thread is live, which are owed a
/// summary, what a row with no recap is allowed to say. Nothing here decides anything; it
/// reads rows, hands them over, and writes back what comes out.
///
/// Reads degrade rather than throw where the screen can still be honest about it, and throw
/// where it cannot: "you have never had a conversation" and "the server didn't answer" are
/// different screens, the same rule `ChangeLedgerService` follows.
@MainActor
enum CoachThreadService {

    enum Failure: Error { case noSession }

    // MARK: - Threads

    private struct ThreadRow: Decodable {
        let id: UUID
        let title: String?
        let summary: String?
        let started_at: Date
        let last_message_at: Date
    }

    /// Every conversation, newest activity first. Throws on an unreadable server.
    static func threads() async throws -> [CoachThreads.Row] {
        let rows: [ThreadRow] = try await Supa.client
            .from("coach_threads")
            .select("id,title,summary,started_at,last_message_at")
            .order("last_message_at", ascending: false)
            .order("id", ascending: false)   // a stable tie order, as in ChatHistory (#93)
            .limit(pageSize)
            .execute()
            .value
        return CoachThreads.inListOrder(rows.map {
            CoachThreads.Row(
                id: $0.id,
                title: $0.title,
                summary: $0.summary,
                startedAt: $0.started_at,
                lastMessageAt: $0.last_message_at
            )
        })
    }

    /// How many conversations the list reads. Generous: a thread is a few hundred bytes, and
    /// the archive is the point of having threads at all.
    static let pageSize = 100

    private struct ThreadInsert: Encodable {
        let id: String
        let user_id: String
        let started_at: String
        let last_message_at: String
    }

    /// Start a new conversation, returning its id.
    ///
    /// The id is minted here rather than left to the column default, for the same reason
    /// `ChatStore.append` mints a message id: the caller has to be able to scope the very
    /// next insert to this thread, and a round trip that lands but can't be read back would
    /// leave the athlete typing into a conversation the app can't name.
    static func create(now: Date = .now) async throws -> UUID {
        guard let uid = Supa.userID?.uuidString else { throw Failure.noSession }
        let id = UUID()
        let stamp = ISO8601DateFormatter().string(from: now)
        _ = try await Supa.client
            .from("coach_threads")
            .insert(ThreadInsert(id: id.uuidString, user_id: uid, started_at: stamp, last_message_at: stamp))
            .execute()
        return id
    }

    /// The thread a message sent now belongs to: the live one, or a fresh one.
    ///
    /// This is what the Coach tab opens into when nothing told it which thread to show —
    /// the onboarding interview, a widget tap, a deep link. `CoachThreads.active` decides
    /// whether the newest thread still counts as the current conversation.
    static func ensureThread(now: Date = .now) async throws -> UUID {
        let rows = try await threads()
        if let live = CoachThreads.active(in: rows, now: now) { return live.id }
        return try await create(now: now)
    }

    private struct TouchPatch: Encodable { let last_message_at: String }

    /// Mark a thread as alive, so it sorts to the top of the list and the idle clock
    /// restarts. Fire-and-forget: a message that landed and a timestamp that didn't is a
    /// mis-sorted row, not lost history, and making the athlete wait on it would put a
    /// second round trip in front of every message they send.
    static func touch(_ threadID: UUID, at date: Date = .now) {
        Task {
            _ = try? await Supa.client
                .from("coach_threads")
                .update(TouchPatch(last_message_at: ISO8601DateFormatter().string(from: date)))
                .eq("id", value: threadID.uuidString)
                .execute()
        }
    }

    // MARK: - What the coach changed, by thread

    private struct AppliedRow: Decodable {
        let id: UUID
        let thread_id: UUID?
        let content: String
        let created_at: Date
        let proposed_action: ProposedAction?
    }

    /// One applied change and the conversation it happened in.
    struct Applied {
        let threadID: UUID?
        let record: ChangeLedger.Record
    }

    /// Every change the coach has actually made, with its thread.
    ///
    /// The same rows "What changed" is built from (`action_state = 'applied'`, migration
    /// 0007) — read once here because Coach home needs them twice: as the change tags on
    /// each thread row, and as this week's count on the "What changed" row. Applied cards
    /// are a handful of rows even after a year of coaching, so one page is the whole set;
    /// `ChangeLedgerService` is the one that has to paginate, because it also has to be
    /// right in year three.
    static func applied() async throws -> [Applied] {
        let rows: [AppliedRow] = try await Supa.client
            .from("coach_messages")
            .select("id,thread_id,content,created_at,proposed_action")
            .eq("action_state", value: "applied")
            .order("created_at", ascending: false)
            .order("id", ascending: false)
            .limit(RunFetch.pageSize)
            .execute()
            .value
        return rows.compactMap { row in
            guard let action = row.proposed_action else { return nil }
            return Applied(
                threadID: row.thread_id,
                record: ChangeLedger.Record(
                    messageID: row.id, date: row.created_at, text: row.content, action: action
                )
            )
        }
    }

    /// The change tags for each thread. A change made before threads existed has no
    /// thread_id and belongs to no row, so it is skipped rather than bundled somewhere.
    static func tags(from applied: [Applied]) -> [UUID: [CoachThreads.Tag]] {
        var byThread: [UUID: [ChangeLedger.Record]] = [:]
        for change in applied {
            guard let threadID = change.threadID else { continue }
            byThread[threadID, default: []].append(change.record)
        }
        return byThread.mapValues(CoachThreads.tags(from:))
    }

    // MARK: - Summarizing a finished thread

    private struct TranscriptRow: Decodable {
        let role: String
        let content: String
        let created_at: Date
    }

    private struct SummaryPatch: Encodable { let title: String; let summary: String }

    /// Threads currently being written up, so two Coach-tab appearances can't spend two
    /// Anthropic requests on the same thread.
    private static var summarizing: Set<UUID> = []

    /// Write up every thread that is owed a recap, and return whether anything changed.
    ///
    /// Called when the Coach tab opens and when a new chat starts — the two moments a
    /// thread stops being the current conversation. Oldest first, one at a time: these are
    /// model round trips, and a backlog raced in parallel is how the onboarding interview
    /// once regenerated two plans at once.
    @discardableResult
    static func summarizePending(_ rows: [CoachThreads.Row], context: CoachContext, now: Date = .now) async -> Bool {
        var wrote = false
        for row in CoachThreads.awaitingSummary(rows, now: now) {
            if await summarize(row, context: context) { wrote = true }
        }
        return wrote
    }

    /// One thread's write-up: read its transcript, ask the coach for {title, summary}, store
    /// what comes back.
    ///
    /// Returns whether the thread now has a recap. False covers an unreachable server, a
    /// reply the parser wouldn't stand behind (`summary.ts` returns nothing rather than half
    /// a summary), and an empty thread — all of which leave the row untitled, which the list
    /// already knows how to show. Nothing is invented locally: a made-up recap is
    /// indistinguishable from a real one, and it would be fed to the coach as fact at the
    /// top of the next conversation.
    @discardableResult
    static func summarize(_ row: CoachThreads.Row, context: CoachContext) async -> Bool {
        guard !summarizing.contains(row.id) else { return false }
        summarizing.insert(row.id)
        defer { summarizing.remove(row.id) }

        // Newest first and flipped back here, never ascending plus a limit: that returns the
        // OLDEST page, and the write-up would describe the opening of the conversation it was
        // asked to summarize — #93, in a place where the only symptom would be a plausible
        // recap of the wrong half. A thread longer than the page is summarized from its
        // recent end, which is where its decisions are.
        let page: [TranscriptRow]
        do {
            page = try await Supa.client
                .from("coach_messages")
                .select("role,content,created_at")
                .eq("thread_id", value: row.id.uuidString)
                .order("created_at", ascending: false)
                .order("id", ascending: false)
                .limit(ChatHistory.pageSize)
                .execute()
                .value
        } catch {
            Telemetry.error("coach.thread_transcript_unreadable", error)
            return false
        }
        let transcript = ChatHistory.inReadingOrder(newestFirst: page, by: { $0.created_at })
        // An empty thread has nothing to write up, and the function would refuse it anyway.
        guard !transcript.isEmpty else { return false }

        struct Request: Encodable {
            let mode: String
            let messages: [ChatStore.WireMessage]
            let context: CoachContext
        }
        /// Both keys absent is the function saying it had nothing worth storing.
        struct Reply: Decodable { let title: String?; let summary: String? }

        let request = Request(
            mode: "summarize",
            messages: transcript.map {
                ChatStore.WireMessage(role: $0.role == "coach" ? "assistant" : "user", content: $0.content)
            },
            context: context
        )
        let reply: Reply
        do {
            reply = try await Supa.client.functions.invoke("coach", options: FunctionInvokeOptions(body: request))
        } catch {
            Telemetry.error("coach.thread_summarize_failed", error)
            return false
        }
        guard let title = reply.title, let summary = reply.summary, !title.isEmpty, !summary.isEmpty else {
            // Not an error: the parser refuses anything half-formed, and the thread is simply
            // offered to the next pass. Logged because a model that never returns a usable
            // write-up would otherwise look like a thread list that just doesn't fill in.
            Telemetry.warn("coach.thread_summary_unusable", "no title/summary in the reply")
            return false
        }
        do {
            _ = try await Supa.client
                .from("coach_threads")
                .update(SummaryPatch(title: title, summary: summary))
                .eq("id", value: row.id.uuidString)
                .execute()
            return true
        } catch {
            Telemetry.error("coach.thread_summary_unsaved", error)
            return false
        }
    }

    // MARK: - Memory

    private struct MemoryRow: Decodable { let fact: String }

    private struct MemoryInsert: Encodable {
        let id: String
        let user_id: String
        let fact: String
        let source_thread_id: String?
    }

    /// The facts the coach is currently carrying, newest first.
    ///
    /// Active only: a retired fact is history, kept so "why did the coach think that" has an
    /// answer, and must never be sent as something the coach still believes.
    static func memory() async throws -> [String] {
        let rows: [MemoryRow] = try await Supa.client
            .from("coach_memory")
            .select("fact")
            .is("retired_at", value: nil)
            .order("created_at", ascending: false)
            .limit(memoryLimit)
            .execute()
            .value
        return rows.map(\.fact)
    }

    /// How many facts ride in the athlete context.
    ///
    /// A ceiling, not a target. Memory is sent on every single turn, so it is the one part
    /// of the context that grows without anything pruning it; 60 facts is far more than a
    /// season of coaching produces and still a few hundred tokens. If it is ever reached,
    /// the newest are kept — and that is the signal to build retirement properly.
    static let memoryLimit = 60

    /// Record a fact the athlete has confirmed. Throws so the confirm card can fail
    /// honestly and offer a retry, like every other write in `ChatStore.apply`.
    static func remember(_ fact: String, threadID: UUID?) async throws {
        guard let uid = Supa.userID?.uuidString else { throw Failure.noSession }
        _ = try await Supa.client
            .from("coach_memory")
            .insert(MemoryInsert(
                id: UUID().uuidString,
                user_id: uid,
                fact: fact,
                source_thread_id: threadID?.uuidString
            ))
            .execute()
    }
}
