import XCTest
@testable import Tempo

/// The recorder's save path (#122): a run recorded in Tempo writes its own `runs` row the
/// moment Apple Health has it, instead of waiting for the next HealthKit sync.
///
/// That shortcut is only safe if the row is *the row the sync would have written*. The sync
/// dedupes on `(user_id, source, external_id)`; a recorder row that differs in any of the three
/// is a stranger to it, and the run gets inserted twice — the 2026-07-10 week that read 31
/// miles instead of 15, except this time Tempo would be doing it to itself, once per run.
/// And a row that agreed on the key but not the numbers would give one run two different
/// paces depending on which path happened to write it first. Nothing on screen would say so.
final class RecordedRunSaveTests: XCTestCase {

    private let user = "5F0B1C2D-3E4F-4A5B-8C6D-7E8F9A0B1C2D"
    private let uuid = UUID(uuidString: "A1B2C3D4-E5F6-4789-ABCD-EF0123456789")!
    /// Sunday 11 Oct 2026, 13:30 UTC — the Chicago start that lost its recording to Strava.
    private let start = Date(timeIntervalSince1970: 1_791_725_400)

    /// A 5-mile run: 8,046.72 m, 42 min moving, 45 min on the wall clock, HR 151.5.
    private func workout(
        uuid: UUID? = nil,
        offset: TimeInterval = 0,
        meters: Double? = 8_046.72,
        movingS: TimeInterval = 2_520.9,
        elapsedS: TimeInterval = 2_700,
        avgHR: Double? = 151.5,
        indoor: Bool = false
    ) -> WorkoutRow.Workout {
        WorkoutRow.Workout(
            uuid: uuid ?? self.uuid,
            start: start.addingTimeInterval(offset),
            end: start.addingTimeInterval(offset + elapsedS),
            distanceM: meters,
            movingS: movingS,
            avgHR: avgHR,
            indoor: indoor
        )
    }

    /// What `HealthService` ingest writes for a batch of workouts it has never seen:
    /// `fetchSummaries` (map, then drop blips), then `sync` (dedupe, then map to inserts).
    /// Spelled out step by step so this test fails if the recorder path stops composing the
    /// same steps.
    private func ingestRows(_ workouts: [WorkoutRow.Workout], existing: [RunSummary] = []) -> [RunInsert] {
        let summaries = workouts.map(WorkoutRow.summary).filter(WorkoutRow.isRun)
        let kept = RunDedupe.reconcile(candidates: summaries, existing: existing).inserts
        return kept.map { WorkoutRow.insert($0, userID: user) }
    }

    /// The row as the archive read hands it back — a database id, the workout uuid as text.
    private func stored(_ row: RunInsert, id: UUID = UUID()) -> RunSummary {
        RunSummary(id: id, start: row.start_time, distanceM: row.distance_m,
                   durationS: row.duration_s, elapsedS: row.elapsed_duration_s, avgHR: row.avg_hr,
                   source: row.source, externalID: row.external_id)
    }

    // MARK: - The recorder writes the ingest row

    func testRecorderRowEqualsTheRowIngestWritesForTheSameWorkout() {
        let cases: [(String, WorkoutRow.Workout)] = [
            ("outdoor, with HR", workout()),
            ("treadmill, no HR, no stops", workout(movingS: 1_800, elapsedS: 1_800, avgHR: nil, indoor: true)),
            ("long stop at a light", workout(movingS: 3_000.4, elapsedS: 3_600)),
            ("HR exactly between two integers", workout(avgHR: 148.5)),
            ("barely a run", workout(meters: 201)),
        ]
        for (name, w) in cases {
            let ingest = ingestRows([w])
            XCTAssertEqual(ingest.count, 1, name)
            XCTAssertEqual(RecordedRunSave.decide(w, nearby: [], userID: user), .insert(ingest[0]), name)
        }
    }

