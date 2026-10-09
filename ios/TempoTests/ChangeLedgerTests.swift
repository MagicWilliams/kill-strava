import XCTest
@testable import Tempo

/// "What changed" (#88).
///
/// The coach had been changing real data — September run amendments, a race-week plan edit —
/// and the only record was a confirm card somewhere in the scroll. The ledger is built from
/// the rows that already exist (`coach_messages.proposed_action`, `action_state = 'applied'`),
/// so every rule about what an entry says lives here, pinned against the shapes `ChatStore.apply`
/// actually writes. Actions are decoded from JSON rather than constructed, because the jsonb
/// column is where they really come from.
final class ChangeLedgerTests: XCTestCase {

    // MARK: - Fixtures

    private func action(_ json: String) throws -> ProposedAction {
        try JSONDecoder().decode(ProposedAction.self, from: Data(json.utf8))
    }

    private let t0 = Date(timeIntervalSince1970: 1_757_000_000)   // 2025-09-04, a Thursday

    private func record(
        _ json: String,
        text: String = "",
        at offset: TimeInterval = 0,
        id: UUID = UUID()
    ) throws -> ChangeLedger.Record {
        ChangeLedger.Record(messageID: id, date: t0.addingTimeInterval(offset), text: text, action: try action(json))
    }

    private func only(_ records: [ChangeLedger.Record], recorded: [UUID: ChangeLedger.RecordedRun] = [:]) throws -> ChangeLedger.Entry {
        let entries = ChangeLedger.entries(from: records, recorded: recorded)
        XCTAssertEqual(entries.count, 1)
        return try XCTUnwrap(entries.first)
    }

    private var iso: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.firstWeekday = 2
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    // MARK: - One test per action type in ChatStore.apply

    func testAmendRunIsARunsEntryLinkedToTheRun() throws {
        // The September shape: the watch under-read a run and the coach corrected it.
        let runID = UUID()
        let entry = try only([record("""
            {"type":"amend_run","summary":"Log Tuesday's run as 8.0 mi","run_id":"\(runID.uuidString)",
             "distance_m":12875,"note":"GPS cut the corners on the river loop"}
            """, text: "That loop is a known GPS shortcut. I'll put it at 8.0.")])
        XCTAssertEqual(entry.kind, .runs)
        XCTAssertEqual(entry.title, "Run amended")
        XCTAssertEqual(entry.target, .run(runID))
        XCTAssertEqual(entry.beforeAfter, "Distance 8.00 mi")
        XCTAssertEqual(entry.why, "That loop is a known GPS shortcut. I'll put it at 8.0.")
    }

    func testAmendRunTakesItsBeforeFromTheRecordedSnapshotAndSaysSo() throws {
        let runID = UUID()
        let entry = try only([record("""
            {"type":"amend_run","run_id":"\(runID.uuidString)","distance_m":12875,"avg_hr":148}
            """)], recorded: [runID: .init(distance_m: 12231, duration_s: 3900, avg_hr: nil)])
        XCTAssertEqual(entry.changes, [
            .init(field: "Distance", before: "7.60 mi", after: "8.00 mi", beforeIsRecorded: true),
            // No recorded HR to compare against: the new value stands alone, nothing invented.
            .init(field: "Avg HR", before: nil, after: "148 bpm"),
        ])
        XCTAssertEqual(entry.beforeAfter, "Distance 7.60 mi (recorded) → 8.00 mi · Avg HR 148 bpm")
    }

