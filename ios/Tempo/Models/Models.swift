import Foundation

/// Codable models mirroring the Supabase schema (see supabase/migrations/0001_init.sql).
/// Read models decode snake_case columns; insert models encode them directly.

// MARK: - Run (a completed activity)

struct Run: Codable, Identifiable, Hashable {
    let id: UUID
    let startTime: Date
    let distanceM: Int
    let durationS: Int
    let avgPaceSec: Int?
    let avgHr: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case startTime = "start_time"
        case distanceM = "distance_m"
        case durationS = "duration_s"
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
    let duration_s: Int
    let avg_pace_sec: Int?
    let avg_hr: Int?
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
    let healthConnected: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, units
        case coachVoice = "coach_voice"
        case healthConnected = "health_connected"
    }
}
