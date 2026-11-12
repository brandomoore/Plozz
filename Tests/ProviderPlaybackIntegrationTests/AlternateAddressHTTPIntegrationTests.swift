import AppRuntime
import CoreModels
import CoreNetworking
import FeatureAuthCore
import Foundation
@testable import ProviderJellyfin
@testable import ProviderPlex
import ProviderSilo
import XCTest
@testable import TestSupportNetworking

/// Controlled provider contracts over real TCP/URLSession, not live upstream servers.
@MainActor
final class AlternateAddressHTTPIntegrationTests: XCTestCase {
    func testJellyfinColdAndWarmFallbackWithProxyPaths() async throws {
        try await exerciseProvider(.jellyfin, cold: true)
        try await exerciseProvider(.jellyfin, cold: false)
    }

    func testEmbyColdAndWarmFallbackWithProxyPaths() async throws {
        try await exerciseProvider(.emby, cold: true)
        try await exerciseProvider(.emby, cold: false)
    }

    func testPlexColdAndWarmFallbackWithProxyPaths() async throws {
        try await exerciseProvider(.plex, cold: true)
        try await exerciseProvider(.plex, cold: false)
    }

    func testSiloPairingApprovalAndColdAndWarmAPIFallback() async throws {
        try await exerciseProvider(.silo, cold: true)
        try await exerciseProvider(.silo, cold: false)
    }

    private func exerciseProvider(_ kind: ProviderKind, cold: Bool) async throws {
        let id = UUID().uuidString
        defer {
            UserDefaults.standard.removeObject(forKey: "plex.reachable.\(id)")
            UserDefaults.standard.removeObject(forKey: "plex.artwork-origins.\(id)")
        }
        let primaryFixture = ManagedAddressFixture(kind: kind, id: id, prefix: "/outside")
        let alternateFixture = ManagedAddressFixture(kind: kind, id: id, prefix: "/inside", probeDelay: .milliseconds(150))
        let (primary, primaryURL) = try await server { await primaryFixture.respond($0) }
        let (alternate, alternateURL) = try await server { await alternateFixture.respond($0) }
        let originalURL = primaryURL.appendingPathComponent("outside")
        let approvedURL = alternateURL.appendingPathComponent("inside")
        let http = client()
        let store = AccountStore(secureStore: InMemorySecureStore())
        let token = kind == .silo ? try siloCredential(access: "account-token") : "account-token"
        let account = Account(id: "account", server: MediaServer(id: id, name: "Fixture",
            baseURL: originalURL, provider: kind), userID: kind == .silo ? "viewer:profile" : "viewer",
            userName: "Viewer", deviceID: "device")
        try store.add(account, token: token)
        let registry = ProviderRegistry()
        registry.register(kind) { context in
            switch kind {
            case .silo:
                return try SiloProvider(context: context, credentials: store, http: http, addressProbe: http)
            case .plex:
                return PlexProvider(session: context.session, accountID: context.accountID,
                    credentialRevision: context.credentialRevision, http: http, probe: http)
            default:
                return JellyfinProvider(session: context.session, accountID: context.accountID,
                    credentialRevision: context.credentialRevision, http: http, addressProbe: http)
            }
        }
        let provider = try registry.provider(for: .init(session: account.session(token: token),
            accountID: account.id, credentialRevision: account.credentialRevision))
        let model = ServerAddressesModel(account: account, store: store, http: http, isAuthorized: { true }) {
            registry.updateServerAddresses(accountID: account.id,
                alternatives: store.loadAccounts().first?.server.alternateConnectionURLs ?? [])
        }
        model.address = approvedURL.absoluteString
        await model.add()
        if kind == .silo {
            let pairingServer = try XCTUnwrap(model.pairingServer)
            let temporary = try SiloCredential.decode(siloCredential(access: "verification-token"))
            let verification = UserSession(server: pairingServer, userID: account.userID,
                userName: account.userName, deviceID: account.deviceID, accessToken: try temporary.encoded())
            await model.completePairing(verification)
        }
        XCTAssertNil(model.errorMessage)
        let updated = try XCTUnwrap(store.loadAccounts().first)
        XCTAssertEqual(updated.server.alternateConnectionURLs, [approvedURL])
        XCTAssertEqual(store.token(for: account.id), token)
        XCTAssertEqual(updated.credentialRevision, account.credentialRevision)

        _ = try registry.provider(for: .init(session: updated.session(token: token),
            accountID: updated.id, credentialRevision: updated.credentialRevision))
        let expectedLibraryIDs = kind.usesMediaBrowserAPI ? ["movies", "\(kind.rawValue):collections"] : ["movies"]
        if !cold {
            let libraries = try await provider.libraries()
            XCTAssertEqual(libraries.map(\.id), expectedLibraryIDs)
            let initialRequests = await primary.requests
            XCTAssertTrue(initialRequests.contains {
                $0.target.contains("libraries") || $0.target.contains("/Views") || $0.target.contains("/sections")
            })
        }
        await primary.stop()
        let libraries = try await provider.libraries()
        XCTAssertEqual(libraries.map(\.id), expectedLibraryIDs)
        let requests = await alternate.requests
        XCTAssertTrue(requests.contains { $0.target.hasPrefix("/inside/") && $0.headers.values.contains(where: { $0.contains("account-token") }) })
        let publicProbes = requests.filter {
            $0.target.contains("/System/Info/Public") || $0.target.contains("/system/info")
        }
        XCTAssertTrue(publicProbes.allSatisfy { $0.headers["authorization"] == nil })
        if kind == .silo {
            XCTAssertEqual(requests.filter { $0.target.hasSuffix("/auth/logout") }.map { $0.headers["authorization"] },
                           ["Bearer verification-token"])
        } else {
            try await verifyMediaFetch(provider, account: updated, token: token, originalURL: originalURL,
                                       approvedURL: approvedURL)
        }

        let beforeRemoval = await alternate.requests.count
        model.remove(approvedURL)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(store.loadAccounts().first?.server.alternateConnectionURLs)
        do {
            _ = try await provider.libraries()
            XCTFail("The retained provider must not use the removed route while its original address is offline")
        } catch { XCTAssertEqual(error as? AppError, .serverUnreachable) }
        let afterRemoval = await alternate.requests.count
        XCTAssertEqual(afterRemoval, beforeRemoval, "No new request, including probes, may use the removed address")
    }

