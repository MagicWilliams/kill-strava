import Foundation

/// A coach-proposed run correction (#206): what the athlete said goes in, the corrected
/// distance, time, pace and heart rate come out.
///
/// The rule this exists for, kept by David on 2026-10-15: **numbers come from code, words
/// come from the model.** Until this file, the coach prompt told Claude to "compute the FINAL
/// corrected totals yourself" and to estimate the missing heart rate, and `ChatStore` wrote
/// whatever came back into `runs`. Those columns feed the load model, readiness and the
/// projection, so one slip in the model's arithmetic would sit in the training history as a
/// plausible-looking number with nothing loud to give it away.
///
/// Now the coach reports the athlete's own words as `Facts` ("another 1.2 mi at 8:30",
/// "it was really 6.0 mi", "the watch stopped 14 minutes early"), and the arithmetic against
/// the run as stored happens here. The confirm card shows this file's result before Confirm.
///
/// **Heart rate is never estimated.** Nothing measured an added segment, so the run keeps
/// the average of the part that was recorded and the card says so. The only HR number that
/// replaces a recorded one is one the athlete read off another device.
///
/// **Two schemas, on purpose.** The app and the `coach` function ship separately, so a
/// build of this app has to cope with a coach that still sends totals (`distance_m`,
/// `duration_s`, `avg_hr`), and a pending card persisted by that coach outlives the deploy.
/// Totals are validated and re-derived (pace) but taken as given; facts win whenever any
/// are present. The coach only sends facts to an app that says it reads them
/// (`coachFeature`), so an older install keeps the totals it understands.
///
/// Pure: no network, no clock, no locale.
enum RunCorrection {

    /// What a build that reads facts tells the coach (`CoachRequest.features`). The coach
    /// function keys its run-editing tools off this exact string.
    static let coachFeature = "run_facts"

    // MARK: - Inputs

    /// The run as it sits in `runs` before the correction. Codable because an amend card
    /// pins it (`ProposedAction.based_on`) the first time it is applied — see `ChatStore`.
    struct Recorded: Codable, Equatable {
        let distance_m: Int
        let duration_s: Int
        let avg_hr: Int?
    }

    /// What the athlete said about an existing run, as the coach reported it. Distances and
    /// paces are in `unit`; times are clock strings ("14:00", "1:05:30").
    struct Facts: Equatable {
        var unit: Units? = nil
        /// A stretch the watch missed: whichever of distance, time and pace he gave.
        var addedDistance: Double? = nil
        var addedTime: String? = nil
        var addedPace: String? = nil
        /// The true totals, when he states them outright.
        var actualDistance: Double? = nil
        var actualTime: String? = nil
        /// An average HR he read off another device. Never a guess.
        var statedAvgHR: Int? = nil

        var isEmpty: Bool {
            addedDistance == nil && addedTime == nil && addedPace == nil
                && actualDistance == nil && actualTime == nil && statedAvgHR == nil
        }
    }

    /// What the athlete said about a run that was never recorded: any two of the three.
    struct NewRun: Equatable {
        var unit: Units? = nil
        var distance: Double? = nil
        var time: String? = nil
        var pace: String? = nil
        var statedAvgHR: Int? = nil

        var isEmpty: Bool { distance == nil && time == nil && pace == nil && statedAvgHR == nil }
    }

    // MARK: - Output

    /// Something the arithmetic had to assume because the athlete didn't say it. Shown on
    /// the card and appended to the run's correction note, so an assumption is never silent.
    enum Assumption: Equatable {
        /// He gave only a time or only a distance for the missed stretch; the other one is
        /// at the run's recorded pace.
        case segmentAtRecordedPace
        /// Time was added and nothing measured heart rate over it: the average is the
        /// recorded part's.
        case heartRateFromRecordedPart
    }

    struct Outcome: Equatable {
        let distanceM: Int
        let durationS: Int
        let avgHR: Int?
        var assumptions: [Assumption] = []

        /// Seconds per mile over moving time, by the same rule as every other pace in the
        /// app (`TimeAccounting.paceSecPerMile`).
        var avgPaceSec: Int? {
            TimeAccounting.paceSecPerMile(seconds: durationS, miles: Double(distanceM) / Units.metersPerMile)
        }
    }

