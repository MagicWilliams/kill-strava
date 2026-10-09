import Foundation

/// "What changed": every write the coach actually made, as a ledger.
///
/// Until this existed, the only record of a change made through chat was its confirm card,
/// buried wherever in the scroll that conversation happened to sit. The race-week plan edit
/// and the September run amendments were real writes to real data with no place to see them
/// together — and a coach that can change your numbers has to be able to show its work.
///
/// No new storage. Every applied action already lives on the message that proposed it
/// (`coach_messages.proposed_action`, `action_state = 'applied'`, migration 0007). This file
/// turns those rows into entries; `Services/ChangeLedgerService` only reads them.
///
/// Rules, each pinned in `ChangeLedgerTests`:
///
///  1. **Once each.** A message id is one change, however many times a page boundary or a
///     retry hands it to us.
///  2. **Newest first.**
///  3. **A "before" is never invented.** The action carries only the new values. A before
///     comes from the previous ledger entry that set the same field on the same target, or —
///     for a run's first amendment — from the run's `original` snapshot, which is flagged as
///     "as recorded" because it is the watch's number, not necessarily the value the edit
///     replaced (a correction made before 0007 left no ledger row). With neither, the line
///     shows the new value alone.
///  4. **The why is the coach's own words** from the message that proposed the change.
///
/// Pure and deterministic: no clock, no locale, no network.
enum ChangeLedger {

    /// One applied row from `coach_messages`.
    struct Record: Equatable {
        let messageID: UUID
        /// The proposing message's `created_at`. Nothing stores the moment of the Confirm
        /// tap; in practice the two are minutes apart.
        let date: Date
        /// The coach's text on that message.
        let text: String
        let action: ProposedAction
    }

    /// A run's pre-correction snapshot (`runs.original`), written on its first correction.
    struct RecordedRun: Equatable, Decodable {
        let distance_m: Int?
        let duration_s: Int?
        let avg_hr: Int?
    }

    enum Kind: String, CaseIterable, Identifiable {
        case plan, runs, body, you
        var id: String { rawValue }
        var label: String {
            switch self {
            case .plan: return "Plan"
            case .runs: return "Runs"
            case .body: return "Body"
            case .you:  return "You"
            }
        }
    }

    /// What an entry links to.
    enum Target: Equatable {
        case run(UUID)
        /// A run the coach logged: its row id is minted by Postgres, but its identity is
        /// derived from the proposing message (`ManualRunIdentity`), so it is findable.
        case loggedRun(externalID: String)
        case session(UUID)
        case plan
        case profile
        case unlinked
    }

    struct Delta: Equatable {
        let field: String
        let before: String?
        let after: String
        /// `before` is the watch's original number, not a previous ledger value.
        var beforeIsRecorded = false

        var line: String {
            guard let before else { return "\(field) \(after)" }
            return "\(field) \(before)\(beforeIsRecorded ? " (recorded)" : "") → \(after)"
        }
    }

    struct Entry: Identifiable, Equatable {
        /// The proposing message's id — which is also the link back into chat.
        let id: UUID
        let date: Date
        let kind: Kind
        let title: String
        let summary: String
        let changes: [Delta]
        let why: String?
        let target: Target

        /// The before→after line, every field on one line.
        var beforeAfter: String { changes.map(\.line).joined(separator: " · ") }
    }

    // MARK: - Building

    /// Records → entries, newest first, each message once.
    ///
    /// - Parameter recorded: `runs.original` for amended runs, keyed by run id. A run with no
    ///   snapshot (never corrected, or deleted) is simply absent.
    static func entries(from records: [Record], recorded: [UUID: RecordedRun] = [:]) -> [Entry] {
        var seen = Set<UUID>()
        let unique = records.filter { seen.insert($0.messageID).inserted }

        // Chain befores in the order the changes happened. Ties keep input order.
        let chronological = unique.enumerated()
            .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element)