    private func verifyMediaFetch(_ provider: any MediaProvider, account: Account, token: String,
                                  originalURL: URL, approvedURL: URL) async throws {
        let kind = account.server.provider
        let originProvider = try XCTUnwrap(provider as? any AuthenticatedHTTPOriginProviding)
        let resolver = ManagedAuthenticatedHTTPResolver()
        resolver.configure { _ in
            .init(provider: kind, accountID: account.id, credentialRevision: account.credentialRevision,
                  baseURL: originalURL, token: token, originProvider: originProvider,
                  connectionScopeKey: account.connectionScopeKey)
        }
        let locator: AuthenticatedHTTPPlaybackLocator
        if let plex = provider as? PlexProvider {
            locator = try plex.authenticatedPlaybackLocator(itemID: "movie", mediaSourceID: nil,
                url: originalURL.appendingPathComponent("media/movie"), deliveryMode: .directFile,
                purpose: .originalFile, playSessionID: nil, formatHint: "mp4")
        } else {
            let jellyfin = try XCTUnwrap(provider as? JellyfinProvider)
            locator = try AuthenticatedHTTPPlaybackLocator(provider: kind, accountID: account.id,
                credentialRevision: account.credentialRevision, itemID: "movie", deliveryMode: .directFile,
                resource: jellyfin.credentialFreeResource(
                    fromServerPath: originalURL.appendingPathComponent("media/movie").absoluteString))
        }
        let resource = try await resolver.resolve(locator)
        XCTAssertEqual(resource.port, approvedURL.port)
        XCTAssertEqual(resource.path, "/inside/media/movie")
        let session = session()
        let (bytes, response) = try await session.data(from: resource)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(bytes, Data("fixture-media-bytes".utf8))
    }

    func testAllAddressesOfflineNeverTransmitsRotatingExchange() async throws {
        let (primary, first) = try await server { _ in .json("{}") }
        let (backup, second) = try await server { _ in .json("{}") }
        await primary.stop()
        await backup.stop()
        let http = client()
        let resolver = ServerAddressResolver(baseURL: first, alternatives: [second]) { url in
            _ = try await http.send(Endpoint(path: "/probe", redirectPolicy: .sameOrigin), baseURL: url)
        }
        let routed = ServerAddressHTTPClient(wrapped: http, resolver: resolver)
        var exchange = Endpoint(method: .post, path: "/refresh", body: Data("one-use-refresh".utf8))
        exchange.reportsUndeliveredRequests = true
        do {
            _ = try await routed.send(exchange, baseURL: first)
            XCTFail("Offline is not a successful refresh")
        } catch let error as HTTPRequestNotSentError {
            XCTAssertEqual(error.underlying, .serverUnreachable)
        }
        XCTAssertNil(resolver.confirmed)
    }

