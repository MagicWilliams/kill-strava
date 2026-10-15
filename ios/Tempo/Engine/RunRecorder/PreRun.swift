import Foundation

/// Every decision between Today's Start button and the first second of a run (#126).
///
/// The screens around it — the button in today's session card, the pre-run sheet, the
/// countdown — are drawn to the signed-off frames (#125, "01 · Start → countdown"). What they
/// *say* and what they *allow* is decided here, purely, because each of these is a place a
/// run can be lost before it starts: a Start button that offers a tempo on a rest day, a Race
/// option that tags a Tuesday jog as the marathon (#117), a GPS pill that says "strong" on a
/// fix `TrackMath` will throw away, or a location prompt fired before the athlete knows why
/// (#110), which iOS never shows twice.
enum PreRun {

    // MARK: - The Start button on Today

    /// The button and what pressing it carries into the pre-run sheet.
    struct StartButton: Equatable {
        enum Style: Equatable {
            /// Volt: today's session, or any run in Just running mode.
            case primary
            /// Quiet: a rest day or a session already banked. Still one tap (David, #125).
            case secondary
        }
        let title: String
        let style: Style
        /// Today's session as the run will carry it; nil for a free run.
        let target: RecorderState.SessionTarget?
    }

    static let freeRunTitle = "Start a run"

    /// Which Start button Today shows (frames 1a, 1b, 1c).
    ///
    /// - Parameters:
    ///   - session: today's planned session, nil when the plan has none.
    ///   - status: the session's `status` (`planned`, `done`, …).
    ///
    /// The session names itself only when there is a session still to run. Once it is done,
    /// or on a rest day, the button stays (a second run is his call) but drops to Secondary
    /// and carries no target: a recovery jog judged against a tempo pace is a wrong number
    /// on screen for the whole run.
    static func startButton(
        mode: TodayMode, session: RecorderState.SessionTarget?, status: String?, units: Units
    ) -> StartButton {
        guard mode == .training else {
            return StartButton(title: freeRunTitle, style: .primary, target: nil)
        }
        guard let session, !isRest(session.type), status != "done" else {
            return StartButton(title: freeRunTitle, style: .secondary, target: nil)
        }
        return StartButton(title: "Start today's " + name(of: session, units: units), style: .primary, target: session)
    }

    /// Session types that are not a run to start. `cross` is cross-training: the plan wants
    /// him on a bike, not on the road with a target.
    static func isRest(_ type: String) -> Bool {
        type == "rest" || type == "cross"
    }

    /// "6 mi tempo", "10 km long run", "intervals". Built from the distance and type rather
    /// than the plan's `title`, which is prose ("Marathon-pace blocks") written in miles; this
    /// follows the athlete's unit (#109) and reads after "Start today's".
    static func name(of session: RecorderState.SessionTarget, units: Units) -> String {
        let noun = noun(for: session.type)
        guard let m = session.distanceM, m > 0 else { return noun }
        return shortDistance(meters: Double(m), units: units) + " " + noun
    }

    /// "6 mi", "6.2 mi", "9.7 km": one decimal, dropped when it is zero. A 6-mile session
    /// is stored as 9,656 m, which is 5.9998 mi; "6.0 mi tempo" reads like a measurement.
    static func shortDistance(meters m: Double, units: Units) -> String {
        let value = (units.distance(meters: m) * 10).rounded() / 10
        let number = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        return number + " " + units.abbreviation
    }

    static func noun(for type: String) -> String {
        switch type {
        case "easy": return "easy run"
        case "long": return "long run"
        case "tempo": return "tempo"
        case "threshold": return "threshold run"
        case "interval": return "intervals"
        case "recovery": return "recovery run"
        case "race": return "race"
        default: return type.isEmpty ? "run" : type + " run"
        }
    }

    // MARK: - What the sheet is opened with

    /// Everything the pre-run sheet needs from Today, captured at the tap.
    struct Request: Identifiable, Equatable {
        let id = UUID()
        /// Today's session, or nil for a free run.
        let target: RecorderState.SessionTarget?
        /// Whether Race is offered (`raceEligible`).
        let raceEligible: Bool
    }

