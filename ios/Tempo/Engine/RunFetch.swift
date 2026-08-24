import Foundation

/// What the read path is allowed to put on screen when Supabase doesn't answer.
///
/// Supabase `runs` outranks HealthKit because it carries the corrections the athlete made
/// through the coach — "that was 8.0, not 7.6". HealthKit still holds the raw numbers those
/// corrections overwrote. The two copies therefore disagree *by design*, and which one is on
/// screen is a fact the athlete has to be told.
///
/// Until this file existed the read path used `try?`, so a failed fetch and an empty table
/// were the same value (`nil`) and the fallback quietly swapped the corrected view for the
/// raw one. A network blip could revert a corrected 8.0 back to 7.6 with no crash and no
/// signal — the same shape as the 2026-08-23 splash freeze, where "couldn't ask" and
/// "nothing there" were also indistinguishable.
///
/// Two rules are encoded here, both pinned by tests:
///
///  1. **A failure never silently replaces corrected numbers with raw ones.** The last
///     corrected set we already hold outranks a fresh HealthKit copy.
///  2. **Anything other than a clean read is announced.** `warning` is non-nil whenever what
///     is on screen is not the corrected record.
///
/// Pure and deterministic so the rules can be pinned without a fake Supabase.
enum RunFetch {

    /// What a read of Supabase `runs` came back with.
    enum Response: Equatable {
        /// The server answered; these rows are the corrected record.
        case rows([RunSummary])

        /// The server answered once, but the re-read after inserting freshly synced runs
        /// failed. These rows are real yet known to be short of the truth.
        case incomplete([RunSummary])

        /// The server never answered.
        case unreachable

        /// The rows we hold, if the server answered at all.
        var knownRows: [RunSummary]? {
            switch self {
            case .rows(let rows), .incomplete(let rows): return rows
            case .unreachable:                           return nil
            }
        }
    }

    /// How far what's on screen is from the corrected record.
    enum Freshness: Equatable {
        case current          // Supabase answered: these are the corrected numbers
        case missingRecent    // just-synced runs are showing as raw Health copies
        case stale            // no answer; still showing the last set we loaded
        case uncorrected      // no answer; showing raw Health numbers instead
    }

    enum Availability: Equatable {
        case ready, empty, unavailable
    }

    struct Decision: Equatable {
        /// The set to display, or `nil` to leave what's already on screen alone — the
        /// difference between "here is the truth" and "I have nothing better than what
        /// you're already looking at".
        let runs: [RunSummary]?
        let availability: Availability
        let freshness: Freshness

        /// One line for the athlete, or nil when the corrected record is on screen.
        var warning: String? {
            switch freshness {
            case .current:       return nil
            case .missingRecent: return Copy.missingRecent
            case .uncorrected:   return Copy.uncorrected
            case .stale:         return availability == .unavailable ? Copy.nothing : Copy.stale
            }
        }
    }

    /// The whole display decision, as a pure function of what the two data sources said.
    ///
    /// - Parameters:
    ///   - response: what Supabase came back with.
    ///   - ingested: this refresh's HealthKit read — raw, uncorrected.
    ///   - onScreen: what the athlete is currently looking at (loaded from Supabase on an
    ///     earlier refresh, so it carries corrections).
    static func resolve(
        _ response: Response,
        ingested: [RunSummary],
        onScreen: [RunSummary]
    ) -> Decision {
        switch response {
        case .rows(let rows):
            return Decision(
                runs: rows,
                availability: rows.isEmpty ? .empty : .ready,
                freshness: .current
            )

        case .incomplete(let rows):
            // We inserted runs and then couldn't read them back. Graft on the HealthKit
            // copies of exactly what's missing rather than hiding runs the athlete just
            // finished — they're raw, but a brand-new run has nothing to correct yet.
            let missing = RunDedupe.newRuns(from: ingested, existing: rows)
            let merged = (rows + missing).sorted { $0.start > $1.start }
            return Decision(
                runs: merged,
                availability: merged.isEmpty ? .empty : .ready,
                freshness: missing.isEmpty ? .current : .missingRecent
            )

        case .unreachable:
            // Rule 1. What's already on screen came from Supabase, so it carries the
            // athlete's corrections; a fresh HealthKit read does not. Keeping the older
            // corrected set beats swapping in newer wrong numbers.
            if !onScreen.isEmpty {
                return Decision(runs: nil, availability: .ready, freshness: .stale)
            }
            if !ingested.isEmpty {
                return Decision(runs: ingested, availability: .ready, freshness: .uncorrected)
            }
            return Decision(runs: nil, availability: .unavailable, freshness: .stale)
        }
    }

    enum Copy {
        static let stale =
            "Couldn't reach the server — showing your last synced runs. Pull to refresh."
        static let uncorrected =
            "Couldn't reach the server — showing raw Apple Health numbers, so any corrections you've made aren't applied."
        static let missingRecent =
            "Your newest runs are showing raw Apple Health numbers — the server didn't answer the re-read."
        static let nothing =
            "Couldn't reach the server, and there's nothing in Apple Health to fall back on."
        static let editNotReflected =
            "Your change was saved, but the run list couldn't refresh. Pull to refresh."
    }
}

extension RunFetch {

    /// The cached coach takeaway for a completed run.
    ///
    /// Same conflation, different cost: `try?` here made "no takeaway written yet" and
    /// "couldn't read the column" identical, so every failed read kicked off a fresh
    /// generation — a Claude call spent to re-derive something that may already exist.
    enum Takeaway: Equatable {
        case cached(String)
        case notGenerated    // read succeeded, the column is empty
        case unreadable      // the read itself failed

        var text: String? {
            if case .cached(let takeaway) = self { return takeaway }
            return nil
        }

        /// Only a *successful* read that found nothing justifies spending a Claude call.
        var shouldGenerate: Bool { self == .notGenerated }
    }
}