    /// Why a correction can't be computed. `message` is what the athlete reads under the
    /// card, so it says what to tell the coach instead.
    enum Rejection: Error, Equatable {
        case nothingStated
        case notPositive(String)
        case unreadableTime(String)
        case contradictory(String)
        case incomplete(String)
        case implausiblePace
        case implausibleHeartRate

        var message: String {
            switch self {
            case .nothingStated:
                return "This card doesn't say what changed. Tell the coach what was wrong with the run."
            case .notPositive(let field):
                return "The \(field) has to be more than zero. Tell the coach the right number."
            case .unreadableTime(let field):
                return "Couldn't read the \(field). Ask the coach to propose it again."
            case .contradictory(let what):
                return "This card gives \(what), which don't agree. Tell the coach which one is right."
            case .incomplete(let what):
                return "This card needs \(what). Tell the coach how far or how long."
            case .implausiblePace:
                return "That would make the pace impossible for a run. Check the numbers with the coach."
            case .implausibleHeartRate:
                return "That heart rate isn't one a run can have. Check it with the coach."
            }
        }
    }

    // MARK: - Bounds

    /// Seconds per mile a run can honestly have: faster than the mile world record is a
    /// typo, slower than a 30:00 walk is a watch left running. Outside this, reject rather
    /// than write a number that would skew every average it lands in.
    static let plausiblePace: ClosedRange<Double> = 150...1800

    static let plausibleHeartRate: ClosedRange<Int> = 40...230

    /// How far a stated distance, time and pace may disagree before the three are treated as
    /// contradictory rather than rounded. "7 mi in 59:30 at 8:30" is exact; "at 8:30" for a
    /// 1:00:10 seven is still the same run.
    static let consistencyTolerance = 0.05

    // MARK: - Amend an existing run

    /// The corrected run. Throws `Rejection` rather than guessing.
    static func amend(_ run: Recorded, with facts: Facts, defaultUnit: Units) throws -> Outcome {
        guard !facts.isEmpty else { throw Rejection.nothingStated }
        let unit = facts.unit ?? defaultUnit

        let addedM = try positive(facts.addedDistance, "added distance").map { unit.meters(distance: $0) }
        let addedS = try clock(facts.addedTime, "added time").map(Double.init)
        let addedPace = try clock(facts.addedPace, "added pace").map { Double($0) / unit.meters }   // s per metre
        let actualM = try positive(facts.actualDistance, "distance").map { unit.meters(distance: $0) }
        let actualS = try clock(facts.actualTime, "time").map(Double.init)

        if addedM != nil, actualM != nil {
            throw Rejection.contradictory("both an added distance and a new total distance")
        }
        if addedS != nil, actualS != nil {
            throw Rejection.contradictory("both added time and a new total time")
        }
        if let addedM, let addedS, let addedPace,
           !agree(addedM * addedPace, addedS) {
            throw Rejection.contradictory("a distance, time and pace for the added stretch")
        }
        if addedPace != nil, addedM == nil, addedS == nil {
            throw Rejection.incomplete("a distance or a time for the added stretch, not just its pace")
        }
        if let pace = statedPace(meters: addedM, seconds: addedS, pacePerMeter: addedPace) {
            try checkPace(pace)
        }

        var assumptions: [Assumption] = []
        let recordedPace: Double? = run.distance_m > 0 && run.duration_s > 0
            ? Double(run.duration_s) / Double(run.distance_m)
            : nil

        // Each total is either the athlete's stated one, or the recorded one plus the stretch
        // the watch missed. A piece of that stretch is only worked out when a total needs it:
        // "stopped 14 minutes early, it was 7.0 in the end" needs no distance for the 14.
        var distance = actualM ?? Double(run.distance_m)
        var duration = actualS ?? Double(run.duration_s)
        if actualM == nil {
            if let addedM {
                distance += addedM
            } else if let addedS, let addedPace {
                distance += addedS / addedPace
            } else if let addedS, let recordedPace {
                distance += addedS / recordedPace
                assumptions.append(.segmentAtRecordedPace)
            } else if addedS != nil {
                throw Rejection.incomplete("a distance or a pace for the added time (this run has no recorded pace)")
            }
        }
        if actualS == nil {
            if let addedS {
                duration += addedS
            } else if let addedM, let addedPace {
                duration += addedM * addedPace
            } else if let addedM, let recordedPace {
                duration += addedM * recordedPace
                assumptions.append(.segmentAtRecordedPace)
            } else if addedM != nil {
                throw Rejection.incomplete("a time or a pace for the added distance (this run has no recorded pace)")
            }
        }

        let outcome = try finish(distance: distance, duration: duration)
        let hr = try heartRate(stated: facts.statedAvgHR, recorded: run, newDurationS: outcome.durationS, assumptions: &assumptions)
        return Outcome(distanceM: outcome.distanceM, durationS: outcome.durationS, avgHR: hr, assumptions: assumptions)
    }

