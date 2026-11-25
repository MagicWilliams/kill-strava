import os
import Security
import Supabase
import XCTest
@testable import Tempo

/// The rule against the real SDK, with a stubbed auth server and in-memory storage.
///
/// What the SDK does to a stored session is the reason any of this exists. It is undocumented,
/// and it changes between patch releases.
final class SessionVaultTests: XCTestCase {

    private let url = URL(string: "https://projectref.example.invalid")!
    private let storage = MemoryStorage()
    private var vault: SessionVault {
        SessionVault(base: storage, key: SessionVault.sdkKey(for: url)) { [storage] in storage.slot($0) }
    }

    override func setUp() {
        super.setUp()
        StubServer.reset()
    }

    private func makeClient() -> SupabaseClient {
        SupabaseClient(
            supabaseURL: url, supabaseKey: "key",
            options: .init(auth: .init(storage: vault, storageKey: vault.key,
                                       autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
                           global: .init(session: StubServer.session)))
    }

    /// One launch, as `Supa.signInAnonymouslyIfNeeded` runs it. Nil is signed in.
    private func launch(_ client: SupabaseClient) async -> SessionLoss.Verdict? {
        do {
            _ = try await client.auth.session
            return nil
        } catch {
            return await SessionRecovery(
                vault: vault,
                refresh: SessionRecovery.refresh(url: url, key: "key", session: StubServer.session)
            ).run(after: error)
        }
    }

    private func storeExpiredSession() throws {
        let session = try AuthClient.Configuration.jsonDecoder.decode(
            Session.self, from: StubServer.session(refreshToken: "old", expiresAt: 1))
        try storage.store(key: vault.key, value: JSONEncoder().encode(session))
    }

    private func refuse(_ status: Int, _ code: String) {
        StubServer.reply = (status, Data(#"{"code":"\#(code)","message":"no"}"#.utf8))
    }

    // MARK: The bug

    func testAnErrorThatLeavesTheSessionStoredIsHeld() async throws {
        for (status, code) in [(429, "over_request_rate_limit"), (500, "unexpected_failure")] {
            try storeExpiredSession()
            refuse(status, code)
            let verdict = await launch(makeClient())
            guard case .hold? = verdict else { return XCTFail("\(status) \(code): \(String(describing: verdict))") }
            XCTAssertEqual(storage.refreshToken(vault.key), "old")
        }
    }

    func testNoConnectionIsHeld() async throws {
        try storeExpiredSession()
        StubServer.reply = nil
        let verdict = await launch(makeClient())
        guard case .hold? = verdict else { return XCTFail(String(describing: verdict)) }
        XCTAssertEqual(storage.refreshToken(vault.key), "old")
        XCTAssertFalse(StubServer.paths.contains { $0.hasSuffix("/signup") })
    }

    // MARK: The codes the SDK removes a session for

    /// Not a list of what the SDK removes: CI resolves the newest SDK, and 2.55.8 added
    /// `user_banned` to the four in 2.55.5. Whatever it does, the session has to be somewhere.
    func testARefusedSessionIsNeverLostWhateverTheSDKDoes() async throws {
        for code in ["session_not_found", "session_expired", "refresh_token_not_found",
                     "refresh_token_already_used", "user_banned", "user_not_found", "bad_jwt"] {
            try storeExpiredSession()
            refuse(400, code)
            _ = try? await makeClient().auth.session
            XCTAssertTrue(vault.stored == .held || vault.setAside == .held, code)
            vault.discardSetAside()
        }
    }

    func testABannedUserIsHeld() async throws {
        try storeExpiredSession()
        refuse(400, "user_banned")
        for _ in 0..<2 {
            let verdict = await launch(makeClient())
            guard case .hold? = verdict else { return XCTFail(String(describing: verdict)) }
        }
    }

    func testAlreadyUsedIsHeldOnEveryLaunchAndComesBackWhenTheServerRelents() async throws {
        try storeExpiredSession()
        refuse(400, "refresh_token_already_used")
        for _ in 0..<3 {
            let verdict = await launch(makeClient())
            XCTAssertEqual(verdict, .hold("refresh_token_already_used"))
            XCTAssertEqual(vault.setAside, .held)
        }

        StubServer.reply = (200, StubServer.session(refreshToken: "new", expiresAt: 4_000_000_000))
        let client = makeClient()
        let verdict = await launch(client)
        XCTAssertEqual(verdict, .restore)
        XCTAssertEqual(client.auth.currentSession?.refreshToken, "new")
        XCTAssertEqual(vault.setAside, .empty)
        let next = await launch(client)
        XCTAssertNil(next)
    }

    func testExpiredByPolicyIsHeld() async throws {
        try storeExpiredSession()
        refuse(400, "session_expired")
        let verdict = await launch(makeClient())
        XCTAssertEqual(verdict, .hold("session_expired"))
    }

    func testGoneFromTheServerCreatesAnAccount() async throws {
        for (code, cause) in [("refresh_token_not_found", SessionLoss.Cause.tokenNotFound),
                              ("session_not_found", .sessionNotFound)] {
            try storeExpiredSession()
            refuse(400, code)
            let verdict = await launch(makeClient())
            XCTAssertEqual(verdict, .createAccount(cause))
            vault.discardSetAside()
        }
    }

    func testARemovalBetweenLaunchesIsNotTakenForAFirstLaunch() async throws {
        // The refresh timer can lose the session while the app is open. Next launch, offline.
        try storeExpiredSession()
        refuse(400, "refresh_token_already_used")
        _ = try? await makeClient().auth.session
        StubServer.reply = nil
        let verdict = await launch(makeClient())
        XCTAssertEqual(verdict, .hold("no_reply"))
    }

    func testAPageThatIsNotASessionRestoresNothing() async throws {
        // A captive portal answers 200 to everything.
        try storeExpiredSession()
        try vault.remove(key: vault.key)
        StubServer.reply = (200, Data("<html>Sign in to Wi-Fi</html>".utf8))
        let verdict = await launch(makeClient())
        XCTAssertEqual(verdict, .hold("restore_failed"))
        XCTAssertEqual(vault.setAside, .held)
    }

    // MARK: Storage

    func testAFirstLaunchCreatesAnAccountWithoutAskingTheServer() async {
        let verdict = await launch(makeClient())
        XCTAssertEqual(verdict, .createAccount(.nothingStored))
        XCTAssertEqual(StubServer.paths, [])
    }

    func testALockedKeychainIsHeld() async throws {
        try storeExpiredSession()
        storage.locked = true
        let verdict = await launch(makeClient())
        XCTAssertEqual(verdict, .hold("storage_unreadable"))
    }

    func testBytesTheSDKCannotDecodeAreHeld() async throws {
        try storage.store(key: vault.key, value: Data("not a session".utf8))
        let verdict = await launch(makeClient())
        guard case .hold? = verdict else { return XCTFail(String(describing: verdict)) }
        XCTAssertEqual(vault.stored, .held)
    }

    func testARemovalThatCannotBeSetAsideLeavesTheSession() throws {
        try storeExpiredSession()
        storage.failsToStore = true
        XCTAssertThrowsError(try vault.remove(key: vault.key))
        XCTAssertEqual(vault.stored, .held)
    }

    func testOtherKeysAreRemovedOutright() throws {
        let verifier = vault.key + "-code-verifier"
        try storage.store(key: verifier, value: Data())
        try vault.remove(key: verifier)
        XCTAssertEqual(storage.slot(verifier), .empty)
        XCTAssertEqual(vault.setAside, .empty)
    }

    func testKeychainStatuses() {
        XCTAssertEqual(SessionVault.slot(for: errSecSuccess), .held)
        XCTAssertEqual(SessionVault.slot(for: errSecItemNotFound), .empty)
        for status in [errSecInteractionNotAllowed, errSecNotAvailable, errSecAuthFailed, errSecDecode] {
            XCTAssertEqual(SessionVault.slot(for: status), .unreadable)
        }
    }

    // MARK: The SDK's defaults, which every installed build's session is stored under

    func testTheKeyIsTheOneTheSDKPicksForItself() {
        for url in [url, SupabaseConfig.url] {
            let recorder = MemoryStorage()
            let client = SupabaseClient(
                supabaseURL: url, supabaseKey: "key",
                options: .init(auth: .init(storage: recorder, autoRefreshToken: false,
                                           emitLocalSessionAsInitialSession: true),
                               global: .init(session: StubServer.session)))
            _ = client.auth.currentSession
            XCTAssertTrue(recorder.asked.contains(SessionVault.sdkKey(for: url)), "\(recorder.asked)")
        }
    }

    func testTheKeychainServiceIsTheSDKsDefault() {
        func service(_ storage: any AuthLocalStorage) -> String? {
            let keychain = Mirror(reflecting: storage).children.first { $0.label == "keychain" }?.value
            return keychain.flatMap { Mirror(reflecting: $0).descendant("service") as? String }
        }
        XCTAssertEqual(service(AuthClient.Configuration.defaultLocalStorage), SessionVault.keychainService)
        XCTAssertEqual(service(SessionVault.keychain(for: url).base), SessionVault.keychainService)
    }
}

private final class MemoryStorage: AuthLocalStorage, @unchecked Sendable {
    private struct Failure: Error {}
    private let lock = OSAllocatedUnfairLock<(items: [String: Data], asked: Set<String>)>(
        uncheckedState: ([:], []))
    var locked = false
    var failsToStore = false

    var asked: Set<String> { lock.withLockUnchecked { $0.asked } }

    func store(key: String, value: Data) throws {
        if locked || failsToStore { throw Failure() }
        lock.withLockUnchecked { $0.items[key] = value }
    }
    func retrieve(key: String) throws -> Data? {
        if locked { throw Failure() }
        return lock.withLockUnchecked {
            $0.asked.insert(key)
            return $0.items[key]
        }
    }
    func remove(key: String) throws {
        if locked { throw Failure() }
        lock.withLockUnchecked { $0.items[key] = nil }
    }
    func slot(_ key: String) -> SessionLoss.Slot {
        if locked { return .unreadable }
        return lock.withLockUnchecked { $0.items[key] == nil ? .empty : .held }
    }
    func refreshToken(_ key: String) -> String? {
        lock.withLockUnchecked { $0.items[key] }
            .flatMap { try? JSONDecoder().decode(Session.self, from: $0).refreshToken }
    }
}

/// Answers every request with `reply`, or fails to connect when there is none.
private final class StubServer: URLProtocol {
    private static let state = OSAllocatedUnfairLock<(reply: (Int, Data)?, paths: [String])>(
        uncheckedState: (nil, []))

    static var reply: (Int, Data)? {
        get { state.withLockUnchecked { $0.reply } }
        set { state.withLockUnchecked { $0.reply = newValue } }
    }
    static var paths: [String] { state.withLockUnchecked { $0.paths } }
    static func reset() { state.withLockUnchecked { $0 = (nil, []) } }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubServer.self]
        return URLSession(configuration: config)
    }()

    static func session(refreshToken: String, expiresAt: Int) -> Data {
        Data("""
        {"access_token":"a","token_type":"bearer","expires_in":3600,"expires_at":\(expiresAt),
         "refresh_token":"\(refreshToken)",
         "user":{"id":"00000000-0000-0000-0000-000000000001","aud":"authenticated",
                 "app_metadata":{},"user_metadata":{},"is_anonymous":true,
                 "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}}
        """.utf8)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.state.withLockUnchecked { $0.paths.append(request.url!.path) }
        guard let (status, body) = Self.reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [
            "Content-Type": "application/json", "X-Supabase-Api-Version": "2024-01-01",
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
