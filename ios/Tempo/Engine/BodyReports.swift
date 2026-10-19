import Foundation

/// What the athlete reported about their body, as something the math can read (#89).
///
/// Before this, "left calf is tight, maybe a 3 out of 10" lived in the chat transcript and
/// nowhere else. The only channel from the athlete's body to readiness was
/// `check_ins.feels_ok` — one bit — so a 3 and an 8 were the same report, and the coach's
/// memory of either lasted exactly as long as its context window.
///
/// A report carries a severity the load model reads and a status the athlete controls. The
/// rules live here, pure, because every way this layer can break is a number going quietly
/// wrong on Today rather than a crash: a cleared calf that keeps capping readiness, or a 7/10
/// that stops.
struct BodyReport: Identifiable, Equatable {

    /// `open` and `watching` are both live; `cleared` is resolved.
    ///
    /// The two live labels exist for the coach's narration ("I'll keep an eye on the calf"),
    /// **not** for the readiness rule — see `BodyReports.capsReadiness`.
    enum Status: String, Equatable {
        case open, watching, cleared

        /// Anything this build doesn't recognise counts as live.
        ///
        /// The safe direction: a status we can't read must not be the reason a 7/10 stops
        /// capping readiness. A future status that genuinely resolves a report has to say so
        /// here, deliberately, and bring a test with it.
        init(decoding raw: String) {
            self = Status(rawValue: raw) ?? .open
        }
    }

    let id: UUID
    /// The athlete's own words, both of them: "left calf", "tight".
    let area: String
    let sensation: String
    /// 0–10, their number. Same spirit as `runs.rpe`: the athlete's word, not a measurement.
    let severity: Int
    let status: Status
    let openedAt: Date
    let clearedAt: Date?
    /// The coach message whose card logged it, for the link back to that conversation.
    let sourceMessageID: UUID?

    init(
        id: UUID,
        area: String,
        sensation: String,
        severity: Int,
        status: Status,
        openedAt: Date,
        clearedAt: Date? = nil,
        sourceMessageID: UUID? = nil
    ) {
        self.id = id
        self.area = area
        self.sensation = sensation
        self.severity = severity
        self.status = status
        self.openedAt = openedAt
        self.clearedAt = clearedAt
        self.sourceMessageID = sourceMessageID
    }

    /// Still standing. Only `cleared` is resolved.
    var isLive: Bool { status != .cleared }

    /// "Left calf · tight · 3/10" — the line on the card and in the Body section.
    var summaryLine: String { "\(area) · \(sensation) · \(severity)/10" }
}

enum BodyReports {

    /// At or above this, a live report caps readiness the way a negative check-in does.
    ///
    /// Five is the middle of the athlete's own scale: the point where "I noticed it" becomes
    /// "it is changing how I run". Below it the report is recorded and shown, and the number
    /// does not move — a 2/10 niggle is information for the coach, not a reason to call a
    /// taper week off.
    ///
    /// A tuning knob, not a fact. It lives here and not in a database constraint so David can
    /// move it in a one-line diff if the reports he logs read consistently high or low — the same
    /// reasoning as `LoadModel.referenceRPE`.
    static let capSeverity = 5

    /// Whether anything the athlete has reported should cap readiness right now.
    ///
    /// **Severity decides, not status.** The coach picks between `open` and `watching` for
    /// its own narration, and a 6/10 it happened to call "watching" must still cap: letting a
    /// label the model chose gate the number is how the athlete's word gets silently
    /// overruled by a word the coach picked. So: live, and severity at or above the
    /// threshold.
    ///
    /// Takes the whole set and filters it here, rather than trusting the caller to have
    /// passed only live ones — `LoadModel.compute` is handed whatever the store holds.
    static func capsReadiness(_ reports: [BodyReport]) -> Bool {
        reports.contains { $0.isLive && $0.severity >= capSeverity }
    }

    /// Live reports, worst first, then newest — what the coach is told about and what the
    /// Body section lists. Ties on severity break by recency so today's 3/10 sits above a
    /// three-week-old 3/10.
    static func live(_ reports: [BodyReport]) -> [BodyReport] {
        reports.filter(\.isLive).sorted {
            $0.severity != $1.severity ? $0.severity > $1.severity : $0.openedAt > $1.openedAt
        }
    }

    /// Resolved reports, most recently cleared first. Kept on screen because "the hip flexor
    /// came back three times this block" is a pattern, and a list that forgets can't show it.
    static func cleared(_ reports: [BodyReport]) -> [BodyReport] {
        reports.filter { !$0.isLive }.sorted {
            ($0.clearedAt ?? $0.openedAt) > ($1.clearedAt ?? $1.openedAt)
        }
    }

    /// What a just-logged report means for the number, in the athlete's terms — the line
    /// under the body card, so confirming a 3/10 never looks like it quietly cost readiness,
    /// and confirming a 6/10 never looks like it did nothing.
    static func readinessEffect(severity: Int) -> String {
        severity >= capSeverity
            ? "Readiness is capped at \(LoadModel.reportedCap) while this stands. Clear it and the number comes back."
            : "A \(severity) doesn't cap readiness. A \(capSeverity) or higher would, until you clear it."
    }
}