        var last: [String: String] = [:]   // "target|field" → the value it was last set to
        var built: [Entry] = []
        for record in chronological {
            let entry = entry(for: record, last: &last, recorded: recorded)
            built.append(entry)
        }
        return built.reversed()
    }

    private static func entry(
        for record: Record,
        last: inout [String: String],
        recorded: [UUID: RecordedRun]
    ) -> Entry {
        let a = record.action
        var changes: [Delta] = []

        /// Record a field the action set, with its before if one is honestly known.
        func set(_ key: String, _ field: String, _ after: String?, recordedBefore: String? = nil) {
            guard let after else { return }
            let slot = "\(key)|\(field)"
            if let previous = last[slot] {
                changes.append(Delta(field: field, before: previous, after: after))
            } else if let recordedBefore {
                changes.append(Delta(field: field, before: recordedBefore, after: after, beforeIsRecorded: true))
            } else {
                changes.append(Delta(field: field, before: nil, after: after))
            }
            last[slot] = after
        }

        let kind: Kind
        let title: String
        let target: Target

        switch a.type {
        case "amend_run":
            kind = .runs
            title = "Run amended"
            let runID = a.run_id.flatMap(UUID.init(uuidString:))
            target = runID.map(Target.run) ?? .unlinked
            let key = "run:\(a.run_id ?? "?")"
            let snapshot = runID.flatMap { recorded[$0] }
            set(key, "Distance", a.distance_m.map(Format.miles),
                recordedBefore: snapshot?.distance_m.map(Format.miles))
            set(key, "Time", a.duration_s.map(Format.clock),
                recordedBefore: snapshot?.duration_s.map(Format.clock))
            set(key, "Avg HR", a.avg_hr.map(Format.bpm),
                recordedBefore: snapshot?.avg_hr.map(Format.bpm))

        case "add_run":
            kind = .runs
            title = "Run logged"
            target = .loggedRun(externalID: ManualRunIdentity.externalID(forProposalIn: record.messageID))
            let key = "logged:\(record.messageID.uuidString)"
            set(key, "Date", a.start_time.flatMap(Format.isoDay))
            set(key, "Distance", a.distance_m.map(Format.miles))
            set(key, "Time", a.duration_s.map(Format.clock))
            set(key, "Avg HR", a.avg_hr.map(Format.bpm))

        case "set_risk_tolerance":
            kind = .you
            title = "Training mode"
            target = .profile
            set("profile", "Mode", a.level.map { $0.capitalized })

        case "update_athlete":
            kind = .body
            title = "Athlete details"
            target = .profile
            set("profile", "Max HR", a.max_hr.map(Format.bpm))
            set("profile", "Birthdate", a.birthdate.flatMap(Format.day))
            set("profile", "Injuries", a.injury_notes)
            set("profile", "Strength notes", a.strength_notes)
            set("profile", "Strength work", a.wants_strength.map { $0 ? "Yes" : "No" })

        case "create_plan":
            kind = .plan
            title = "Plan built"
            target = .plan
            set("goal", "Goal", a.goal_time_s.map(Format.clock))
            set("goal", "Race", a.race_name)
            set("goal", "Race day", a.race_date.flatMap(Format.day))

        case "update_plan_settings":
            kind = .plan
            title = "Plan structure"
            target = .plan
            set("settings", "Days/week", a.days_per_week.map { "\($0)" })
            set("settings", "Long run", a.long_run_day.flatMap(Format.weekday))

        case "update_session":
            kind = .plan
            target = a.session_id.flatMap(UUID.init(uuidString:)).map(Target.session) ?? .plan
            let key = "session:\(a.session_id ?? "?")"
            set(key, "Day", a.date.flatMap(Format.day))
            set(key, "Type", a.session_type.map { $0.capitalized })
            set(key, "Title", a.title)
            set(key, "Distance", a.target_distance_m.map(Format.miles))
            set(key, "Pace", a.target_pace_sec.map(Format.pace))
            set(key, "Detail", a.detail)
            set(key, "Status", a.session_status.map { $0.capitalized })
            if a.session_status == "skipped" {
                title = "Session skipped"
            } else if a.date != nil, changes.count == 1 {
                title = "Session moved"
            } else {
                title = "Session changed"
            }

        case "complete_onboarding":
            kind = .you
            title = "Setup finished"
            target = .profile

        default:
            // An action type this build doesn't know. It was applied, so it is listed —
            // rule 1 says every applied change, not every one we understand.
            kind = .you
            title = "Change"
            target = .unlinked
        }

        return Entry(
            id: record.messageID,
            date: record.date,
            kind: kind,
            title: title,
            summary: a.displaySummary,
            changes: changes,
            why: why(text: record.text, action: a),
            target: target
        )
    }

    // MARK: - Why

    /// Longest why shown on an entry; the full text is one tap away in chat.
    static let whyLimit = 240

    /// The coach's reasoning, from the message that proposed the change.
    ///
    /// A second proposal in one reply is stored with its own summary as its text (see
    /// `ChatStore.handleReply`), which says nothing about why. Then the action's own
    /// rationale or note stands in — and if that only repeats the summary, there is no why
    /// rather than a fake one.
    static func why(text: String, action: ProposedAction) -> String? {
        let summary = action.displaySummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [text, action.rationale, action.note].compactMap { $0 }
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != summary else { continue }
            return clip(trimmed)
        }
        return nil
    }

    /// First paragraph, then the last whole sentence that fits, then a word boundary.
    static func clip(_ text: String, limit: Int = whyLimit) -> String {
        let paragraph = text.components(separatedBy: "\n\n").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? text
        guard paragraph.count > limit else { return paragraph }
        let head = String(paragraph.prefix(limit))
        if let end = head.lastIndex(where: { ".!?".contains($0) }),
           head.distance(from: head.startIndex, to: end) >= limit / 3 {
            return String(head[...end])
        }
        let words = head.split(separator: " ").dropLast()
        return words.joined(separator: " ") + "…"
    }

    // MARK: - Grouping and filtering

    struct Groups: Equatable {
        var thisWeek: [Entry] = []
        var earlier: [Entry] = []
    }

    /// Split newest-first entries at the start of the current week. `calendar` decides where
    /// a week starts; the app passes `RunStore.cal` (ISO, Monday) so "this week" means the
    /// same seven days here as on Today.
    static func grouped(_ entries: [Entry], now: Date, calendar: Calendar) -> Groups {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else {
            return Groups(thisWeek: [], earlier: entries)
        }
        var groups = Groups()
        for entry in entries {
            if entry.date >= week.start { groups.thisWeek.append(entry) } else { groups.earlier.append(entry) }
        }
        return groups
    }

    /// This week's count for the Coach tab row.
    ///
    /// `alsoApplied` is what the open chat has just turned green. The card's state is written
    /// to the database in a fire-and-forget task, so a ledger read made the moment the card
    /// flips can come back one short; counting the union by message id means the row never
    /// lags the confirm the athlete just watched land, and never counts it twice.
    static func countThisWeek(
        _ entries: [Entry],
        alsoApplied: [(id: UUID, date: Date)] = [],
        now: Date,
        calendar: Calendar
    ) -> Int {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return 0 }
        var ids = Set(entries.filter { $0.date >= week.start }.map(\.id))
        for local in alsoApplied where local.date >= week.start { ids.insert(local.id) }
        return ids.count
    }

    /// `nil` is "All".
    static func filtered(_ entries: [Entry], kind: Kind?) -> [Entry] {
        guard let kind else { return entries }
        return entries.filter { $0.kind == kind }
    }

    // MARK: - Links

    /// The run an entry points at, if it is still in the log. A superseded or deleted run is
    /// absent from `runs`, and the link says so rather than opening the wrong one.
    static func run(for target: Target, in runs: [RunSummary]) -> RunSummary? {
        switch target {
        case .run(let id):
            return runs.first { $0.id == id }
        case .loggedRun(let externalID):
            return runs.first { $0.source == ManualRunIdentity.source && $0.externalID == externalID }
        default:
            return nil
        }
    }

    // MARK: - Formatting

    /// Fixed-locale formatting, so a ledger line reads the same in a test as on the phone.
    enum Format {
        static func miles(_ meters: Int) -> String {
            String(format: "%.2f mi", Double(meters) / 1609.34)
        }

        static func clock(_ seconds: Int) -> String {
            seconds >= 3600
                ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
                : String(format: "%d:%02d", seconds / 60, seconds % 60)
        }

        static func pace(_ secPerMile: Int) -> String {
            String(format: "%d:%02d /mi", secPerMile / 60, secPerMile % 60)
        }

        static func bpm(_ value: Int) -> String { "\(value) bpm" }

        private static let parse: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = Calendar(identifier: .gregorian)
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()

        private static let show: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = Calendar(identifier: .gregorian)
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "MMM d"
            return f
        }()

        /// `yyyy-MM-dd` → `Sep 14`. Not a date we can read is shown as written.
        static func day(_ iso: String) -> String? {
            parse.date(from: String(iso.prefix(10))).map(show.string(from:)) ?? iso
        }

        /// An ISO timestamp's calendar day as the coach wrote it. Taking the leading
        /// `yyyy-MM-dd` rather than converting zones keeps "the run on the 14th" the 14th.
        static func isoDay(_ timestamp: String) -> String? { day(timestamp) }

        /// `0` = Sunday, matching `profiles.long_run_day`.
        static func weekday(_ index: Int) -> String? {
            let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            return names.indices.contains(index) ? names[index] : nil
        }
    }
}
