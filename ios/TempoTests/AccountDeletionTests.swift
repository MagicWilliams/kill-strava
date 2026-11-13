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

    func testTheFailureSaysNothingWasDeleted() {
        // "It half worked" is the reading to rule out: someone who believes their data is
        // partly gone has no idea what is left or what to do next.
        XCTAssertTrue(AccountDeletion.Copy.failure.contains("Nothing was deleted"))
        XCTAssertTrue(AccountDeletion.Copy.failure.contains("still here"))
    }
}
