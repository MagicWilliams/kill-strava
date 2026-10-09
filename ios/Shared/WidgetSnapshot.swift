import Foundation

/// Everything the Home Screen, Today View and Lock Screen widgets know, written by the app and
/// read by the `TempoWidgets` extension through the shared App Group (#76).
///
/// **The widget never talks to Supabase or HealthKit.** It has no session, no Health
/// permission, and a few milliseconds of budget; if it fetched its own numbers it would
/// sooner or later disagree with Today, and a glance that disagrees with the app is worse
/// than no glance. So the app is the only author: at the end of every successful refresh it
/// builds one of these from the same `RunStore` state Today renders, and the widget only
/// ever *displays* it.
///
/// Compiled into both targets. Everything here is pure — the build, the week rollover, the
/// stale rule and the timeline schedule are decisions, and they are pinned in
/// `WidgetSnapshotTests` because none of them can be observed without a phone.
struct WidgetSnapshot: Codable, Equatable {

    /// One upcoming planned session, flattened from `SessionInfo`.
    struct Session: Codable, Equatable {
        /// Local midnight of the session's day.
        let day: Date
        let type: String
        let title: String?
        let targetMiles: Double?
        let targetPaceSec: Int?
        let detail: String?

        var name: String { title ?? type.capitalized }
    }

    /// The coach's most recent read, with the day it was about. Dated because it is carried
    /// forward across refreshes (see `build`): an undated line from Tuesday sitting under
    /// Friday's session would read as advice about Friday.
    struct CoachLine: Codable, Equatable {
        let text: String
        let day: Date
    }

    let generatedAt: Date
    /// Monday 00:00 of the week `dayMiles` describes.
    let weekStart: Date
    /// Miles per day, Monday first. Always seven entries.
    let dayMiles: [Double]
    let lastWeekMiles: Double
    /// The plan's mileage target for `weekStart`'s week, and for the one after it — the
    /// second is what the gauge measures against once the week rolls over without the app
    /// being opened.
    let weekTargetMiles: Double?
    let nextWeekTargetMiles: Double?
    /// Planned, non-rest sessions from the snapshot's day onward, soonest first. Several, not
    /// one, so the widget can step past today's session at midnight without the app.
    let upcoming: [Session]
    let coach: CoachLine?

    var weekMiles: Double { dayMiles.reduce(0, +) }
}

// MARK: - Shared constants

extension WidgetSnapshot {
    /// Must match the `com.apple.security.application-groups` entry in **both** targets'
    /// entitlements; a mismatch fails silently — the app writes into a container the widget
    /// can't see, and the widget shows "Open Tempo" forever.
    static let appGroup = "group.studio.delight.tempo"
    static let defaultsKey = "widget.snapshot.v1"

    /// Past this, the widget stops presenting the numbers as current. 36h rather than 24h so
    /// a normal one-launch-a-day habit never trips it — opening the app at 7am and again at
    /// 6pm the next day is a day and a half.
    static let staleAfter: TimeInterval = 36 * 3600

    /// How many upcoming sessions travel in the snapshot. A week is more than the stale
    /// window can ever reach.
    static let upcomingLimit = 7

    /// Cap on the coach line. The medium widget has room for about two lines of body text
    /// under the session; more than this gets cut mid-word by the layout instead of by us.
    static let coachLineMaxLength = 140

    /// Training weeks run Mon–Sun. Built the same way as `RunStore.cal`, which the widget
    /// target cannot see; the two have to agree or the widget's week boundary drifts from
    /// Today's.
    static let weekCalendar: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.firstWeekday = 2
        return c
    }()
}

// MARK: - Building (app side)

extension WidgetSnapshot {

    /// A run, reduced to what the widget counts.
    struct RunInput: Equatable {
        let start: Date
        let miles: Double
    }

    /// A session as the plan holds it, status included so the builder can drop what's
    /// already done or skipped.
    struct SessionInput: Equatable {
        let day: Date
        let type: String
        let title: String?
        let status: String
        let targetMiles: Double?
        let targetPaceSec: Int?
        let detail: String?
    }