    // MARK: - Log a run that was never recorded

    static func log(_ facts: NewRun, defaultUnit: Units) throws -> Outcome {
        guard !facts.isEmpty else { throw Rejection.nothingStated }
        let unit = facts.unit ?? defaultUnit
        let meters = try positive(facts.distance, "distance").map { unit.meters(distance: $0) }
        let seconds = try clock(facts.time, "time").map(Double.init)
        let pace = try clock(facts.pace, "pace").map { Double($0) / unit.meters }

        let distance: Double
        let duration: Double
        switch (meters, seconds, pace) {
        case let (m?, s?, p?):
            guard agree(m * p, s) else { throw Rejection.contradictory("a distance, time and pace") }
            (distance, duration) = (m, s)
        case let (m?, s?, nil): (distance, duration) = (m, s)
        case let (m?, nil, p?): (distance, duration) = (m, m * p)
        case let (nil, s?, p?): (distance, duration) = (s / p, s)
        default:
            throw Rejection.incomplete("two of distance, time and pace")
        }
        let outcome = try finish(distance: distance, duration: duration)
        if let hr = facts.statedAvgHR, !plausibleHeartRate.contains(hr) { throw Rejection.implausibleHeartRate }
        return Outcome(distanceM: outcome.distanceM, durationS: outcome.durationS, avgHR: facts.statedAvgHR)
    }

    // MARK: - Totals (the coach before #206)

    /// A card from a coach that still sends final totals. Taken as given — there is nothing
    /// else to compute them from — but validated, and the pace is still code's.
    static func amend(_ run: Recorded, distanceM: Int?, durationS: Int?, avgHR: Int?) throws -> Outcome {
        guard distanceM != nil || durationS != nil || avgHR != nil else { throw Rejection.nothingStated }
        if let distanceM, distanceM <= 0 { throw Rejection.notPositive("distance") }
        if let durationS, durationS <= 0 { throw Rejection.notPositive("time") }
        if let avgHR, !plausibleHeartRate.contains(avgHR) { throw Rejection.implausibleHeartRate }
        let outcome = try finish(
            distance: Double(distanceM ?? run.distance_m),
            duration: Double(durationS ?? run.duration_s)
        )
        return Outcome(distanceM: outcome.distanceM, durationS: outcome.durationS, avgHR: avgHR ?? run.avg_hr)
    }

    static func log(distanceM: Int?, durationS: Int?, avgHR: Int?) throws -> Outcome {
        guard let distanceM, let durationS else { throw Rejection.incomplete("a distance and a time") }
        guard distanceM > 0 else { throw Rejection.notPositive("distance") }
        guard durationS > 0 else { throw Rejection.notPositive("time") }
        if let avgHR, !plausibleHeartRate.contains(avgHR) { throw Rejection.implausibleHeartRate }
        let outcome = try finish(distance: Double(distanceM), duration: Double(durationS))
        return Outcome(distanceM: outcome.distanceM, durationS: outcome.durationS, avgHR: avgHR)
    }

    // MARK: - Clock strings

