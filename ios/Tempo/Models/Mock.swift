import Foundation

/// Placeholder data so the shell renders before HealthKit + Supabase are wired.
/// Paces come from the real engine so the UI matches what we'll ship.
struct PlannedSession {
    let title: String
    let detail: String
}

enum Mock {
    /// sub-3:15 marathon reference athlete.
    static let paces = PaceModel.paces(for: .marathon, goalSeconds: 11_700)

    static let today = PlannedSession(
        title: "Tempo intervals",
        detail: "3×1 mi @ \(PaceModel.format(paces.threshold)) with 2:00 jog"
    )

    // (title, subtitle, mileage)
    static let planWeeks: [(String, String, String)] = [
        ("Week 4 · Base", "First 14-mi long run", "30 mi"),
        ("Week 5 · Base", "Step-back week", "24 mi"),
        ("Week 6 · Build", "Threshold work begins", "34 mi"),
    ]

    // (text, isUser)
    static let coach: [(String, Bool)] = [
        ("Morning, David. Yesterday's easy 5 looked smooth. How are the legs?", false),
        ("Feeling good, slept well.", true),
        ("Good — today's the key session. Warm up easy, then settle the reps at \(PaceModel.format(paces.threshold)). Not faster.", false),
    ]
}
