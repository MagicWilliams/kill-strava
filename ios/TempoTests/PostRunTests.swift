import XCTest
@testable import Tempo

/// Pins the decisions on the post-run save screen (#129).
///
/// Chicago, 11 Oct 2026: the marathon was lost to a recorder that stopped. The recorder is
/// built so that can't happen again; this screen is the last stretch of that road, between
/// the clock stopping and the run being in Health, and its failures are quieter. A Save that
/// waits on a question he skipped. A shoe default that loads a second late and overwrites the
/// "None" he tapped. A test run under 200 m that saves "successfully" onto a Today with no run
/// on it. A pace on this screen that disagrees by a second with the same run on Today. Each
/// test below is one of those.
final class PostRunTests: XCTestCase {

    private var chicago: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }

    /// Tuesday 13 Oct 2026, two days after the marathon, at `hour`:`minute` in Chicago.
    private func tuesday(_ hour: Int, _ minute: Int = 0) -> Date {
        chicago.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: hour, minute: minute))!
    }

    private func session(_ type: String) -> RecorderState.SessionTarget {
        RecorderState.SessionTarget(sessionID: UUID(), type: type, title: "Marathon-pace blocks",
                                    distanceM: 9_656, paceSecPerMile: 465)
    }

    // MARK: - Save is always one tap

    /// He finishes, taps Save, and has answered nothing. That is a valid journal: no effort,
    /// no feel, no notes — and a title and shoes, from the defaults, because he left those
    /// alone rather than clearing them.
    func testSavingWithNothingFilledInIsAValidJournal() {
        let shoe = UUID()
        let entry = PostRun.journal(PostRun.Draft(), defaultTitle: "Tuesday tempo", defaultShoeID: shoe)
        XCTAssertNil(entry.rpe)
        XCTAssertEqual(entry.feelTags, [])
        XCTAssertNil(entry.notes)
        XCTAssertEqual(entry.title, "Tuesday tempo")
        XCTAssertEqual(entry.shoeID, shoe)
        XCTAssertNil(entry.photoPath, "the photo travels separately; its key is written once it lands")
    }

    func testWhatHeWroteIsWhatIsSaved() {
        let shoe = UUID()
        var draft = PostRun.Draft()
        draft.rpe = 8
        draft.feelTags = ["heavy legs", "windy"]
        draft.notes = "  Lakefront headwind the whole way back.\n"
        draft.title = "Headwind tempo"
        draft.shoe = .chosen(shoe)
        let entry = PostRun.journal(draft, defaultTitle: "Tuesday tempo", defaultShoeID: UUID())
        XCTAssertEqual(entry, RunJournalEntry(rpe: 8, feelTags: ["heavy legs", "windy"],
                                              notes: "Lakefront headwind the whole way back.",
                                              title: "Headwind tempo", photoPath: nil, shoeID: shoe))
    }

    /// The field is prefilled with the default. Clearing it and saving is "I didn't name
    /// it", not "name it nothing": the run gets the default, never a blank title.
    func testAClearedTitleSavesAsTheDefault() {
        for blank in ["", "   ", "\n"] {
            let draft = PostRun.Draft(title: blank)
            XCTAssertEqual(PostRun.journal(draft, defaultTitle: "Tuesday tempo", defaultShoeID: nil).title,
                           "Tuesday tempo", "\(blank.debugDescription)")
        }
    }

    /// An RPE off the scale never reaches the write: the column's check constraint would
    /// refuse the whole row, and his notes would go down with it.
    func testAnRPEOffTheScaleIsDroppedNotSent() {
        XCTAssertNil(PostRun.journal(PostRun.Draft(rpe: 11), defaultTitle: "x", defaultShoeID: nil).rpe)
        XCTAssertNil(PostRun.journal(PostRun.Draft(rpe: 0), defaultTitle: "x", defaultShoeID: nil).rpe)
    }

    // MARK: - Effort and feel

    /// One tap rates it. A second tap on the same number un-rates it — otherwise a mis-tap
    /// can only be corrected to *another* rating, and that rating then drives his load (#123).
    func testTappingTheRatedNumberAgainClearsIt() {
        XCTAssertEqual(PostRun.tappedRPE(7, current: nil), 7)
        XCTAssertEqual(PostRun.tappedRPE(4, current: 7), 4)
        XCTAssertNil(PostRun.tappedRPE(7, current: 7))
        XCTAssertEqual(PostRun.tappedRPE(12, current: 7), 7, "a number off the scale changes nothing")
    }

    func testTheWordUnderTheScale() {
        XCTAssertEqual(PostRun.rpeWord(2), "Very easy")
        XCTAssertEqual(PostRun.rpeWord(5), "Moderate")
        XCTAssertEqual(PostRun.rpeWord(8), "Hard")
        XCTAssertEqual(PostRun.rpeWord(10), "All out")
        XCTAssertTrue(PostRun.rpeWord(nil).contains("Leave it"), "unrated says it may stay unrated")
    }

    /// Tags go to the coach as stored (`CoachJournal`), lowercase, in the order he picked.
    func testFeelTagsToggleInPickOrder() {
        var tags: [String] = []
        tags = PostRun.toggled("windy", in: tags)
        tags = PostRun.toggled("heavy legs", in: tags)
        XCTAssertEqual(tags, ["windy", "heavy legs"])
        tags = PostRun.toggled("windy", in: tags)
        XCTAssertEqual(tags, ["heavy legs"])
        XCTAssertEqual(PostRun.tagLabel("heavy legs"), "Heavy legs")
        XCTAssertEqual(PostRun.feelTags, PostRun.feelTags.map { $0.lowercased() })
    }

    // MARK: - Shoes

    /// The shoes arrive over the network after the screen is up. If he has already tapped
    /// "None", the default arriving late must not put a pair back on the run.
    func testALateDefaultNeverOverridesNoneHeTapped() {
        let pegasus = UUID()
        XCTAssertEqual(PostRun.shoeID(.untouched, defaultID: nil), nil, "before the load")
        XCTAssertEqual(PostRun.shoeID(.untouched, defaultID: pegasus), pegasus, "untouched follows the default in")
        XCTAssertNil(PostRun.shoeID(.chosen(nil), defaultID: pegasus), "None stays None")
        let other = UUID()
        XCTAssertEqual(PostRun.shoeID(.chosen(other), defaultID: pegasus), other)
    }

    /// Retired pairs aren't offered after a run (#121); the default leads, then newest first.
    func testThePickerOffersPairsInServiceDefaultFirst() {
        let old = Shoe(id: UUID(), name: "Old Pegasus", startedAt: tuesday(6).addingTimeInterval(-200 * 86_400))
        let new = Shoe(id: UUID(), name: "Vaporfly", startedAt: tuesday(6).addingTimeInterval(-20 * 86_400))
        let retired = Shoe(id: UUID(), name: "Dead Ghost", startedAt: tuesday(6).addingTimeInterval(-400 * 86_400),
                           retiredAt: tuesday(6).addingTimeInterval(-30 * 86_400))
        XCTAssertEqual(PostRun.shoeOptions([old, retired, new], defaultID: nil).map(\.name), ["Vaporfly", "Old Pegasus"])
        XCTAssertEqual(PostRun.shoeOptions([old, retired, new], defaultID: old.id).map(\.name), ["Old Pegasus", "Vaporfly"])
    }

    // MARK: - The default title

    /// The issue's own example: Tuesday's tempo is "Tuesday tempo".
    func testARunOfTheSessionIsNamedForIt() {
        XCTAssertEqual(PostRun.defaultTitle(startedAt: tuesday(6, 42), kind: .outdoor, target: session("tempo"),
                                            calendar: chicago), "Tuesday tempo")
        XCTAssertEqual(PostRun.defaultTitle(startedAt: tuesday(6, 42), kind: .outdoor, target: session("long"),
                                            calendar: chicago), "Tuesday long run")
        XCTAssertEqual(PostRun.defaultTitle(startedAt: tuesday(6, 42), kind: .treadmill, target: session("interval"),
                                            calendar: chicago), "Tuesday intervals")
    }

    /// A free run is named for where and when; a race for what it was.
    func testAFreeRunIsNamedForWhenAndWhere() {
        let t = { (h: Int, kind: RecorderState.RunKind) in
            PostRun.defaultTitle(startedAt: self.tuesday(h), kind: kind, target: nil, calendar: self.chicago)
        }
        XCTAssertEqual(t(5, .outdoor), "Tuesday morning run")
        XCTAssertEqual(t(13, .outdoor), "Tuesday afternoon run")
        XCTAssertEqual(t(18, .outdoor), "Tuesday evening run")
        XCTAssertEqual(t(22, .outdoor), "Tuesday night run")
        XCTAssertEqual(t(18, .treadmill), "Tuesday treadmill run")
        XCTAssertEqual(t(7, .race), "Tuesday race")
    }

    /// A rest-day session is never carried into a run (`PreRun.startButton`), but if one
    /// were, "Tuesday rest" is not a name for a run.
    func testARestSessionDoesNotNameTheRun() {
        XCTAssertEqual(PostRun.defaultTitle(startedAt: tuesday(18), kind: .outdoor, target: session("rest"),
                                            calendar: chicago), "Tuesday evening run")
    }

    /// The day is the day it started, in his zone: 11:50 pm Tuesday in Chicago is already
    /// Wednesday in UTC, and still Tuesday's run.
    func testTheDayIsTheLocalDayItStarted() {
        XCTAssertEqual(PostRun.defaultTitle(startedAt: tuesday(23, 50), kind: .outdoor, target: nil,
                                            calendar: chicago), "Tuesday night run")
    }

    // MARK: - The summary

    /// 6.02 mi in 48:31 is 483.57 s/mi. The live average rounds that to 8:04; the archive
    /// stores whole seconds and Today shows 8:03. This screen shows what Today will.
    func testThePaceIsTheOneTodayWillShow() {
        let s = PostRun.summary(distanceM: 9_688, movingS: 2_911, elapsedS: 3_130, units: .mi)
        XCTAssertEqual(s.distance, "6.02")
        XCTAssertEqual(s.distanceUnit, "mi")
        XCTAssertEqual(s.time, "48:31")
        XCTAssertEqual(s.pace, "8:03")
        XCTAssertEqual(s.paceUnit, "/mi")
        XCTAssertEqual(s.elapsed, "52:10", "paused for 3:39, so the wall clock is shown too")
    }

    func testAKilometreAthleteSeesKilometres() {
        let s = PostRun.summary(distanceM: 9_688, movingS: 2_911, elapsedS: 2_911, units: .km)
        XCTAssertEqual(s.distance, "9.69")
        XCTAssertEqual(s.distanceUnit, "km")
        XCTAssertEqual(s.pace, "5:00")
        XCTAssertEqual(s.paceUnit, "/km")
        XCTAssertNil(s.elapsed, "no pauses, no second clock")
    }

    /// A marathon is over an hour; a run that never got a GPS lock has no pace, not 0:00.
    func testLongRunsReadInHoursAndNoDistanceHasNoPace() {
        XCTAssertEqual(PostRun.summary(distanceM: 42_195, movingS: 11_942, elapsedS: 11_942, units: .mi).time, "3:19:02")
        XCTAssertEqual(PostRun.summary(distanceM: 0, movingS: 600, elapsedS: 600, units: .mi).pace, Units.missing)
    }

    /// Splits in the run's unit; the partial one at the end reads as the fraction it is, at
    /// the same per-mile scale, and the bars are relative to the fastest.
    func testSplitRows() {
        let splits = [
            TrackMath.Split(index: 1, meters: 1_609.34, durationS: 480, paceS: 480, elevationDeltaM: nil, isPartial: false),
            TrackMath.Split(index: 2, meters: 1_609.34, durationS: 450, paceS: 450, elevationDeltaM: nil, isPartial: false),
            TrackMath.Split(index: 3, meters: 643.7, durationS: 186, paceS: 465, elevationDeltaM: nil, isPartial: true),
        ]
        let rows = PostRun.splitRows(splits, splitMeters: Units.mi.splitMeters)
        XCTAssertEqual(rows.map(\.label), ["1", "2", "0.4"])
        XCTAssertEqual(rows.map(\.pace), ["8:00", "7:30", "7:45"])
        XCTAssertEqual(rows[1].barFraction, 1)
        XCTAssertEqual(rows[0].barFraction, 450.0 / 480.0, accuracy: 1e-9)
        XCTAssertEqual(PostRun.splitRows([], splitMeters: 1_000), [])
    }

    // MARK: - What the screen is showing

    func testTheFormIsUpUntilTheSaveLands() {
        XCTAssertEqual(PostRun.stage(phase: .ending(.review), kind: .outdoor, landing: nil),
                       .review(saving: false, failure: nil))
        XCTAssertEqual(PostRun.stage(phase: .ending(.saving), kind: .treadmill, landing: nil),
                       .review(saving: true, failure: nil))
    }

    /// A failed save keeps the form, and everything in it, with the reason and Retry.
    func testAFailedSaveKeepsTheFormForTheRetry() {
        let reason = "Saved to Apple Health, but Tempo couldn't store it"
        XCTAssertEqual(PostRun.stage(phase: .ending(.failed(reason: reason)), kind: .outdoor, landing: nil),
                       .review(saving: false, failure: reason))
    }

    /// A race saves itself at the finish (#125, decision 3) and never gets the form — not
    /// while saving, and not if that save failed and needs a retry.
    func testARaceNeverGetsTheForm() {
        XCTAssertEqual(PostRun.stage(phase: .ending(.saving), kind: .race, landing: nil),
                       .race(saving: true, failure: nil))
        XCTAssertEqual(PostRun.stage(phase: .ending(.failed(reason: "Couldn't save to Apple Health")), kind: .race, landing: nil),
                       .race(saving: false, failure: "Couldn't save to Apple Health"))
    }

    /// Saved onto Today: close, and he sees it there. Saved anywhere else — too short for the
    /// log, or queued in a dead spot — and a closing cover onto an unchanged Today reads as a
    /// lost run, so the screen says where it went first.
    func testASaveThatIsNotOnTodaySaysWhereItWent() {
        let saved = RecorderState.Phase.saved(workoutID: UUID())
        XCTAssertEqual(PostRun.stage(phase: saved, kind: .outdoor, landing: .inTempo), .close)
        guard case .saved(let short) = PostRun.stage(phase: saved, kind: .outdoor, landing: .tooShort),
              case .saved(let queued) = PostRun.stage(phase: saved, kind: .outdoor, landing: .queued) else {
            return XCTFail("too short and queued both stop to explain")
        }
        XCTAssertTrue(short.contains("Apple Health") && short.contains("too short"))
        XCTAssertTrue(queued.contains("Apple Health") && queued.contains("next time"))
    }

    func testADiscardClosesTheCover() {
        XCTAssertEqual(PostRun.stage(phase: .discarded, kind: .outdoor, landing: nil), .close)
    }

    /// After Tempo refused the row the workout is already in Health, and a discard leaves it
    /// there. The confirmation must not tell him the run is gone.
    func testTheDiscardWarningTellsTheTruthAboutHealth() {
        XCTAssertTrue(PostRun.discardMessage(alreadyInHealth: false).contains("Nothing from this run will be saved"))
        let after = PostRun.discardMessage(alreadyInHealth: true)
        XCTAssertTrue(after.contains("already in Apple Health"))
        XCTAssertFalse(after.contains("Nothing from this run"))
    }

    /// The whole road from Stop to Saved, through the reducer, with the screen reading each
    /// phase: Stop puts up the form, Save locks it, the save landing closes it.
    func testFromStopToSavedThroughTheReducer() {
        let start = tuesday(6, 42)
        var state = RecorderState.reduce(RecorderState(), .start(.init(kind: .outdoor, target: session("tempo")), at: start))
        state = RecorderState.reduce(state, .countdownDone(at: start.addingTimeInterval(3)))
        state = RecorderState.reduce(state, .endRequested(.liveScreen, at: start.addingTimeInterval(2_914)))
        XCTAssertEqual(PreRun.screen(for: state.phase), .save)
        XCTAssertEqual(PostRun.stage(phase: state.phase, kind: state.kind, landing: nil), .review(saving: false, failure: nil))
        state = RecorderState.reduce(state, .endConfirmed)
        XCTAssertEqual(PostRun.stage(phase: state.phase, kind: state.kind, landing: nil), .review(saving: true, failure: nil))
        state = RecorderState.reduce(state, .saveSucceeded(workoutID: UUID()))
        XCTAssertEqual(PostRun.stage(phase: state.phase, kind: state.kind, landing: .inTempo), .close)
        XCTAssertEqual(PostRun.defaultTitle(startedAt: state.startedAt!, kind: state.kind, target: state.target,
                                            calendar: chicago), "Tuesday tempo")
    }
}
