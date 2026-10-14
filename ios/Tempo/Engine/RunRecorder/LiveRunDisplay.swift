import Foundation

/// Every string and every offer the live run screen (#127) draws, from one `RecorderSnapshot`.
///
/// The view is a fixed layout (frame 4a): TIME big, DISTANCE and CURRENT PACE under it, then
/// three small tiles. What goes *in* those slots is decided here, so a test can pin it: the
/// screen is the one place he reads a number mid-run, and every past bug in this app that
/// touched a number corrupted it silently rather than crashing.
///
/// Pure. Formats with `Units` at the edge like everything else; spells no unit itself.
struct LiveRunDisplay: Equatable {

    /// Which surface the run is on, and so which controls exist. Each case offers exactly
    /// what the reducer would accept from the live screen (`LiveRunDisplayTests` walks it),
    /// so the screen never draws a button that does nothing.
    enum Stage: Equatable {
        /// 3-2-1. The pre-run sheet (#126) owns it; nothing to press here.
        case countdown
        /// Pause, and hold-to-end.
        case running
        /// Resume, and hold-to-end. Frame 5a (#128) draws over this.
        case paused
        /// The recorder lost the run and has not got it back. Only hold-to-end ("save what we
        /// have") is accepted; the recovery prompt is #128.
        case recovering
        /// The clock has stopped: the save screen's business (#129), not this one's.
        case over

        var offersPause: Bool { self == .running }
        var offersResume: Bool { self == .paused }
        var offersHoldToEnd: Bool {
            switch self {
            case .running, .paused, .recovering: true
            case .countdown, .over: false
            }
        }
    }

    /// A small tile: a mono label, a value, and a line under it.
    struct Tile: Equatable {
        let label: String
        let value: String
        let detail: String?
    }

    /// The vs-target tile, with which way the gap goes so the view can tint it.
    struct VsTarget: Equatable {
        enum Trend: Equatable { case ahead, onPace, behind, unknown }
        let tile: Tile
        let trend: Trend
    }

    /// The one-tap target chip (David, #125: "override/hide in favor of free running
    /// whenever"). `.none` is a run with no target at all: no chip, nothing to bring back.
    enum TargetChip: Equatable {
        case none
        case shown
        case hidden

        /// The visibility one tap asks for. Nil when there is nothing to toggle.
        var toggled: Bool? {
            switch self {
            case .none: nil
            case .shown: false
            case .hidden: true
            }
        }
    }

    /// The pill in the top bar: what kind of run, and whether GPS is there yet.
    struct Status: Equatable {
        enum Tone: Equatable { case good, waiting, neutral }
        let text: String
        let tone: Tone
    }

    let stage: Stage
    let status: Status
    /// The elapsed clock. Never moving time: see `elapsedClock`.
    let time: String
    let distance: String
    /// "miles" / "km", under the distance.
    let distanceUnit: String
    let currentPace: String
    /// "/mi" / "/km", after both paces.
    let paceSuffix: String
    let averagePace: String
    /// Heart rate when there is one, else the last split (#125).
    let secondary: Tile
    /// Nil while running free, or on a run with no target.
    let vsTarget: VsTarget?
    /// "6 mi tempo · 7:30 /mi", over the numbers while the target is shown.
    let targetLine: String?
    let targetChip: TargetChip

    // MARK: - Timing

    /// How long a finger has to stay on End before the run ends (#128, frame 5a). Long enough
    /// that a pocket brush or a sweaty palm landing on the glass can't do it; short enough
    /// that at the finish it is one deliberate press, not a wait.
    static let holdToEndS = 1.0

    /// The screen lock is undone the same way, for the same pocket.
    static let holdToUnlockS = 1.0

    /// How long the split banner (frame 4c) stays up. The voice says the same thing once;
    /// the banner is for a glance in the seconds after it.
    static let splitBannerS = 6.0

    // MARK: - Building one

    init(_ snap: RecorderSnapshot) {
        let units = snap.units
        stage = Self.stage(snap.phase)
        status = Self.status(kind: snap.kind, gpsLocked: snap.gpsLocked)
        time = Self.elapsedClock(snap.elapsedS)
        distance = Self.distance(meters: snap.distanceM, units: units)
        distanceUnit = units.tileName
        currentPace = Self.pace(snap.currentPaceS)
        paceSuffix = units.paceSuffix
        averagePace = Self.pace(snap.averagePaceS)
        secondary = Self.secondary(snap.secondary, units: units)
        vsTarget = snap.target.flatMap { Self.vsTarget($0, units: units) }
        targetLine = snap.target.map { Self.targetLine($0, units: units) }
        targetChip = !snap.hasTarget ? .none : (snap.target == nil ? .hidden : .shown)
    }

    static func stage(_ phase: RecorderState.Phase) -> Stage {
        switch phase {
        case .countdown: .countdown
        case .running: .running
        case .paused: .paused
        case .recovering: .recovering
        case .idle, .ending, .saved, .discarded: .over
        }
    }

    static func status(kind: RecorderState.RunKind, gpsLocked: Bool) -> Status {
        switch kind {
        case .treadmill:
            return Status(text: "Treadmill", tone: .neutral)
        case .outdoor, .race:
            // Starting before a lock is allowed (#125, question 4): distance fills in once GPS
            // has him, so the pill says it is still looking rather than that it failed.
            let prefix = kind == .race ? "Race · " : ""
            return gpsLocked
                ? Status(text: prefix + "GPS", tone: .good)
                : Status(text: prefix + "Finding GPS", tone: .waiting)
        }
    }

    // MARK: - Formatting

