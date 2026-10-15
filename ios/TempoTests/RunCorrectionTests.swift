import XCTest
@testable import Tempo

/// Rule 3 for run corrections (#206): the coach reports what the athlete said, and code works
/// out the corrected run.
///
/// Until 2026-10-15 the coach prompt said "compute the FINAL corrected totals yourself" and
/// had the model estimate the heart rate of the stretch it added; `ChatStore.applyAmend`
/// wrote the result into `runs`. Those columns feed the load model, readiness and the
/// projection, and a model's arithmetic slip there doesn't crash anything. It just becomes a
/// plausible number in the training history. So the arithmetic moved into
/// `Engine/RunCorrection.swift`, and these pin it: the three ways a run gets corrected, the
/// inputs it must refuse rather than guess at, the coach's old totals cards it must still
/// read, and the card that shows the result before Confirm.
final class RunCorrectionTests: XCTestCase {

    private func action(_ json: String) throws -> ProposedAction {
        try JSONDecoder().decode(ProposedAction.self, from: Data(json.utf8))
    }

    private func rejection(_ body: () throws -> Any) -> RunCorrection.Rejection? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? RunCorrection.Rejection
        }
    }

    /// 6.0 mi in 50:00 at 148 bpm: Tuesday as the watch saw it.
    private let tuesday = RunCorrection.Recorded(distance_m: 9656, duration_s: 3000, avg_hr: 148)

    // MARK: - The three corrections

    /// "Forgot to restart the watch after the light: another 1.2 mi at 8:30."
    func testAddedSegmentIsAddedToBothDistanceAndTimeAtTheStatedPace() throws {
        let facts = RunCorrection.Facts(unit: .mi, addedDistance: 1.2, addedPace: "8:30")
        let out = try RunCorrection.amend(tuesday, with: facts, defaultUnit: .mi)

        XCTAssertEqual(out.distanceM, 11587, "9656 m + 1.2 × 1609.34 m, rounded once at the end")
        XCTAssertEqual(out.durationS, 3612, "50:00 + 1.2 × 8:30 = 1:00:12")
        XCTAssertEqual(out.avgPaceSec, 501, "the pace is code's too: 3612 s over 7.1998 mi")
        XCTAssertEqual(out.avgHR, 148, "never estimated: the recorded part's average stands")
        XCTAssertEqual(out.assumptions, [.heartRateFromRecordedPart], "and the card says so")
    }

    /// "The treadmill said 6.0, the watch only got 5.6."
    func testReplacedDistanceKeepsTheTimeAndTheHeartRate() throws {
        let run = RunCorrection.Recorded(distance_m: 9012, duration_s: 2940, avg_hr: 141)
        let out = try RunCorrection.amend(run, with: .init(unit: .mi, actualDistance: 6.0), defaultUnit: .mi)

        XCTAssertEqual(out.distanceM, 9656)
        XCTAssertEqual(out.durationS, 2940, "only the distance was wrong")
        XCTAssertEqual(out.avgHR, 141)
        XCTAssertEqual(out.avgPaceSec, 490, "8:45 becomes 8:10 because the distance grew, not the effort")
        XCTAssertEqual(out.assumptions, [], "nothing was assumed: he gave the number")
    }

    /// "The watch stopped 14 minutes early." No distance for the 14: it is counted at the
    /// run's own recorded pace, and the card says that was an assumption.
    func testEarlyStopExtendsTheRunAtItsRecordedPace() throws {
        let run = RunCorrection.Recorded(distance_m: 6437, duration_s: 2160, avg_hr: 150)   // 4.0 mi at 9:00
        let out = try RunCorrection.amend(run, with: .init(unit: .mi, addedTime: "14:00"), defaultUnit: .mi)

        XCTAssertEqual(out.durationS, 3000, "36:00 + 14:00")
        XCTAssertEqual(out.distanceM, 8940, "840 s at 2160 s / 6437 m is another 2503 m")
        XCTAssertEqual(out.avgPaceSec, 540, "same pace, longer run")
        XCTAssertEqual(out.assumptions, [.segmentAtRecordedPace, .heartRateFromRecordedPart])
    }

    /// "Stopped 14 minutes early, it was 5.5 in the end": the stated total wins, and nothing
    /// about the 14 minutes' distance needs assuming.
    func testEarlyStopWithAStatedTotalAssumesNoPace() throws {
        let run = RunCorrection.Recorded(distance_m: 6437, duration_s: 2160, avg_hr: 150)
        let facts = RunCorrection.Facts(unit: .mi, addedTime: "14:00", actualDistance: 5.5)
        let out = try RunCorrection.amend(run, with: facts, defaultUnit: .mi)

        XCTAssertEqual(out.distanceM, 8851)
        XCTAssertEqual(out.durationS, 3000)
        XCTAssertEqual(out.assumptions, [.heartRateFromRecordedPart])
    }

    func testKilometresAreKilometres() throws {
        let run = RunCorrection.Recorded(distance_m: 10000, duration_s: 3000, avg_hr: nil)
        let stated = try RunCorrection.amend(run, with: .init(unit: .km, addedDistance: 2, addedPace: "5:00"), defaultUnit: .mi)
        XCTAssertEqual(stated.distanceM, 12000)
        XCTAssertEqual(stated.durationS, 3600)
        XCTAssertNil(stated.avgHR, "no HR recorded, none invented")
        XCTAssertEqual(stated.assumptions, [], "nothing to label when there was no HR to begin with")

        // A card without a unit is in the athlete's own unit, not silently in miles.
        let unitless = try RunCorrection.amend(run, with: .init(addedDistance: 2, addedPace: "5:00"), defaultUnit: .km)
        XCTAssertEqual(unitless, stated)
    }

    func testAStatedHeartRateIsTheOnlyOneThatReplacesTheRecordedOne() throws {
        let out = try RunCorrection.amend(tuesday, with: .init(statedAvgHR: 152), defaultUnit: .mi)
        XCTAssertEqual(out.avgHR, 152)
        XCTAssertEqual(out.distanceM, tuesday.distance_m)
        XCTAssertEqual(out.durationS, tuesday.duration_s)
    }

    // MARK: - Refused, never guessed

    func testImpossibleInputsAreRejected() {
        let mi = Units.mi
        func amend(_ facts: RunCorrection.Facts) -> RunCorrection.Rejection? {
            rejection { try RunCorrection.amend(self.tuesday, with: facts, defaultUnit: mi) }
        }
        XCTAssertEqual(amend(.init(unit: .mi, addedDistance: -1.2, addedPace: "8:30")), .notPositive("added distance"))
        XCTAssertEqual(amend(.init(unit: .mi, addedDistance: 0, addedPace: "8:30")), .notPositive("added distance"))
        XCTAssertEqual(amend(.init(unit: .mi, actualDistance: 0)), .notPositive("distance"))
        XCTAssertEqual(amend(.init(addedTime: "0:00")), .notPositive("added time"))
        XCTAssertEqual(amend(.init(addedTime: "14")), .unreadableTime("added time"),
                       "a bare 14 is minutes or seconds; the wrong guess is a 60× error")
        XCTAssertEqual(amend(.init(unit: .mi, addedDistance: 10, addedTime: "10:00")), .implausiblePace,
                       "ten miles in ten minutes is a typo, not a run")
        XCTAssertEqual(amend(.init(unit: .mi, actualDistance: 30)), .implausiblePace,
                       "30 mi in 50:00 would skew every average it lands in")
        XCTAssertEqual(amend(.init(unit: .mi, addedDistance: 1, actualDistance: 7)),
                       .contradictory("both an added distance and a new total distance"))
        XCTAssertEqual(amend(.init(addedTime: "5:00", actualTime: "55:00")),
                       .contradictory("both added time and a new total time"))
        XCTAssertEqual(amend(.init(unit: .mi, addedDistance: 1, addedTime: "8:30", addedPace: "6:00")),
                       .contradictory("a distance, time and pace for the added stretch"))
        XCTAssertEqual(amend(.init(unit: .mi, addedPace: "8:30")),
                       .incomplete("a distance or a time for the added stretch, not just its pace"))
        XCTAssertEqual(amend(.init(statedAvgHR: 300)), .implausibleHeartRate)
        XCTAssertEqual(amend(.init()), .nothingStated)
    }

    func testARunWithNoRecordedPaceCannotLendItsPaceToTheExtraTime() {
        let empty = RunCorrection.Recorded(distance_m: 0, duration_s: 1200, avg_hr: nil)
        XCTAssertEqual(
            rejection { try RunCorrection.amend(empty, with: .init(addedTime: "14:00"), defaultUnit: .mi) },
            .incomplete("a distance or a pace for the added time (this run has no recorded pace)")
        )
    }

    func testEveryRejectionTellsTheAthleteWhatToDo() {
        let all: [RunCorrection.Rejection] = [
            .nothingStated, .notPositive("distance"), .unreadableTime("time"),
            .contradictory("x"), .incomplete("y"), .implausiblePace, .implausibleHeartRate,
        ]
        for r in all { XCTAssertFalse(r.message.isEmpty, "\(r)") }
    }

    // MARK: - A run that was never recorded

    func testLoggedRunTakesAnyTwoOfDistanceTimeAndPace() throws {
        let distanceTime = try RunCorrection.log(.init(unit: .mi, distance: 5, time: "42:30"), defaultUnit: .mi)
        XCTAssertEqual(distanceTime.distanceM, 8047)
        XCTAssertEqual(distanceTime.durationS, 2550)
        XCTAssertNil(distanceTime.avgHR, "no HR said, none estimated")

        let distancePace = try RunCorrection.log(.init(unit: .km, distance: 8, pace: "5:00"), defaultUnit: .mi)
        XCTAssertEqual(distancePace.distanceM, 8000)
        XCTAssertEqual(distancePace.durationS, 2400)

        let timePace = try RunCorrection.log(.init(unit: .mi, time: "40:00", pace: "8:00"), defaultUnit: .mi)
        XCTAssertEqual(timePace.distanceM, 8047)
        XCTAssertEqual(timePace.durationS, 2400)

        let allThree = try RunCorrection.log(.init(unit: .mi, distance: 5, time: "42:30", pace: "8:30", statedAvgHR: 152), defaultUnit: .mi)
        XCTAssertEqual(allThree.distanceM, 8047)
        XCTAssertEqual(allThree.avgHR, 152)
    }

    func testLoggedRunRefusesWhatItCannotCompute() {
        XCTAssertEqual(rejection { try RunCorrection.log(.init(unit: .mi, distance: 5), defaultUnit: .mi) },
                       .incomplete("two of distance, time and pace"))
        XCTAssertEqual(rejection { try RunCorrection.log(.init(unit: .mi, distance: 5, time: "42:30", pace: "7:00"), defaultUnit: .mi) },
                       .contradictory("a distance, time and pace"))
        XCTAssertEqual(rejection { try RunCorrection.log(.init(unit: .mi, distance: -5, time: "42:30"), defaultUnit: .mi) },
                       .notPositive("distance"))
    }

    // MARK: - The coach before #206 (totals)

    /// The deploy-order half: a card from the coach that is live today, or one persisted by
    /// it and confirmed after this ships, still applies, with the pace re-derived by code.
    func testATotalsCardFromTheCurrentCoachStillApplies() throws {
        let card = try action("""
        {"type":"amend_run","run_id":"8B0F1E22-0000-4000-8000-00000000ABCD",
         "distance_m":12874,"duration_s":4512,"avg_hr":141,
         "note":"Added the 2 unrecorded miles at the stated 10:00 pace.",
         "summary":"Correct Tue's run: 6.0 → 8.0 mi, 55:12 → 1:15:12, avg HR est. 141"}
        """)
        let run = RunCorrection.Recorded(distance_m: 9656, duration_s: 3312, avg_hr: 139)
        let out = try RunCorrection.amendment(proposed: card, to: run, units: .mi)
        XCTAssertEqual(out.distanceM, 12874)
        XCTAssertEqual(out.durationS, 4512)
        XCTAssertEqual(out.avgHR, 141)
        XCTAssertEqual(out.avgPaceSec, 564)

        let partial = try RunCorrection.amendment(
            proposed: try action(#"{"type":"amend_run","run_id":"x","distance_m":12875}"#), to: run, units: .mi)
        XCTAssertEqual(partial.durationS, 3312, "a total it didn't send stays as recorded")
        XCTAssertEqual(partial.avgHR, 139)

        let logged = try RunCorrection.loggedRun(
            proposed: try action(#"{"type":"add_run","start_time":"2025-09-02T12:30:00Z","distance_m":8047,"duration_s":2550}"#),
            units: .mi)
        XCTAssertEqual(logged.distanceM, 8047)
        XCTAssertEqual(logged.durationS, 2550)
    }

    func testATotalsCardIsValidatedToo() throws {
        let run = tuesday
        XCTAssertEqual(rejection {
            try RunCorrection.amendment(proposed: try self.action(#"{"type":"amend_run","run_id":"x","distance_m":0}"#), to: run, units: .mi)
        }, .notPositive("distance"))
        XCTAssertEqual(rejection {
            // A card with neither totals nor facts — what the new coach leaves of a run card
            // whose only numbers were the model's own. It used to mark the run corrected
            // and change nothing.
            try RunCorrection.amendment(proposed: try self.action(#"{"type":"amend_run","run_id":"x","note":"n"}"#), to: run, units: .mi)
        }, .nothingStated)
        XCTAssertEqual(rejection {
            try RunCorrection.loggedRun(proposed: try self.action(#"{"type":"add_run","start_time":"2025-09-02T12:30:00Z","distance_m":8047}"#), units: .mi)
        }, .incomplete("a distance and a time"))
    }

    func testFactsOutrankTotalsOnTheSameCard() throws {
        // A facts card after Confirm carries code's totals too (`stamping`). Re-reading it
        // must not take those totals as the instruction.
        let card = try action("""
        {"type":"amend_run","run_id":"x","unit":"mi","added_distance":1.2,"added_pace":"8:30",
         "distance_m":99999,"duration_s":1}
        """)
        let out = try RunCorrection.amendment(proposed: card, to: tuesday, units: .mi)
        XCTAssertEqual(out.distanceM, 11587)
        XCTAssertEqual(out.durationS, 3612)
    }

    // MARK: - After Confirm

    /// "What changed" reads totals off applied cards. A facts card carries none until Confirm
    /// stamps code's result on it, which is what keeps its ledger entry showing numbers.
    func testStampedCardShowsCodesNumbersInWhatChanged() throws {
        let runID = UUID()
        let card = try action("""
        {"type":"amend_run","run_id":"\(runID.uuidString)","unit":"mi","added_distance":1.2,"added_pace":"8:30",
         "summary":"Add 1.2 mi at 8:30/mi to Tuesday's run","note":"Forgot to restart after the light."}
        """)
        let outcome = try RunCorrection.amendment(proposed: card, to: tuesday, units: .mi)
        let stamped = RunCorrection.stamping(card, with: outcome)
        let entries = ChangeLedger.entries(from: [.init(messageID: UUID(), date: .now, text: "", action: stamped)])
        XCTAssertEqual(entries.first?.beforeAfter, "Distance 7.20 mi · Time 1:00:12 · Avg HR 148 bpm")
    }

    func testThePinnedBaseSurvivesStorage() throws {
        // A Retry after a landed write — even after a relaunch — must compute from the run
        // the first attempt saw, or "add 1.2 mi" adds it twice.
        var card = try action(#"{"type":"amend_run","run_id":"x","unit":"mi","added_distance":1.2,"added_pace":"8:30"}"#)
        card.based_on = tuesday
        let reheated = try JSONDecoder().decode(ProposedAction.self, from: JSONEncoder().encode(card))
        XCTAssertEqual(reheated.based_on, tuesday)
        XCTAssertEqual(reheated, card)
    }

    func testCorrectionNoteCarriesWhatCodeAssumed() throws {
        let run = RunCorrection.Recorded(distance_m: 6437, duration_s: 2160, avg_hr: 150)
        let out = try RunCorrection.amend(run, with: .init(addedTime: "14:00"), defaultUnit: .mi)
        XCTAssertEqual(
            RunCorrection.correctionNote("Watch stopped 14 minutes early.", outcome: out),
            "Watch stopped 14 minutes early. The added stretch is counted at this run's recorded pace. "
                + "Avg HR is the recorded part's; nothing measured the added time."
        )
    }

    // MARK: - The confirm card

    func testCardShowsTheComputedRunBeforeConfirm() throws {
        let card = try action(#"{"type":"amend_run","run_id":"x","unit":"mi","added_distance":1.2,"added_pace":"8:30"}"#)
        XCTAssertEqual(RunCorrection.cardPreview(for: card, run: tuesday, units: .mi), .computed(
            rows: [
                .init(label: "Distance", before: "6.00 mi", after: "7.20 mi"),
                .init(label: "Time", before: "50:00", after: "1:00:12"),
                .init(label: "Pace", before: "8:20 /mi", after: "8:21 /mi"),
                .init(label: "Avg HR", before: nil, after: "148 bpm"),
            ],
            notes: ["Avg HR is the recorded part's; nothing measured the added time."]
        ))
    }

    func testCardPreviewsAgainstThePinnedBaseOverTheLoadedRun() throws {
        // A failed card whose write landed: the loaded run already shows 7.20 mi. The card
        // must still show what a Retry writes — the same 7.20, not 8.40.
        var card = try action(#"{"type":"amend_run","run_id":"x","unit":"mi","added_distance":1.2,"added_pace":"8:30"}"#)
        card.based_on = tuesday
        let alreadyCorrected = RunCorrection.Recorded(distance_m: 11587, duration_s: 3612, avg_hr: 148)
        guard case .computed(let rows, _)? = RunCorrection.cardPreview(for: card, run: alreadyCorrected, units: .mi) else {
            return XCTFail("expected a computed preview")
        }
        XCTAssertEqual(rows.first, .init(label: "Distance", before: "6.00 mi", after: "7.20 mi"))
    }

    func testCardSaysWhyItCannotCompute() throws {
        let bad = try action(#"{"type":"amend_run","run_id":"x","unit":"mi","added_distance":-1}"#)
        XCTAssertEqual(RunCorrection.cardPreview(for: bad, run: tuesday, units: .mi),
                       .rejected(RunCorrection.Rejection.notPositive("added distance").message))

        let notLoaded = try action(#"{"type":"amend_run","run_id":"x","unit":"mi","added_distance":1}"#)
        XCTAssertEqual(RunCorrection.cardPreview(for: notLoaded, run: nil, units: .mi), .runNotLoaded)

        let plan = try action(#"{"type":"update_plan_settings","days_per_week":5}"#)
        XCTAssertNil(RunCorrection.cardPreview(for: plan, run: tuesday, units: .mi), "not a run card")
    }

    func testNewRunCardHasNoBefore() throws {
        let card = try action(#"{"type":"add_run","start_time":"2026-10-14T12:00:00Z","unit":"km","distance":8,"time":"40:00"}"#)
        XCTAssertEqual(RunCorrection.cardPreview(for: card, run: nil, units: .km), .computed(
            rows: [
                .init(label: "Distance", before: nil, after: "8.00 km"),
                .init(label: "Time", before: nil, after: "40:00"),
                .init(label: "Pace", before: nil, after: "5:00 /km"),
            ],
            notes: []
        ))
    }

    // MARK: - Clock strings

    func testClockStringsParseOnlyWhenUnambiguous() {
        XCTAssertEqual(RunCorrection.seconds(fromClock: "14:00"), 840)
        XCTAssertEqual(RunCorrection.seconds(fromClock: "8:30"), 510)
        XCTAssertEqual(RunCorrection.seconds(fromClock: " 8:30 "), 510)
        XCTAssertEqual(RunCorrection.seconds(fromClock: "1:05:30"), 3930)
        XCTAssertEqual(RunCorrection.seconds(fromClock: "75:00"), 4500, "minutes past the hour in m:ss are fine")
        for bad in ["14", "14 min", "8.5", "8:75", "1:75:00", "-1:00", "", ":30", "1:2:3:4"] {
            XCTAssertNil(RunCorrection.seconds(fromClock: bad), bad)
        }
    }
}
