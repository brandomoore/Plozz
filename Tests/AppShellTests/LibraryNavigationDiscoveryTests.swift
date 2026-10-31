import CoreModels
import FeatureSettings
import Foundation
import Observation
import XCTest
@testable import AppShell

@MainActor
final class LibraryNavigationDiscoveryTests: XCTestCase {
    func testSettingsRecoveryPublishesLibrariesToNavigationAndItsEditor() async {
        let discovery = LibraryDiscoveryModel()
        let navigation = makeNavigation()
        let settings = DiscoveredLibrariesStore()
        let failed = await discovery.refreshNavigationLibraries(
            from: [account("plex", kind: .plex) { throw AppError.serverUnreachable }],
            navigation: navigation, settings: settings, isCurrent: { true }
        )
        XCTAssertFalse(failed)
        XCTAssertTrue(navigation.contentLibraries.isEmpty)
        XCTAssertEqual(settings.unreachableAccountIDs, ["plex"])

        let recovered = await discovery.refreshNavigationLibraries(
            from: [
                account("plex", kind: .plex) { [.init(id: "movies", title: "Movies", kind: .movie)] },
                account("jellyfin", kind: .jellyfin) { [.init(id: "shows", title: "Shows", kind: .series)] }
            ],
            navigation: navigation, settings: settings, isCurrent: { true }
        )
        XCTAssertTrue(recovered)
        XCTAssertEqual(navigation.contentLibraries, settings.state.value)
        XCTAssertEqual(Set(navigation.contentLibraries.map(\.key)), ["plex:movies", "jellyfin:shows"])
        XCTAssertTrue(settings.failures.isEmpty)
        XCTAssertTrue(navigation.offlineAccountIDs.isEmpty)
        for style in NavigationStyle.allCases {
            let keys = NavigationRailPlan.customizableKeys(
                visibleLibraries: navigation.contentLibraries, style: style
            )
            XCTAssertTrue(navigation.librarySections(available: keys).enabled.contains("plex:movies"))
            XCTAssertTrue(NavigationRailPlan.destinations(
                visibleLibraries: navigation.contentLibraries,
                layout: navigation.resolvedLibraryLayout, availableKeys: keys
            ).contains(.library("plex:movies")))
        }
    }

    func testRefreshPreservesManualHidesAndOfflineLibrariesButRemovesExcludedAccounts() async {
        let discovery = LibraryDiscoveryModel()
        let navigation = makeNavigation()
        let settings = DiscoveredLibrariesStore()
        let plex = account("plex", kind: .plex) { [.init(id: "movies", title: "Movies", kind: .movie)] }
        let jellyfin = account("jellyfin", kind: .jellyfin) { [.init(id: "shows", title: "Shows", kind: .series)] }
        _ = await discovery.refreshNavigationLibraries(
            from: [plex, jellyfin], navigation: navigation, settings: settings, isCurrent: { true }
        )
        let keys = NavigationRailPlan.customizableKeys(visibleLibraries: navigation.contentLibraries)
        var sections = navigation.librarySections(available: keys)
        sections.enabled.removeAll { $0 == "plex:movies" }
        sections.disabled.append("plex:movies")
        navigation.applyLibrarySections(sections, available: keys)
        let savedLayout = navigation.libraryLayout

        _ = await discovery.refreshNavigationLibraries(
            from: [account("plex", kind: .plex) { throw AppError.serverUnreachable }],
            navigation: navigation, settings: settings, changedAccountID: "jellyfin", isCurrent: { true }
        )
        XCTAssertEqual(navigation.contentLibraries.map(\.key), ["plex:movies"])
        XCTAssertEqual(navigation.offlineAccountIDs, ["plex"])
        XCTAssertEqual(navigation.libraryLayout, savedLayout)
        XCTAssertTrue(settings.refreshingAccountIDs.isEmpty)

        _ = await discovery.refreshNavigationLibraries(
            from: [plex], navigation: navigation, settings: settings, isCurrent: { true }
        )
        XCTAssertEqual(navigation.contentLibraries, settings.state.value)
        XCTAssertEqual(navigation.libraryLayout, savedLayout)
        let available = NavigationRailPlan.customizableKeys(visibleLibraries: navigation.contentLibraries)
        XCTAssertTrue(navigation.librarySections(available: available).disabled.contains("plex:movies"))
        XCTAssertFalse(NavigationRailPlan.destinations(
            visibleLibraries: navigation.contentLibraries, layout: navigation.resolvedLibraryLayout,
            availableKeys: available
        ).contains(.library("plex:movies")))

        _ = await discovery.refreshNavigationLibraries(
            from: [account("plex", kind: .plex) { [] }],
            navigation: navigation, settings: settings, isCurrent: { true }
        )
        XCTAssertTrue(navigation.contentLibraries.isEmpty)
        XCTAssertEqual(settings.state, .empty)
    }