    /// Builds the snapshot from the same state Today renders.
    ///
    /// - Parameters:
    ///   - coachLine: today's coach takeaway, when one exists.
    ///   - previous: the snapshot already on disk. Its coach line is carried forward when
    ///     today has none, because the takeaway only exists on days with a completed session
    ///     and "latest" means the latest one, not today's.
    static func build(
        now: Date,
        runs: [RunInput],
        sessions: [SessionInput],
        weekTargetMiles: Double?,
        nextWeekTargetMiles: Double?,
        coachLine: CoachLine?,
        previous: WidgetSnapshot?,
        calendar: Calendar = weekCalendar
    ) -> WidgetSnapshot {
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 7 * 86_400)
        let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: week.start) ?? week.start
        let lastWeek = DateInterval(start: lastWeekStart, end: week.start)

        var dayMiles = Array(repeating: 0.0, count: 7)
        var lastWeekMiles = 0.0
        for run in runs {
            if week.contains(run.start) {
                let index = calendar.dateComponents([.day], from: week.start, to: calendar.startOfDay(for: run.start)).day ?? 0
                dayMiles[min(max(index, 0), 6)] += run.miles
            } else if lastWeek.contains(run.start) && run.start < week.start {
                lastWeekMiles += run.miles
            }
        }

        let today = calendar.startOfDay(for: now)
        let upcoming = sessions
            .filter { $0.status == "planned" && $0.type != "rest" && $0.day >= today }
            .sorted { $0.day < $1.day }
            .prefix(upcomingLimit)
            .map {
                Session(day: $0.day, type: $0.type, title: $0.title,
                        targetMiles: $0.targetMiles, targetPaceSec: $0.targetPaceSec, detail: $0.detail)
            }

        let coach = coachLine
            .flatMap { line in clip(line.text).map { CoachLine(text: $0, day: line.day) } }
            ?? previous?.coach

        return WidgetSnapshot(
            generatedAt: now,
            weekStart: week.start,
            dayMiles: dayMiles,
            lastWeekMiles: lastWeekMiles,
            weekTargetMiles: weekTargetMiles,
            nextWeekTargetMiles: nextWeekTargetMiles,
            upcoming: Array(upcoming),
            coach: coach
        )
    }

    /// The first two sentences, capped at `coachLineMaxLength` on a word boundary. Nil for
    /// text with nothing in it, so an empty takeaway can't blank out the carried-forward one.
    static func clip(_ text: String) -> String? {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return nil }

        // A sentence ends at . ! ? followed by a space — "7.5 mi" and "8:05/mi." both survive.
        var sentences = 0
        var end = flat.endIndex
        var i = flat.startIndex
        while i < flat.endIndex {
            let next = flat.index(after: i)
            if ".!?".contains(flat[i]), next == flat.endIndex || flat[next] == " " {
                sentences += 1
                if sentences == 2 { end = next; break }
            }
            i = next
        }
        var clipped = String(flat[..<end])

        if clipped.count > coachLineMaxLength {
            let hard = clipped.prefix(coachLineMaxLength - 1)
            let soft = hard.lastIndex(of: " ").map { hard[..<$0] } ?? hard
            clipped = soft.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:—-")) + "\u{2026}"
        }
        return clipped
    }
}

// MARK: - Reading (widget side)

extension WidgetSnapshot {

    /// What a widget shows at a given moment. A pure function of the snapshot and the clock,
    /// because the widget renders entries for times the app will never see — next Monday,
    /// tomorrow morning — and each has to be honest on its own.
    enum Display: Equatable {
        /// The app has never written a snapshot.
        case empty
        /// Older than `staleAfter`. The widget says "Open Tempo to refresh" and shows no
        /// numbers: a week that stopped updating looks identical to a week with no running.
        case stale(asOf: Date)
        case current(Week)
    }

    struct Week: Equatable {
        enum GaugeBasis: Equatable { case plan, lastWeek }

        let miles: Double
        /// Monday first, seven entries.
        let dayMiles: [Double]
        /// 0 = Monday … 6 = Sunday, for the "today" ring on the dots.
        let todayIndex: Int
        /// Nil after a rollover that skipped a whole week — nobody counted it.
        let lastWeekMiles: Double?
        let gaugeTarget: Double?
        let gaugeBasis: GaugeBasis?
        let nextSession: Session?
        let coach: CoachLine?

