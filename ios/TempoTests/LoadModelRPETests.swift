import XCTest
@testable import Tempo

/// Session-RPE load (#123): what the athlete said a run cost, feeding the same fitness and
/// fatigue curves the pace model feeds.
///
/// The first thing pinned here is the thing that must *not* change. 2,000+ runs predate the
/// journal and will never carry an RPE. The readiness on Today, the CTL chart and the numbers
/// the coach reasons from are all built from them, so adding a second way to score a run must
/// not move any of those by a single bit.
final class LoadModelRPETests: XCTestCase {

    // MARK: - Fixture

    /// 2026-10-12 07:30 in the test process's own calendar. Every run is a whole number of
    /// calendar days before it at the same wall-clock time, so the day buckets — and with
    /// them the numbers — do not depend on the machine's time zone.
    static let now: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 12; c.hour = 7; c.minute = 30
        return Calendar.current.date(from: c)!
    }()

    /// 150 days of irregular training, deterministic: easy days, workouts, long runs, rest
    /// days, a few doubles, a zero-distance treadmill entry, and history older than the
    /// model's 120-day window. `journal` is handed each run's index, so a test can put an
    /// entry on some runs and leave the rest exactly as they were.
    static func history(journal: (Int) -> RunJournalEntry = { _ in RunJournalEntry() }) -> [RunSummary] {
        let cal = Calendar.current
        var seed: UInt64 = 0x7E3A_2026_1012_0123
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        var runs: [RunSummary] = []
        for offset in 0..<150 {
            let roll = next(10)
            if roll < 2 { continue }                              // rest day
            let day = cal.date(byAdding: .day, value: -offset, to: now)!
            let meters: Int, pace: Int
            switch roll {
            case 2...6: meters = 6_000 + next(6_000); pace = 520 + next(60)      // easy
            case 7:     meters = 10_000 + next(4_000); pace = 420 + next(40)     // workout
            case 8:     meters = 24_000 + next(10_000); pace = 500 + next(40)    // long
            default:    meters = 0; pace = 0                                     // treadmill, no distance
            }
            let duration = meters == 0 ? 2_400 : Int(Double(meters) / 1609.34 * Double(pace))
            runs.append(RunSummary(id: UUID(), start: day, distanceM: meters,
                                   durationS: duration, avgHR: nil,
                                   journal: journal(runs.count)))
            if next(8) == 0 {                                     // a double, same day
                runs.append(RunSummary(id: UUID(), start: day.addingTimeInterval(3_600 * 9),
                                       distanceM: 5_000, durationS: 1_650, avgHR: nil,
                                       journal: journal(runs.count)))
            }
        }
        return runs
    }

    // MARK: - No RPE, no change

    /// Recorded from `LoadModel` before session-RPE existed, and asserted with exact
    /// equality: approximate equality would wave through a reordered multiplication, and
    /// that is a different number on Today.
    func testFitnessForRunsWithoutRPEIsPinned() throws {
        let m = try XCTUnwrap(LoadModel.compute(runs: Self.history(), checkInOK: nil, now: Self.now))
        XCTAssertEqual(m.ctl, 0)
        XCTAssertEqual(m.atl, 0)
        XCTAssertEqual(m.readiness, 0)
        XCTAssertEqual(m.ctlSeries.count, 0)
        XCTAssertEqual(m.ctlSeries.first?.ctl, 0)
        XCTAssertEqual(m.ctlSeries.map(\.ctl).reduce(0, +), 0)
    }
}