    func testSupersededDiscoveryCannotOverwriteNewerSettingsOrNavigation() async {
        let discovery = LibraryDiscoveryModel()
        let navigation = makeNavigation()
        let settings = DiscoveredLibrariesStore()
        let started = expectation(description: "Old discovery started")
        let gate = LibraryDiscoveryGate()
        let oldAccount = account("plex", kind: .plex) { await gate.load(started: started) }
        let oldTask = Task {
            await discovery.refreshNavigationLibraries(
                from: [oldAccount], navigation: navigation, settings: settings, isCurrent: { true }
            )
        }
        await fulfillment(of: [started], timeout: 5)
        _ = await discovery.refreshNavigationLibraries(
            from: [account("plex", kind: .plex) { [.init(id: "new", title: "New", kind: .movie)] }],
            navigation: navigation, settings: settings, isCurrent: { true }
        )
        await gate.finish()
        let oldPublished = await oldTask.value
        XCTAssertFalse(oldPublished)
        XCTAssertEqual(navigation.contentLibraries.map(\.key), ["plex:new"])
        XCTAssertEqual(navigation.contentLibraries, settings.state.value)
    }

    func testCancelledSettingsRefreshCannotStrandTheShellDiscovery() async {
        for cancelSettings in [true, false] {
            let discovery = LibraryDiscoveryModel()
            let navigation = makeNavigation()
            let settings = DiscoveredLibrariesStore()
            let shellStarted = expectation(description: "Shell discovery started")
            let settingsStarted = expectation(description: "Settings discovery started")
            let shellGate = LibraryDiscoveryGate()
            let settingsGate = LibraryDiscoveryGate()
            let shell = Task {
                await discovery.refreshNavigationLibraries(
                    from: [account("plex", kind: .plex) { await shellGate.load(started: shellStarted) }],
                    navigation: navigation, settings: settings, isCurrent: { true }
                )
            }
            await fulfillment(of: [shellStarted], timeout: 5)
            let detail = Task {
                await discovery.refreshNavigationLibraries(
                    from: [account("plex", kind: .plex) { await settingsGate.load(started: settingsStarted) }],
                    navigation: navigation, settings: settings, isCurrent: { true }
                )
            }
            await fulfillment(of: [settingsStarted], timeout: 5)
            if cancelSettings {
                detail.cancel()
                await settingsGate.finish()
                let published = await detail.value
                XCTAssertFalse(published)
            } else {
                shell.cancel()
                await shellGate.finish()
                let published = await shell.value
                XCTAssertFalse(published)
            }
            XCTAssertTrue(settings.state.isLoading)
            XCTAssertEqual(settings.refreshingAccountIDs, ["plex"])
            if cancelSettings { await shellGate.finish() } else { await settingsGate.finish() }
            let published = await (cancelSettings ? shell : detail).value
            XCTAssertTrue(published)
            XCTAssertEqual(navigation.contentLibraries.map(\.key), ["plex:old"])
            XCTAssertEqual(navigation.contentLibraries, settings.state.value)
            XCTAssertFalse(settings.state.isLoading)
            XCTAssertTrue(settings.refreshingAccountIDs.isEmpty)
        }
    }

