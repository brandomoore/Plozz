import CoreModels
import CoreUI
import EnginePlozzigen
import FeatureHomeCore
import FeaturePlayback
import Observation
import SwiftUI
import TopShelfKit
import UIKit
import XCTest
@testable import AppShell

@MainActor
final class DeepLinkPlaybackHostedTests: XCTestCase {
    func testWarmLinkReplacesPlayingTitleAndSameTitleCanBeRequestedAgain() async throws {
        let host = try await makeHost()
        host.probe.play("first")
        try await waitForPlayback(host.probe, title: "first", count: 1)
        host.probe.play("second")
        try await waitForPlayback(host.probe, title: "second", count: 2)
        XCTAssertEqual(host.probe.engines[0].status, .idle)
        host.probe.play("second")
        try await waitForPlayback(host.probe, title: "second", count: 3)
        XCTAssertEqual(host.probe.engines[1].status, .idle)
        XCTAssertEqual(host.probe.path, ["first", "second", "second"])
    }

    func testWarmResumeRequestDismissesOldPlayerBeforePrompt() async throws {
        let host = try await makeHost()
        host.probe.play("first")
        try await waitForPlayback(host.probe, title: "first", count: 1)
        host.probe.play("resume")
        try await waitUntil { host.probe.engines[0].status == .idle }
        XCTAssertEqual(host.probe.models.count, 1, "The resume choice must precede playback.")
        XCTAssertNil(host.probe.playRequest, "The old request must not reopen when the prompt is cancelled.")
        XCTAssertEqual(host.probe.resumePrompt?.id, "resume")
        try await waitUntil {
            (host.window.rootViewController?.presentedViewController as? UIAlertController)?.title == "resume"
        }
        host.probe.resumePrompt = nil
        try await waitUntil { host.window.rootViewController?.presentedViewController == nil }
        XCTAssertNil(host.probe.playRequest)
        host.probe.play("after-cancel")
        try await waitForPlayback(host.probe, title: "after-cancel", count: 2)
    }

    func testColdQueuedLinkWaitsForAccountsAndProfileAuthorization() async throws {
        let host = try await makeHost(initialLink: "cold", accountsReady: false, authorized: false)
        XCTAssertEqual(host.probe.models.count, 0)
        host.probe.accountsReady = true
        XCTAssertNil(host.probe.pendingPlay.request)
        host.probe.authorized = true
        try await waitForPlayback(host.probe, title: "cold", count: 1)
        XCTAssertNil(host.probe.pendingPlay.request)
    }

    func testRapidLinksDuringDismissalPlayOnlyTheLatestPendingTitle() async throws {
        let host = try await makeHost()
        host.probe.play("first")
        try await waitForPlayback(host.probe, title: "first", count: 1)
        host.probe.play("superseded")
        try await waitUntil { host.probe.playRequest?.item.id == "superseded" }
        host.probe.play("latest")
        try await waitUntil {
            host.probe.opened.last == "latest" && host.probe.engines.last?.hasPresentedVideoFrame == true
        }
        XCTAssertEqual(host.probe.opened, ["first", "latest"])
        XCTAssertEqual(host.probe.engines[0].status, .idle)
    }

    func testWarmLinkAfterBackgroundPauseAndOrdinaryDismissal() async throws {
        let host = try await makeHost()
        host.probe.play("first")
        try await waitForPlayback(host.probe, title: "first", count: 1)
        host.probe.models[0].didEnterBackground()
        host.probe.play("after-background")
        try await waitForPlayback(host.probe, title: "after-background", count: 2)
        host.window.rootViewController?.presentedViewController?.dismiss(animated: true)
        try await waitUntil { host.probe.playRequest == nil }
        host.probe.play("after-dismissal")
        try await waitForPlayback(host.probe, title: "after-dismissal", count: 3)
    }

    func testCoalescedDirectThenResumeIntentKeepsTheLatestPrompt() async throws {
        let host = try await makeHost()
        host.probe.play("first")
        try await waitForPlayback(host.probe, title: "first", count: 1)
        // No suspension between these writes: SwiftUI observes only the final pair.
        host.probe.present(host.probe.provider.movie("superseded"))
        host.probe.present(host.probe.provider.movie("resume"))
        try await waitUntil {
            (host.window.rootViewController?.presentedViewController as? UIAlertController)?.title == "resume"
        }
        XCTAssertNil(host.probe.playRequest)
        XCTAssertEqual(host.probe.resumePrompt?.id, "resume")
        XCTAssertEqual(host.probe.opened, ["first"])
        try await waitUntil { host.probe.engines[0].status == .idle }
        XCTAssertEqual(host.probe.engines[0].status, .idle)
    }

