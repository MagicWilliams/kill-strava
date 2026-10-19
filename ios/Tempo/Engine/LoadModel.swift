import Foundation

/// Training-load model — the deterministic math behind readiness.
///
/// Each run scores load = miles × intensity², where intensity is the run's pace
/// relative to the athlete's own recent baseline (their median pace — so the model
/// is self-calibrating and works without HR). A run the athlete rated scores his RPE
/// instead, in the same units — see `LoadModel.load(of:baseline:)`. Two exponential
/// moving averages:
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

    /// The ceiling the athlete's own word puts on readiness. Named because two separate
    /// reports now impose it — a negative check-in and a body report at or above
    /// `BodyReports.capSeverity` (#89) — and because the body card quotes the number back
    /// to the athlete.
    static let reportedCap = 40

    /// Compute current metrics from real runs. `checkInOK == false` caps readiness, and so
    /// does a live body report the athlete rated at `BodyReports.capSeverity` or worse — the
    /// athlete's own report outranks the math, whichever way they gave it.
    ///
    /// `bodyReports` defaults to none so the 2,000-run history and every test that predates
    /// #89 keep calling this unchanged; which of them count is decided in
    /// `BodyReports.capsReadiness`, not here.
    static func compute(
        runs: [RunSummary],
        checkInOK: Bool?,
        bodyReports: [BodyReport] = [],
        now: Date = .now
    ) -> FitnessMetrics? {
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
            guard let load = load(of: run, baseline: baseline) else { continue }
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
        // The athlete's word wins — said as a check-in or as a body report (#89). One cap,
        // not two: a bad check-in and a 7/10 calf on the same day is one athlete saying the
        // same thing twice, and stacking them would put readiness below what either means.
        if checkInOK == false || BodyReports.capsReadiness(bodyReports) {
            readiness = min(readiness, reportedCap)
        }
        readiness = min(max(readiness, 5), 98)

        return FitnessMetrics(
            readiness: readiness,
            ctl: ctl,
            atl: atl,
            ctlSeries: Array(series.suffix(56)).map { (date: $0.0, ctl: $0.1) }
        )
    }

    // MARK: - One run's load

    /// The RPE a run at the athlete's median pace is taken to carry. It sets the exchange
    /// rate between the two scores, and 4 is where they agree on the sessions that make up
    /// most weeks: an easy run ~8 % slower than the median scores ~0.86 per mile by pace
    /// and 3/4 × 1.08 ≈ 0.81 by RPE 3; a threshold run ~15 % faster scores ~1.38 by pace
    /// and 7/4 × 0.85 ≈ 1.49 by RPE 7. So a block that switches from pace to RPE scoring
    /// mid-way doesn't put a step into the CTL chart. It is a calibration, not a fact
    /// about the athlete — if his logged RPEs run consistently high or low against his
    /// paces, this is the number to move.
    static let referenceRPE = 4.0

    /// One run's contribution to the day's load, in miles-at-median-pace — or nil when the
    /// run can't be scored at all and is skipped, as it always was.
    ///
    /// **With an RPE (#123): session-RPE load.** Foster's session RPE — effort × minutes —
    /// is a validated training-load measure that needs no heart rate, which is the point:
    /// Garmin's HR doesn't reliably reach us, and pace alone reads a hot, sick, or
    /// heavy-legged 8:30 as the same 8:30 as a fresh one. The athlete's own number does
    /// not. It is put in the pace model's units so the two can share one EWMA:
    ///
    ///     load = (rpe / referenceRPE) × (moving seconds / baseline sec-per-mile)
    ///          = rpe × minutes / (referenceRPE × baseline minutes-per-mile)
    ///
    /// i.e. the miles the session's time would have covered at the median pace, scaled by
    /// how hard he said it was. Moving time, like every other clock in the model. It needs
    /// no distance, so an RPE'd treadmill run with no distance now counts where it was
    /// skipped before.
    ///
    /// **Without one: pace load, unchanged.** miles × intensity², intensity = baseline /
    /// pace. The expression is kept exactly as it was — same operands, same order — because
    /// the 2,000+ runs that predate the journal never get an RPE and their numbers are
    /// pinned bit-for-bit (`LoadModelRPETests`).
    ///
    /// **The blend is per run, not per day.** Each run is scored one way or the other and
    /// both land in the same daily bucket, so a history that is mostly pace-scored with
    /// RPE'd runs arriving from the recorder needs no switch-over: the RPE'd ones simply
    /// count what he said they cost. RPE replaces the pace score for that run rather than
    /// averaging with it — averaging would dilute exactly the disagreement (an easy pace
    /// that felt like a 9) that makes RPE worth asking for.
    ///
    /// An RPE outside 1–10 is ignored rather than clamped (the database refuses one, so it
    /// can only come from a bad decode), and the run falls back to its pace score.
    static func load(of run: RunSummary, baseline: Double) -> Double? {
        if let rpe = run.journal.rpe, (1...10).contains(rpe), run.durationS > 0 {
            return Double(rpe) / referenceRPE * (Double(run.durationS) / baseline)
        }
        guard let pace = run.paceSecPerMile, pace > 0 else { return nil }
        let intensity = baseline / Double(pace)
        return run.miles * intensity * intensity
    }
}
