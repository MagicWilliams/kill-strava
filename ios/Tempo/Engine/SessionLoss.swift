import Foundation

/// What a launch that cannot get a session may do about it.
///
/// Accounts are anonymous: the session on this phone is the only key to one. A new account
/// made over the top of it leaves the old plan, coach history and corrections in the database
/// with nobody able to open them. So an account is created only when there is no key to lose:
/// nothing is stored, or the server says the thing the key opened is gone. Anything else is a
/// hold, which the launch gate shows as unreachable with a Retry.
///
/// The SDK cannot make this call for us. `auth.session` refreshes an expired token, so a
/// timeout or a 5xx throws there too. For some error codes (`sessionCleanupErrorCodes`:
/// four in 2.55.5, `user_banned` too by 2.55.8) it deletes the stored session and throws
/// `.sessionMissing`, the same error as having none.
/// An unreadable Keychain also reads as none. `SessionVault` keeps the evidence those cases
/// lose, and this decides on it.
enum SessionLoss {

    /// One place a session can be kept.
    enum Slot: Equatable {
        case empty
        case held
        /// The Keychain would not say. Never to be read as `empty`.
        case unreadable
    }

    /// Why an account may be created.
    enum Cause: String {
        case nothingStored = "nothing_stored"
        case tokenNotFound = "refresh_token_not_found"
        case sessionNotFound = "session_not_found"
    }

    enum Step: Equatable {
        case createAccount(Cause)
        /// Not signed in, and every stored session stays where it is. The reason is an
        /// enum-ish string for telemetry.
        case hold(String)
        /// The SDK removed a session. Present it to the server once more to learn why.
        case askServer
    }

    /// After `auth.session` threw. `stored` is the slot the SDK reads, `setAside` is where a
    /// session it removed went, and `failure` names the error for telemetry.
    static func step(stored: Slot, setAside: Slot, failure: String) -> Step {
        switch (stored, setAside) {
        // Still there: the SDK did not consider it rejected, so neither do we. Timeouts, 429s,
        // 5xx, a cancelled launch, a banned user and codes we have never seen all land here.
        case (.held, _):              return .hold(failure)
        case (.unreadable, _):        return .hold("storage_unreadable")
        case (.empty, .unreadable):   return .hold("storage_unreadable")
        case (.empty, .held):         return .askServer
        case (.empty, .empty):        return .createAccount(.nothingStored)
        }
    }

    /// The server's answer to a session the SDK removed.
    enum Reply: Equatable {
        case none
        case http(status: Int, code: String?)
    }

    enum Verdict: Equatable {
        case restore
        case createAccount(Cause)
        case hold(String)
    }

    /// The line is whether the credential's row still exists on the server. Gone means nobody
    /// can make this session work again. Present but refused means somebody still can:
    ///
    ///  - `refresh_token_already_used`: the account is alive and its token row is there,
    ///    revoked. Auth forgives one lost refresh reply, but a phone restored from a backup
    ///    presents an old token and gets this, on an account in use. Un-revoking the token
    ///    brings it back on the next Retry. (Auth's newer token format deletes the session
    ///    when it says this, so asking again gets `session_not_found` or
    ///    `refresh_token_not_found`. By then the key is gone for good.)
    ///  - `session_expired`: a timebox, inactivity or single-session setting, checked on each
    ///    request. Turning the setting off revives the session, and Tempo has no other way
    ///    back into an account, so a dashboard mistake must not cost every tester theirs.
    ///  - `user_banned`: lifted by whoever set it.
    static func verdict(on reply: Reply) -> Verdict {
        guard case .http(let status, let code) = reply else { return .hold("no_reply") }
        if (200..<300).contains(status) { return .restore }
        // A code counts only from the auth server's own refusal, not from an error page or a
        // gateway that happens to carry one.
        if (400..<500).contains(status), let cause = code.flatMap(Cause.init(refusal:)) {
            return .createAccount(cause)
        }
        return .hold(code ?? "http_\(status)")
    }
}

private extension SessionLoss.Cause {
    init?(refusal code: String) {
        switch code {
        case Self.tokenNotFound.rawValue:   self = .tokenNotFound
        case Self.sessionNotFound.rawValue: self = .sessionNotFound
        default:                            return nil
        }
    }
}
