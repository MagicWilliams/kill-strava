import HealthKit
import XCTest
@testable import Tempo

/// The live numbers (#114) and what a recorded run writes into Health.
///
/// The snapshot is what the run screen, the Lock Screen and the Dynamic Island all read, so
/// a wrong number here is wrong in three places at once. The rest of the file pins the
/// three decisions about what goes into Health: which fixes make the route, how distance is
/// written, and the metadata the workout carries.
final class RecorderSnapshotTests: XCTestCase {

    typealias State = RecorderState

    private let t0 = ISO8601DateFormatter().date(from: "2026-10-11T12:30:00Z")!
    private func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private let tempo = State.SessionTarget(sessionID: UUID(), type: "tempo", title: "6 mi tempo",
                                            distanceM: 9656, paceSecPerMile: 450)

    private func running(target: State.SessionTarget? = nil, showTarget: Bool = true) -> State {
        [RecorderEvent.start(State.Setup(kind: .outdoor, target: target, showTarget: showTarget), at: t(-3)),
         .countdownDone(at: t(0))].reduce(State(), State.reduce)
    }

    /// A steady curve: `secPerKm` from 0 to `seconds`, a point a second.
    private func steady(secPerKm: Double, seconds: Double) -> [BestEfforts.Point] {
        stride(from: 0.0, through: seconds, by: 1).map { BestEfforts.Point(t: $0, m: $0 * 1000 / secPerKm) }
    }

    // MARK: - The numbers

