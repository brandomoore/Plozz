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

        init(homeUser: Bool = false, suspended: Bool = false) throws {
            suite = "FamilyGuidanceTests.\(UUID())"
            defaults = UserDefaults(suiteName: suite)!
            let store = ProfileStore(defaults: defaults)
            store.saveProfiles([
                Profile(id: "owner", name: "Owner"),
                Profile(id: "child", name: "Child", plexHomeUserID: "child-user", plexHomeUserAccountID: "account")
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
            let client = GuidanceHTTP(suspended: suspended)
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
                switchProfile: { _ in }
            )
            service = FamilyGuidanceService(accounts: accounts, profiles: profiles, plexHome: home)
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
        fixture.home.plexDiscoverTokens.setToken("CHILD-CLOUD", for: "account")
        _ = try await fixture.service.loadFamilyGuidance(for: fixture.item)
        let tokens = await fixture.http.tokens
        XCTAssertEqual(tokens, ["CHILD-CLOUD"])
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

    init(suspended: Bool) { self.suspended = suspended }

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
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if suspended { await withCheckedContinuation { continuation = $0 } }
        return (
            Data(#"{"MediaContainer":{"CommonSenseMedia":[{"AgeRating":[{"type":"official","age":14,"rating":3}]}]}}"#.utf8),
            HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}
