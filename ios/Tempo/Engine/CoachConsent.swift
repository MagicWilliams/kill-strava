import Foundation

/// Whether any of this athlete's data may go to Anthropic's Claude.
///
/// App Review guideline 5.1.2(i): an app must "clearly disclose where personal data will be
/// shared with third parties, including with third-party AI, and obtain explicit permission
/// before doing so". Tempo reads HealthKit, and its coach and plan functions both call Claude,
/// so the answer has to exist before the first request does.
///
/// The rule encoded here: *only a decision the athlete actually made can open the gate.*
/// Not knowing is a no. A read that failed, a session that hasn't loaded, an unrecognised
/// value in the column: none of them are consent, and none of them send.
///
/// `CoachGateway` is the only caller that enforces this, and it is the only path to the edge
/// functions. Screens read the same status to explain themselves, never to decide.
enum CoachConsent {
    enum Decision: String, Codable, Equatable {
        case agreed
        case declined
    }

    /// One decision and when it was made. The time is what settles a disagreement between
    /// the phone and the server: see `resolve`.
    struct Record: Codable, Equatable {
        let decision: Decision
        let at: Date
    }

    enum Status: Equatable {
        /// Not loaded yet, or nothing could be read. Never prompts: someone who has already
        /// answered must not be asked again because of a dropped connection.
        case unknown
        /// Asked nothing, answered nothing. The one state that shows the consent screen.
        case undecided
        case agreed
        case declined
    }

    /// May this send? The whole gate.
    static func maySend(_ status: Status) -> Bool {
        status == .agreed
    }

    /// Whether the athlete still owes an answer. A decline is an answer, so it is asked once:
    /// after that the coach's screens explain themselves and offer the way back.
    static func shouldPrompt(_ status: Status) -> Bool {
        status == .undecided
    }

    /// What reading `profiles.coach_consent` came back with.
    enum ServerRead: Equatable {
        /// The columns exist. Nil means they are empty: this athlete has never answered.
        case record(Record?)
        /// Migration 0024 isn't applied yet, so the phone's copy is all there is.
        case columnMissing
        /// The read failed. It says nothing about what the athlete decided.
        case unreadable
    }

    struct Resolution: Equatable {
        let status: Status
        /// The decision in force, for the phone to keep a copy of. Nil when there isn't one.
        let record: Record?
        /// A decision the server doesn't hold yet, to write back. It gets there either way:
        /// made before the migration, or while the write couldn't reach the server.
        let upload: Record?
    }

    /// Settle the phone's copy and the server's into one status.
    ///
    /// Both exist because each covers a hole in the other. The phone's copy works before
    /// migration 0024 is applied and through a failed write. The server's survives a reinstall,
    /// which empties UserDefaults while the anonymous session lives on in the Keychain.
    ///
    /// Newest wins, so withdrawing consent offline can't be undone by an older "agreed" on the
    /// server. A tie between two different answers resolves to the decline: this is the one
    /// place a coin toss must not land on sending.
    static func resolve(server: ServerRead, local: Record?) -> Resolution {
        switch server {
        case .columnMissing:
            return Resolution(status: local.map(status(of:)) ?? .undecided, record: local, upload: nil)
        case .unreadable:
            return Resolution(status: local.map(status(of:)) ?? .unknown, record: local, upload: nil)
        case .record(let held):
            guard let local else {
                return Resolution(status: held.map(status(of:)) ?? .undecided, record: held, upload: nil)
            }
            guard let held else {
                return Resolution(status: status(of: local), record: local, upload: local)
            }
            // The same answer on both sides needs nothing written. Compared before the dates
            // because the phone's copy can keep sub-second precision the column's string lost,
            // and that alone must not re-upload the decision on every launch.
            if held.decision == local.decision {
                return Resolution(status: status(of: held), record: held, upload: nil)
            }
            if local.at == held.at {
                let declined = local.decision == .declined ? local : held
                return Resolution(status: .declined, record: declined, upload: declined == local ? local : nil)
            }
            return local.at > held.at
                ? Resolution(status: status(of: local), record: local, upload: local)
                : Resolution(status: status(of: held), record: held, upload: nil)
        }
    }

    /// The columns as a record. A half-filled pair or an unrecognised value is not a decision.
    static func record(decision: String?, at: Date?) -> Record? {
        guard let decision = decision.flatMap(Decision.init(rawValue:)), let at else { return nil }
        return Record(decision: decision, at: at)
    }

    private static func status(of record: Record) -> Status {
        record.decision == .agreed ? .agreed : .declined
    }

    /// Published from `site/privacy.html` (#250). The screen and the policy describe the
    /// same flow, and PRD-02 rule 5 holds both to it: if what the coach is sent changes, the
    /// lists below and that page get reviewed together. `CoachConsentTests` pins the part of
    /// the promise a scan can check.
    static let privacyPolicy = URL(string: "https://magicwilliams.github.io/kill-strava/privacy.html")!

    enum Copy {
        static let title = "Your coach runs on Claude"
        static let lead = "Tempo's coach is written by Claude, an AI made by Anthropic, a separate company. To reply, it needs some of your data, so Tempo asks first. Nothing goes to Anthropic unless you agree."

        static let sentHeading = "What Tempo sends to Anthropic"
        /// Wider than "messages, plan, goals, notes", because the payloads are. Each line maps
        /// to `CoachContext`, the takeaway's `RunPayload`, the block review's `CoachBlock`, or
        /// the feature summary `plan` builds on the server.
        static let sent = [
            "Your messages to the coach and your recent conversation",
            "Run summaries: date, distance, pace, heart rate, effort, splits, cadence and elevation",
            "Your plan, goals, training settings, fitness numbers and best times",
            "Your journal and check-in notes, and what you've told the coach, like an injury, your birthdate or your max heart rate",
        ]

        static let notSentHeading = "What stays out"
        static let notSent = [
            "Your GPS routes",
            "Second-by-second health samples from Apple Health",
            "Your run photos",
        ]

        static let purpose = "Anthropic uses this to write the coach's replies and run reads."
        static let decline = "If you say no, your runs, history and the recorder all still work. Only the coach stays off, and you can change your mind on the You tab."
        static let policyLink = "Read the privacy policy"

        static let agree = "Agree and turn on coach"
        static let dontShare = "Don't share"

        static let sharingOn = "You've agreed. The coach is on."
        static let keepSharing = "Keep sharing"
        static let stopSharing = "Stop sharing"

        /// The notice on every coach surface while the gate is shut. Says why the coach isn't
        /// answering, because "Couldn't reach the coach" would be a lie about a working server.
        static let offLabel = "Coach is off"
        static let off = "The coach needs your OK to send your data to Anthropic's Claude. Your runs, history and the recorder work without it."
        static let unconfirmed = "Tempo couldn't confirm your choice about sending your data to Anthropic's Claude, so the coach stays off until it can."
        static let review = "Review and agree"

        /// Under a card that needed the plan engine, which is a Claude call too.
        static let planNeedsConsent = "Building a plan uses the coach, which is off. Turn it on from the You tab, then Confirm to retry."

        static func notice(for status: Status) -> String {
            status == .unknown ? unconfirmed : off
        }
    }
}
