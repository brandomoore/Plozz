import CoreModels
import CoreNetworking
import XCTest
@testable import SeerService

final class SeerAccountConnectionsTests: XCTestCase {
    private let url = URL(string: "https://requests.example.test/seerr")!

    func testMigrationKeepsMappedUserAndDoesNotEnrollLaterProfiles() throws {
        let store = InMemorySeerAccountConnectionStore()
        var existing = Profile(id: "existing", name: "Existing")
        existing.seerrUserID = 42
        existing.seerrUserName = "Saved user"
        existing.seerrServerIdentity = SeerServerIdentity(baseURL: url)
        let key = SeerConnection(baseURL: url, apiKey: "fixture-api-key")
        try store.migrateLegacy(key, profiles: [existing])
        let state = try store.load(profileID: existing.id)
        XCTAssertEqual(state.connections.count, 1)
        XCTAssertEqual(state.selected?.config.userId, 42)
        XCTAssertEqual(state.selected?.accountName, "Saved user")
        XCTAssertFalse(state.offersChoice)
        let later = Profile(id: "later", name: "Later")
        try store.migrateLegacy(key, profiles: [existing, later])
        XCTAssertTrue(try store.load(profileID: later.id).connections.isEmpty)
    }

    @MainActor
    func testProfileSwitchRejectsLateSignInAndDoesNotBorrowConnection() throws {
        let first = Profile(id: "first", name: "First")
        let second = Profile(id: "second", name: "Second")
        var current = first
        let service = SeerService(connectionStore: InMemorySeerConnectionStore())
        service.configureProfiles(store: InMemorySeerAccountConnectionStore(), profiles: [first, second], current: { current })
        let revision = service.connectionRevision
        let generation = service.requestAuthorizationGeneration
        current = second
        XCTAssertThrowsError(try service.saveAccount(
            account(), expectedProfileID: first.id, expectedRevision: revision
        ))
        XCTAssertFalse(service.isConfigured)
        XCTAssertNotEqual(service.requestAuthorizationGeneration, generation)
        XCTAssertTrue(service.profileConnections.connections.isEmpty)
    }

    @MainActor
    func testExplicitAccountsKeepDefaultAndDirectoryUsersAreNotConnections() throws {
        let profile = Profile(id: "first", name: "First")
        let service = SeerService(connectionStore: InMemorySeerConnectionStore())
        service.configureProfiles(store: InMemorySeerAccountConnectionStore(), profiles: [profile], current: { profile })
        try service.saveAccount(account(userID: 10), expectedProfileID: profile.id, expectedRevision: service.connectionRevision)
        let savedDefault = service.profileConnections.defaultID
        XCTAssertFalse(service.profileConnections.offersChoice)
        try service.saveAccount(account(userID: 20), expectedProfileID: profile.id, expectedRevision: service.connectionRevision)
        XCTAssertEqual(service.profileConnections.defaultID, savedDefault)
        XCTAssertEqual(service.profileConnections.selected?.config.session?.userID, 10)
        XCTAssertTrue(service.profileConnections.offersChoice)
        XCTAssertFalse(service.profileConnections.askEachTime)
    }

    func testSessionStripsKeyAndActingUserAndRefusesCrossOriginRedirects() async throws {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/request", json: #"{"id":17,"status":1}"#)
        var config = SeerConfig(baseURL: url, session: credential())
        config.apiKey = "must-not-be-sent"
        config.userId = 999
        let client = SeerClient(config: config, http: http)
        _ = try await client.createRequest(SeerRequestBody(mediaType: "movie", mediaId: 17), actingUserID: 999)
        let sent = try XCTUnwrap(http.lastSent(pathSuffix: "/request"))
        XCTAssertNil(sent.headers["X-Api-Key"])
        XCTAssertNil(sent.headers["X-API-User"])
        XCTAssertEqual(sent.headers["Cookie"], "connect.sid=fixture-session")
        XCTAssertEqual(sent.redirectPolicy, .sameOrigin)
    }

