import XCTest
@testable import Tempo

/// Confirming a plan card read backwards: "Plan is live: 16 weeks…" appeared *above* the
/// "Confirmed — …" turn that caused it, because `invokePlanEngine` appended its own narration
/// from inside the switch that runs before the confirmation is recorded (#39).
///
/// The fix is structural — the line is returned now, and only `ChatStore.apply` decides where
/// it goes — so no unit test can hold the ordering itself; that lives in an `@MainActor` store
/// wrapped around Supabase. What these hold is the wording that moved during the extraction.
/// It is the coach's voice announcing a plan the athlete just committed to, and every way it
/// breaks is quiet: a stray underscore, a volume range with one end missing, "0 weeks"
/// announced as if it were a plan.
final class PlanNarrationTests: XCTestCase {

    private func result(
        weeks: Int? = 16,
        archetype: String? = "base_build",
        rationale: String? = nil,
        projectedFinishSeconds: Int? = nil,
        startWeeklyMiles: Double? = nil,
        peakWeeklyMiles: Double? = nil
    ) -> PlanNarration.PlanResult {
        PlanNarration.PlanResult(
            weeks: weeks,
            archetype: archetype,
            rationale: rationale,
            projectedFinishSeconds: projectedFinishSeconds,
            startWeeklyMiles: startWeeklyMiles,
            peakWeeklyMiles: peakWeeklyMiles
        )
    }

    /// The whole line, as the athlete reads it after tapping Confirm.
    func testFullResultReadsAsOneSentenceRun() {
        let line = PlanNarration.planIsLive(result(
            rationale: "You're rebuilding, so the first four weeks stay easy.",
            projectedFinishSeconds: 11_700,
            startWeeklyMiles: 22.4,
            peakWeeklyMiles: 45.6
        ))
        XCTAssertEqual(line, "Plan is live: 16 weeks (base build). Volume runs 22 → 46 mi/wk. "
                           + "Projection today: 3:15:00. You're rebuilding, so the first four weeks stay easy.")
    }

    /// The archetype comes off the wire as a snake_case identifier. It is being spoken, not
    /// logged.
    func testArchetypeIsSpokenNotPrinted() {
        XCTAssertEqual(PlanNarration.planIsLive(result(archetype: "sharpen_and_taper")),
                       "Plan is live: 16 weeks (sharpen and taper).")
    }

    /// The `plan` function does not guarantee an archetype. A blank pair of parentheses would
    /// look like a bug in the sentence; "custom" is true and reads.
    func testMissingArchetypeFallsBackToCustom() {
        XCTAssertEqual(PlanNarration.planIsLive(result(archetype: nil)),
                       "Plan is live: 16 weeks (custom).")
    }

    /// No week count means no plan came back. Announcing one anyway is the failure that would
    /// leave the athlete believing a write landed when it didn't.
    func testNoWeekCountSaysNothingAtAll() {
        XCTAssertNil(PlanNarration.planIsLive(result(weeks: nil, projectedFinishSeconds: 11_700)))
    }

    /// A range needs both ends. One of them alone is not a smaller sentence, it is a wrong one.
    func testVolumeNeedsBothEndsOfTheRange() {
        XCTAssertEqual(PlanNarration.planIsLive(result(startWeeklyMiles: 22.4)),
                       "Plan is live: 16 weeks (base build).")
        XCTAssertEqual(PlanNarration.planIsLive(result(peakWeeklyMiles: 45.6)),
                       "Plan is live: 16 weeks (base build).")
    }

    /// Mileage is whole numbers in conversation — nobody says "runs 22.4 to 45.6 mi/wk".
    func testMileageIsRoundedForSpeech() {
        XCTAssertEqual(PlanNarration.planIsLive(result(startWeeklyMiles: 19.5, peakWeeklyMiles: 50.4)),
                       "Plan is live: 16 weeks (base build). Volume runs 20 → 50 mi/wk.")
    }

    /// The projection is the number the athlete actually came for, and it is optional on the
    /// wire — a plan with no projection still gets announced, just without it.
    func testProjectionIsIncludedWhenPresentAndSkippedWhenNot() {
        XCTAssertEqual(PlanNarration.planIsLive(result(projectedFinishSeconds: 10_845)),
                       "Plan is live: 16 weeks (base build). Projection today: 3:00:45.")
        XCTAssertEqual(PlanNarration.planIsLive(result(projectedFinishSeconds: nil)),
                       "Plan is live: 16 weeks (base build).")
    }

    /// The rationale is the coach's reasoning and always goes last, after the numbers it
    /// explains.
    func testRationaleClosesTheLine() {
        let line = PlanNarration.planIsLive(result(rationale: "Ten weeks is tight for this goal."))
        XCTAssertEqual(line, "Plan is live: 16 weeks (base build). Ten weeks is tight for this goal.")
    }

    /// Saving structure with no plan behind it still has to say something: the alternative is a
    /// Confirm that writes to `profiles` and then appears to have done nothing.
    func testSettingsWithoutAPlanStillSayThatTheyLanded() {
        XCTAssertFalse(PlanNarration.settingsSavedWithoutPlan.isEmpty)
        XCTAssertTrue(PlanNarration.settingsSavedWithoutPlan.hasPrefix("Settings saved."))
    }
}
