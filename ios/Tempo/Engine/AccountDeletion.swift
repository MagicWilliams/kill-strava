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

    /// Every `UserDefaults` key this phone holds for one account.
    ///
    /// Cleared on deletion because the next anonymous account on this phone is a different
    /// person as far as Tempo is concerned, and inheriting the last one's answer about
    /// sending data to Anthropic would be consent nobody gave.
    static func localKeys(uid: String) -> [String] {
        [CoachConsent.defaultsKey(uid: uid)]
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

        /// Shown in place of a result when the call failed. Says that nothing was deleted,
        /// because the reading to rule out is "it half worked".
        static let failure = "Tempo couldn't delete your account just now. Nothing was deleted, and your data is still here. Check your connection and try again."
    }
}
