import Foundation

/// What the recorder says out loud, and when (#118).
///
/// With the phone in a pocket the voice is the whole interface. David chose a cue at every
/// split with the split pace and the running average: "Mile three. Seven forty-one. Average
/// seven forty-eight."
///
/// The sentences are built in words, not digits. Handed "7:41", the synthesizer has to guess:
/// a time of day ("seven forty-one"), a ratio ("seven colon forty-one"), and "7:05" can come
/// out as "seven zero five". A runner says "seven oh five" and "seven flat". Spelling it out
/// here means one sentence, the same on every voice and every iOS, that a test can pin. It's
/// also why every number goes through `Units.clock`'s rule first: round the whole pace, then
/// split it, so 7:59.6 is "eight flat" and never "seven sixty".
///
/// Pure. `CueSpeaker` does the talking; this file never touches audio. Fixed English, because
/// the voice is fixed English (`CueSpeaker.voiceLanguage`).
enum CueText {

    // MARK: - When

    /// The split to announce when distance moves from `previousMeters` to `currentMeters`,
    /// or nil when no boundary was crossed. Built on `Units.completedSplits`, so a split lands
    /// exactly on its boundary: reaching 1609.34 m announces mile 1, 1609.33 m does not.
    ///
    /// If one update crosses two boundaries (GPS came back after a tunnel), only the latest
    /// split is announced. Mile 4's pace read out at mile 5 is a wrong number in his ear; the
    /// split list after the run still has both.
    static func splitToAnnounce(previousMeters: Double, currentMeters: Double, units: Units) -> Int? {
        let before = units.completedSplits(meters: previousMeters)
        let now = units.completedSplits(meters: currentMeters)
        return now > before ? now : nil
    }

    /// True on the one update that carries distance up to or past `mark` (the race distance,
    /// #117). Same boundary rule as splits: reaching the mark exactly counts.
    static func crossed(_ mark: Double, previousMeters: Double, currentMeters: Double) -> Bool {
        guard mark > 0, mark.isFinite else { return false }
        return previousMeters < mark && currentMeters >= mark
    }

    // MARK: - What

    /// "Mile three. Seven forty-one. Average seven forty-eight."
    ///
    /// `paceS` and `averagePaceS` are seconds per one of `units`, the way `TrackMath.Split` and
    /// `TrackMath.Summary` carry them. No average (not enough data yet) drops that sentence
    /// rather than saying something made up.
    static func split(index: Int, paceS: Double, averagePaceS: Double?, units: Units) -> String {
        var parts = [capitalized(units.name(plural: false)) + " " + words(index) + "."]
        if let pace = spokenPace(paceS) { parts.append(capitalized(pace) + ".") }
        if let average = averagePaceS.flatMap(spokenPace) { parts.append("Average " + average + ".") }
        return parts.joined(separator: " ")
    }

    /// The cue for a finished split from `TrackMath`. Nil for the partial split in progress:
    /// a split is only announced once it is a whole mile or kilometre.
    static func split(_ split: TrackMath.Split, averagePaceS: Double?, units: Units) -> String? {
        guard !split.isPartial else { return nil }
        return Self.split(index: split.index, paceS: split.paceS, averagePaceS: averagePaceS, units: units)
    }

    /// Auto-pause stopped the clock (#113). Said every time, because a silent auto-pause is how
    /// a runner finds out at the finish that a stretch of his race wasn't recorded. "Auto"
    /// tells him he didn't press anything.
    static let autoPaused = "Auto-paused."

    /// Auto-pause saw him moving again and restarted the clock (#113).
    static let autoResumed = "Resumed."

    /// The cue for an `AutoPause.Decision`, so the service speaks from the same value it
    /// dispatches to the reducer and the two can't drift apart.
    static func autoPause(_ decision: AutoPause.Decision) -> String {
        switch decision {
        case .pause: return autoPaused
        case .resume: return autoResumed
        }
    }