    /// 25 minutes at 5:00/km with a 2-minute pause in the middle: average pace is over moving
    /// time, so the stop doesn't make the running look slower.
    func testAveragePaceIsOverMovingTime() throws {
        var state = running()
        state = State.reduce(state, .pause(.manual(.liveScreen), at: t(600)))
        state = State.reduce(state, .resume(.manual(.liveScreen), at: t(720)))
        // The curve is flat across the pause, the way the recorder builds it.
        let before = steady(secPerKm: 300, seconds: 600)
        let after = stride(from: 720.0, through: 1620, by: 1).map { BestEfforts.Point(t: $0, m: 2000 + ($0 - 720) * 1000 / 300) }
        let snap = RecorderSnapshot.make(state: state, at: t(1620), timeline: before + after,
                                         units: .km, heartRate: nil, gpsLocked: true)

        XCTAssertEqual(snap.elapsedS, 1620)
        XCTAssertEqual(snap.movingS, 1500)
        XCTAssertEqual(snap.distanceM, 5000, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snap.averagePaceS), 300, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(snap.currentPaceS), 300, accuracy: 1)
        XCTAssertEqual(snap.completedSplits, 5)
    }

    func testPausedHasNoCurrentPace() {
        let paused = State.reduce(running(), .pause(.manual(.liveScreen), at: t(600)))
        let snap = RecorderSnapshot.make(state: paused, at: t(605), timeline: steady(secPerKm: 300, seconds: 600),
                                         units: .km, heartRate: nil, gpsLocked: true)
        XCTAssertNil(snap.currentPaceS, "a paused run shows no pace, not the last one")
        XCTAssertNotNil(snap.averagePaceS)
    }

    /// 1.3 miles in: one split done, the second 0.3 mi along with its own pace.
    func testCurrentAndLastSplitInMiles() throws {
        let secPerMile = 480.0
        let timeline = stride(from: 0.0, through: 1.3 * secPerMile, by: 1)
            .map { BestEfforts.Point(t: $0, m: $0 * Units.metersPerMile / secPerMile) }
        let snap = RecorderSnapshot.make(state: running(), at: t(1.3 * secPerMile), timeline: timeline,
                                         units: .mi, heartRate: nil, gpsLocked: true)

        XCTAssertEqual(snap.completedSplits, 1)
        XCTAssertEqual(try XCTUnwrap(snap.lastSplit).paceS, 480, accuracy: 0.5)
        let current = try XCTUnwrap(snap.currentSplit)
        XCTAssertEqual(current.index, 2)
        XCTAssertEqual(current.meters, 0.3 * Units.metersPerMile, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(current.paceS), 480, accuracy: 0.5)
    }

    /// Right on a split boundary there is a current split with no pace yet, not a missing one.
    func testAFreshSplitExistsWithoutAPace() throws {
        let timeline = steady(secPerKm: 300, seconds: 302)
        let snap = RecorderSnapshot.make(state: running(), at: t(302), timeline: timeline,
                                         units: .km, heartRate: nil, gpsLocked: true)
        let current = try XCTUnwrap(snap.currentSplit)
        XCTAssertEqual(current.index, 2)
        XCTAssertNil(current.paceS)
        XCTAssertEqual(current.durationS, 2, accuracy: 0.01)
    }

    // MARK: - Heart rate or the last split (#125)

    func testHeartRateShowsWhenFreshAndGivesWayToTheLastSplitWhenNot() {
        let timeline = steady(secPerKm: 300, seconds: 400)
        let hr = RecorderSnapshot.HeartRate(bpm: 151.6, at: t(390))

        let fresh = RecorderSnapshot.make(state: running(), at: t(400), timeline: timeline,
                                          units: .km, heartRate: hr, gpsLocked: true)
        XCTAssertEqual(fresh.heartRateBPM, 152)
        XCTAssertEqual(fresh.secondary, .heartRate(bpm: 152))

        // The strap dropped out 40 s ago: its last number is not live, so it goes.
        let stale = RecorderSnapshot.make(state: running(), at: t(430), timeline: timeline,
                                          units: .km, heartRate: hr, gpsLocked: true)
        XCTAssertNil(stale.heartRateBPM)
        guard case .lastSplit(let split) = stale.secondary else {
            return XCTFail("no heart rate: the tile shows the last split, got \(stale.secondary)")
        }
        XCTAssertEqual(split.index, 1)
    }

    func testNoHeartRateAndNoSplitYetIsNone() {
        let snap = RecorderSnapshot.make(state: running(), at: t(60), timeline: steady(secPerKm: 300, seconds: 60),
                                         units: .km, heartRate: nil, gpsLocked: true)
        XCTAssertEqual(snap.secondary, .none)
    }

    // MARK: - Target

    /// The plan stores pace per mile; a km runner sees it per km. Positive delta is slower.
    func testTargetIsConvertedToTheUnitAndComparedWithAveragePace() throws {
        let snap = RecorderSnapshot.make(state: running(target: tempo), at: t(600),
                                         timeline: steady(secPerKm: 290, seconds: 600),
                                         units: .km, heartRate: nil, gpsLocked: true)
        let target = try XCTUnwrap(snap.target)
        XCTAssertEqual(try XCTUnwrap(target.paceS), 450 * 1000 / Units.metersPerMile, accuracy: 0.01) // 4:39.6 /km
        XCTAssertEqual(try XCTUnwrap(target.deltaS), 290 - 279.62, accuracy: 0.5)
        XCTAssertEqual(target.title, "6 mi tempo")
    }

    func testRunningFreeHidesTheTarget() {
        let hidden = RecorderSnapshot.make(state: running(target: tempo, showTarget: false), at: t(60),
                                           timeline: [], units: .mi, heartRate: nil, gpsLocked: false)
        XCTAssertNil(hidden.target)
        let shownAgain = State.reduce(running(target: tempo, showTarget: false), .setTargetVisible(true))
        XCTAssertNotNil(RecorderSnapshot.make(state: shownAgain, at: t(60), timeline: [], units: .mi,
                                              heartRate: nil, gpsLocked: false).target)
    }

    // MARK: - Route

    /// Every fix the distance used goes on the map, and nothing it rejected does: not the
    /// cached fix from before the start, not the inaccurate ones before a lock, not the
    /// spike. The lock candidates are held, then released together when the lock completes.
    func testTheRouteIsExactlyTheFixesTheDistanceUsed() {
        let lat0 = 41.8756, lon0 = -87.6244
        let mPerDeg = TrackMath.earthRadiusM * .pi / 180
        func fix(_ s: Double, north: Double, accuracy: Double = 5) -> TrackMath.Fix {
            TrackMath.Fix(timestamp: t(s), latitude: lat0 + north / mPerDeg, longitude: lon0,
                          horizontalAccuracy: accuracy)
        }
        let fixes: [(label: String, fix: TrackMath.Fix)] = [
            ("cached", fix(-30, north: -500)),        // stale: from before the start
            ("a", fix(0, north: 0)),
            ("blurry", fix(1, north: 3, accuracy: 60)), // breaks the lock in progress
            ("b", fix(2, north: 6)),
            ("c", fix(3, north: 9)),
            ("d", fix(4, north: 12)),                // completes the lock with b, c
            ("e", fix(5, north: 15)),
            ("spike", fix(6, north: 400)),           // under a building
            ("f", fix(7, north: 21)),
        ]
        var track = TrackMath.Track(start: t0)
        var gate = RouteGate<String>()
        var route: [String] = []
        for (label, f) in fixes {
            let wasLocked = track.isLocked
            route += gate.admit(label, verdict: track.ingest(f), wasLocked: wasLocked)
        }
        XCTAssertEqual(route, ["b", "c", "d", "e", "f"])
    }

    func testAResetGateHoldsNothingFromBeforeThePause() {
        var gate = RouteGate<Int>()
        _ = gate.admit(1, verdict: .awaitingLock, wasLocked: false)
        _ = gate.admit(2, verdict: .awaitingLock, wasLocked: false)
        gate.reset()
        _ = gate.admit(3, verdict: .awaitingLock, wasLocked: false)
        _ = gate.admit(4, verdict: .awaitingLock, wasLocked: false)
        XCTAssertEqual(gate.admit(5, verdict: .accepted, wasLocked: false), [3, 4, 5])
    }

    // MARK: - Distance samples

    func testDistanceIsWrittenInTenSecondStretchesAndTheRestAtTheEnd() throws {
        let timeline = steady(secPerKm: 300, seconds: 25)
        let origin = BestEfforts.Point(t: 0, m: 0)

        XCTAssertNil(DistanceChunks.next(timeline: Array(timeline.prefix(9)), flushed: origin, final: false),
                     "under ten seconds: wait")
        let first = try XCTUnwrap(DistanceChunks.next(timeline: Array(timeline.prefix(11)), flushed: origin, final: false))
        XCTAssertEqual(first.from, origin)
        XCTAssertEqual(first.to.t, 10)
        XCTAssertEqual(first.meters, 33.33, accuracy: 0.01)

        XCTAssertNil(DistanceChunks.next(timeline: timeline, flushed: BestEfforts.Point(t: 20, m: 66.67), final: false))
        let tail = try XCTUnwrap(DistanceChunks.next(timeline: timeline, flushed: BestEfforts.Point(t: 20, m: 66.67), final: true))
        XCTAssertEqual(tail.to.t, 25, "the end flushes whatever is left")
        XCTAssertNil(DistanceChunks.next(timeline: timeline, flushed: tail.to, final: true), "and only once")
    }

    /// `close()` can credit the last metres at the instant of the point before them. Those
    /// metres still reach Health, or its total reads short of the screen.
    func testAClosingTailWithNoDurationIsStillWritten() throws {
        let flushed = BestEfforts.Point(t: 600, m: 1995)
        let closed = [BestEfforts.Point(t: 0, m: 0), flushed, BestEfforts.Point(t: 600, m: 2000)]
        let tail = try XCTUnwrap(DistanceChunks.next(timeline: closed, flushed: flushed, final: true))
        XCTAssertEqual(tail.meters, 5, accuracy: 0.001)
        XCTAssertNil(DistanceChunks.next(timeline: closed, flushed: flushed, final: false),
                     "live, it waits like any other short stretch")
    }

    /// A run rebuilt after a kill (#115) has its whole curve to write at once. One sample
    /// for all of it would flatten every split Health hands back to the run's average, so
    /// the backlog goes in the same ten-second stretches a live run writes.
    func testABacklogIsWrittenInTenSecondStretchesThatAddUpToTheCurve() throws {
        let timeline = steady(secPerKm: 300, seconds: 605)
        let origin = BestEfforts.Point(t: 0, m: 0)
        let chunks = DistanceChunks.backlog(timeline: timeline, flushed: origin)

        XCTAssertEqual(chunks.count, 61, "sixty ten-second stretches and the last five seconds")
        XCTAssertEqual(chunks.first?.from, origin)
        XCTAssertEqual(chunks.last?.to, timeline.last)
        XCTAssertTrue(chunks.dropLast().allSatisfy { $0.to.t - $0.from.t >= DistanceChunks.minSpanS })
        XCTAssertTrue(zip(chunks, chunks.dropFirst()).allSatisfy { $0.to == $1.from }, "contiguous, no overlap")
        XCTAssertEqual(chunks.map(\.meters).reduce(0, +), timeline.last!.m, accuracy: 1e-9)

        // From a bookmark part-way along — what Health already held — only the rest.
        let bookmark = timeline[300]
        let rest = DistanceChunks.backlog(timeline: timeline, flushed: bookmark)
        XCTAssertEqual(rest.first?.from, bookmark)
        XCTAssertEqual(rest.map(\.meters).reduce(0, +), timeline.last!.m - bookmark.m, accuracy: 1e-9)
        XCTAssertTrue(DistanceChunks.backlog(timeline: timeline, flushed: timeline.last!).isEmpty, "and only once")
    }

    /// On a live run the end-of-run backlog is the one short tail `next` would have given.
    func testALiveRunsFinalBacklogIsOneTail() throws {
        let flushed = BestEfforts.Point(t: 600, m: 1995)
        let closed = [BestEfforts.Point(t: 0, m: 0), flushed, BestEfforts.Point(t: 600, m: 2000)]
        let tail = DistanceChunks.backlog(timeline: closed, flushed: flushed)
        XCTAssertEqual(tail, [try XCTUnwrap(DistanceChunks.next(timeline: closed, flushed: flushed, final: true))])
    }

    // MARK: - Metadata

    func testIndoorKeyIsHealthKits() {
        XCTAssertEqual(RecordingMetadata.indoorKey, HKMetadataKeyIndoorWorkout)
    }

    func testMetadataCarriesKindRecordingAndTheTargetSeen() throws {
        let id = UUID()
        let outdoor = RecordingMetadata.atBegin(recordingID: id, kind: .outdoor, target: tempo)
        XCTAssertEqual(outdoor[HKMetadataKeyIndoorWorkout] as? Bool, false)
        XCTAssertEqual(outdoor[RecordingMetadata.raceKey] as? Bool, false)
        XCTAssertEqual(outdoor[RecordingMetadata.recordingIDKey] as? String, id.uuidString)
        XCTAssertEqual(outdoor[RecordingMetadata.planSessionIDKey] as? String, tempo.sessionID?.uuidString)
        XCTAssertEqual(outdoor[RecordingMetadata.targetTypeKey] as? String, "tempo")
        XCTAssertEqual(outdoor[RecordingMetadata.targetPaceKey] as? Int, 450)
        XCTAssertEqual(outdoor[RecordingMetadata.targetDistanceMKey] as? Int, 9656)

        let treadmill = RecordingMetadata.atBegin(recordingID: id, kind: .treadmill, target: nil)
        XCTAssertEqual(treadmill[HKMetadataKeyIndoorWorkout] as? Bool, true)
        XCTAssertNil(treadmill[RecordingMetadata.targetTypeKey], "a free run carries no target")

        let race = RecordingMetadata.atBegin(recordingID: id, kind: .race, target: nil)
        XCTAssertEqual(race[RecordingMetadata.raceKey] as? Bool, true)
        XCTAssertEqual(race[HKMetadataKeyIndoorWorkout] as? Bool, false)

        // Every key is one HealthKit will take: custom keys must not claim Apple's prefix.
        for key in outdoor.keys where key != HKMetadataKeyIndoorWorkout {
            XCTAssertFalse(key.hasPrefix("HK"), key)
        }
    }

    func testSaveRecordsWhetherHeRanWithTheTargetShowing() {
        let hidden = State.reduce(running(target: tempo), .setTargetVisible(false))
        XCTAssertEqual(RecordingMetadata.atSave(state: hidden)[RecordingMetadata.targetShownKey] as? Bool, false)
        XCTAssertTrue(RecordingMetadata.atSave(state: running()).isEmpty, "no target, nothing to say")
    }
}
