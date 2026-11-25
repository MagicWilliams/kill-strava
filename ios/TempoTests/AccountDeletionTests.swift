import XCTest
@testable import Tempo

/// Deleting an account, the parts a test can hold.
///
/// Written against one failure in particular, which has not happened and must not: the phone
/// signs out and wipes its copies on the strength of a call that did not actually delete
/// anything. Tempo's accounts are anonymous, so the session in the Keychain is the only way
/// back to the rows. Lose it with the rows still there and the data is both undeleted and
/// unreachable, and the screen has already said it is gone.
final class AccountDeletionTests: XCTestCase {

    // MARK: Reading the server's answer

    func testOnlyAnExplicitDeletedFlagCounts() {
        XCTAssertEqual(AccountDeletion.outcome(deleted: true), .deleted)
        XCTAssertEqual(AccountDeletion.outcome(deleted: false), .failed)
        XCTAssertEqual(AccountDeletion.outcome(deleted: nil), .failed, "a body that doesn't say is a no")
    }

    // MARK: What the phone may forget

    func testThePhoneForgetsOnlyAfterAConfirmedDeletion() {
        XCTAssertTrue(AccountDeletion.mayForget(.deleted))
        XCTAssertFalse(AccountDeletion.mayForget(.failed), "a failed call leaves the session alone")
    }

    // MARK: The keys that go with the account

    private let uid = "11111111-2222-4333-8444-555555555555"
    private let other = "99999999-8888-4777-8666-555555555555"

    func testTheConsentAnswerIsErased() {
        // The next anonymous account on this phone is a different person as far as Tempo is
        // concerned. Inheriting this one's yes would be permission nobody gave.
        XCTAssertTrue(AccountDeletion.localKeys(uid: uid).contains(CoachConsent.defaultsKey(uid: uid)))
    }

    func testTheKeysAreScopedToTheAccountBeingDeleted() {
        let mine = Set(AccountDeletion.localKeys(uid: uid))
        let theirs = Set(AccountDeletion.localKeys(uid: other))
        XCTAssertFalse(mine.isEmpty)
        XCTAssertTrue(mine.isDisjoint(with: theirs), "deleting one account must not erase another's")
        for key in mine {
            XCTAssertTrue(key.contains(uid), "\(key) says which account it belongs to")
        }
    }

    func testErasingTheKeysReallyClearsWhatTheStoreWrote() {
        // The store and the eraser have to agree on the spelling. They did not have to
        // before: the key was a literal inside `CoachConsentStore`, and nothing else had a
        // reason to name it.
        let key = CoachConsent.defaultsKey(uid: uid)
        let before = UserDefaults.standard.data(forKey: key)
        defer { UserDefaults.standard.set(before, forKey: key) }

        let record = CoachConsent.Record(decision: .agreed, at: Date(timeIntervalSince1970: 1_000))
        UserDefaults.standard.set(try? JSONEncoder().encode(record), forKey: key)
        XCTAssertNotNil(UserDefaults.standard.data(forKey: key))

        for key in AccountDeletion.localKeys(uid: uid) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        XCTAssertNil(UserDefaults.standard.data(forKey: key), "the answer is gone with the account")
    }

    func testTheUnscopedKeysAreTheOnesWithNoAccountInTheirName() {
        let keys = AccountDeletion.unscopedKeys
        XCTAssertEqual(Set(keys), ["shoes.defaultShoeID", "shoes.retirementMiles",
                                   "sync.dedupeDrops.unknownUUID.lastSeen"])
        // How the phone behaves, not what one account trained.
        XCTAssertFalse(keys.contains(CueSpeaker.enabledKey))
        XCTAssertFalse(keys.contains(PreRun.autoPauseKey))
    }

    // MARK: The run still waiting to upload

