import Foundation

/// Codable models mirroring the Supabase schema (see supabase/migrations/0001_init.sql).
/// Read models decode snake_case columns; insert models encode them directly.

// MARK: - Run (a completed activity)

struct Run: Codable, Identifiable, Hashable {
    let id: UUID
    let startTime: Date
    /// Moving time — see `TimeAccounting`. Everything that computes on a run uses this.
    let durationS: Int
    /// Wall clock, when known. Additive: nil for every run ingested before migration 0009.
    let elapsedDurationS: Int?
    let distanceM: Int
    let avgPaceSec: Int?
    let avgHr: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case startTime = "start_time"
        case distanceM = "distance_m"
        case durationS = "duration_s"
        case elapsedDurationS = "elapsed_duration_s"
        case avgPaceSec = "avg_pace_sec"
        case avgHr = "avg_hr"
    }

    /// Distance in miles.
    var miles: Double { Double(distanceM) / 1609.34 }
}

/// What we write when ingesting a run from HealthKit. The DB fills id/created_at;
/// `(user_id, source, external_id)` is unique so re-ingesting is an idempotent upsert.
struct RunInsert: Encodable {
    let user_id: String
    let source: String
    let external_id: String
    let start_time: Date
    let distance_m: Int
    let duration_s: Int             // moving time
    let elapsed_duration_s: Int?    // wall clock; nil when the source didn't say
    let avg_pace_sec: Int?
    let avg_hr: Int?
}

// MARK: - RunSummary (a run as read from HealthKit)

/// A completed run. Read path is Supabase `runs` (source of truth — carries user
/// corrections); HealthKit-shaped instances exist only for ingest + offline fallback.
struct RunSummary: Identifiable, Hashable {
    let id: UUID          // Supabase row id (or HKWorkout uuid on the ingest/fallback path)
    let start: Date
    let distanceM: Int
    /// **Moving time.** The default clock everywhere — labels, pace, load, records.
    /// See `TimeAccounting` for why a run carries two of these.
    let durationS: Int
    /// Wall clock start→finish, when the source recorded it. `var` for the same reason
    /// `avgHR` is: the sync backfills it onto rows that predate migration 0009.
    var elapsedS: Int? = nil
    var avgHR: Int?       // var: HR backfill fills it in when Garmin didn't associate samples
    var corrected: Bool = false
    var source: String = "healthkit"
    var externalID: String? = nil   // HKWorkout uuid for healthkit rows → detail-series lookup

    var miles: Double { Double(distanceM) / 1609.34 }

    /// Pace over **moving** time. This is the pace on every label and in every record;
    /// the elapsed-time pace lives on the detail page and nowhere else.
    var paceSecPerMile: Int? { TimeAccounting.paceSecPerMile(seconds: durationS, miles: miles) }

    /// Both clocks, invariants enforced. Falls back to a stopless run when elapsed is unknown.
    var clocks: TimeAccounting.Clocks {
        TimeAccounting.resolve(movingS: durationS, elapsedS: elapsedS)
    }

    /// "5.1 mi · 9:10 /mi · 138 bpm" (drops what's unknown).
    /// The pace here is deliberately the moving pace — see `paceSecPerMile`.
    var metricsLine: String {
        var parts = [String(format: "%.1f mi", miles)]
        if let pace = paceSecPerMile { parts.append(PaceModel.format(pace) + " /mi") }
        if let hr = avgHR { parts.append("\(hr) bpm") }
        return parts.joined(separator: " · ")
    }
}

/// One training week's aggregate (Mon–Sun).
struct WeekSummary: Identifiable {
    let weekStart: Date
    let miles: Double
    let runCount: Int
    let durationS: Int
    var id: Date { weekStart }
}

// MARK: - Goal

struct Goal: Codable, Identifiable {
    let id: UUID
    let raceName: String?
    let raceDate: Date?
    let distance: String
    let goalTimeSeconds: Int?
    let daysPerWeek: Int

    enum CodingKeys: String, CodingKey {
        case id
        case raceName = "race_name"
        case raceDate = "race_date"
        case distance
        case goalTimeSeconds = "goal_time_seconds"
        case daysPerWeek = "days_per_week"
    }
}

struct GoalInsert: Encodable {
    let user_id: String
    let race_name: String?
    let race_date: String?       // ISO date (yyyy-MM-dd)
    let distance: String
    let goal_time_seconds: Int?
    let days_per_week: Int
    let start_mileage: Double?
}

// MARK: - Profile

struct Profile: Codable, Identifiable {
    let id: UUID
    let name: String?
    let units: String
    let coachVoice: String

    enum CodingKeys: String, CodingKey {
        case id, name, units
        case coachVoice = "coach_voice"
    }
}
