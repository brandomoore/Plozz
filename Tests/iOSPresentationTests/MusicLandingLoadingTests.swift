import CoreModels
@testable import FeatureMusic
import SwiftUI
import UIKit
import XCTest

@MainActor
final class MusicLandingLoadingTests: XCTestCase {
    func testCancelledInitialLoadRemainsRetryableWithoutClaimingLibraryIsEmpty() async {
        let gate = LandingRequestGate()
        let entered = expectation(description: "Initial profile request entered")
        let provider = LandingTestProvider { kind in
            guard kind == .album else { return MusicPage() }
            entered.fulfill()
            await gate.wait()
            try Task.checkCancellation()
            return MusicPage(albums: [MusicAlbum(id: "album", title: "Album")])
        }
        let model = MusicLandingViewModel(context: MusicContext(accounts: [provider.resolved]))
        let task = Task { await model.load() }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        await gate.release()
        await task.value
        XCTAssertEqual(model.state, .idle)
    }

    func testTransientInitialFailureRecoversWithoutManualRetry() async {
        let attempts = LandingAttempts()
        let provider = LandingTestProvider { kind in
            guard kind == .album else { return MusicPage() }
            if await attempts.next() == 1 { throw AppError.serverUnreachable }
            return MusicPage(albums: [MusicAlbum(id: "album", title: "Album")])
        }
        let model = MusicLandingViewModel(context: MusicContext(accounts: [provider.resolved]))
        await model.load()
        XCTAssertEqual(model.state.value?.albums.map(\.id), ["album"])
        let calls = await attempts.count
        XCTAssertEqual(calls, 2)
    }

    func testAuthorizationFailureIsNotEmptyAndDoesNotRetry() async {
        let attempts = LandingAttempts()
        let provider = LandingTestProvider { kind in
            guard kind == .album else { return MusicPage() }
            _ = await attempts.next()
            throw AppError.unauthorized
        }
        let model = MusicLandingViewModel(context: MusicContext(accounts: [provider.resolved]))
        await model.load()
        XCTAssertEqual(model.state, .failed(.unauthorized))
        let calls = await attempts.count
        XCTAssertEqual(calls, 1)
    }