    /// The sheet's title: the session's name ("6 mi tempo"), or "Free run".
    static func sheetTitle(_ target: RecorderState.SessionTarget?, units: Units) -> String {
        guard let target else { return "Free run" }
        let name = name(of: target, units: units)
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// The line under it: "6 mi @ 7:45 /mi". Nil with nothing to say.
    static func targetLine(_ target: RecorderState.SessionTarget?, units: Units) -> String? {
        guard let target else { return nil }
        let distance = target.distanceM.flatMap { $0 > 0 ? shortDistance(meters: Double($0), units: units) : nil }
        let pace = target.paceSecPerMile.flatMap { $0 > 0 ? units.formatPace(secondsPerMile: $0) : nil }
        switch (distance, pace) {
        case let (d?, p?): return d + " @ " + p
        case let (d?, nil): return d
        case let (nil, p?): return "@ " + p
        case (nil, nil): return nil
        }
    }

    /// The "Show today's target" row's explanation, for the toggle's two positions.
    static func targetToggleDetail(_ target: RecorderState.SessionTarget, shown: Bool, units: Units) -> String {
        guard shown else { return "Off — running free. No pace target on screen or in your ear." }
        let what = target.paceSecPerMile.flatMap { $0 > 0 ? units.formatPace(secondsPerMile: $0) : nil }
            ?? targetLine(target, units: units) ?? "Today's target"
        return what + " on screen and in your ear. Hide it mid-run with one tap."
    }

    // MARK: - Race mode (#117)

    /// How far from race day Race is still offered, in calendar days either side. A day
    /// early covers a shakeout he wants tagged (or a race in another time zone); a day late,
    /// a race that ran past midnight before he opened the app.
    static let raceWindowDays = 1

    /// Whether the sheet offers Race. Only an open block's race, and only within
    /// `raceWindowDays` of its date. Off that window the option is hidden, not disabled:
    /// a race run auto-saves and links itself as the block's result, so a stray tap on an
    /// ordinary Tuesday would file that Tuesday as the marathon.
    ///
    /// Calendar days in the athlete's zone, like `RaceCountdown`: race dates are `yyyy-MM-dd`
    /// at local midnight.
    static func raceEligible(
        raceDay: Date?, blockClosed: Bool, now: Date, calendar: Calendar = RaceCountdown.calendar
    ) -> Bool {
        guard let raceDay, !blockClosed else { return false }
        let from = calendar.startOfDay(for: now), to = calendar.startOfDay(for: raceDay)
        guard let days = calendar.dateComponents([.day], from: from, to: to).day else { return false }
        return abs(days) <= raceWindowDays
    }

    /// The type picker's options, in the frame's order.
    static func kinds(raceEligible: Bool) -> [RecorderState.RunKind] {
        raceEligible ? [.outdoor, .treadmill, .race] : [.outdoor, .treadmill]
    }

    // MARK: - Location (#110)

    /// What stands between the chosen run type and Start.
    enum Gate: Equatable {
        /// Nothing. Start is live.
        case ready
        /// Never asked: show the explainer (frame 2b), which then fires the system prompt.
        /// iOS shows that prompt once, ever, so it is never fired cold.
        case explain
        /// Asked and refused, or unusable. Start is off for this type; the message says why
        /// and every one of them offers the treadmill.
        case blocked(String)
    }

    static func gate(kind: RecorderState.RunKind, access: LocationAccess) -> Gate {
        if kind == .treadmill { return .ready }
        if access.canPrompt { return .explain }
        if let blocker = access.blocker { return .blocked(blocker) }
        return .ready
    }

    // MARK: - GPS signal

    /// The pill on the sheet and the countdown (component "GPS pill"). Start is allowed in
    /// every state but `.off` (David, #125): the clock runs from the countdown, and distance
    /// fills in once `TrackMath` has its lock.
    enum Signal: Equatable {
        case strong(accuracyM: Int)
        case weak(accuracyM: Int)
        case searching
        case off

        var label: String {
            switch self {
            case .strong: "GPS strong"
            case .weak: "GPS weak"
            case .searching: "Finding GPS\u{2026}"
            case .off: "Location off"
            }
        }

        /// Lit bars of three.
        var bars: Int {
            switch self {
            case .strong: 3
            case .weak: 2
            case .searching: 1
            case .off: 0
            }
        }

        /// The sentence beside the pill on the sheet.
        var caption: String {
            switch self {
            case .strong(let m): "Locked, \u{00B1}\(m) m. Ready when you are."
            case .weak(let m): "\u{00B1}\(m) m. You can start; distance sharpens as the signal settles."
            case .searching: "You can start now. Distance fills in once GPS locks."
            case .off: "Tempo can't see your location."
            }
        }
    }

    /// At or inside this, the pill says strong.
    static let strongAccuracyM = 10.0
    /// A fix older than this says nothing about the signal now (a phone just pulled out of a
    /// bag, a tunnel).
    static let staleFixS = 10.0

    /// - Parameters:
    ///   - accuracyM: the newest fix's `horizontalAccuracy`; negative means no position.
    ///   - age: seconds since that fix.
    ///
    /// "Weak" ends where `TrackMath` stops using fixes (`maxHorizontalAccuracyM`). Past it a
    /// fix is thrown away, so the pill says "Finding GPS…", which is what the run will see.
    static func signal(access: LocationAccess, accuracyM: Double?, age: TimeInterval?) -> Signal {
        guard access.canRecordOutdoors else { return .off }
        guard let accuracyM, let age, accuracyM >= 0, age <= staleFixS else { return .searching }
        let shown = max(1, Int(accuracyM.rounded()))
        if accuracyM <= strongAccuracyM { return .strong(accuracyM: shown) }
        if accuracyM <= TrackMath.maxHorizontalAccuracyM { return .weak(accuracyM: shown) }
        return .searching
    }

    // MARK: - Countdown

    enum Countdown {
        /// 3-2-1.
        static let seconds = 3

        /// The number on screen `elapsed` seconds into the countdown: 3, 2, 1, then 0 (go).
        static func showing(elapsed: TimeInterval) -> Int {
            guard elapsed.isFinite else { return seconds }
            return min(seconds, max(0, seconds - Int(elapsed.rounded(.down))))
        }

        /// How far round the ring is within the current second, 0 ..< 1.
        static func sweep(elapsed: TimeInterval) -> Double {
            guard elapsed.isFinite, elapsed > 0 else { return 0 }
            guard elapsed < Double(seconds) else { return 1 }
            return elapsed - elapsed.rounded(.down)
        }
    }

    // MARK: - Which recorder screen is up

    /// What covers the app while a run exists. Follows the recorder's phase, so the live
    /// screen comes up after the countdown, after a relaunch into a recovered run (#115), and
    /// goes away only when the run is reset — never because a view decided so on its own.
    enum Screen: Equatable {
        case none
        case countdown
        /// The live run (#127): recording, paused, or lost and waiting to be picked back up.
        case live
        /// The save screen (#129), from the moment the clock stops until the recorder is
        /// reset: the journal, the save in flight, a failed save and its retry, and the
        /// instant after a save or a discard when only the cover is left to close
        /// (`PostRun.stage`).
        case save
        /// "We kept your run" (#115): launch picked up a run iOS had killed, and he has not
        /// seen it yet. Shown in the same cover, in place of the live or save screen, until
        /// he answers it (`WorkoutRecorder.acknowledgeRecovery`) or the run is reset.
        case recovered
    }

    /// `recovered` is `WorkoutRecorder.recovered != nil`. It outranks the phase for any run
    /// that exists — a rescued run in `.recovering` has only the prompt's two ways out — and
    /// never conjures a cover for a recorder that is idle.
    static func screen(for phase: RecorderState.Phase, recovered: Bool = false) -> Screen {
        switch phase {
        case .idle: .none
        case .countdown: .countdown
        case _ where recovered: .recovered
        case .running, .paused, .recovering: .live
        case .ending, .saved, .discarded: .save
        }
    }

    // MARK: - Settings the sheet writes

    /// Auto-pause, off unless he turns it on (David, 2026-10-12). Like the voice-cue setting
    /// (`CueSpeaker.enabledKey`), a device preference in `UserDefaults`, not training data.
    static let autoPauseKey = "recorder.autoPauseEnabled"
}