    /// A run saved in a dead spot sits on disk with its journal and photo until a refresh can
    /// send it. The relaunch after a deletion ends in exactly that refresh, signed in as someone
    /// new, so the file has to be gone by then.
    @MainActor
    func testTheQueuedRunsAreErasedFromDisk() throws {
        let url = URL.applicationSupportDirectory.appending(path: "recorded-runs-pending.json")
        let before = try? Data(contentsOf: url)
        defer { if let before { try? before.write(to: url) } }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        for contents in ["[]", "not json, and so unreadable to the queue that wrote it"] {
            try Data(contents.utf8).write(to: url)
            RecordedRunSaver.eraseQueue()
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        RecordedRunSaver.eraseQueue()   // an empty queue has no file, and that is not an error
    }

    /// `forgetDeletedAccount` is private I/O, so what a test can hold is that it names every
    /// store on the phone, and that nothing reaches it without a confirmed deletion.
    func testForgettingCoversEveryStoreAndNeedsAConfirmedDeletion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Tempo/Services/RunStore.swift"), encoding: .utf8)

        let start = try XCTUnwrap(source.range(of: "private func forgetDeletedAccount("))
        let end = try XCTUnwrap(source.range(of: "private func forgetLoadedState(", range: start.upperBound..<source.endIndex))
        let body = source[start.upperBound..<end.lowerBound]
        for store in ["RecordedRunSaver.eraseQueue()", "InProgressRunStore.erase()", "CoachConsentStore.shared.forget()",
                      "AccountDeletion.unscopedKeys", "URLCache.shared.removeAllCachedResponses()",
                      "clearWidgetSnapshot()", "forgetLoadedState()"] {
            XCTAssertTrue(body.contains(store), "a deletion must reach \(store)")
        }

        XCTAssertEqual(source.components(separatedBy: "forgetDeletedAccount(uid:").count - 1, 2,
                       "declared once, called once, by leaveDeletedAccount")
        let callers = source.components(separatedBy: "await leaveDeletedAccount(").dropLast()
        XCTAssertEqual(callers.count, 2, "the tap, and the launch that settles a lost reply")
        for before in callers {
            XCTAssertTrue(before.suffix(250).contains("AccountDeletion.mayForget(outcome)"),
                          "the phone forgets only what the server confirmed")
        }
    }

    // MARK: Work that comes back after the account has gone

    private let a = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let b = UUID(uuidString: "99999999-8888-4777-8666-555555555555")!

    func testADeletedAccountIsNotSignedInWhileItsSessionIsStillInTheKeychain() {
        XCTAssertEqual(AccountDeletion.signedIn(stored: a, deleted: []), a)
        XCTAssertNil(AccountDeletion.signedIn(stored: a, deleted: [a]),
                     "the local sign-out takes a moment, and a retry must not find a user in it")
        XCTAssertEqual(AccountDeletion.signedIn(stored: b, deleted: [a]), b, "the next account is untouched")
        XCTAssertNil(AccountDeletion.signedIn(stored: nil, deleted: [a]))
    }

    func testWorkContinuesOnlyForTheAccountItBeganWith() {
        XCTAssertTrue(AccountDeletion.mayContinue(owner: a, current: a))
        XCTAssertFalse(AccountDeletion.mayContinue(owner: a, current: b), "an upload that woke up as someone else")
        XCTAssertFalse(AccountDeletion.mayContinue(owner: a, current: nil), "between the two accounts")
        XCTAssertFalse(AccountDeletion.mayContinue(owner: nil, current: b))
    }

    // MARK: A reply that never arrived

    /// The server deletes the account and the answer is lost. The phone still holds a session
    /// for it, and until that is settled the athlete is stuck: the app launches into onboarding
    /// for a user who does not exist, and every write fails.
    private func asked(_ uid: UUID? = nil, secondsAgo: TimeInterval = 60) -> AccountDeletion.Asked {
        AccountDeletion.Asked(uid: uid ?? a, at: now.addingTimeInterval(-secondsAgo))
    }
    private let now = Date(timeIntervalSince1970: 10_000)

    func testARequestIsOnlyFollowedUpForTheAccountThatMadeIt() {
        XCTAssertEqual(AccountDeletion.recheck(asked(), current: a), .ask(asked()))
        XCTAssertEqual(AccountDeletion.recheck(asked(), current: b), .stale,
                       "one account's request says nothing about another")
        XCTAssertEqual(AccountDeletion.recheck(asked(), current: nil), .none)
        XCTAssertEqual(AccountDeletion.recheck(nil, current: a), .none)
    }

