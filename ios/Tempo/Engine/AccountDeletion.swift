import Foundation

/// Deleting the account, and what has to be true before the phone lets go of it.
///
/// App Review 5.1.1(v): an app that creates an account offers deletion of that account from
/// inside the app. Tempo's accounts are anonymous and made on first launch, so there is no
/// support flow to fall back on and no way to prove ownership later: whoever is holding the
/// phone is the account. The server half is the `delete-account` edge function.
///
/// The rule encoded here: *the phone forgets only what the server confirmed it deleted.*
/// A sign-out on the back of a failed call would be the worst outcome available. The rows
/// would still be on the server, the anonymous session that was the only way to reach them
/// would be gone, and the screen would have said "deleted".
enum AccountDeletion {

    /// What came back. There is no partial case on purpose: the function returns 200 only
    /// when the photos went and the auth user went, so the app has two states to handle.
    enum Outcome: Equatable {
        case deleted
        case failed
    }

    /// Reads the function's reply. `deleted: true` and nothing else is a deletion.
    ///
    /// A 200 with a missing or false flag is a failure here rather than a success with a
    /// shrug: a body that doesn't say what this one says came from something other than the
    /// function we asked, and guessing in this direction loses an athlete's data.
    static func outcome(deleted: Bool?) -> Outcome {
        deleted == true ? .deleted : .failed
    }

    /// May the phone drop the session and wipe its local copies? Only on a confirmed delete.
    static func mayForget(_ outcome: Outcome) -> Bool {
        outcome == .deleted
    }

    /// Every `UserDefaults` key this phone holds under one account's id.
    ///
    /// Cleared on deletion because the next anonymous account on this phone is a different
    /// person as far as Tempo is concerned, and inheriting the last one's answer about
    /// sending data to Anthropic would be consent nobody gave.
    static func localKeys(uid: String) -> [String] {
        [CoachConsent.defaultsKey(uid: uid)]
    }

    /// The keys with no account id in them that still describe one account's training: which
    /// shoes it runs in, when it wants a nudge to replace them, and the last count of its
    /// unexplained sync drops, which the next account's telemetry would report as its own.
    ///
    /// Voice cues and auto-pause are not here. Those are how the phone behaves, and nobody
    /// who deletes their account expects their settings for the next run to start talking.
    static let unscopedKeys = [
        ShoeStore.defaultShoeKey,
        ShoeStore.retirementMilesKey,
        HealthService.unexplainedDropsKey,
    ]

    // MARK: - Work that outlives the account

    /// The account the app is signed in as, given the session in the Keychain and the accounts
    /// this process has seen deleted.
    ///
    /// The session outlives the account by the length of a local sign-out, and a retry or a
    /// sync that wakes in that gap must not find a user to write for.
    static func signedIn(stored: UUID?, deleted: Set<UUID>) -> UUID? {
        stored.flatMap { deleted.contains($0) ? nil : $0 }
    }

    /// May work that began for `owner` still act?
    ///
    /// The app carries on in the same process as a new athlete, and a sync, a photo upload
    /// between retries or a coach reply can come back after that. Most late writes are refused
    /// by RLS because they name the old user. The ones that aren't are those that read the
    /// user late, and they would file the old account's words under the new one.
    static func mayContinue(owner: UUID?, current: UUID?) -> Bool {
        owner == current
    }

    // MARK: - A deletion whose answer was lost

    /// A deletion the athlete asked for, on disk until the server has settled it.
    ///
    /// Without it a lost reply strands them: the next launch finds a working session, no
    /// profile behind it, and onboards a user who no longer exists.
    struct Asked: Codable, Equatable {
        let uid: UUID
        let at: Date
    }

    static let askedKey = "account.deletionAsked"

    enum Recheck: Equatable {
        /// Nothing was asked, or nobody is signed in to ask about.
        case none
        /// This account was asked to go, and no answer arrived. Find out.
        case ask(Asked)
        /// It was about an account this phone no longer holds a session for. Nothing can be
        /// asked on its behalf, and it says nothing about the one signed in now.
        case stale
    }

    static func recheck(_ asked: Asked?, current: UUID?) -> Recheck {
        guard let asked, let current else { return .none }
        return asked.uid == current ? .ask(asked) : .stale
    }

    /// What the auth server says about the account this phone holds a session for.
    enum Standing: Equatable {
        case exists
        case gone
        /// Offline, timed out, expired, refused. Not an answer either way.
        case unknown
    }

    /// Reads an auth error. `user_not_found` is sent only for a token whose signature and
    /// expiry have already been checked (see `resolveCaller` in `delete-account`), so an
    /// expired or malformed token, a revoked session and an outage are all `.unknown`.
    static func standing(authErrorCode: String?) -> Standing {
        authErrorCode == "user_not_found" ? .gone : .unknown
    }

    enum Settle: Equatable {
        /// Ask `delete-account` to confirm. Safe to call without a tap, because there is no
        /// account left for it to delete, and only its answer lets the phone forget.
        case confirm
        /// Launch as usual and look again next time.
        case keepAsking
        /// The account is there and the request has had time to finish. The deletion did not
        /// happen, and it is not repeated unless the athlete asks again.
        case drop
    }

    /// How long a request may still be running on the server after the phone lost it. Longer
    /// than an edge function is allowed to live.
    static let mayStillBeRunning: TimeInterval = 10 * 60

    /// Never `.confirm` for an account that exists or might: asking is how a deletion starts,
    /// and an athlete who saw it fail and kept their account has not asked again.
    static func settle(_ asked: Asked, standing: Standing, now: Date) -> Settle {
        switch standing {
        case .gone: return .confirm
        case .unknown: return .keepAsking
        case .exists: return now.timeIntervalSince(asked.at) < mayStillBeRunning ? .keepAsking : .drop
        }
    }

    enum Copy {
        /// The row on the You tab, and the sheet's title. The same words, so the sheet is
        /// plainly the thing that was tapped.
        static let title = "Delete my account and data"

        /// Named one by one rather than "all your data": the point of the sentence is that
        /// the athlete can tell what goes. Apple Health is called out because Tempo writes
        /// recorded runs there, it is the one store this cannot and must not touch, and
        /// "delete everything" would otherwise read as covering it.
        static let body = "This deletes your Tempo account, your plan, coach conversations, corrections and photos from our server. Your runs in Apple Health stay where they are. This can't be undone."

        static let confirm = "Delete everything"
        static let cancel = "Keep my account"
        static let working = "Deleting\u{2026}"

        /// Shown when no confirmation came back. It used to say that nothing was deleted, which
        /// was not always so: photos go before the account, and a reply that times out says
        /// nothing about what the server did. This is true in every case, including the one
        /// where everything is already gone.
        static let failure = "Tempo couldn't confirm that your account was deleted. Some or all of your data may already be gone. Check your connection and try again to finish, or email david@delight.studio."
    }
}