    func testUnchangedSettingsRefreshDoesNotInvalidateNavigationChrome() async {
        let discovery = LibraryDiscoveryModel()
        let navigation = makeNavigation()
        let settings = DiscoveredLibrariesStore()
        let source = account("plex", kind: .plex) { [.init(id: "movies", title: "Movies", kind: .movie)] }
        _ = await discovery.refreshNavigationLibraries(
            from: [source], navigation: navigation, settings: settings, isCurrent: { true }
        )
        let changed = expectation(description: "Unchanged navigation must not invalidate Settings focus")
        changed.isInverted = true
        withObservationTracking {
            _ = navigation.contentLibraries
            _ = navigation.discoveredAccountIDs
            _ = navigation.offlineAccountIDs
        } onChange: {
            changed.fulfill()
        }
        _ = await discovery.refreshNavigationLibraries(
            from: [source], navigation: navigation, settings: settings, isCurrent: { true }
        )
        await fulfillment(of: [changed], timeout: 0.1)
    }

    func testProfileOrCredentialChangeRejectsInFlightDiscovery() async {
        let discovery = LibraryDiscoveryModel()
        let original = makeNavigation()
        let replacement = makeNavigation()
        let settings = DiscoveredLibrariesStore()
        let started = expectation(description: "Discovery started before scope change")
        let gate = LibraryDiscoveryGate()
        var current = original
        let source = account("plex", kind: .plex) { await gate.load(started: started) }
        let task = Task {
            await discovery.refreshNavigationLibraries(
                from: [source], navigation: original, settings: settings,
                isCurrent: { current === original }
            )
        }
        await fulfillment(of: [started], timeout: 5)
        current = replacement
        await gate.finish()
        let published = await task.value
        XCTAssertFalse(published)
        XCTAssertTrue(original.contentLibraries.isEmpty)
        XCTAssertTrue(replacement.contentLibraries.isEmpty)
        XCTAssertNil(settings.state.value)
        XCTAssertFalse(settings.state.isLoading)
        XCTAssertTrue(settings.refreshingAccountIDs.isEmpty)
    }

    func testCancellationCannotPublishAProviderAnswerThatIgnoresCancellation() async {
        let discovery = LibraryDiscoveryModel()
        let navigation = makeNavigation()
        let settings = DiscoveredLibrariesStore()
        let started = expectation(description: "Discovery started")
        let gate = LibraryDiscoveryGate()
        let source = account("plex", kind: .plex) { await gate.load(started: started) }
        let task = Task {
            await discovery.refreshNavigationLibraries(
                from: [source], navigation: navigation, settings: settings, isCurrent: { true }
            )
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        await gate.finish()
        let published = await task.value
        XCTAssertFalse(published)
        XCTAssertTrue(navigation.contentLibraries.isEmpty)
        XCTAssertNil(settings.state.value)
        XCTAssertFalse(settings.state.isLoading)
        XCTAssertTrue(settings.refreshingAccountIDs.isEmpty)
    }

    private func makeNavigation() -> NavigationStyleSettingsModel {
        let suite = "LibraryNavigationDiscoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return NavigationStyleSettingsModel(
            store: NavigationStyleSettingsStore(defaults: defaults),
            layoutStore: NavigationLibraryLayoutStore(defaults: defaults),
            librariesSnapshotStore: NavigationLibrariesSnapshotStore(defaults: defaults)
        )
    }

    private func account(
        _ id: String, kind: ProviderKind,
        libraries: @escaping @Sendable () async throws -> [MediaLibrary]
    ) -> ResolvedAccount {
        let server = MediaServer(
            id: id, name: id, baseURL: URL(string: "https://server.example")!, provider: kind
        )
        let session = UserSession(
            server: server, userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
        )
        return ResolvedAccount(
            account: Account(id: id, server: server, userID: "viewer", userName: "Viewer", deviceID: "fixture"),
            provider: NavigationLibraryProvider(session: session, loadLibraries: libraries)
        )
    }
}

private actor LibraryDiscoveryGate {
    private var continuation: CheckedContinuation<[MediaLibrary], Never>?

    func load(started: XCTestExpectation) async -> [MediaLibrary] {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func finish() {
        continuation?.resume(returning: [.init(id: "old", title: "Old", kind: .movie)])
        continuation = nil
    }
}

private struct NavigationLibraryProvider: MediaProvider {
    let session: UserSession
    let loadLibraries: @Sendable () async throws -> [MediaLibrary]
    var kind: ProviderKind { session.server.provider }
    func libraries() async throws -> [MediaLibrary] { try await loadLibraries() }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        .init(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
