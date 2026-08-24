import XCTest
@testable import Tempo

/// Regression suite for the splash-screen freeze (2026-08-23): the Supabase project
/// auto-paused on the free tier, every launch request failed, and because "profile not
/// loaded yet" and "profile could not be loaded" were the same state (`nil`), the app sat
/// on the brand splash indefinitely with no error and no retry.
///
/// The two invariants below are the ones that actually matter. Everything else is detail.
final class LaunchGateTests: XCTestCase {

    // MARK: Invariant 1 — a failure is never indistinguishable from loading

    func testResolveNeverReturnsLoading() {
        // `.loading` is an initial state only. If resolution could produce it, the freeze
        // would be reachable again by a different route.
        let everyOutcome: [LaunchGate] = [true, false].flatMap { signedIn in
            [LaunchGate.Profile.onboarded, .new, .unreadable].map {
                LaunchGate.resolve(signedIn: signedIn, profile: $0)
            }
        }
        XCTAssertFalse(everyOutcome.contains(.loading))
        XCTAssertEqual(everyOutcome.count, 6)
    }

    func testUnreadableProfileIsUnreachable() {
        let gate = LaunchGate.resolve(signedIn: true, profile: .unreadable)
        XCTAssertEqual(gate, .unreachable(reason: LaunchGate.Copy.noProfile))
        XCTAssertTrue(gate.isUnreachable)
    }

    func testFailedSignInIsUnreachableWhateverTheProfileSays() {
        for profile in [LaunchGate.Profile.onboarded, .new, .unreadable] {
            XCTAssertEqual(
                LaunchGate.resolve(signedIn: false, profile: profile),
                .unreachable(reason: LaunchGate.Copy.noSession),
                "no session means we know nothing, regardless of \(profile)"
            )
        }
    }

    // MARK: Invariant 2 — a failure never demotes an athlete into onboarding

    func testUnreadableProfileNeverRoutesToOnboarding() {
        // Onboarding is a takeover that restarts the setup interview from zero. Reaching it
        // because the network blipped would look exactly like losing the athlete's account.
        XCTAssertNotEqual(LaunchGate.resolve(signedIn: true,  profile: .unreadable), .onboarding)
        XCTAssertNotEqual(LaunchGate.resolve(signedIn: false, profile: .unreadable), .onboarding)
        XCTAssertNotEqual(LaunchGate.resolve(signedIn: false, profile: .onboarded),  .onboarding)
    }

    // MARK: The happy paths still work

    func testNewAthleteOnboards() {
        XCTAssertEqual(LaunchGate.resolve(signedIn: true, profile: .new), .onboarding)
    }

    func testOnboardedAthleteGoesStraightToTheApp() {
        XCTAssertEqual(LaunchGate.resolve(signedIn: true, profile: .onboarded), .ready)
    }

    func testNeedsOnboardingBridgeTreatsUnreachableAsUnknown() {
        // RootTabView switches on `launch`, but the legacy tri-state is still read in a few
        // places. Unreachable must map to nil (unknown) — never to `true`, which would push
        // the onboarding takeover on a connection failure.
        XCTAssertNil(LaunchGate.unreachable(reason: "x").needsOnboardingEquivalent)
        XCTAssertNil(LaunchGate.loading.needsOnboardingEquivalent)
        XCTAssertEqual(LaunchGate.onboarding.needsOnboardingEquivalent, true)
        XCTAssertEqual(LaunchGate.ready.needsOnboardingEquivalent, false)
    }

    // MARK: Deadline

    func testDeadlineReturnsWorkThatFinishesInTime() async throws {
        let value = try await Deadline.run(2) { "done" }
        XCTAssertEqual(value, "done")
    }

    func testDeadlineThrowsWhenWorkOverruns() async {
        do {
            _ = try await Deadline.run(0.1) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "never"
            }
            XCTFail("expected the deadline to fire")
        } catch is Deadline.Exceeded {
            // expected
        } catch {
            XCTFail("expected Deadline.Exceeded, got \(error)")
        }
    }

    func testDeadlinePropagatesTheUnderlyingError() async {
        struct Boom: Error {}
        do {
            _ = try await Deadline.run(5) { throw Boom() }
            XCTFail("expected the thrown error")
        } catch is Boom {
            // expected — a real failure must not be reported as a timeout
        } catch {
            XCTFail("expected Boom, got \(error)")
        }
    }
}

private extension LaunchGate {
    /// Mirror of `RunStore.needsOnboarding`, testable without touching the store's I/O.
    var needsOnboardingEquivalent: Bool? {
        switch self {
        case .loading, .unreachable: return nil
        case .onboarding:            return true
        case .ready:                 return false
        }
    }
}