    func testTheRowFieldByField() {
        // Pinned literally as well, so a change to the shared mapping shows up here as a
        // number on the run that moved — not only as two paths that still agree.
        guard case .insert(let row) = RecordedRunSave.decide(workout(), nearby: [], userID: user) else {
            return XCTFail("a new 5-mile run must be written")
        }
        XCTAssertEqual(row.user_id, user)
        XCTAssertEqual(row.source, "healthkit")
        XCTAssertEqual(row.external_id, "A1B2C3D4-E5F6-4789-ABCD-EF0123456789")
        XCTAssertEqual(row.start_time, start)
        XCTAssertEqual(row.distance_m, 8_046, "meters truncate, as ingest always has")
        XCTAssertEqual(row.duration_s, 2_520, "moving time, truncated")
        XCTAssertEqual(row.elapsed_duration_s, 2_700, "wall clock, start to end")
        XCTAssertEqual(row.avg_pace_sec, 504, "pace over moving time: 2520 s / 4.9996 mi")
        XCTAssertEqual(row.avg_hr, 152, "151.5 rounds half away from zero")
    }

    func testExternalIDIsTheUppercaseUUIDEveryStoredRowUses() {
        // The unique key compares text. 2,000+ rows carry `uuidString` — uppercase. A
        // lowercase id here would not collide with the sync's row; it would sit beside it.
        guard case .insert(let row) = RecordedRunSave.decide(workout(), nearby: [], userID: user) else {
            return XCTFail()
        }
        XCTAssertEqual(row.external_id, uuid.uuidString)
        XCTAssertNotEqual(row.external_id, uuid.uuidString.lowercased())
    }

    func testIndoorDoesNotChangeTheRow() {
        // `runs` has no column for it yet: a treadmill run and the same numbers outdoors are
        // the same row, exactly as ingest writes them.
        XCTAssertEqual(RecordedRunSave.decide(workout(indoor: true), nearby: [], userID: user),
                       RecordedRunSave.decide(workout(indoor: false), nearby: [], userID: user))
    }

    // MARK: - The next sync sees it as already stored

    func testTheNextSyncDropsTheRecordedRunAsAlreadyStored() {
        guard case .insert(let row) = RecordedRunSave.decide(workout(), nearby: [], userID: user) else {
            return XCTFail()
        }
        // Later, the sync reads the very same workout back out of Health.
        let fromHealth = [workout()].map(WorkoutRow.summary).filter(WorkoutRow.isRun)
        let pass = RunDedupe.reconcile(candidates: fromHealth, existing: [stored(row)])

        XCTAssertTrue(pass.inserts.isEmpty, "the recorded run must not be written a second time")
        XCTAssertEqual(pass.droppedAlreadyStored, 1)
        XCTAssertEqual(pass.droppedUnknownUUID, 0,
                       "a recorded run must not read as a Garmin re-export and fire that alarm")
        XCTAssertTrue(pass.elapsedPatches.isEmpty)
        XCTAssertTrue(pass.suspectedElapsedStored.isEmpty)
    }

    // MARK: - When a row is already there

    func testSyncGotThereFirst() {
        // The refresh ran between the Health save and the row write, or an earlier attempt
        // landed and only its answer was lost. Nothing to write; the journal goes on that row.
        let rowID = UUID()
        let existing = stored(ingestRows([workout()])[0], id: rowID)
        XCTAssertEqual(RecordedRunSave.decide(workout(), nearby: [existing], userID: user),
                       .alreadyStored(rowID: rowID))
    }

    func testAGarminCopyOfTheSameOutingIsNotWrittenTwice() {
        // A watch on the wrist recorded the same run and its copy synced first: a different
        // uuid, starting 40 s earlier. The sync would drop the phone's workout as the same run;
        // so does the recorder, and the journal attaches to the run that is there.
        let garminID = UUID()
        let garmin = stored(ingestRows([workout(uuid: UUID(), offset: -40, meters: 8_100)])[0], id: garminID)
        XCTAssertEqual(RecordedRunSave.decide(workout(), nearby: [garmin], userID: user),
                       .sameRunAs(rowID: garminID))
        XCTAssertTrue(ingestRows([workout()], existing: [garmin]).isEmpty,
                      "and that is exactly what ingest would do")
    }