    /// "14:00" → 840, "1:05:30" → 3930. Two parts are m:ss, three are h:mm:ss; anything
    /// else (a bare "14", "14 min", "8.5") is unreadable rather than guessed at, because
    /// "14" alone could be minutes or seconds and the wrong guess is a 60× error.
    static func seconds(fromClock text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces)
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { Int($0) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        let n = parts.compactMap { $0 }
        if n.count == 2 {
            guard n[1] < 60 else { return nil }
            return n[0] * 60 + n[1]
        }
        guard n[1] < 60, n[2] < 60 else { return nil }
        return n[0] * 3600 + n[1] * 60 + n[2]
    }

    // MARK: - Pieces

    private static func positive(_ value: Double?, _ field: String) throws -> Double? {
        guard let value else { return nil }
        guard value.isFinite, value > 0 else { throw Rejection.notPositive(field) }
        return value
    }

    private static func clock(_ text: String?, _ field: String) throws -> Int? {
        guard let text else { return nil }
        guard let s = seconds(fromClock: text) else { throw Rejection.unreadableTime(field) }
        guard s > 0 else { throw Rejection.notPositive(field) }
        return s
    }

    private static func agree(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= consistencyTolerance * max(a, b)
    }

    /// The added stretch's pace in seconds per mile, when the athlete's own numbers fix it.
    private static func statedPace(meters: Double?, seconds: Double?, pacePerMeter: Double?) -> Double? {
        if let pacePerMeter { return pacePerMeter * Units.metersPerMile }
        if let meters, let seconds { return seconds / meters * Units.metersPerMile }
        return nil
    }

    private static func checkPace(_ secondsPerMile: Double) throws {
        guard plausiblePace.contains(secondsPerMile) else { throw Rejection.implausiblePace }
    }

    /// Round once, at the end, and check the run that results is one a person could run.
    private static func finish(distance: Double, duration: Double) throws -> Outcome {
        guard distance.isFinite, distance > 0 else { throw Rejection.notPositive("distance") }
        guard duration.isFinite, duration > 0 else { throw Rejection.notPositive("time") }
        let outcome = Outcome(distanceM: Int(distance.rounded()), durationS: Int(duration.rounded()), avgHR: nil)
        guard let pace = outcome.avgPaceSec else { throw Rejection.implausiblePace }
        try checkPace(Double(pace))
        return outcome
    }

    private static func heartRate(
        stated: Int?,
        recorded run: Recorded,
        newDurationS: Int,
        assumptions: inout [Assumption]
    ) throws -> Int? {
        if let stated {
            guard plausibleHeartRate.contains(stated) else { throw Rejection.implausibleHeartRate }
            return stated
        }
        if run.avg_hr != nil, newDurationS > run.duration_s {
            assumptions.append(.heartRateFromRecordedPart)
        }
        return run.avg_hr
    }
}

// MARK: - From a coach card

extension RunCorrection {

    /// The unit a card's facts are in. Nil for anything but "mi"/"km", so an odd value
    /// falls back to the athlete's own unit rather than to miles.
    private static func unit(of action: ProposedAction) -> Units? {
        action.unit.flatMap { Units(rawValue: $0.lowercased()) }
    }

    /// The facts an amend_run card carries, empty for a totals-style card.
    static func facts(of action: ProposedAction) -> Facts {
        Facts(
            unit: unit(of: action),
            addedDistance: action.added_distance,
            addedTime: action.added_time,
            addedPace: action.added_pace,
            actualDistance: action.actual_distance,
            actualTime: action.actual_time,
            statedAvgHR: action.stated_avg_hr
        )
    }

    static func newRun(of action: ProposedAction) -> NewRun {
        NewRun(
            unit: unit(of: action),
            distance: action.run_distance,
            time: action.run_time,
            pace: action.run_pace,
            statedAvgHR: action.stated_avg_hr
        )
    }

    /// An amend_run card's result against `run`. Facts win whenever any are present; a card
    /// with none is a totals card from the coach before #206.
    static func amendment(proposed action: ProposedAction, to run: Recorded, units: Units) throws -> Outcome {
        let stated = facts(of: action)
        if stated.isEmpty {
            return try amend(run, distanceM: action.distance_m, durationS: action.duration_s, avgHR: action.avg_hr)
        }
        return try amend(run, with: stated, defaultUnit: units)
    }