    func testOnlyUserNotFoundMeansTheAccountIsGone() {
        XCTAssertEqual(AccountDeletion.standing(authErrorCode: "user_not_found"), .gone)
        for code in ["bad_jwt", "invalid_jwt", "session_not_found", "session_expired", "refresh_token_not_found",
                     "no_authorization", "user_banned", "over_request_rate_limit", "unexpected_failure",
                     "unknown", ""] {
            XCTAssertEqual(AccountDeletion.standing(authErrorCode: code), .unknown, code)
        }
        XCTAssertEqual(AccountDeletion.standing(authErrorCode: nil), .unknown)
    }

    func testALaunchNeverDeletesAnAccountThatMightExist() {
        // Someone who saw it fail, kept their account and reopened the app has not asked again.
        for seconds in [0, 60, 3_600, 86_400] as [TimeInterval] {
            for standing in [AccountDeletion.Standing.exists, .unknown] {
                XCTAssertNotEqual(AccountDeletion.settle(asked(secondsAgo: seconds), standing: standing, now: now), .confirm)
            }
            XCTAssertEqual(AccountDeletion.settle(asked(secondsAgo: seconds), standing: .gone, now: now), .confirm)
        }
    }

    func testARequestIsDroppedOnlyOnceItCannotStillLand() {
        XCTAssertEqual(AccountDeletion.settle(asked(secondsAgo: 5), standing: .exists, now: now), .keepAsking,
                       "killed and reopened while the server was still working")
        XCTAssertEqual(AccountDeletion.settle(asked(secondsAgo: 601), standing: .exists, now: now), .drop)
        XCTAssertEqual(AccountDeletion.settle(asked(secondsAgo: 86_400), standing: .unknown, now: now), .keepAsking,
                       "a day offline is not an answer")
    }

    func testTheRequestSurvivesARelaunch() throws {
        let relaunched = try JSONDecoder().decode(AccountDeletion.Asked.self, from: JSONEncoder().encode(asked()))
        XCTAssertEqual(relaunched, asked())
    }

    // MARK: What the sheet promises

    func testTheCopyNamesWhatGoesAndWhatStays() {
        let body = AccountDeletion.Copy.body
        for named in ["plan", "coach conversations", "corrections", "photos"] {
            XCTAssertTrue(body.contains(named), "the sheet must name \(named)")
        }
        XCTAssertTrue(body.contains("Apple Health"), "the one store this must not touch is named")
        XCTAssertTrue(body.contains("can't be undone"), "there is no undo, so it says so")
    }

    func testTheWayOutIsOfferedInWords() {
        XCTAssertFalse(AccountDeletion.Copy.cancel.isEmpty)
        XCTAssertNotEqual(AccountDeletion.Copy.cancel, AccountDeletion.Copy.confirm)
    }

    func testTheFailureIsTrueWhateverTheServerDid() {
        // Shown for a call that never left the phone, one that stopped after the photos, and
        // one that finished and whose answer was lost. It used to say "Nothing was deleted, and
        // your data is still here", which is wrong in the last two.
        let copy = AccountDeletion.Copy.failure
        XCTAssertFalse(copy.contains("Nothing was deleted"))
        XCTAssertFalse(copy.contains("still here"))
        XCTAssertTrue(copy.contains("couldn't confirm"))
        XCTAssertTrue(copy.contains("Some or all of your data may already be gone"))
        XCTAssertTrue(copy.contains("try again"), "and trying again is what settles it")
        XCTAssertFalse(copy.contains("\u{2014}") || copy.contains("\u{2013}"))
    }

    func testALaunchAfterADeletionDoesNotPromiseTheDataIsSafe() {
        XCTAssertTrue(LaunchGate.Copy.hint(deleting: false).contains("safe on the server"))
        XCTAssertFalse(LaunchGate.Copy.hint(deleting: true).contains("safe"))
        XCTAssertFalse(LaunchGate.Copy.hint(deleting: true).contains("no data was lost"))
    }
}