    func testARunStartingAWindowAwayIsItsOwnRun() {
        // Two runs five minutes apart are two runs — the window is exclusive at its edge,
        // same as the sync's.
        let earlier = stored(ingestRows([workout(uuid: UUID(), offset: -RunDedupe.windowSeconds)])[0])
        guard case .insert = RecordedRunSave.decide(workout(), nearby: [earlier], userID: user) else {
            return XCTFail("a run 300 s away is not a duplicate")
        }
    }

    func testTheNearbyReadCoversTheWholeDedupeWindow() {
        let range = RecordedRunSave.nearbyRange(for: workout())
        XCTAssertEqual(range.lowerBound, start.addingTimeInterval(-RunDedupe.windowSeconds))
        XCTAssertEqual(range.upperBound, start.addingTimeInterval(RunDedupe.windowSeconds))
    }

    // MARK: - Too short to be a run

    func testABlipIsNeverWritten() {
        // Ingest has always dropped ≤ 200 m as a GPS blip or an accidental start. A recorder
        // row for one would be a row the sync would never have written.
        for meters in [nil, 0, 150, 200] as [Double?] {
            XCTAssertEqual(RecordedRunSave.decide(workout(meters: meters), nearby: [], userID: user),
                           .tooShort, "\(String(describing: meters)) m")
            XCTAssertTrue(ingestRows([workout(meters: meters)]).isEmpty)
        }
    }

    // MARK: - The retry queue

    private func pending(_ journal: RunJournalEntry, uuid: UUID? = nil) -> RecordedRunSave.Pending {
        RecordedRunSave.Pending(workout: workout(uuid: uuid), journal: journal,
                                photoJPEG: Data([0xFF, 0xD8, 0xFF]), queuedAt: start)
    }

    func testSavingTheSameWorkoutTwiceQueuesOneWriteWithTheNewerJournal() {
        let first = pending(RunJournalEntry(rpe: 6))
        let second = pending(RunJournalEntry(rpe: 8, notes: "legs came back at 3"))
        let queue = RecordedRunSave.enqueue(second, into: RecordedRunSave.enqueue(first, into: []))
        XCTAssertEqual(queue, [second])
    }

    func testDifferentRunsQueueSideBySideAndLeaveOneAtATime() {
        let a = pending(RunJournalEntry(rpe: 5))
        let otherID = UUID()
        let b = pending(RunJournalEntry(rpe: 7), uuid: otherID)
        let queue = RecordedRunSave.enqueue(b, into: RecordedRunSave.enqueue(a, into: []))
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(RecordedRunSave.removing(otherID, from: queue), [a])
    }

    func testAQueuedRunSurvivesARelaunch() throws {
        // The queue is the only copy of the journal until a row exists. Everything the athlete
        // said has to come back off disk intact.
        let entry = RunJournalEntry(rpe: 9, feelTags: ["heavy legs", "windy"], notes: "Mile 20 hurt.",
                                    title: "Chicago", photoPath: nil, shoeID: UUID())
        let original = pending(entry)
        let data = try JSONEncoder().encode([original])
        XCTAssertEqual(try JSONDecoder().decode([RecordedRunSave.Pending].self, from: data), [original])
    }

    // MARK: - A treadmill run corrected to its console (#116)

    /// 5.00 mi on the console, 4.71 on the phone, 40 minutes on the belt: the workout as
    /// Health hands it back once the recorder has written the console's curve into it. Its
    /// samples add up to a hair under the console in floating point.
    private func corrected(console: Double = 8_046.7, estimate: Double = 7_580.0) -> WorkoutRow.Workout {
        var w = workout(meters: console - 1e-9, movingS: 2_400, elapsedS: 2_400, avgHR: nil, indoor: true)
        w.correction = WorkoutRow.Workout.Correction(
            consoleM: console, estimateM: estimate,
            note: "Treadmill console: 5.00 mi (phone estimated 4.71 mi)")
        return w
    }