        /// 0…1 for the Lock Screen gauge.
        var gaugeFraction: Double {
            guard let gaugeTarget, gaugeTarget > 0 else { return 0 }
            return min(max(miles / gaugeTarget, 0), 1)
        }
    }

    static func display(_ snapshot: WidgetSnapshot?, at date: Date, calendar: Calendar = weekCalendar) -> Display {
        guard let snapshot else { return .empty }
        if date.timeIntervalSince(snapshot.generatedAt) > staleAfter {
            return .stale(asOf: snapshot.generatedAt)
        }

        let weekStart = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        let weeksLater = calendar.dateComponents([.weekOfYear], from: snapshot.weekStart, to: weekStart).weekOfYear ?? 0

        let miles: Double
        let dayMiles: [Double]
        let lastWeek: Double?
        let target: Double?
        switch weeksLater {
        case ..<1:
            // Same week as the snapshot (or a clock that went backwards — show what we have).
            miles = snapshot.weekMiles
            dayMiles = snapshot.dayMiles
            lastWeek = snapshot.lastWeekMiles
            target = snapshot.weekTargetMiles
        case 1:
            // Monday 00:00 without a refresh: the week we counted is now *last* week. Showing
            // it as this week's total is the specific lie the rollover entry exists to prevent.
            miles = 0
            dayMiles = Array(repeating: 0, count: 7)
            lastWeek = snapshot.weekMiles
            target = snapshot.nextWeekTargetMiles
        default:
            miles = 0
            dayMiles = Array(repeating: 0, count: 7)
            lastWeek = nil
            target = nil
        }

        let gaugeTarget: Double?
        let basis: Week.GaugeBasis?
        if let target, target > 0 {
            gaugeTarget = target; basis = .plan
        } else if let lastWeek, lastWeek > 0 {
            gaugeTarget = lastWeek; basis = .lastWeek
        } else {
            gaugeTarget = nil; basis = nil
        }

        let today = calendar.startOfDay(for: date)
        let todayIndex = calendar.dateComponents([.day], from: weekStart, to: today).day ?? 0

        return .current(Week(
            miles: miles,
            dayMiles: dayMiles,
            todayIndex: min(max(todayIndex, 0), 6),
            lastWeekMiles: lastWeek,
            gaugeTarget: gaugeTarget,
            gaugeBasis: basis,
            nextSession: snapshot.upcoming.first { $0.day >= today },
            coach: snapshot.coach
        ))
    }

    /// When the widget's picture changes without the app: every local midnight for the next
    /// week (the next-session label, and Monday's rollover among them) and the moment the
    /// snapshot goes stale. Sorted, deduplicated, always starting at `now`.
    static func entryDates(for snapshot: WidgetSnapshot?, now: Date, calendar: Calendar = weekCalendar) -> [Date] {
        var dates: [Date] = [now]
        var midnight = calendar.startOfDay(for: now)
        for _ in 0..<8 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: midnight) else { break }
            midnight = next
            dates.append(midnight)
        }
        if let snapshot {
            let staleAt = snapshot.generatedAt.addingTimeInterval(staleAfter + 1)
            if staleAt > now { dates.append(staleAt) }
        }
        return Array(Set(dates)).sorted()
    }
}

// MARK: - Relative wording

extension WidgetSnapshot {
    /// "Today", "Tomorrow", or the weekday — the session line on every widget.
    static func dayLabel(for day: Date, at date: Date, calendar: Calendar = weekCalendar) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: day)).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default:
            let f = DateFormatter()
            f.calendar = calendar
            f.setLocalizedDateFormatFromTemplate("EEE")
            return f.string(from: day)
        }
    }
}

// MARK: - Deep links

/// `tempo://` links the widgets open. Routing is the app's job (`TempoApp.onOpenURL`); this
/// only names the destinations so both targets spell them the same way.
enum WidgetLink: String, CaseIterable {
    case today, coach

    static let scheme = "tempo"

    var url: URL { URL(string: "\(Self.scheme)://\(rawValue)")! }

    init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host, let link = WidgetLink(rawValue: host) else { return nil }
        self = link
    }
}
