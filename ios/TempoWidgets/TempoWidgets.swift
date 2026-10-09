import SwiftUI
import WidgetKit

/// Tempo's widgets (#76): the week at a glance, and what the coach wants next.
///
/// Display only. Every number comes from the `WidgetSnapshot` the app last wrote — see that
/// file for why the extension never fetches anything itself.
@main
struct TempoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        WeekWidget()
        CoachWidget()
    }
}

// MARK: - Timeline

struct TempoEntry: TimelineEntry {
    let date: Date
    let display: WidgetSnapshot.Display
}

struct TempoProvider: TimelineProvider {
    func placeholder(in context: Context) -> TempoEntry {
        TempoEntry(date: .now, display: WidgetSnapshot.display(.sample(), at: .now))
    }

    /// The widget gallery shows real numbers when there are some, and a sample otherwise —
    /// an "Open Tempo" tile in the gallery would sell the widget as broken.
    func getSnapshot(in context: Context, completion: @escaping (TempoEntry) -> Void) {
        let stored = WidgetSnapshotStore.load()
        let snapshot = stored ?? (context.isPreview ? .sample() : nil)
        completion(TempoEntry(date: .now, display: WidgetSnapshot.display(snapshot, at: .now)))
    }

    /// One entry per local midnight for a week plus the stale moment, so Monday's rollover,
    /// "Tomorrow" becoming "Today", and "Open Tempo to refresh" all happen without the app.
    func getTimeline(in context: Context, completion: @escaping (Timeline<TempoEntry>) -> Void) {
        let snapshot = WidgetSnapshotStore.load()
        let entries = WidgetSnapshot.entryDates(for: snapshot, now: .now).map {
            TempoEntry(date: $0, display: WidgetSnapshot.display(snapshot, at: $0))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

// MARK: - Widgets

struct WeekWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TempoWeek", provider: TempoProvider()) { entry in
            WeekWidgetView(entry: entry)
                .widgetURL(WidgetLink.today.url)
        }
        .configurationDisplayName("This week")
        .description("Weekly mileage, the days you ran, and your next session.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

struct CoachWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TempoCoach", provider: TempoProvider()) { entry in
            CoachWidgetView(entry: entry)
                .widgetURL(WidgetLink.coach.url)
        }
        .configurationDisplayName("Coach")
        .description("Your next session and the coach's latest read.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - Week

struct WeekWidgetView: View {
    let entry: TempoEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:    circular.containerBackground(for: .widget) { Color.clear }
        case .accessoryRectangular: rectangular.containerBackground(for: .widget) { Color.clear }
        default:                    small.containerBackground(for: .widget) { Tokens.Palette.canvas }
        }
    }

    // Home Screen / Today View

    @ViewBuilder private var small: some View {
        switch entry.display {
        case .empty:
            NeedsApp(title: "Open Tempo", detail: "to load your week")
        case .stale(let asOf):
            NeedsApp(title: "Open Tempo to refresh", detail: "Last synced \(asOf.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
        case .current(let week):
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Eyebrow("This week")
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 4)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Fmt.miles(week.miles))
                        .font(Tokens.Font.display(40))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .foregroundStyle(Tokens.Palette.textPrimary)
                        .widgetAccentable()
                    Text("mi")
                        .font(Tokens.Font.mono(13))
                        .foregroundStyle(Tokens.Palette.textSecondary)
                }
                Text(comparison(week))
                    .font(Tokens.Font.mono(10))
                    .tracking(1)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                DayDots(week: week)
            }
        }
    }

    /// The reference under the big number: the plan's target when there is one, last week
    /// otherwise — the same choice the Lock Screen gauge makes.
    private func comparison(_ week: WidgetSnapshot.Week) -> String {
        switch week.gaugeBasis {
        case .plan:     return "OF \(Fmt.miles(week.gaugeTarget ?? 0)) PLANNED"
        case .lastWeek: return "LAST WK \(Fmt.miles(week.gaugeTarget ?? 0))"
        case nil:       return week.lastWeekMiles == nil ? " " : "LAST WK 0.0"
        }
    }

    // Lock Screen

    @ViewBuilder private var circular: some View {
        switch entry.display {
        case .empty, .stale:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 18, weight: .semibold))
                    .accessibilityLabel("Open Tempo to refresh")
            }
        case .current(let week):
            if week.gaugeTarget != nil {
                Gauge(value: week.gaugeFraction) {
                    Text("mi")
                } currentValueLabel: {
                    Text(Fmt.milesShort(week.miles))
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .widgetAccentable()
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: -2) {
                        Text(Fmt.milesShort(week.miles))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.6)
                        Text("mi").font(.system(size: 10, weight: .semibold))
                    }
                }
            }
        }
    }

    @ViewBuilder private var rectangular: some View {
        switch entry.display {
        case .empty:
            VStack(alignment: .leading) {
                Text("Tempo").font(.headline).widgetAccentable()
                Text("Open Tempo to load your week").font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .stale:
            VStack(alignment: .leading) {
                Text("Tempo").font(.headline).widgetAccentable()
                Text("Open Tempo to refresh").font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .current(let week):
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(Fmt.miles(week.miles)).font(.system(.title3, design: .rounded, weight: .bold))
                    Text(week.gaugeBasis == .plan ? "/ \(Fmt.miles(week.gaugeTarget ?? 0)) mi" : "mi this week")
                        .font(.caption)
                }
                .widgetAccentable()
                if let next = week.nextSession {
                    Text("\(WidgetSnapshot.dayLabel(for: next.day, at: entry.date)) · \(next.name)")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if let target = Fmt.target(next) {
                        Text(target).font(.caption).lineLimit(1)
                    }
                } else {
                    Text("No session planned").font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The Mon–Sun strip from Today, at widget size.
private struct DayDots: View {
    let week: WidgetSnapshot.Week

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { index in
                let ran = week.dayMiles[index] > 0
                let isToday = index == week.todayIndex
                VStack(spacing: 3) {
                    Text(["M", "T", "W", "T", "F", "S", "S"][index])
                        .font(Tokens.Font.ui(9, isToday ? .semibold : .medium))
                        .foregroundStyle(isToday ? Tokens.Palette.textSecondary : Tokens.Palette.textTertiary)
                    Circle()
                        .fill(ran ? Tokens.Palette.voltMark : Tokens.Palette.elevated)
                        .frame(width: 8, height: 8)
                        .widgetAccentable(ran)
                        .overlay {
                            if isToday {
                                Circle()
                                    .strokeBorder(Tokens.Palette.voltMark.opacity(0.5), lineWidth: 1.2)
                                    .frame(width: 13, height: 13)
                            }
                        }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Coach

struct CoachWidgetView: View {
    let entry: TempoEntry

    var body: some View {
        content.containerBackground(for: .widget) { Tokens.Palette.canvas }
    }

    @ViewBuilder private var content: some View {
        switch entry.display {
        case .empty:
            NeedsApp(title: "Open Tempo", detail: "to load your plan and your coach's read")
        case .stale(let asOf):
            NeedsApp(title: "Open Tempo to refresh", detail: "Last synced \(asOf.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
        case .current(let week):
            VStack(alignment: .leading, spacing: 8) {
                session(week.nextSession)
                Rectangle().fill(Tokens.Palette.divider).frame(height: 0.5)
                coach(week.coach)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private func session(_ next: WidgetSnapshot.Session?) -> some View {
        if let next {
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow("Next · \(WidgetSnapshot.dayLabel(for: next.day, at: entry.date))", color: Tokens.Palette.accentText)
                HStack(alignment: .firstTextBaseline) {
                    Text(next.name)
                        .font(Tokens.Font.ui(16, .semibold))
                        .foregroundStyle(Tokens.Palette.textPrimary)
                        .lineLimit(1)
                        .widgetAccentable()
                    Spacer(minLength: 6)
                    if let target = Fmt.target(next) {
                        Text(target)
                            .font(Tokens.Font.mono(12))
                            .foregroundStyle(Tokens.Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow("Next")
                Text("No session planned")
                    .font(Tokens.Font.ui(16, .semibold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
            }
        }
    }

    @ViewBuilder private func coach(_ line: WidgetSnapshot.CoachLine?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let line {
                Eyebrow("Coach · \(line.day.formatted(.dateTime.weekday(.abbreviated)))")
                Text(line.text)
                    .font(Tokens.Font.ui(13))
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(3)
            } else {
                Eyebrow("Coach")
                Text("Your coach's read lands here after your next run.")
                    .font(Tokens.Font.ui(13))
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .lineLimit(2)
            }
        }
    }
}

// MARK: - Shared pieces

/// `SectionLabel` from the app's design system, which lives in `Components.swift` and drags
/// the whole component library with it — this is the one piece the widgets need.
private struct Eyebrow: View {
    let text: String
    var color: Color = Tokens.Palette.textTertiary

    init(_ text: String, color: Color = Tokens.Palette.textTertiary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(Tokens.Font.mono(10))
            .tracking(1.2)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// The honest empty/stale state: no numbers, one instruction.
private struct NeedsApp: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow("Tempo", color: Tokens.Palette.accentText)
            Spacer(minLength: 0)
            Text(title)
                .font(Tokens.Font.ui(15, .semibold))
                .foregroundStyle(Tokens.Palette.textPrimary)
            Text(detail)
                .font(Tokens.Font.ui(12))
                .foregroundStyle(Tokens.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private enum Fmt {
    /// One decimal, matching Today's "This week" card — the numbers are meant to be checked
    /// against each other.
    static func miles(_ m: Double) -> String { String(format: "%.1f", m) }

    /// For the 40-point circle: whole miles once there's no room for the decimal.
    static func milesShort(_ m: Double) -> String { m >= 100 ? String(format: "%.0f", m) : String(format: "%.1f", m) }

    /// "6.0 mi · 8:30 /mi", or the session's detail line when it has no numbers.
    static func target(_ s: WidgetSnapshot.Session) -> String? {
        var parts: [String] = []
        if let miles = s.targetMiles { parts.append(String(format: "%.1f mi", miles)) }
        if let pace = s.targetPaceSec { parts.append(String(format: "%d:%02d /mi", pace / 60, pace % 60)) }
        return parts.isEmpty ? s.detail : parts.joined(separator: " · ")
    }
}

// MARK: - Sample (gallery + previews)

extension WidgetSnapshot {
    static func sample(now: Date = .now) -> WidgetSnapshot {
        let cal = weekCalendar
        let today = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today) ?? today
        return WidgetSnapshot(
            generatedAt: now,
            weekStart: cal.dateInterval(of: .weekOfYear, for: now)?.start ?? today,
            dayMiles: [5.1, 0, 8.0, 6.2, 0, 0, 0],
            lastWeekMiles: 34.6,
            weekTargetMiles: 40,
            nextWeekTargetMiles: 42,
            upcoming: [Session(day: tomorrow, type: "threshold", title: "Threshold repeats",
                               targetMiles: 7, targetPaceSec: 425, detail: "3×1 mi @ 7:05")],
            coach: CoachLine(text: "Even splits on a warm morning — that's the aerobic base showing. Keep tomorrow honest at threshold, not faster.", day: today)
        )
    }
}

#Preview("Week", as: .systemSmall) {
    WeekWidget()
} timeline: {
    TempoEntry(date: .now, display: WidgetSnapshot.display(.sample(), at: .now))
    TempoEntry(date: .now, display: .stale(asOf: .now.addingTimeInterval(-40 * 3600)))
}

#Preview("Coach", as: .systemMedium) {
    CoachWidget()
} timeline: {
    TempoEntry(date: .now, display: WidgetSnapshot.display(.sample(), at: .now))
}

#Preview("Lock", as: .accessoryRectangular) {
    WeekWidget()
} timeline: {
    TempoEntry(date: .now, display: WidgetSnapshot.display(.sample(), at: .now))
}