    func testACorrectedTreadmillRunIsWrittenAsAnEditedRun() throws {
        guard case .insert(let row) = RecordedRunSave.decide(corrected(), nearby: [], userID: user) else {
            return XCTFail("a new treadmill run must be written")
        }
        XCTAssertEqual(row.distance_m, 8_047, "the console's figure to the metre, not the samples' float sum truncated")
        XCTAssertEqual(row.avg_pace_sec, 479, "pace from the console: 2400 s / 5.0002 mi, truncated")
        XCTAssertEqual(row.corrected, true)
        XCTAssertEqual(row.correction_note, "Treadmill console: 5.00 mi (phone estimated 4.71 mi)")
        // `original` is what the phone counted — the snapshot a coach amendment would keep.
        XCTAssertEqual(row.original, RunInsert.Original(distance_m: 7_580, duration_s: 2_400, avg_hr: nil,
                                                        avg_pace_sec: 509))
    }

    /// Everything that is not a console correction is written exactly as before, down to the
    /// JSON keys. The sync's bulk upsert sends one key set for every row; a row that grew
    /// `corrected: false` or `original: null` would change what every insert sends.
    func testAnUncorrectedRowSendsTheKeysItAlwaysHas() throws {
        guard case .insert(let row) = RecordedRunSave.decide(workout(indoor: true), nearby: [], userID: user) else {
            return XCTFail()
        }
        XCTAssertNil(row.corrected)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["user_id", "source", "external_id", "start_time", "distance_m",
                                         "duration_s", "elapsed_duration_s", "avg_pace_sec", "avg_hr"])
        let fixed = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            WorkoutRow.corrected(row, by: corrected()))) as? [String: Any])
        XCTAssertTrue(Set(fixed.keys).isSuperset(of: ["corrected", "correction_note", "original"]))
    }

    /// Saved with no signal in a basement gym: by the time the queued retry runs, the sync
    /// has written the row from Health, unmarked. The retry marks it.
    func testARowTheSyncWroteFirstIsMarkedCorrected() throws {
        let w = corrected()
        let existing = stored(ingestRows([w])[0])
        XCTAssertEqual(RecordedRunSave.decide(w, nearby: [existing], userID: user), .alreadyStored(rowID: existing.id))
        let patch = try XCTUnwrap(RecordedRunSave.correctionPatch(for: w))
        XCTAssertEqual(patch.corrected, true)
        XCTAssertEqual(patch.distance_m, 8_047)
        XCTAssertEqual(patch.correction_note, w.correction?.note)
        XCTAssertEqual(patch.original.distance_m, 7_580)
        XCTAssertNil(RecordedRunSave.correctionPatch(for: workout()), "nothing to add to an uncorrected run")
    }

    /// A run queued before this build has no correction in its JSON, and still comes back.
    func testAQueuedRunFromBeforeCorrectionsStillDecodes() throws {
        let old = pending(RunJournalEntry(rpe: 4))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        var workoutJSON = try XCTUnwrap(json["workout"] as? [String: Any])
        workoutJSON["correction"] = nil
        json["workout"] = workoutJSON
        let decoded = try JSONDecoder().decode(RecordedRunSave.Pending.self,
                                               from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, old)

        let queued = RecordedRunSave.Pending(workout: corrected(), journal: RunJournalEntry(), photoJPEG: nil, queuedAt: start)
        XCTAssertEqual(try JSONDecoder().decode(RecordedRunSave.Pending.self, from: JSONEncoder().encode(queued)), queued,
                       "and a queued correction survives a relaunch")
    }

    func testOnlyANotNowStaysQueued() {
        // No answer at all is the dead spot at the end of a run — the case the queue is for.
        for status in [nil, 408, 429, 500, 503] as [Int?] {
            XCTAssertTrue(RecordedRunSave.keepsAfterFailure(statusCode: status), "\(String(describing: status))")
        }
        // A refusal will still be a refusal next launch. The run is in Health either way.
        for status in [400, 401, 403, 404, 409] {
            XCTAssertFalse(RecordedRunSave.keepsAfterFailure(statusCode: status), "\(status)")
        }
    }
}