    func testLocalSignInPrimesCSRFAndVerifiesRealUser() async throws {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/settings/public", json: #"{"initialized":true,"localLogin":true}"#,
                  headers: ["Set-Cookie": "XSRF-TOKEN=csrf-token; Path=/"])
        http.stub(pathSuffix: "/auth/local", json: #"{"id":18}"#,
                  headers: ["Set-Cookie": "connect.sid=fixture-session; Path=/seerr/api; HttpOnly"])
        http.stub(pathSuffix: "/auth/me", json: #"{"id":18,"displayName":"Pat","permissions":8}"#)
        let result = try await SeerAuthentication(baseURL: url, http: http).password(
            username: "pat@example.test", password: "fixture-password", local: true
        )
        XCTAssertEqual(result.user.id, 18)
        XCTAssertEqual(http.lastSent(pathSuffix: "/auth/local")?.headers["X-XSRF-TOKEN"], "csrf-token")
        XCTAssertTrue(http.lastSent(pathSuffix: "/auth/me")?.headers["Cookie"]?.contains("connect.sid=fixture-session") == true)
        guard case let .session(session) = result.credential else { return XCTFail("Expected user session") }
        XCTAssertEqual(session.userID, 18)
        XCTAssertEqual(session.permissions, 8)
    }

    func testPublicStatusCannotValidateAnAPIKey() async throws {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/settings/public", json: #"{"initialized":true}"#)
        http.stub(pathSuffix: "/auth/me", json: #"{"message":"Unauthorized"}"#, status: 401)
        do {
            _ = try await SeerAuthentication(baseURL: url, http: http).apiKey("invalid-fixture-key")
            XCTFail("An invalid key must not connect")
        } catch { XCTAssertEqual(error as? AppError, .unauthorized) }
    }

    func testUninitializedServerCannotBeConfiguredBySignIn() async throws {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/settings/public", json: #"{"initialized":false}"#)
        do {
            _ = try await SeerAuthentication(baseURL: url, http: http).password(
                username: "fixture", password: "fixture", local: false
            )
            XCTFail("Initial server setup is not a login")
        } catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
        XCTAssertEqual(http.sentPaths, ["/api/v1/settings/public"])
    }

    func testQuickConnectApprovesOnlyTheIssuedCodeAndChecksTheUser() async throws {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/settings/public", json: #"{"initialized":true,"mediaServerType":2,"mediaServerLogin":true}"#)
        http.stub(pathSuffix: "/quickconnect/initiate", json: #"{"code":"654321","secret":"fixture-secret"}"#)
        http.stub(pathSuffix: "/quickconnect/authenticate", json: #"{"id":18}"#,
                  headers: ["Set-Cookie": "connect.sid=fixture-jellyfin; Path=/seerr/api"])
        http.stub(pathSuffix: "/auth/me", json: #"{"id":18,"displayName":"Pat","permissions":8,"jellyfinUserId":"fixture-user"}"#)
        let result = try await SeerAuthentication(baseURL: url, http: http).jellyfin { code in
            XCTAssertEqual(code, "654321")
        }
        XCTAssertEqual(result.mediaUserID, "fixture-user")
        XCTAssertEqual(http.lastSent(pathSuffix: "/quickconnect/authenticate")?.json?["secret"] as? String, "fixture-secret")
        XCTAssertFalse(http.sent.contains { $0.headers["X-Emby-Token"] != nil })
    }

    func testNewLoginNeverUsesAnotherLoginCookie() async throws {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/settings/public", json: #"{"initialized":true,"localLogin":true}"#)
        http.stub(pathSuffix: "/auth/local", json: #"{"id":18}"#,
                  headers: ["Set-Cookie": "connect.sid=first-session; Path=/seerr/api"])
        http.stub(pathSuffix: "/auth/me", json: #"{"id":18,"permissions":8}"#)
        _ = try await SeerAuthentication(baseURL: url, http: http).password(username: "first", password: "fixture", local: true)
        _ = try await SeerAuthentication(baseURL: url, http: http).methods()
        XCTAssertEqual(http.lastSent(pathSuffix: "/settings/public")?.headers["Cookie"], "")
    }

    @MainActor
    func testExpiredSessionNeverFallsBackToHouseholdKey() async throws {
        let profile = Profile(id: "first", name: "First")
        let http = SeerRecordingHTTPClient()
        let service = configuredService(profile: profile, http: http)
        var expired = account()
        var session = credential()
        session.expiresAt = .distantPast
        expired = .init(baseURL: url, credential: .session(session), user: expired.user)
        try service.saveAccount(expired, expectedProfileID: profile.id, expectedRevision: service.connectionRevision)
        let result = await service.request(MediaItem(id: "seer:movie:17", title: "Fixture", kind: .movie))
        XCTAssertEqual(result, .failure(.signInRequired))
        XCTAssertTrue(http.sentPaths.isEmpty)
    }

    @MainActor
    func testRequestRechecksKidsPermissionsWithoutSendingMutation() async throws {
        let profile = Profile(id: "first", name: "First")
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/auth/me", json: #"{"id":10,"permissions":2}"#)
        let service = configuredService(profile: profile, http: http)
        service.refusesAdminRequests = { true }
        try service.saveAccount(account(), expectedProfileID: profile.id, expectedRevision: service.connectionRevision)
        let result = await service.request(MediaItem(id: "seer:movie:17", title: "Fixture", kind: .movie))
        XCTAssertEqual(result, .failure(.noPermission))
        XCTAssertEqual(http.sentPaths, ["/api/v1/auth/me"])
    }

    @MainActor
    func testSessionConflictDoesNotDeleteOrRetryAnExistingRequest() async throws {
        let profile = Profile(id: "first", name: "First")
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/auth/me", json: #"{"id":10,"permissions":8}"#)
        http.stub(pathSuffix: "/request", json: #"{"message":"Already requested"}"#, status: 409)
        let service = configuredService(profile: profile, http: http)
        try service.saveAccount(account(), expectedProfileID: profile.id, expectedRevision: service.connectionRevision)
        let result = await service.request(MediaItem(id: "seer:movie:17", title: "Fixture", kind: .movie))
        XCTAssertEqual(result, .failure(.alreadyRequested))
        XCTAssertEqual(http.sentPaths, ["/api/v1/auth/me", "/api/v1/request"])
        XCTAssertNil(service.profileConnections.lastSuccessfulID)
    }

    @MainActor
    func testAlternativeRequestKeepsDefaultAndReturnsDestinationScopedSuccess() async throws {
        let profile = Profile(id: "first", name: "First")
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/auth/me", json: #"{"id":20,"permissions":8}"#)
        http.stub(pathSuffix: "/movie/17", json: #"{"mediaInfo":{"status":1}}"#)
        http.stub(pathSuffix: "/request", json: #"{"id":17,"status":1}"#)
        let service = configuredService(profile: profile, http: http)
        try service.saveAccount(account(), expectedProfileID: profile.id, expectedRevision: service.connectionRevision)
        let defaultID = service.profileConnections.defaultID
        try service.saveAccount(account(userID: 20), expectedProfileID: profile.id, expectedRevision: service.connectionRevision)
        let alternative = try XCTUnwrap(service.profileConnections.connections.last)
        let task = Task { await service.request(MediaItem(id: "seer:movie:17", title: "Fixture", kind: .movie)) }
        let deadline = ContinuousClock.now + .seconds(3)
        while service.pendingDestination == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(service.pendingDestination)
        service.chooseDestination(alternative.id)
        let result = await task.value
        guard case .successElsewhere = result else { return XCTFail("Wrong destination result: \(result)") }
        XCTAssertEqual(service.profileConnections.defaultID, defaultID)
        XCTAssertEqual(service.profileConnections.lastSuccessfulID, alternative.id)
        XCTAssertEqual(service.profileConnections.selected?.config.session?.userID, 10)
        XCTAssertEqual(http.sentPaths, ["/api/v1/auth/me", "/api/v1/movie/17", "/api/v1/request"])
    }

    @MainActor
    func testProfileChangeDuringPermissionCheckCancelsBeforeMutation() async throws {
        let first = Profile(id: "first", name: "First")
        var current = first
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/auth/me", json: #"{"id":10,"permissions":8}"#)
        http.suspend(pathSuffix: "/auth/me")
        let service = SeerService(connectionStore: InMemorySeerConnectionStore(), http: http)
        service.configureProfiles(store: InMemorySeerAccountConnectionStore(), profiles: [first], current: { current })
        try service.saveAccount(account(), expectedProfileID: first.id, expectedRevision: service.connectionRevision)
        let task = Task { await service.request(MediaItem(id: "seer:movie:17", title: "Fixture", kind: .movie)) }
        await http.waitUntilSuspended(pathSuffix: "/auth/me")
        current = Profile(id: "second", name: "Second")
        service.synchronizeProfile()
        http.resume(pathSuffix: "/auth/me")
        let result = await task.value
        XCTAssertEqual(result, .failure(.cancelled))
        XCTAssertFalse(http.sentPaths.contains("/api/v1/request"))
    }

    func testSecureStoreReadFailureCannotBecomeAnEmptyLedger() throws {
        let secure = SeerFixtureSecureStore()
        secure.failReads = true
        let store = SeerAccountConnectionStore(secureStore: secure)
        XCTAssertThrowsError(try store.save(.init(), profileID: "first"))
        XCTAssertTrue(secure.values.isEmpty)
    }

    @MainActor
    func testUnreadableHouseholdKeyDoesNotCompleteProfileMigration() throws {
        let secure = SeerFixtureSecureStore()
        let household = HouseholdSeerConnectionStore(secureStore: secure)
        try household.save(.init(baseURL: url, apiKey: "fixture"))
        let store = InMemorySeerAccountConnectionStore()
        let profile = Profile(id: "first", name: "First")
        let service = SeerService(connectionStore: household)
        secure.failReads = true
        service.configureProfiles(store: store, profiles: [profile], current: { profile })
        XCTAssertNotNil(service.storageFailure)
        XCTAssertTrue(try store.load(profileID: profile.id).connections.isEmpty)
        secure.failReads = false
        service.configureProfiles(store: store, profiles: [profile], current: { profile })
        XCTAssertNil(service.storageFailure)
        XCTAssertEqual(service.profileConnections.selected?.config.apiKey, "fixture")
    }

    func testTransferExcludesSessionsAndCannotOverwriteLocalChoice() throws {
        let secure = SeerFixtureSecureStore()
        let store = SeerAccountConnectionStore(secureStore: secure)
        let key = SeerAccountConnection(id: UUID(), baseURL: url, name: "", credential: .apiKey(key: "fixture", userID: 18, userName: "Pat"))
        let session = SeerAccountConnection(id: UUID(), baseURL: url, name: "", credential: .session(credential()))
        var state = SeerProfileConnections()
        state.connections = [key, session]
        state.defaultID = session.id
        state.configured = true
        try store.save(state, profileID: "first")
        let exported = try store.exportAPIKeys()
        XCTAssertEqual(exported["first"]?.connections, [key])
        XCTAssertEqual(exported["first"]?.defaultID, key.id)
        XCTAssertTrue(try store.importAPIKeysIfAbsent(exported, allowedProfiles: ["first"]).isEmpty)
        XCTAssertEqual(try store.load(profileID: "first"), state)
        XCTAssertThrowsError(try store.importAPIKeysIfAbsent(["second": state], allowedProfiles: ["second"]))
        XCTAssertTrue(try store.load(profileID: "second").connections.isEmpty)
    }

    @MainActor
    func testRemovingDefaultSelectsRemainingAccountAndReaddingItDoesNotCreateAChoice() throws {
        let profile = Profile(id: "first", name: "First")
        let service = configuredService(profile: profile, http: SeerRecordingHTTPClient())
        try service.saveAccount(account(), expectedProfileID: profile.id, expectedRevision: service.connectionRevision)
        let first = try XCTUnwrap(service.profileConnections.defaultID)
        try service.saveAccount(account(userID: 20), expectedProfileID: profile.id, expectedRevision: service.connectionRevision)
        try service.removeConnection(first)
        XCTAssertTrue(service.isConfigured)
        XCTAssertEqual(service.requestIdentity.userID, 20)
        XCTAssertFalse(service.needsAdminConfirmation)
        try service.saveAccount(account(userID: 20), expectedProfileID: profile.id, expectedRevision: service.connectionRevision)
        XCTAssertEqual(service.profileConnections.connections.count, 1)
        XCTAssertFalse(service.profileConnections.offersChoice)
        try service.updateSelection(defaultID: service.profileConnections.defaultID, rememberLastUsed: false, askEachTime: true)
        XCTAssertTrue(service.profileConnections.offersChoice)
    }

    @MainActor
    func testAPIKeyReconnectPreservesMappedUserAndRelinkRequirement() throws {
        var profile = Profile(id: "first", name: "First")
        profile.seerrUserID = 42
        profile.seerrUserName = "Pat"
        let service = SeerService(connectionStore: InMemorySeerConnectionStore(
            connection: .init(baseURL: url, apiKey: "old-fixture-key")
        ))
        service.configureProfiles(store: InMemorySeerAccountConnectionStore(), profiles: [profile], current: { profile })
        let id = try XCTUnwrap(service.profileConnections.defaultID)
        XCTAssertTrue(try XCTUnwrap(service.profileConnections.selected).requiresRelink)
        let replacement = SeerAuthenticatedAccount(
            baseURL: url, credential: .apiKey(key: "new-fixture-key", userID: nil, userName: "Admin"),
            user: SeerUser(id: 1, name: "Admin")
        )
        try service.saveAccount(replacement, expectedProfileID: profile.id, expectedRevision: service.connectionRevision, replacing: id)
        let saved = try XCTUnwrap(service.profileConnections.selected)
        XCTAssertEqual(saved.config.apiKey, "new-fixture-key")
        XCTAssertEqual(saved.config.userId, 42)
        XCTAssertEqual(saved.accountName, "Pat")
        XCTAssertTrue(saved.requiresRelink)
    }

    @MainActor
    func testUnchangedReloadDoesNotInvalidatePendingAuthentication() async throws {
        let profile = Profile(id: "first", name: "First")
        let service = configuredService(profile: profile, http: SeerRecordingHTTPClient())
        let revision = service.connectionRevision
        await service.reloadConnection()
        XCTAssertEqual(service.connectionRevision, revision)
        try service.saveAccount(account(), expectedProfileID: profile.id, expectedRevision: revision)
        XCTAssertEqual(service.requestAccountName, "User 10")
    }

    @MainActor
    func testReplacingAccountAfterChoosingCannotSendAsTheReplacementUser() async throws {
        let profile = Profile(id: "first", name: "First")
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/auth/me", json: #"{"id":20,"permissions":8}"#)
        http.stub(pathSuffix: "/request", json: #"{"id":17,"status":1}"#)
        let service = configuredService(profile: profile, http: http)
        try service.saveAccount(account(), expectedProfileID: profile.id, expectedRevision: service.connectionRevision)
        let id = try XCTUnwrap(service.profileConnections.defaultID)
        try service.updateSelection(defaultID: id, rememberLastUsed: false, askEachTime: true)
        let request = Task { await service.request(MediaItem(id: "seer:movie:17", title: "Fixture", kind: .movie)) }
        try await choose(id, service: service)
        try service.saveAccount(account(userID: 20), expectedProfileID: profile.id,
                                expectedRevision: service.connectionRevision, replacing: id)
        let outcome = await request.value
        XCTAssertEqual(outcome, .failure(.cancelled))
        XCTAssertTrue(http.sentPaths.isEmpty)
    }

    @MainActor
    func testKidsRestrictionAddedDuringAlternateLookupPreventsAdminMutation() async throws {
        let profile = Profile(id: "first", name: "First")
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/auth/me", json: #"{"id":20,"permissions":2}"#)
        http.stub(pathSuffix: "/movie/17", json: #"{"mediaInfo":{"status":1}}"#)
        http.suspend(pathSuffix: "/movie/17")
        let service = configuredService(profile: profile, http: http)
        var isKids = false
        service.refusesAdminRequests = { isKids }
        try service.saveAccount(account(), expectedProfileID: profile.id, expectedRevision: service.connectionRevision)
        try service.saveAccount(account(userID: 20), expectedProfileID: profile.id, expectedRevision: service.connectionRevision)
        let alternate = try XCTUnwrap(service.profileConnections.connections.last?.id)
        let task = Task { await service.request(MediaItem(id: "seer:movie:17", title: "Fixture", kind: .movie)) }
        try await choose(alternate, service: service)
        await http.waitUntilSuspended(pathSuffix: "/movie/17")
        isKids = true
        http.resume(pathSuffix: "/movie/17")
        let outcome = await task.value
        XCTAssertEqual(outcome, .failure(.noPermission))
        XCTAssertFalse(http.sentPaths.contains("/api/v1/request"))
    }

    @MainActor
    func testRememberedAlternateAndDuplicateKeepDestinationScopedResults() async throws {
        for status in [200, 409] {
            let profile = Profile(id: "first", name: "First")
            let http = SeerRecordingHTTPClient()
            http.stub(pathSuffix: "/auth/me", json: #"{"id":20,"permissions":8}"#)
            http.stub(pathSuffix: "/movie/17", json: #"{"mediaInfo":{"status":1}}"#)
            http.stub(pathSuffix: "/request", json: status == 200 ? #"{"id":17,"status":1}"# : #"{"message":"Already requested"}"#, status: status)
            let service = configuredService(profile: profile, http: http)
            try service.saveAccount(account(), expectedProfileID: profile.id, expectedRevision: service.connectionRevision)
            try service.saveAccount(account(userID: 20), expectedProfileID: profile.id, expectedRevision: service.connectionRevision)
            try service.updateSelection(defaultID: service.profileConnections.defaultID, rememberLastUsed: true, askEachTime: false)
            let alternate = try XCTUnwrap(service.profileConnections.connections.last?.id)
            let generation = service.requestAuthorizationGeneration
            let task = Task { await service.request(MediaItem(id: "seer:movie:17", title: "Fixture", kind: .movie)) }
            try await choose(alternate, service: service)
            let outcome = await task.value
            guard case .successElsewhere = outcome else { return XCTFail("Lost destination scope: \(outcome)") }
            XCTAssertEqual(service.profileConnections.selected?.id, status == 200 ? alternate : service.profileConnections.defaultID)
            XCTAssertEqual(service.requestAuthorizationGeneration, generation)
        }
    }

    func testSessionCookiesOutsideServerScopeCannotAuthenticate() async throws {
        for cookie in [
            "connect.sid=fixture; Domain=other.example.test; Path=/",
            "connect.sid=fixture; Path=/another-app",
            "connect.sid=fixture; Path=/; Max-Age=0"
        ] {
            let http = SeerRecordingHTTPClient()
            http.stub(pathSuffix: "/settings/public", json: #"{"initialized":true,"localLogin":true}"#)
            http.stub(pathSuffix: "/auth/local", json: #"{"id":10}"#, headers: ["Set-Cookie": cookie])
            http.stub(pathSuffix: "/auth/me", json: #"{"id":10,"permissions":8}"#)
            do {
                _ = try await SeerAuthentication(baseURL: url, http: http).password(username: "fixture", password: "fixture", local: true)
                XCTFail("Unusable cookie must not authenticate")
            } catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
        }
    }

    @MainActor
    private func choose(_ id: UUID, service: SeerService) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while service.pendingDestination == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard service.pendingDestination != nil else {
            XCTFail("Request did not offer its destination")
            throw CancellationError()
        }
        service.chooseDestination(id)
    }

    @MainActor
    private func configuredService(profile: Profile, http: SeerRecordingHTTPClient) -> SeerService {
        let service = SeerService(connectionStore: InMemorySeerConnectionStore(), http: http)
        service.configureProfiles(store: InMemorySeerAccountConnectionStore(), profiles: [profile], current: { profile })
        return service
    }

    private func credential(userID: Int = 10) -> SeerSessionCredential {
        .init(cookie: "connect.sid=fixture-session", csrfToken: "fixture-csrf",
              userID: userID, name: "User \(userID)", permissions: 8, expiresAt: .distantFuture)
    }

    private final class SeerFixtureSecureStore: SecureStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        var failReads = false
        func setString(_ value: String, for key: String) throws { values[key] = value }
        func string(for key: String) -> String? { values[key] }
        func readString(for key: String) throws -> String? {
            if failReads { throw AppError.unauthorized }
            return values[key]
        }
        func removeValue(for key: String) throws { values.removeValue(forKey: key) }
    }
    private func account(userID: Int = 10) -> SeerAuthenticatedAccount {
        .init(baseURL: url, credential: .session(credential(userID: userID)),
              user: SeerUser(id: userID, name: "User \(userID)"))
    }
}