    func testCoalescedResumeThenDirectIntentKeepsTheLatestPlayer() async throws {
        let host = try await makeHost()
        host.probe.play("first")
        try await waitForPlayback(host.probe, title: "first", count: 1)
        host.probe.present(host.probe.provider.movie("resume"))
        host.probe.present(host.probe.provider.movie("latest"))
        try await waitForPlayback(host.probe, title: "latest", count: 2)
        XCTAssertNil(host.probe.resumePrompt)
        XCTAssertEqual(host.probe.opened, ["first", "latest"])
        XCTAssertEqual(host.probe.engines[0].status, .idle)
    }

    func testJellyfinWarmLinksAndParentRendersDoNotRecreatePlayers() async throws {
        let host = try await makeHost(kind: .jellyfin)
        host.probe.play("first")
        try await waitForPlayback(host.probe, title: "first", count: 1)
        for value in 1...20 {
            host.probe.renderTick = value
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(host.probe.opened, ["first"])
        host.probe.play("second")
        try await waitForPlayback(host.probe, title: "second", count: 2)
    }

    func testNewLinkDuringVersionPreparationCancelsOldPresentation() async throws {
        let host = try await makeHost()
        host.probe.play("slow-version")
        try await waitUntil { host.probe.preparingSlowVersion }
        host.probe.play("latest")
        try await waitForPlayback(host.probe, title: "latest", count: 1)
        XCTAssertTrue(host.probe.cancelledSlowVersion)
    }

    func testDirectLinkSupersedesVisibleResumePrompt() async throws {
        let host = try await makeHost()
        host.probe.play("resume")
        try await waitUntil {
            (host.window.rootViewController?.presentedViewController as? UIAlertController)?.title == "resume"
        }
        host.probe.play("direct")
        try await waitForPlayback(host.probe, title: "direct", count: 1)
        XCTAssertNil(host.probe.resumePrompt)
    }

    func testPlozzigenWarmLinksPresentNewFramesAndStopTheOutgoingEngine() async throws {
        let host = try await makeHost(usePlozzigen: true)
        host.probe.play("first")
        try await waitForPlayback(host.probe, title: "first", count: 1)
        host.probe.play("second")
        try await waitForPlayback(host.probe, title: "second", count: 2)
        XCTAssertEqual(host.probe.engines[0].status, .idle)
        XCTAssertTrue(host.probe.models.last?.videoEngine is PlozzigenVideoEngine)
    }

    private func waitForPlayback(_ probe: DeepLinkPlaybackProbe, title: String, count: Int) async throws {
        try await waitUntil("Expected moving frames for \(title), presentation \(count); opened \(probe.opened)") {
            probe.models.last?.diagnosticsPlayer?.isMuted = true
            return probe.models.count == count && probe.opened.last == title
                && probe.engines.last?.hasPresentedVideoFrame == true
                && (probe.engines.last?.currentTime ?? 0) > 0.2
        }
        XCTAssertEqual(probe.models.last?.phase, .ready)
        XCTAssertFalse(probe.models.last?.showBringUpSpinner ?? true)
    }

    private func makeHost(
        kind: ProviderKind = .plex, initialLink: String? = nil,
        accountsReady: Bool = true, authorized: Bool = true, usePlozzigen: Bool = false
    ) async throws -> DeepLinkPlaybackHost {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "live-continuity", withExtension: "mp4", subdirectory: "Fixtures"
        ))
        let probe = DeepLinkPlaybackProbe(url: fixture, kind: kind, usePlozzigen: usePlozzigen)
        probe.accountsReady = accountsReady
        probe.authorized = authorized
        if let initialLink { probe.play(initialLink) }
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView: DeepLinkPlaybackFixture(probe: probe))
        window.makeKeyAndVisible()
        let host = DeepLinkPlaybackHost(window: window, previous: previous, probe: probe)
        addTeardownBlock { @MainActor in await host.close() }
        return host
    }

    private func waitUntil(
        _ message: String = "The real presentation/player did not reach the expected state.",
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(condition(), message)
        if !condition() { throw AppError.cancelled }
    }
}

@MainActor
private struct DeepLinkPlaybackHost {
    let window: UIWindow
    let previous: UIWindow?
    let probe: DeepLinkPlaybackProbe

    func close() async {
        probe.playRequest = nil
        probe.resumePrompt = nil
        for model in probe.models { await model.stop() }
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKeyAndVisible()
        probe.defaults.removePersistentDomain(forName: probe.suite)
    }
}

@MainActor
private struct DeepLinkPlaybackFixture: View {
    @Bindable var probe: DeepLinkPlaybackProbe