    func testSupersededRequestCannotReplaceNewerContent() async throws {
        let gate = LandingRequestGate()
        let attempts = LandingAttempts()
        let entered = expectation(description: "Older request entered")
        let provider = LandingTestProvider { kind in
            guard kind == .album else { return MusicPage() }
            let call = await attempts.next()
            if call == 1 {
                entered.fulfill()
                await gate.wait()
            }
            return MusicPage(albums: [MusicAlbum(id: "\(call)", title: "Album \(call)")])
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = MusicLandingCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MusicLandingViewModel(context: MusicContext(accounts: [provider.resolved]), cache: cache)
        let old = Task { await model.load() }
        await fulfillment(of: [entered], timeout: 2)
        await model.load()
        await gate.release()
        await old.value
        XCTAssertEqual(model.state.value?.albums.map(\.id), ["2"])
        let snapshot = await cache.snapshot(for: MusicLandingCache.key(visibleLibraryIDs: [:]))
        XCTAssertEqual(snapshot?.albums.map(\.id), ["2"])
    }

    func testSuccessfulEmptyLibraryStillShowsEmpty() async {
        let provider = LandingTestProvider { _ in MusicPage() }
        let model = MusicLandingViewModel(context: MusicContext(accounts: [provider.resolved]))
        await model.load()
        XCTAssertEqual(model.state, .empty)
    }

    func testPersistentTransientFailureHasBoundedRetries() async {
        let attempts = LandingAttempts()
        let provider = LandingTestProvider { kind in
            guard kind == .album else { return MusicPage() }
            _ = await attempts.next()
            throw AppError.serverUnreachable
        }
        let model = MusicLandingViewModel(context: MusicContext(accounts: [provider.resolved]))
        await model.load(retryDelays: [.zero, .zero])
        XCTAssertEqual(model.state, .failed(.serverUnreachable))
        let calls = await attempts.count
        XCTAssertEqual(calls, 3)
    }

    func testRateLimitDoesNotRetry() async {
        let attempts = LandingAttempts()
        let provider = LandingTestProvider { kind in
            guard kind == .album else { return MusicPage() }
            _ = await attempts.next()
            throw AppError.rateLimited(retryAfter: 30)
        }
        let model = MusicLandingViewModel(context: MusicContext(accounts: [provider.resolved]))
        await model.load(retryDelays: [.zero, .zero])
        XCTAssertEqual(model.state, .failed(.rateLimited(retryAfter: 30)))
        let calls = await attempts.count
        XCTAssertEqual(calls, 1)
    }

    func testUsablePartialContentSurvivesFailedRequestAndLaterRefresh() async {
        let attempts = LandingAttempts()
        let provider = LandingTestProvider { kind in
            if kind == .playlist { throw AppError.serverUnreachable }
            guard kind == .album else { return MusicPage() }
            if await attempts.next() > 1 { throw AppError.serverUnreachable }
            return MusicPage(albums: [MusicAlbum(id: "album", title: "Album")])
        }
        let model = MusicLandingViewModel(context: MusicContext(accounts: [provider.resolved]))
        await model.load(retryDelays: [])
        XCTAssertEqual(model.state.value?.albums.map(\.id), ["album"])
        await model.load(retryDelays: [])
        XCTAssertEqual(model.state.value?.albums.map(\.id), ["album"])
    }

    func testProviderCancellationWithoutParentCancellationCanRecover() async {
        let attempts = LandingAttempts()
        let provider = LandingTestProvider { kind in
            guard kind == .album else { return MusicPage() }
            if await attempts.next() == 1 { throw URLError(.cancelled) }
            return MusicPage(albums: [MusicAlbum(id: "album", title: "Album")])
        }
        let model = MusicLandingViewModel(context: MusicContext(accounts: [provider.resolved]))
        await model.load(retryDelays: [.zero])
        XCTAssertEqual(model.state.value?.albums.map(\.id), ["album"])
    }

    func testReenteringViewRestartsWhileCancelledLoadIsStillUnwinding() async throws {
        let gate = LandingRequestGate()
        let attempts = LandingAttempts()
        let entered = expectation(description: "Initial request")
        let cancelled = expectation(description: "View task cancelled")
        let reentered = expectation(description: "Reentry starts a fresh request")
        let provider = LandingTestProvider { kind in
            guard kind == .album else { return MusicPage() }
            if await attempts.next() == 1 {
                entered.fulfill()
                await withTaskCancellationHandler {
                    await gate.wait()
                } onCancel: { cancelled.fulfill() }
            } else {
                reentered.fulfill()
            }
            return MusicPage(albums: [MusicAlbum(id: "album", title: "Album")])
        }
        let model = MusicLandingViewModel(context: MusicContext(accounts: [provider.resolved]))
        let controller = AudioPlaybackController()
        let landing = MusicLandingView(
            viewModel: model, controller: controller, onSelectRoute: { _ in }, onPlayTrack: { _ in }
        )
        try await withHost(AnyView(landing)) { host in
            await fulfillment(of: [entered], timeout: 2)
            host.rootView = AnyView(Color.clear)
            await fulfillment(of: [cancelled], timeout: 2)
            host.rootView = AnyView(landing)
            await fulfillment(of: [reentered], timeout: 2)
            await gate.release()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(model.state.value?.albums.map(\.id), ["album"])
        }
        controller.stop()
    }

    func testMountedTabRefreshesWhenDiscoveryAndProfileScopeChange() async throws {
        let loaded = (0..<4).map { expectation(description: "Scope \($0) requested") }
        let attempts = LandingAttempts()
        let provider = LandingTestProvider { kind in
            guard kind == .album else { return MusicPage() }
            let call = await attempts.next()
            if call <= loaded.count { loaded[call - 1].fulfill() }
            return MusicPage()
        }
        let account = provider.resolved
        let renewed = ResolvedAccount(
            account: account.account, provider: provider, credentialRevision: CredentialRevision()
        )
        let controller = AudioPlaybackController()
        let settings = MusicPlayerSettingsModel()
        let namespace = UUID().uuidString
        func tab(_ accounts: [ResolvedAccount], libraries: [String: [String]], profile: String) -> AnyView {
            AnyView(MusicTabView(
                accounts: accounts, visibleLibraryIDs: libraries, controller: controller,
                authenticatedHTTPResolver: LandingHTTPResolver(), musicPlayer: settings,
                showNowPlaying: .constant(false), namespace: profile
            ))
        }
        try await withHost(tab([], libraries: [:], profile: namespace)) { host in
            // Let the original empty-context model become retained SwiftUI state.
            try await Task.sleep(for: .milliseconds(100))
            let scopes: [([ResolvedAccount], [String: [String]], String)] = [
                ([account], ["account": ["first"]], namespace),
                ([account], ["account": ["second"]], namespace),
                ([renewed], ["account": ["second"]], namespace),
                ([renewed], ["account": ["second"]], namespace + "-next")
            ]
            for (index, scope) in scopes.enumerated() {
                host.rootView = tab(scope.0, libraries: scope.1, profile: scope.2)
                await fulfillment(of: [loaded[index]], timeout: 2)
            }
        }
        controller.stop()
    }

    private func withHost(
        _ view: AnyView, inspect: (UIHostingController<AnyView>) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await inspect(host)
    }
}

private struct LandingHTTPResolver: AuthenticatedHTTPResourceResolving {
    func resolve(_ locator: AuthenticatedHTTPPlaybackLocator) async throws -> URL { throw AppError.notFound }
}

private actor LandingRequestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor LandingAttempts {
    private(set) var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

private final class LandingTestProvider: MediaProvider, MusicProvider, Sendable {
    let kind = ProviderKind.jellyfin
    let session = UserSession(
        server: MediaServer(id: "server", name: "Server", baseURL: URL(string: "https://music.example")!, provider: .jellyfin),
        userID: "user", userName: "User", deviceID: "device", accessToken: ""
    )
    let request: @Sendable (MusicItemKind) async throws -> MusicPage
    init(request: @escaping @Sendable (MusicItemKind) async throws -> MusicPage) { self.request = request }
    var resolved: ResolvedAccount { ResolvedAccount(account: Account(id: "account", from: session), provider: self) }
    func musicLibraries() async throws -> [MediaLibrary] { [MediaLibrary(id: "music", title: "Music", kind: .folder)] }
    func tracks(in containerID: String) async throws -> [MusicTrack] { [] }
    func musicItems(in containerID: String, kind: MusicItemKind, page: PageRequest) async throws -> MusicPage {
        try await request(kind)
    }
    func audioPlaybackInfo(for trackID: String, queueContext: [String]?) async throws -> AudioPlaybackRequest { throw AppError.notFound }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