    /// The big TIME: wall-clock seconds since the start, "m:ss" under an hour and "h:mm:ss"
    /// from there (a marathon reads "3:05:42", not "185:42").
    ///
    /// Elapsed, never moving time (EM decision on #127, from #113). Auto-pause backdates its
    /// decision to the start of the stop, so the moving clock steps back about eight seconds
    /// when a pause confirms. A ticking number that jumps backwards mid-run reads as a broken
    /// watch. Elapsed only ever goes forward; moving time is for the summaries.
    static func elapsedClock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = s % 3600 / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    /// Hundredths, rounded **down**. The split cue and the banner fire on the exact metre a
    /// split completes (`Units.completedSplits`); rounding to nearest would print "1.00" from
    /// 0.995 on, five hundredths before the voice says "Mile one", and the screen and his ear
    /// would disagree about whether the mile is done.
    static func distance(meters: Double, units: Units) -> String {
        guard meters.isFinite, meters > 0 else { return Units.fixed(0, decimals: 2) }
        // Whole units and hundredths floored separately: the whole part is then the very
        // division `completedSplits` does, so a float landing at 2.9999999999999996 can't be
        // multiplied up to "3.00" while the split count still says 2.
        let d = units.distance(meters: meters)
        let whole = d.rounded(.down)
        let hundredths = min(99, ((d - whole) * 100).rounded(.down))
        return Units.fixed(whole + hundredths / 100, decimals: 2)
    }

    /// "7:41", or "—" for no pace (paused, no distance yet, GPS still finding him).
    static func pace(_ secondsPerUnit: Double?) -> String {
        secondsPerUnit.map(Units.clock) ?? Units.missing
    }

    /// Heart rate, else the last split, else an empty last-split tile (#125). The empty one
    /// only exists for the first split of a run with no strap: the tile keeps its place, and
    /// fills at the first split boundary.
    static func secondary(_ secondary: RecorderSnapshot.Secondary, units: Units) -> Tile {
        switch secondary {
        case .heartRate(let bpm):
            return Tile(label: "Heart rate", value: String(bpm), detail: "bpm")
        case .lastSplit(let split):
            return Tile(label: "Last split", value: Units.clock(split.paceS),
                        detail: units.abbreviation + " " + String(split.index))
        case .none:
            return Tile(label: "Last split", value: Units.missing, detail: nil)
        }
    }

    /// Average pace against the target pace: "+0:12" is twelve seconds a unit slower, "-0:08"
    /// eight faster. Within half a second either way is "on pace", which is what a whole-
    /// second display would show as "+0:00" anyway.
    ///
    /// A target with no pace (an easy run judged on distance) shows the distance instead. One
    /// with neither has nothing to compare, and no tile.
    static func vsTarget(_ target: RecorderSnapshot.Target, units: Units) -> VsTarget? {
        if let paceS = target.paceS {
            let detail = "target " + Units.clock(paceS)
            guard let delta = target.deltaS, delta.isFinite else {
                return VsTarget(tile: Tile(label: "Vs target", value: Units.missing, detail: detail), trend: .unknown)
            }
            if abs(delta) < 0.5 {
                return VsTarget(tile: Tile(label: "Vs target", value: "on pace", detail: detail), trend: .onPace)
            }
            let sign = delta > 0 ? "+" : "-"
            return VsTarget(tile: Tile(label: "Vs target", value: sign + Units.clock(abs(delta)), detail: detail),
                            trend: delta > 0 ? .behind : .ahead)
        }
        // To the nearest tenth, unlike the live distance: the plan's "6 mi" is stored as
        // 9656 m, which is 5.99997 mi, and rounding that down would print a target nobody set.
        if let meters = target.distanceM, meters > 0 {
            return VsTarget(tile: Tile(label: "Target", value: units.number(meters: Double(meters), decimals: 1),
                                       detail: units.tileName),
                            trend: .unknown)
        }
        return nil
    }

    /// The line naming today's session over the numbers: "6 mi tempo · 7:30 /mi".
    static func targetLine(_ target: RecorderSnapshot.Target, units: Units) -> String {
        let name = target.title ?? target.type.capitalized
        guard let paceS = target.paceS else { return name }
        return name + " · " + units.formatPace(paceS)
    }

    // MARK: - The split banner (frame 4c)

    /// What the banner says when a split completes: the same three numbers the voice cue
    /// says (#118), so his eye and his ear never get different answers.
    struct SplitBanner: Equatable {
        /// "Mile 3" / "Kilometer 12".
        let title: String
        /// "7:41 /mi".
        let pace: String
        /// "avg 7:48", or nil before there is one.
        let average: String?
    }

    /// The banner to raise when the snapshot has more completed splits than the screen last
    /// saw, else nil. Named for the *latest* split if one update crossed two (GPS back after a
    /// tunnel), the same rule as `CueText.splitToAnnounce`: mile 4's pace shown at mile 5 is a
    /// wrong number.
    static func splitBanner(seenSplits: Int, snapshot: RecorderSnapshot) -> SplitBanner? {
        guard snapshot.completedSplits > seenSplits,
              let split = snapshot.lastSplit, !split.isPartial,
              split.index == snapshot.completedSplits
        else { return nil }
        let units = snapshot.units
        let name = units.name(plural: false)
        let capitalized = String(name.prefix(1)).uppercased() + String(name.dropFirst())
        return SplitBanner(
            title: capitalized + " " + String(split.index),
            pace: units.formatPace(split.paceS),
            average: snapshot.averagePaceS.map { "avg " + Units.clock($0) }
        )
    }
}