    func testCancelledRealHTTPRequestDoesNotFallBack() async throws {
        let (primary, first) = try await server { request in
            .init(delay: request.target == "/operation" ? .seconds(2) : .zero)
        }
        let (backup, second) = try await server { _ in .init(delay: .milliseconds(150)) }
        let http = client()
        let resolver = ServerAddressResolver(baseURL: first, alternatives: [second]) { url in
            _ = try await http.send(Endpoint(path: "/probe", redirectPolicy: .sameOrigin), baseURL: url)
        }
        let routed = ServerAddressHTTPClient(wrapped: http, resolver: resolver)
        let task = Task { try await routed.send(Endpoint(path: "/operation"), baseURL: first) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await primary.requests.contains(where: { $0.target == "/operation" })), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let started = await primary.requests.contains { $0.target == "/operation" }
        XCTAssertTrue(started)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError || error as? AppError == .cancelled) }
        let requests = await backup.requests
        XCTAssertFalse(requests.contains { $0.target == "/operation" })
    }

    func testContinuousSuccessfulTrafficDoesNotPostponeRouteReconsideration() async throws {
        let availability = AddressRecoveryFixture()
        let (_, preferred) = try await server { await availability.respond($0) }
        let (_, fallback) = try await server { request in
            .init(body: Data("fallback".utf8), delay: request.target == "/probe" ? .milliseconds(150) : .zero)
        }
        let http = client()
        let resolver = ServerAddressResolver(baseURL: preferred, alternatives: [fallback]) { url in
            _ = try await http.send(Endpoint(path: "/probe", redirectPolicy: .sameOrigin), baseURL: url)
        }
        let routed = ServerAddressHTTPClient(wrapped: http, resolver: resolver)
        let endpoint = Endpoint(path: "/read")
        let (initial, _) = try await routed.send(endpoint, baseURL: preferred)
        XCTAssertEqual(initial, Data("fallback".utf8))
        await availability.recover()
        for _ in 0..<7 {
            try await Task.sleep(for: .seconds(5))
            _ = try await routed.send(endpoint, baseURL: preferred)
        }
        XCTAssertEqual(resolver.current, preferred,
                       "Successful requests every five seconds must not extend the 30-second selection lifetime")
    }

    func testWrongServerAndCrossOriginValidationRedirectNeverReceiveSavedCredential() async throws {
        let (foreign, foreignURL) = try await server { _ in .json(#"{"Id":"saved-server"}"#) }
        for redirects in [false, true] {
            let (candidate, url) = try await server { _ in
                redirects ? .init(status: 302, headers: ["Location": foreignURL.absoluteString + "/identity"])
                    : .json(#"{"Id":"wrong-server"}"#)
            }
            let account = Account(server: .init(id: "saved-server", name: "Saved",
                baseURL: URL(string: "https://saved.invalid")!, provider: .jellyfin),
                userID: "viewer", userName: "Viewer", deviceID: "device")
            let store = AccountStore(secureStore: InMemorySecureStore())
            try store.add(account, token: "private-saved-token")
            let model = ServerAddressesModel(account: account, store: store, http: client(),
                isAuthorized: { true }, onChanged: { XCTFail("Unverified address persisted") })
            model.address = url.absoluteString
            await model.add()
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(store.loadAccounts(), [account])
            let received = await candidate.requests
            XCTAssertFalse(received.isEmpty)
            XCTAssertTrue(received.allSatisfy { $0.headers["authorization"] == nil })
        }
        let redirected = await foreign.requests
        XCTAssertTrue(redirected.isEmpty)
    }

    private actor AddressRecoveryFixture {
        private var online = false
        func recover() { online = true }
        func respond(_ request: LoopbackHTTPServer.Request) -> LoopbackHTTPServer.Response {
            online ? .init(body: Data("preferred".utf8)) : .init(disconnect: true)
        }
    }

    func testConnectionDropRetriesGETButNeverReplaysTransmittedMutation() async throws {
        for method in [HTTPMethod.get, .post, .delete] {
            let (_, first) = try await server { request in
                request.target == "/probe" ? .json("{}") : .init(disconnect: true)
            }
            let (backup, second) = try await server { request in
                .init(body: Data("backup".utf8), delay: request.target == "/probe" ? .milliseconds(150) : .zero)
            }
            let http = client()
            let resolver = ServerAddressResolver(baseURL: first, alternatives: [second]) { url in
                _ = try await http.send(Endpoint(path: "/probe", redirectPolicy: .sameOrigin), baseURL: url)
            }
            let routed = ServerAddressHTTPClient(wrapped: http, resolver: resolver)
            let endpoint = Endpoint(method: method, path: "/operation",
                                    headers: ["Authorization": "Bearer account-token"],
                                    body: method == .post ? Data("mutation".utf8) : nil)
            do {
                let (data, _) = try await routed.send(endpoint, baseURL: first)
                XCTAssertEqual(method, .get)
                XCTAssertEqual(data, Data("backup".utf8))
            } catch {
                XCTAssertNotEqual(method, .get)
                XCTAssertEqual(error as? AppError, .serverUnreachable)
            }
            let requests = await backup.requests.filter { $0.target == "/operation" }
            XCTAssertEqual(requests.count, method == .get ? 1 : 0)
        }
    }

    func testAuthenticationFailureAndCrossOriginRedirectDoNotTryOtherAddresses() async throws {
        let (foreign, foreignURL) = try await server { _ in .json("{}") }
        for status in [401, 403, 302] {
            let (_, first) = try await server { request in
                request.target == "/probe" ? .json("{}")
                    : .init(status: status, headers: ["Location": foreignURL.absoluteString + "/foreign"])
            }
            let (backup, second) = try await server { _ in .init(body: Data()) }
            let http = client()
            let resolver = ServerAddressResolver(baseURL: first, alternatives: [second]) { url in
                _ = try await http.send(Endpoint(path: "/probe", redirectPolicy: .sameOrigin), baseURL: url)
            }
            // Confirm the challenged endpoint independently of probe scheduling.
            let selected = try await resolver.resolved(excluding: second)
            XCTAssertEqual(selected, first)
            let routed = ServerAddressHTTPClient(wrapped: http, resolver: resolver)
            do {
                _ = try await routed.send(Endpoint(path: "/operation",
                    headers: ["Authorization": "Bearer account-token"]), baseURL: first)
                XCTFail("The response must remain a failure")
            } catch {
                XCTAssertEqual(error as? AppError, status == 302 ? .invalidResponse : .unauthorized)
            }
            let requests = await backup.requests
            XCTAssertTrue(requests.allSatisfy { $0.target == "/probe" && $0.headers["authorization"] == nil })
        }
        let requests = await foreign.requests
        XCTAssertTrue(requests.isEmpty)
    }

    private func server(
        _ response: @escaping @Sendable (LoopbackHTTPServer.Request) async -> LoopbackHTTPServer.Response
    ) async throws -> (LoopbackHTTPServer, URL) {
        let fixture = try LoopbackHTTPServer(respond: response)
        addTeardownBlock { await fixture.stop() }
        return (fixture, try await fixture.start())
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel() }
        return session
    }

    private func client() -> URLSessionHTTPClient { URLSessionHTTPClient(session: session()) }

    private func siloCredential(access: String) throws -> String {
        let tokens = try JSONDecoder().decode(SiloTokenPair.self, from: Data("""
            {"access_token":"\(access)","refresh_token":"fixture-refresh","expires_in":3600,
             "user":{"id":"viewer","username":"Viewer"}}
            """.utf8))
        let profile = try JSONDecoder().decode(SiloProfile.self, from: Data(
            #"{"id":"profile","name":"Viewer","has_pin":false,"is_child":false}"#.utf8))
        return try SiloCredential(tokens: tokens, profile: profile, profileToken: nil).encoded()
    }
}

private actor ManagedAddressFixture {
    let kind: ProviderKind
    let id: String
    let prefix: String
    let probeDelay: Duration
    init(kind: ProviderKind, id: String, prefix: String, probeDelay: Duration = .zero) {
        self.kind = kind
        self.id = id
        self.prefix = prefix
        self.probeDelay = probeDelay
    }

    func respond(_ request: LoopbackHTTPServer.Request) -> LoopbackHTTPServer.Response {
        guard request.target.hasPrefix(prefix + "/") else { return .json("{}", status: 404) }
        let path = String(request.target.dropFirst(prefix.count)).split(separator: "?").first.map(String.init) ?? ""
        if ["/System/Info/Public", "/identity", "/api/v2/system/info"].contains(path) {
            var result = LoopbackHTTPServer.Response.json(
                kind == .plex ? "{\"MediaContainer\":{\"machineIdentifier\":\"\(id)\"}}"
                    : kind == .silo ? #"{"api_major":2}"# : "{\"Id\":\"\(id)\"}"
            )
            result.delay = probeDelay
            return result
        }
        if path == "/api/v2/auth/logout" {
            return .json("{}", status: request.headers["authorization"] == "Bearer verification-token" ? 200 : 401)
        }
        guard request.headers.values.contains(where: { $0.contains("account-token") })
            || request.target.contains("account-token") else { return .json("{}", status: 401) }
        if path == "/media/movie" { return .init(body: Data("fixture-media-bytes".utf8)) }
        if kind == .plex {
            return .json(#"{"MediaContainer":{"Directory":[{"key":"movies","title":"Movies","type":"movie"}]}}"#)
        }
        if kind == .silo {
            return .json(#"{"items":[{"id":"movies","name":"Movies","type":"movie"}]}"#)
        }
        return .json(#"{"Items":[{"Id":"movies","Name":"Movies","CollectionType":"movies"}],"TotalRecordCount":1}"#)
    }
}