    /// An add_run card's result, by the same rule.
    static func loggedRun(proposed action: ProposedAction, units: Units) throws -> Outcome {
        let stated = newRun(of: action)
        if stated.isEmpty {
            return try log(distanceM: action.distance_m, durationS: action.duration_s, avgHR: action.avg_hr)
        }
        return try log(stated, defaultUnit: units)
    }

    /// The card once its write has landed, carrying the totals code computed. "What
    /// changed" (`ChangeLedger`) reads `distance_m`/`duration_s`/`avg_hr` off applied cards,
    /// so this is what keeps a facts card showing its numbers there.
    static func stamping(_ action: ProposedAction, with outcome: Outcome) -> ProposedAction {
        var stamped = action
        stamped.distance_m = outcome.distanceM
        stamped.duration_s = outcome.durationS
        stamped.avg_hr = outcome.avgHR
        return stamped
    }

    /// The assumptions in words, for the card and for the run's correction note.
    static func explain(_ assumption: Assumption) -> String {
        switch assumption {
        case .segmentAtRecordedPace:
            return "The added stretch is counted at this run's recorded pace."
        case .heartRateFromRecordedPart:
            return "Avg HR is the recorded part's; nothing measured the added time."
        }
    }

    /// `runs.correction_note`: the coach's words, then anything code assumed.
    static func correctionNote(_ note: String, outcome: Outcome) -> String {
        ([note] + outcome.assumptions.map(explain)).joined(separator: " ")
    }
}

// MARK: - The confirm card

extension RunCorrection {

    /// What a run card shows under its summary before Confirm.
    enum CardPreview: Equatable {
        struct Row: Equatable {
            let label: String
            /// Nil for a new run, or a value the correction leaves alone.
            let before: String?
            let after: String
        }
        case computed(rows: [Row], notes: [String])
        case rejected(String)
        /// An amend card whose run isn't in the loaded history. Confirm still computes from
        /// the saved row; there is just nothing on the phone to preview it against.
        case runNotLoaded
    }

    /// Nil for a card that isn't a run correction.
    ///
    /// `run` is the run to preview against: the card's pinned `based_on` when it has one
    /// (a retry writes exactly what the first attempt computed), else the run as loaded.
    static func cardPreview(for action: ProposedAction, run: Recorded?, units: Units) -> CardPreview? {
        switch action.type {
        case "amend_run":
            guard let run = action.based_on ?? run else { return .runNotLoaded }
            do {
                let outcome = try amendment(proposed: action, to: run, units: units)
                return .computed(rows: rows(outcome, before: run, units: units), notes: outcome.assumptions.map(explain))
            } catch {
                return .rejected((error as? Rejection)?.message ?? Rejection.nothingStated.message)
            }
        case "add_run":
            do {
                let outcome = try loggedRun(proposed: action, units: units)
                return .computed(rows: rows(outcome, before: nil, units: units), notes: [])
            } catch {
                return .rejected((error as? Rejection)?.message ?? Rejection.nothingStated.message)
            }
        default:
            return nil
        }
    }

    private static func rows(_ outcome: Outcome, before run: Recorded?, units: Units) -> [CardPreview.Row] {
        func row(_ label: String, _ before: String?, _ after: String) -> CardPreview.Row {
            CardPreview.Row(label: label, before: before == after ? nil : before, after: after)
        }
        var rows = [
            row("Distance",
                run.map { units.formatDistance(meters: Double($0.distance_m)) },
                units.formatDistance(meters: Double(outcome.distanceM))),
            row("Time",
                run.map { ChangeLedger.Format.clock($0.duration_s) },
                ChangeLedger.Format.clock(outcome.durationS)),
            row("Pace",
                run.map { units.formatRunPace(movingSeconds: $0.duration_s, meters: $0.distance_m) },
                units.formatRunPace(movingSeconds: outcome.durationS, meters: outcome.distanceM)),
        ]
        if let hr = outcome.avgHR {
            rows.append(row("Avg HR", run?.avg_hr.map(ChangeLedger.Format.bpm), ChangeLedger.Format.bpm(hr)))
        }
        return rows
    }
}