    var body: some View {
        NavigationStack(path: $probe.path) {
            Color.black
                .navigationDestination(for: String.self) { title in
                    Text(verbatim: title)
                }
        }
            .opacity(probe.renderTick.isMultiple(of: 2) ? 1 : 0.99)
            .background {
                HomeTab.DeepLinkPlayRouter(
                    pendingPlay: probe.pendingPlay,
                    accounts: probe.accountsReady ? [probe.account] : [],
                    scopeKey: "fixture", isActive: true,
                    onResolved: { item, action in
                        probe.path.append(item.id)
                        guard action == .play else { return }
                        probe.present(item)
                    }
                )
            }
            .playbackPresentation(
                playRequest: $probe.playRequest, resumePrompt: $probe.resumePrompt,
                onResume: { item, position in
                    probe.resumePrompt = nil
                    probe.playRequest = PlayRequest(item: item, startPosition: position)
                }
            ) { request in
                PlayerPresentation(
                    request: request,
                    make: { request, _, _ in try probe.make(request) },
                    makeFailover: { _, _ in nil },
                    showDiagnostics: false, themePalette: .dark,
                    versionPreferences: probe.preferences,
                    prepareVersion: { _, item in
                        if item.id == "slow-version" {
                            probe.preparingSlowVersion = true
                            do {
                                try await Task.sleep(for: .seconds(60))
                            } catch {
                                probe.cancelledSlowVersion = true
                                throw error
                            }
                        }
                        return item
                    },
                    versionAuthorizationScope: ["fixture"]
                )
            }
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "en_US"))
    }
}

@MainActor
@Observable
private final class DeepLinkPlaybackProbe {
    let provider: DeepLinkPlaybackProvider
    let usePlozzigen: Bool
    let suite = "DeepLinkPlaybackHostedTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let preferences: VersionPreferenceStore
    var playRequest: PlayRequest?
    var resumePrompt: MediaItem?
    var models: [PlayerViewModel] = []
    var engines: [any VideoEngine] = []
    var opened: [String] = []
    var path: [String] = []
    var accountsReady = true
    var authorized = true
    var renderTick = 0
    var preparingSlowVersion = false
    var cancelledSlowVersion = false
    @ObservationIgnored lazy var pendingPlay = PendingPlayRequest(isAuthorized: { [weak self] in
        self?.authorized == true
    })

    var account: ResolvedAccount {
        ResolvedAccount(
            account: Account(
                id: "fixture", server: provider.session.server, userID: "fixture",
                userName: "Fixture", deviceID: "fixture"
            ),
            provider: provider
        )
    }

    init(url: URL, kind: ProviderKind, usePlozzigen: Bool) {
        provider = DeepLinkPlaybackProvider(url: url, kind: kind)
        self.usePlozzigen = usePlozzigen
        defaults = UserDefaults(suiteName: suite)!
        preferences = VersionPreferenceStore(defaults: defaults)
    }

    func play(_ id: String) {
        pendingPlay.enqueue(TopShelf.itemReference(from: TopShelf.itemDeepLink(id: id))!)
    }

    func present(_ item: MediaItem) {
        if item.resumePosition != nil {
            playRequest = nil
            resumePrompt = item
        } else {
            resumePrompt = nil
            playRequest = PlayRequest(item: item, startPosition: 0, versionPreferences: preferences)
        }
    }

    func make(_ request: PlayRequest) throws -> PlayerViewModel {
        let usePlozzigen = self.usePlozzigen
        let engine: any VideoEngine = usePlozzigen
            ? try PlozzigenVideoEngine() : NativeVideoEngine(startsMuted: true)
        var factory = EngineFactory(makeNative: { _ in
            usePlozzigen ? NativeVideoEngine(startsMuted: true) : engine
        })
        if usePlozzigen { factory.makePlozzigen = { engine } }
        var settings = PlaybackSettings.default
        settings.useCommunityMarkers = false
        settings.fadeOnDynamicRangeChange = false
        settings.fadeOnFrameRateChange = false
        let model = PlayerViewModel(
            provider: provider, itemID: request.item.id,
            playbackSettings: settings, startPosition: request.startPosition,
            engineFactory: factory,
            preferencesStore: PlaybackPreferencesStore(defaults: defaults)
        )
        models.append(model)
        engines.append(engine)
        opened.append(request.item.id)
        return model
    }
}

private struct DeepLinkPlaybackProvider: MediaProvider {
    let url: URL
    let kind: ProviderKind
    var session: UserSession {
        UserSession(
            server: MediaServer(id: "fixture", name: "Fixture", baseURL: URL(string: "https://example.test")!, provider: kind),
            userID: "fixture", userName: "Fixture", deviceID: "fixture", accessToken: "fixture"
        )
    }
    func movie(_ id: String) -> MediaItem {
        var item = MediaItem(id: id, title: id, kind: .movie)
        if id == "resume" { item.resumePosition = 3 }
        return item
    }
    func item(id: String) async throws -> MediaItem { movie(id) }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        PlaybackRequest(item: movie(itemID), streamURL: url)
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