    /// The race-distance cue (#117): "Twenty-six point two miles. Three hours, five minutes,
    /// forty-two seconds. Average six fifty-nine. GPS reads long, so the finish is still
    /// ahead. Keep going."
    ///
    /// The last sentence is the point. GPS overreads on a race course: the measured line is
    /// the shortest legal path, and nobody runs it, so the phone reaches 26.2 a few hundred
    /// metres before the mat. Without the warning, this cue sounds like "you're done" at
    /// exactly the moment he can least afford to ease off.
    static func raceDistance(meters: Double, elapsedS: Double, averagePaceS: Double?, units: Units) -> String {
        var parts = [capitalized(spokenDistance(meters: meters, units: units)) + "."]
        if let elapsed = spokenDuration(elapsedS) { parts.append(capitalized(elapsed) + ".") }
        if let average = averagePaceS.flatMap(spokenPace) { parts.append("Average " + average + ".") }
        parts.append("GPS reads long, so the finish is still ahead. Keep going.")
        return parts.joined(separator: " ")
    }

    // MARK: - Spoken numbers

    /// A pace as a runner says it: "seven forty-one", "seven oh five", "seven flat",
    /// "forty-five seconds". Rounded to the whole second before it is split, like
    /// `Units.clock`. Nil for a negative or non-finite pace: no cue beats a wrong one.
    static func spokenPace(_ secondsPerUnit: Double) -> String? {
        guard secondsPerUnit.isFinite, secondsPerUnit >= 0 else { return nil }
        let total = Int(secondsPerUnit.rounded())
        let m = total / 60, s = total % 60
        if m == 0 { return words(s) + (s == 1 ? " second" : " seconds") }
        if s == 0 { return words(m) + " flat" }
        if s < 10 { return words(m) + " oh " + words(s) }
        return words(m) + " " + words(s)
    }

    /// An elapsed time, said in full: "three hours, five minutes, forty-two seconds",
    /// "nineteen minutes, fifty-two seconds", "one hour". The `m:ss` shorthand is fine for a
    /// pace, which is always minutes-and-seconds; a finish time can be either, and "three
    /// oh five" for 3:05:00 is ambiguous with a pace. Zero parts are left out.
    static func spokenDuration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append(words(h) + (h == 1 ? " hour" : " hours")) }
        if m > 0 { parts.append(words(m) + (m == 1 ? " minute" : " minutes")) }
        if s > 0 || parts.isEmpty { parts.append(words(s) + (s == 1 ? " second" : " seconds")) }
        return parts.joined(separator: ", ")
    }

    /// A distance in the athlete's unit to one decimal, the way the number is printed on the
    /// race shirt: "twenty-six point two miles", "forty-two point two kilometers", "ten
    /// miles", "one mile". A whole number drops the "point zero".
    static func spokenDistance(meters: Double, units: Units) -> String {
        let tenths = Int((units.distance(meters: max(meters, 0)) * 10).rounded())
        let whole = tenths / 10, tenth = tenths % 10
        let number = tenth == 0 ? words(whole) : words(whole) + " point " + words(tenth)
        return number + " " + units.name(plural: tenths != 10)
    }

    /// 0–999 in words: "seven", "forty-one", "one hundred five". Digits past that: no split
    /// index or pace minute gets there, and a synthesizer reads "1200" fine.
    static func words(_ n: Int) -> String {
        guard n >= 0, n < 1000 else { return String(n) }
        if n < 20 { return ones[n] }
        if n < 100 {
            let t = tens[n / 10], o = n % 10
            return o == 0 ? t : t + "-" + ones[o]
        }
        let h = ones[n / 100] + " hundred", rest = n % 100
        return rest == 0 ? h : h + " " + words(rest)
    }

    private static let ones = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
        "eighteen", "nineteen",
    ]
    private static let tens = [
        "", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
    ]

    private static func capitalized(_ s: String) -> String {
        s.prefix(1).uppercased() + s.dropFirst()
    }
}
