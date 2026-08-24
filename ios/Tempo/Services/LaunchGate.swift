import Foundation

/// What Tempo shows before it has anything to show.
///
/// The first screen is decided entirely by a Supabase round-trip: sign in, then read the
/// athlete's `profiles` row to learn whether onboarding is done. Every step can fail, and on
/// 2026-08-23 all of them did at once — the free-tier project auto-paused after a week of
/// inactivity, so nothing answered. The gate at the time had only two states ("profile is
/// nil → splash" and "profile loaded → app"), which meant an unreachable backend was
/// **indistinguishable from still loading**: the splash stayed up forever with no way out.
///
/// The rule encoded here: *a failure never looks like loading.* Two corollaries, both
/// load-bearing —
///
///  - Unreachable gets its own state, carrying a reason and a retry.
///  - A failed profile read must never fall through to `.onboarding`. Demoting an onboarded
///    athlete into the setup interview would restart it from zero and read, correctly, as
///    data loss. When we don't know, we say we don't know.
enum LaunchGate: Equatable {
    case loading
    case onboarding
    case ready
    case unreachable(reason: String)

    /// Outcome of reading the athlete's profile row. Distinguishes "no row yet" (a genuinely
    /// new athlete — onboard them) from "couldn't ask" (say so instead of guessing).
    enum Profile: Equatable {
        case onboarded      // row exists, onboarded_at set
        case new            // row exists but never onboarded, or no row yet
        case unreadable     // query threw, timed out, or auth never produced a user
    }

    /// The whole launch decision, as a pure function of what the network told us.
    static func resolve(signedIn: Bool, profile: Profile) -> LaunchGate {
        guard signedIn else { return .unreachable(reason: Copy.noSession) }
        switch profile {
        case .onboarded:  return .ready
        case .new:        return .onboarding
        case .unreadable: return .unreachable(reason: Copy.noProfile)
        }
    }

    var isUnreachable: Bool {
        if case .unreachable = self { return true }
        return false
    }

    enum Copy {
        static let noSession = "Couldn't sign in to Tempo's server."
        static let noProfile = "Couldn't load your profile."
        static let hint = "Your training history is safe on the server — this is a connection problem, not lost data."
    }
}

/// A leash for work that must not stall a screen.
///
/// `URLSession.shared` waits 60s per request by default, and the launch path chains four of
/// them — so an unreachable backend can hold the splash for minutes before anything gives
/// up. Launch work gets a short deadline and a real error instead.
///
/// This is belt to `Supa`'s braces (which shortens the transport timeout globally): the
/// deadline also covers a call that never touches the network at all, such as auth waiting
/// on a keychain lock.
enum Deadline {
    /// Long enough for a slow-but-working cellular round-trip; short enough that a broken
    /// one is a blip rather than a hang.
    static let launch: TimeInterval = 12

    struct Exceeded: Error, CustomStringConvertible {
        let seconds: TimeInterval
        var description: String { "timed out after \(Int(seconds))s" }
    }

    static func run<T: Sendable>(
        _ seconds: TimeInterval = launch,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Exceeded(seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let winner = try await group.next() else { throw Exceeded(seconds: seconds) }
            return winner
        }
    }
}
