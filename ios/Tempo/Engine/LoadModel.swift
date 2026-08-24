import Foundation

/// Training-load model — the deterministic math behind readiness.
///
/// Each run scores load = miles × intensity², where intensity is the run's pace
/// relative to the athlete's own recent baseline (their median pace — so the model
/// is self-calibrating and works without HR). Two exponential moving averages:
///   CTL (fitness, 42-day) — what you've built
///   ATL (fatigue,  7-day) — what you're carrying
///   Form = CTL − ATL      — what you can spend today
struct FitnessMetrics {
    let readiness: Int          // 0–100
    let ctl: Double
    let atl: Double
    var form: Double { ctl - atl }
    let ctlSeries: [(date: Date, ctl: Double)]   // trailing ~8 weeks, oldest first

    var label: String {
        switch readiness {
        case 70...: return "Primed"
        case 55..<70: return "Ready"
        case 40..<55: return "Loaded"
        default: return "Run easy"
        }
    }

    var caption: String {
        switch readiness {
        case 70...: return "Fresh and fit — green light for quality."
        case 55..<70: return "Solid to train. Quality is fine; respect the paces."
        case 40..<55: return "You're carrying load. Easy miles serve you best today."
        default: return "Fatigue outweighs fitness right now — recovery IS the workout."
        }
    }
}

enum LoadModel {

    /// Compute current metrics from real runs. `checkInOK == false` caps readiness —
    /// the athlete's own report outranks the math.
    static func compute(runs: [RunSummary], checkInOK: Bool?, now: Date = .now) -> FitnessMetrics? {
        guard !runs.isEmpty else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let horizon = 120          // days of history feeding the EWMAs
        guard let windowStart = cal.date(byAdding: .day, value: -horizon, to: today) else { return nil }

        // Self-calibrating intensity baseline: median pace of the last 60 days.
        let recent = runs.filter { $0.start >= (cal.date(byAdding: .day, value: -60, to: today) ?? today) }
        let paces = (recent.isEmpty ? runs : recent).compactMap(\.paceSecPerMile).sorted()
        guard !paces.isEmpty else { return nil }
        let baseline = Double(paces[paces.count / 2])

        // Daily load buckets.
        var daily: [Date: Double] = [:]
        for run in runs where run.start >= windowStart {
            guard let pace = run.paceSecPerMile, pace > 0 else { continue }
            let intensity = baseline / Double(pace)
            let load = run.miles * intensity * intensity
            let day = cal.startOfDay(for: run.start)
            daily[day, default: 0] += load
        }

        // EWMAs, day by day.
        let kCTL = 1.0 / 42.0
        let kATL = 1.0 / 7.0
        var ctl = 0.0, atl = 0.0
        var series: [(Date, Double)] = []
        var day = windowStart
        while day <= today {
            let load = daily[day] ?? 0
            ctl += (load - ctl) * kCTL
            atl += (load - atl) * kATL
            series.append((day, ctl))
            day = cal.date(byAdding: .day, value: 1, to: day) ?? today.addingTimeInterval(1)
        }

        // Readiness: form relative to fitness, centered at 55.
        let formPct = (ctl - atl) / max(ctl, 0.5)
        var readiness = Int((55 + formPct * 90).rounded())
        if checkInOK == false { readiness = min(readiness, 40) }   // athlete's word wins
        readiness = min(max(readiness, 5), 98)

        return FitnessMetrics(
            readiness: readiness,
            ctl: ctl,
            atl: atl,
            ctlSeries: Array(series.suffix(56)).map { (date: $0.0, ctl: $0.1) }
        )
    }
}