    func testASecondAmendmentChainsFromTheFirstNotFromTheWatch() throws {
        // Two corrections to one run. The second one's "before" is what the first set it to;
        // showing the watch's number there would describe a change that never happened.
        let runID = UUID()
        let entries = ChangeLedger.entries(from: [
            try record(#"{"type":"amend_run","run_id":"\#(runID.uuidString)","distance_m":12875}"#, at: 0),
            try record(#"{"type":"amend_run","run_id":"\#(runID.uuidString)","distance_m":13200}"#, at: 600),
        ], recorded: [runID: .init(distance_m: 12231, duration_s: 3900, avg_hr: nil)])
        XCTAssertEqual(entries.map(\.beforeAfter), [
            "Distance 8.00 mi → 8.20 mi",
            "Distance 7.60 mi (recorded) → 8.00 mi",
        ])
    }

    func testAddRunLinksToTheRowItsProposalMinted() throws {
        let messageID = UUID()
        let entry = try only([record("""
            {"type":"add_run","summary":"Log a 5.0 mi treadmill run","start_time":"2025-09-02T12:30:00Z",
             "distance_m":8047,"duration_s":2700}
            """, id: messageID)])
        XCTAssertEqual(entry.kind, .runs)
        XCTAssertEqual(entry.title, "Run logged")
        XCTAssertEqual(entry.target, .loggedRun(externalID: ManualRunIdentity.externalID(forProposalIn: messageID)))
        XCTAssertEqual(entry.beforeAfter, "Date Sep 2 · Distance 5.00 mi · Time 45:00")
    }

    func testRiskToleranceIsYouAndChainsBetweenEntries() throws {
        let entries = ChangeLedger.entries(from: [
            try record(#"{"type":"set_risk_tolerance","level":"ambitious","risk_named":"injury risk"}"#, at: 0),
            try record(#"{"type":"set_risk_tolerance","level":"standard"}"#, at: 86_400),
        ])
        XCTAssertEqual(entries.map(\.kind), [.you, .you])
        XCTAssertEqual(entries.map(\.target), [.profile, .profile])
        XCTAssertEqual(entries.map(\.beforeAfter), ["Mode Ambitious → Standard", "Mode Ambitious"])
    }

    func testUpdateAthleteIsBody() throws {
        let entry = try only([record("""
            {"type":"update_athlete","max_hr":189,"injury_notes":"Left Achilles tight after long runs",
             "wants_strength":true}
            """)])
        XCTAssertEqual(entry.kind, .body)
        XCTAssertEqual(entry.target, .profile)
        XCTAssertEqual(entry.beforeAfter,
                       "Max HR 189 bpm · Injuries Left Achilles tight after long runs · Strength work Yes")
    }

    func testCreatePlanIsPlanAndFallsBackToItsRationaleForWhy() throws {
        // An extra proposal in one reply is stored with its summary as its text — no reasoning
        // there, so the plan's own rationale stands in.
        let entry = try only([record("""
            {"type":"create_plan","summary":"Build a sub-3:15 plan for Chicago","goal_time_s":11700,
             "race_name":"Chicago Marathon","race_date":"2026-10-11","rationale":"Your base supports 50 mi weeks."}
            """, text: "Build a sub-3:15 plan for Chicago")])
        XCTAssertEqual(entry.kind, .plan)
        XCTAssertEqual(entry.target, .plan)
        XCTAssertEqual(entry.beforeAfter, "Goal 3:15:00 · Race Chicago Marathon · Race day Oct 11")
        XCTAssertEqual(entry.why, "Your base supports 50 mi weeks.")
    }

    func testUpdatePlanSettingsIsPlan() throws {
        let entry = try only([record(#"{"type":"update_plan_settings","days_per_week":5,"long_run_day":6}"#)])
        XCTAssertEqual(entry.kind, .plan)
        XCTAssertEqual(entry.title, "Plan structure")
        XCTAssertEqual(entry.beforeAfter, "Days/week 5 · Long run Saturday")
    }

    func testUpdateSessionLinksToTheSessionAndNamesWhatHappened() throws {
        // The race-week shape: a session moved, and one skipped outright.
        let sessionID = UUID()
        let moved = try only([record(#"{"type":"update_session","session_id":"\#(sessionID.uuidString)","date":"2026-10-08"}"#)])
        XCTAssertEqual(moved.kind, .plan)
        XCTAssertEqual(moved.target, .session(sessionID))
        XCTAssertEqual(moved.title, "Session moved")
        XCTAssertEqual(moved.beforeAfter, "Day Oct 8")

        let skipped = try only([record(#"{"type":"update_session","session_id":"\#(UUID().uuidString)","session_status":"skipped"}"#)])
        XCTAssertEqual(skipped.title, "Session skipped")

        let reshaped = try only([record("""
            {"type":"update_session","session_id":"\(UUID().uuidString)","title":"Shakeout",
             "target_distance_m":4828,"target_pace_sec":540}
            """)])
        XCTAssertEqual(reshaped.title, "Session changed")
        XCTAssertEqual(reshaped.beforeAfter, "Title Shakeout · Distance 3.00 mi · Pace 9:00 /mi")
    }

    func testCompleteOnboardingHasNoFieldsButIsStillListed() throws {
        let entry = try only([record(#"{"type":"complete_onboarding","summary":"Finish setup"}"#)])
        XCTAssertEqual(entry.kind, .you)
        XCTAssertTrue(entry.changes.isEmpty)
        XCTAssertEqual(entry.summary, "Finish setup")
    }

    func testAnUnknownTypeIsStillListed() throws {
        // Applied by a newer build, read by an older one. "Every applied change" means every.
        let entry = try only([record(#"{"type":"remember","summary":"Remember: hates track"}"#)])
        XCTAssertEqual(entry.target, .unlinked)
        XCTAssertEqual(entry.summary, "Remember: hates track")
    }

    // MARK: - Once each, newest first

    func testEachMessageAppearsOnceNewestFirst() throws {
        let a = UUID(), b = UUID()
        let older = try record(#"{"type":"set_risk_tolerance","level":"standard"}"#, at: 0, id: a)
        let newer = try record(#"{"type":"update_plan_settings","days_per_week":6}"#, at: 3_600, id: b)
        // The same row delivered twice — a page boundary, a retried read.
        let entries = ChangeLedger.entries(from: [older, newer, older])
        XCTAssertEqual(entries.map(\.id), [b, a])
    }

    // MARK: - Why

    func testWhyIsNilRatherThanARepeatOfTheSummary() throws {
        let a = try action(#"{"type":"amend_run","summary":"Fix Tuesday","note":"Fix Tuesday"}"#)
        XCTAssertNil(ChangeLedger.why(text: "Fix Tuesday", action: a))
    }

    func testWhyKeepsTheFirstParagraphAndClipsAtASentence() {
        let long = String(repeating: "Easy miles build the engine. ", count: 12) + "\n\nConfirm below."
        let clipped = ChangeLedger.clip(long)
        XCTAssertLessThanOrEqual(clipped.count, ChangeLedger.whyLimit)
        XCTAssertTrue(clipped.hasSuffix("engine."))
        XCTAssertFalse(clipped.contains("Confirm below"))
        XCTAssertEqual(ChangeLedger.clip("Short.\n\nSecond paragraph."), "Short.")
    }

    // MARK: - This week / Earlier

    func testGroupsSplitAtTheStartOfTheISOWeek() throws {
        // t0 is a Thursday; Monday 00:00 UTC is three days earlier.
        let monday = iso.dateInterval(of: .weekOfYear, for: t0)!.start
        let inWeek = try record(#"{"type":"complete_onboarding"}"#, at: monday.timeIntervalSince(t0) + 1)
        let lastSunday = try record(#"{"type":"complete_onboarding"}"#, at: monday.timeIntervalSince(t0) - 1)
        let entries = ChangeLedger.entries(from: [inWeek, lastSunday])
        let groups = ChangeLedger.grouped(entries, now: t0, calendar: iso)
        XCTAssertEqual(groups.thisWeek.map(\.id), [inWeek.messageID])
        XCTAssertEqual(groups.earlier.map(\.id), [lastSunday.messageID])
    }

    func testWeekCountIncludesAConfirmTheDatabaseHasNotCaughtUpWith() throws {
        let landed = try record(#"{"type":"complete_onboarding"}"#)
        let entries = ChangeLedger.entries(from: [landed])
        let justConfirmed = UUID()
        XCTAssertEqual(ChangeLedger.countThisWeek(
            entries,
            alsoApplied: [(landed.messageID, t0), (justConfirmed, t0)],
            now: t0, calendar: iso
        ), 2, "the landed one once, the in-flight one once")
    }

    func testFilterByKind() throws {
        let entries = ChangeLedger.entries(from: [
            try record(#"{"type":"update_athlete","max_hr":189}"#),
            try record(#"{"type":"update_plan_settings","days_per_week":6}"#, at: 1),
        ])
        XCTAssertEqual(ChangeLedger.filtered(entries, kind: .body).map(\.kind), [.body])
        XCTAssertEqual(ChangeLedger.filtered(entries, kind: nil).count, 2)
    }

    // MARK: - Links

    func testRunLinksResolveOnlyToLiveRuns() {
        let live = RunSummary(id: UUID(), start: t0, distanceM: 12875, durationS: 3900)
        let messageID = UUID()
        let logged = RunSummary(id: UUID(), start: t0, distanceM: 8047, durationS: 2700,
                                source: ManualRunIdentity.source,
                                externalID: ManualRunIdentity.externalID(forProposalIn: messageID))
        let runs = [live, logged]
        XCTAssertEqual(ChangeLedger.run(for: .run(live.id), in: runs)?.id, live.id)
        XCTAssertEqual(ChangeLedger.run(
            for: .loggedRun(externalID: ManualRunIdentity.externalID(forProposalIn: messageID)), in: runs
        )?.id, logged.id)
        // Superseded as a duplicate (migration 0008): not in the live list, so no link.
        XCTAssertNil(ChangeLedger.run(for: .run(UUID()), in: runs))
    }
}
