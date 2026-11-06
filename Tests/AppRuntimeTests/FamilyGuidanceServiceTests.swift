@testable import AppRuntime
import CoreModels
import CoreNetworking
import CoreSecureStore
import FeatureAuthCore
import Foundation
import ProviderPlex
import XCTest

@MainActor
final class FamilyGuidanceServiceTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let defaults: UserDefaults
        let suite: String
        let profiles: ProfilesModel
        let accounts: AccountsProvidersModel
        let home: PlexHomeUsersModel
        let service: FamilyGuidanceService
        let http: GuidanceHTTP
        let item = MediaItem(
            id: "123", title: "Fixture", kind: .movie,
            providerIDs: ["PlexGuid": "plex://movie/0123456789abcdef01234567"], sourceAccountID: "account"
        )

        init(homeUser: Bool = false, suspended: Bool = false, statuses: [Int] = [200]) throws {
            suite = "FamilyGuidanceTests.\(UUID())"
            defaults = UserDefaults(suiteName: suite)!
            let store = ProfileStore(defaults: defaults)
            store.saveProfiles([
                Profile(id: "owner", name: "Owner"),
                Profile(id: "child", name: "Child").settingHomeUserBinding(
                    .init(homeUserID: "child-user", name: "Child", requiresPIN: false), forPlexAccount: "account"
                )
            ])
            store.setActiveProfileID(homeUser ? "child" : "owner")
            profiles = ProfilesModel(store: store)
            let accountStore = AccountStore(secureStore: InMemorySecureStore())
            try accountStore.add(Account(
                id: "account", server: MediaServer(id: UUID().uuidString, name: "Fixture",
                    baseURL: URL(string: "https://server.example")!, provider: .plex),
                userID: "viewer", userName: "Viewer", deviceID: "fixture"
            ), token: homeUser ? "CHILD-SERVER" : "OWNER-TOKEN")
            accountStore.setActiveAccountIDs(["account"])
            let client = GuidanceHTTP(suspended: suspended, statuses: statuses)
            http = client
            let registry = ProviderRegistry()
            registry.register(.plex) { context in
                PlexProvider(session: context.session, accountID: context.accountID,
                             credentialRevision: context.credentialRevision, http: client)
            }
            accounts = AccountsProvidersModel(accountStore: accountStore, registry: registry, profilesModel: profiles)
            accounts.tokenResolver = { accountStore.token(for: $0) }
            accounts.reloadAccounts()
            home = PlexHomeUsersModel(
                accountsProviders: accounts, profilesModel: profiles,
                plexHomeUserTokenCache: PlexHomeUserTokenCache(store: InMemorySecureStore()),
                automaticSignInStore: AutomaticSignInStore(defaults: defaults, secureStore: InMemorySecureStore()),
                offlineSignInStore: .init(secureStore: InMemorySecureStore()),
                switchProfile: { _ in }
            )
            home.plexHomeUserSwitch = { _, _, _, _ in throw AppError.unauthorized }
            home.plexServerTokenResolve = { _, _, _ in nil }
            accounts.tokenResolver = { [weak home] in home?.resolvedToken(for: $0) }
            accounts.credentialRevision = { [weak home] in home?.effectiveCredentialRevision(for: $0) ?? $0.credentialRevision }
            service = FamilyGuidanceService(accounts: accounts, profiles: profiles, plexHome: home)
        }

        func prepareHomeIdentity() async {
            home.plexHomeUsersFetch = { _, _ in
                [PlexHomeUser(id: "child-user", name: "Child", requiresPIN: false)]
            }
            home.plexHomeUserSwitch = { _, _, _, _ in "INITIAL-CHILD-CLOUD" }
            home.plexServerTokenResolve = { _, _, _ in "CHILD-SERVER" }
            home.ensurePlexIdentityForActiveProfile()
            await home.waitForPlexPINRequirementCheck()
        }

        func prepareMissingHomeCloudCredential() async throws {
            await prepareHomeIdentity()
            home.plexDiscoverTokens.setToken(nil, for: "account")
            home.plexServerTokenResolve = { _, _, _ in nil }
        }

        func close() { defaults.removePersistentDomain(forName: suite) }
    }

    func testOwnerUsesOwnCredential() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = try await fixture.service.loadFamilyGuidance(for: fixture.item)
        let tokens = await fixture.http.tokens
        XCTAssertEqual(tokens, ["OWNER-TOKEN"])
    }

    func testHomeUserWithoutCloudCredentialCannotFallBackToOwner() async throws {
        let fixture = try Fixture(homeUser: true)
        defer { fixture.close() }
        do {
            _ = try await fixture.service.loadFamilyGuidance(for: fixture.item)
            XCTFail("Expected missing Home credential to fail closed")
        } catch let error as AppError {
            XCTAssertEqual(error, .unauthorized)
        }
        let tokens = await fixture.http.tokens
        XCTAssertTrue(tokens.isEmpty)
    }

    func testHomeUserUsesAccountTokenInsteadOfServerToken() async throws {
        let fixture = try Fixture(homeUser: true)
        defer { fixture.close() }
        await fixture.prepareHomeIdentity()
        fixture.home.plexDiscoverTokens.setToken("CHILD-CLOUD", for: "account")
        _ = try await fixture.service.loadFamilyGuidance(for: fixture.item)
        let tokens = await fixture.http.tokens
        XCTAssertEqual(tokens, ["CHILD-CLOUD"])
        let hosts = await fixture.http.hosts
        XCTAssertEqual(hosts, ["metadata.provider.plex.tv"])
    }

    func testMissingHomeCloudCredentialIsRecoveredBeforeGuidanceRequest() async throws {
        let fixture = try Fixture(homeUser: true)
        defer { fixture.close() }
        try await fixture.prepareMissingHomeCloudCredential()
        fixture.home.plexHomeUserSwitch = { user, pin, _, _ in
            XCTAssertEqual(user, "child-user")
            XCTAssertNil(pin)
            return "RECOVERED-CHILD-CLOUD"
        }
        let context = fixture.service.contextID
        let result = try await fixture.service.loadFamilyGuidance(for: fixture.item)
        guard case .available = result else { return XCTFail("The recovered credential must load the review.") }
        XCTAssertEqual(fixture.service.contextID, context, "Credential repair must not dismiss an unchanged user's sheet.")
        XCTAssertEqual(fixture.home.resolvedToken(for: "account"), "CHILD-SERVER")
        let tokens = await fixture.http.tokens
        XCTAssertEqual(tokens, ["RECOVERED-CHILD-CLOUD"])
    }

    func testFirstGuidanceLoadWaitsForProfileAuthorization() async throws {
        let fixture = try Fixture(homeUser: true)
        defer { fixture.close() }
        fixture.home.plexHomeUserSwitch = { _, _, _, _ in "RECOVERED-CHILD-CLOUD" }
        fixture.home.plexServerTokenResolve = { _, _, _ in
            XCTFail("Opening guidance must not refresh the library's server credential.")
            return "ROTATED-SERVER-CREDENTIAL"
        }
        do {
            _ = try await fixture.service.loadFamilyGuidance(for: fixture.item)
            XCTFail("Guidance must not authorize an unresolved profile.")
        } catch let error as AppError {
            XCTAssertEqual(error, .unauthorized)
        }
        XCTAssertNil(fixture.home.resolvedToken(for: "account"))
        let tokens = await fixture.http.tokens
        XCTAssertTrue(tokens.isEmpty)
    }

    func testRetryAfterCloudRecoveryFailureUsesNewScopedCredential() async throws {
        let fixture = try Fixture(homeUser: true)
        defer { fixture.close() }
        try await fixture.prepareMissingHomeCloudCredential()
        fixture.home.plexHomeUserSwitch = { _, _, _, _ in throw AppError.unauthorized }
        do {
            _ = try await fixture.service.loadFamilyGuidance(for: fixture.item)
            XCTFail("The failed switch must not send the server or owner credential to guidance.")
        } catch let error as AppError {
            XCTAssertEqual(error, .unauthorized)
        }
        let rejectedTokens = await fixture.http.tokens
        XCTAssertTrue(rejectedTokens.isEmpty)
        fixture.home.plexHomeUserSwitch = { _, _, _, _ in "RECOVERED-CHILD-CLOUD" }
        let result = try await fixture.service.loadFamilyGuidance(for: fixture.item)
        guard case .available = result else { return XCTFail("Retry must try recovering the same Home user again.") }
        let tokens = await fixture.http.tokens
        XCTAssertEqual(tokens, ["RECOVERED-CHILD-CLOUD"])
    }

    func testSourceDisabledDuringCloudRecoveryDoesNotRequestGuidance() async throws {
        let fixture = try Fixture(homeUser: true)
        defer { fixture.close() }
        try await fixture.prepareMissingHomeCloudCredential()
        fixture.home.plexHomeUserSwitch = { _, _, _, _ in
            await MainActor.run {
                fixture.profiles.setActiveAccountIDs([], for: fixture.profiles.activeProfileID)
                fixture.accounts.reloadAccounts()
            }
            return "RECOVERED-CHILD-CLOUD"
        }
        do {
            _ = try await fixture.service.loadFamilyGuidance(for: fixture.item)
            XCTFail("The disabled source must not make a guidance request.")
        } catch is CancellationError {}
        let tokens = await fixture.http.tokens
        XCTAssertTrue(tokens.isEmpty)
    }

    func testRetryResolvesCurrentHomeCredentialWithoutOwnerFallback() async throws {
        let fixture = try Fixture(homeUser: true, statuses: [401, 200])
        defer { fixture.close() }
        await fixture.prepareHomeIdentity()
        fixture.home.plexDiscoverTokens.setToken("OLD-CHILD-CLOUD", for: "account")
        do {
            _ = try await fixture.service.loadFamilyGuidance(for: fixture.item)
            XCTFail("The rejected credential must be surfaced.")
        } catch let error as AppError {
            XCTAssertEqual(error, .unauthorized)
        }
        fixture.home.plexDiscoverTokens.setToken("NEW-CHILD-CLOUD", for: "account")
        let result = try await fixture.service.loadFamilyGuidance(for: fixture.item)
        guard case .available = result else { return XCTFail("Retry should use the now-current credential.") }
        let tokens = await fixture.http.tokens
        XCTAssertEqual(tokens, ["OLD-CHILD-CLOUD", "NEW-CHILD-CLOUD"])
        let hosts = await fixture.http.hosts
        XCTAssertEqual(hosts, ["metadata.provider.plex.tv", "metadata.provider.plex.tv"])
    }

    func testProfileSwitchDiscardsAnInFlightResponse() async throws {
        let fixture = try Fixture(suspended: true)
        defer { fixture.close() }
        let operation = Task { try await fixture.service.loadFamilyGuidance(for: fixture.item) }
        await fixture.http.waitForRequest()
        fixture.profiles.select("child")
        await fixture.http.resume()
        do {
            _ = try await operation.value
            XCTFail("A previous profile's guidance must not be published")
        } catch is CancellationError {}
    }

    func testRevokedHomeCredentialDiscardsAnInFlightResponse() async throws {
        let fixture = try Fixture(homeUser: true, suspended: true)
        defer { fixture.close() }
        await fixture.prepareHomeIdentity()
        fixture.home.plexDiscoverTokens.setToken("CHILD-CLOUD", for: "account")
        let operation = Task { try await fixture.service.loadFamilyGuidance(for: fixture.item) }
        await fixture.http.waitForRequest()
        fixture.home.plexDiscoverTokens.removeAll()
        await fixture.http.resume()
        do {
            _ = try await operation.value
            XCTFail("A revoked credential's response must not be published")
        } catch is CancellationError {}
    }

    func testDisabledSourceDiscardsAnInFlightResponse() async throws {
        let fixture = try Fixture(suspended: true)
        defer { fixture.close() }
        let operation = Task { try await fixture.service.loadFamilyGuidance(for: fixture.item) }
        await fixture.http.waitForRequest()
        fixture.profiles.setActiveAccountIDs([], for: fixture.profiles.activeProfileID)
        fixture.accounts.reloadAccounts()
        await fixture.http.resume()
        do {
            _ = try await operation.value
            XCTFail("A disabled source's response must not be published")
        } catch is CancellationError {}
    }
}

private actor GuidanceHTTP: HTTPClient {
    private let suspended: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var tokens: [String] = []
    private(set) var hosts: [String] = []
    private let statuses: [Int]

    init(suspended: Bool, statuses: [Int]) {
        self.suspended = suspended
        self.statuses = statuses
    }

    func waitForRequest() async {
        if !tokens.isEmpty { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        try await sendRaw(endpoint, baseURL: baseURL)
    }

    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        tokens.append(endpoint.headers["X-Plex-Token"] ?? "")
        hosts.append(baseURL.host ?? "")
        let status = statuses[min(tokens.count - 1, statuses.count - 1)]
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if suspended { await withCheckedContinuation { continuation = $0 } }
        return (
            Data(#"{"MediaContainer":{"CommonSenseMedia":[{"AgeRating":[{"type":"official","age":14,"rating":3}]}]}}"#.utf8),
            HTTPURLResponse(url: baseURL, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}
