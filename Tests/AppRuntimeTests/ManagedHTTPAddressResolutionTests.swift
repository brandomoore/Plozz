import AppRuntime
import CoreModels
import CoreSecureStore
import FeatureAuthCore
import Foundation
import MediaTransportCore
import ProviderSilo
@testable import TestSupportNetworking
import XCTest

@MainActor
final class ManagedHTTPAddressResolutionTests: XCTestCase {
    func testSiloResumeGrantSurvivesOnlySameViewerAndLoginRefreshes() async throws {
        let account = Account(id: "a", server: MediaServer(id: "server1", name: "Silo",
            baseURL: URL(string: "https://silo.test")!, provider: .silo),
            userID: "user:viewer", userName: "Viewer", deviceID: "device")
        func newLogin() throws -> String {
            try JSONDecoder().decode(SiloCredential.self, from: Data("""
                {"loginID":"\(UUID())","accountID":"user","profileID":"viewer","accessToken":"fixture",
                 "refreshToken":"refresh","expiresAt":2000000000}
                """.utf8)).encoded()
        }
        let store = AccountStore(secureStore: InMemorySecureStore())
        try store.add(account, token: newLogin())
        store.setActiveAccountIDs([account.id])
        let suite = "SiloResumeGrant.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        let model = AccountsProvidersModel(accountStore: store, registry: ProviderRegistry(),
                                          profilesModel: profiles, removedAccountIDs: { [] })
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/catalog/items/movie:1", json: """
            {"content_id":"movie:1","type":"movie","title":"Movie","position_seconds":125,
             "versions":[{"file_id":"42","resolution":"1080p","codec_video":"h264","codec_audio":"aac",
             "container":"mkv","duration":600,"file_size":100,"bitrate":1000}]}
            """)
        http.stub(pathSuffix: "/playback/capabilities", json: """
            {"installation_id":"server1","protocol_versions":[3],"features":["fixed_media_file_v1"],
             "deliveries":["original_http"],"state":"available","allowed":true}
            """)
        http.stub(pathSuffix: "/playback/start", json: """
            {"protocol_version":3,"outcome":"playable","session_id":"s1","playback_plan":{
             "protocol_version":3,"delivery":"original_http","effective_media_file_id":"42",
             "stream":{"url":"https://silo.test/api/v2/stream/s1","headers":{},"header_refresh":"none"},
             "timeline":{"source_start_seconds":0,"player_start_seconds":0,"timeline_offset_seconds":0,"can_seek_anywhere":true},
             "subtitle":{"mode":"none","inventory":[]}}}
            """)
        model.registry.register(.silo) { try SiloProvider(context: $0, credentials: store, http: http) }
        model.tokenResolver = { store.token(for: $0) }
        model.reloadAccounts()
        let retained = try XCTUnwrap(model.homeAccounts.first?.provider)
        model.reloadAccounts()
        func resumeGrant(from provider: any MediaProvider) async throws -> AuthenticatedHTTPPlaybackLocator {
            let request = try await provider.playbackInfo(for: "movie:1")
            XCTAssertEqual(request.startPosition, 125)
            guard case .authenticatedHTTP(let locator) = request.playbackSource else {
                XCTFail("Expected an opaque Silo grant")
                throw AppError.invalidResponse
            }
            return locator
        }
        let locator = try await resumeGrant(from: retained)
        let resolver = ManagedAuthenticatedHTTPResolver()
        resolver.configure { locator in
            guard let current = model.provider(forAccountID: locator.accountID) as? SiloProvider else {
                throw AppError.unauthorized
            }
            return .init(provider: current.kind, accountID: current.accountID,
                         credentialRevision: current.credentialRevision, baseURL: current.session.server.baseURL,
                         token: current.session.accessToken, resourceResolver: current)
        }
        model.reloadAccounts()
        let url = try await resolver.resolve(locator)
        XCTAssertEqual(url.path, "/api/v2/stream/s1")
        let other = profiles.add(name: "Other", activeAccountIDs: [account.id])
        profiles.select(other.id)
        model.reloadAccounts()
        do {
            _ = try await resolver.resolve(locator)
            XCTFail("A different Plozz profile must not inherit the first viewer's stream")
        } catch { XCTAssertEqual(error as? AppError, .notFound) }
        let next = try XCTUnwrap(model.homeAccounts.first?.provider)
        let previousLogin = try await resumeGrant(from: next)
        try store.replaceAuthenticatedSession(account.session(token: newLogin()), expected: XCTUnwrap(model.accounts.first))
        model.reloadAccounts()
        do {
            _ = try await resolver.resolve(previousLogin)
            XCTFail("Replacing a login must retire its grants")
        } catch {
            guard case .authentication = error as? MediaTransportError else {
                return XCTFail("Expected the credential revision check to reject the old grant")
            }
        }
        let signedIn = try XCTUnwrap(model.homeAccounts.first?.provider)
        let currentLogin = try await resumeGrant(from: signedIn)
        try store.remove(id: account.id)
        model.reloadAccounts()
        do {
            _ = try await resolver.resolve(currentLogin)
            XCTFail("Removing an account must retire its grants")
        } catch { XCTAssertEqual(error as? AppError, .unauthorized) }
    }

    func testResolvedOriginUsesItsBasePathAndRejectsAnAddressEditDuringSuspension() async throws {
        for changeDuringResolution in [false, true] {
            let resolver = ManagedAuthenticatedHTTPResolver()
            let origin = HeldHTTPOrigin()
            let revision = CredentialRevision()
            var scope = "before"
            resolver.configure { _ in
                .init(provider: .jellyfin, accountID: "account", credentialRevision: revision,
                      baseURL: URL(string: "https://original.test/old")!, token: "credential",
                      originProvider: origin, connectionScopeKey: scope)
            }
            let locator = try AuthenticatedHTTPPlaybackLocator(
                provider: .jellyfin, accountID: "account", credentialRevision: revision,
                itemID: "movie", deliveryMode: .directFile,
                resource: AuthenticatedHTTPResource(pathBase: .configuredBaseURL, path: "Videos/movie/stream")
            )
            let task = Task { try await resolver.resolve(locator) }
            await origin.waitUntilResolving()
            if changeDuringResolution { scope = "after" }
            await origin.release()
            do {
                let result = try await task.value
                XCTAssertFalse(changeDuringResolution)
                XCTAssertEqual(result.host, "192.168.1.50")
                XCTAssertEqual(result.path, "/local/Videos/movie/stream")
            } catch {
                XCTAssertTrue(changeDuringResolution)
            }
        }
    }
}

private actor HeldHTTPOrigin: AuthenticatedHTTPOriginProviding {
    nonisolated let authenticatedHTTPOrigin = URL(string: "http://192.168.1.50/local")!
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func resolveAuthenticatedHTTPOrigin() async throws -> URL {
        await withCheckedContinuation {
            pending = $0
            observer?.resume()
            observer = nil
        }
        return authenticatedHTTPOrigin
    }
    func waitUntilResolving() async {
        if pending != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { pending?.resume(); pending = nil }
}
