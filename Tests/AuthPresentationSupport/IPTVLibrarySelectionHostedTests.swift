import CoreModels
import AppRuntime
import CoreSecureStore
import CoreUI
import FeatureAuthCore
import FeatureLiveTV
import FeatureLiveTVCore
import SwiftUI
import UIKit
import Vision
import XCTest
#if os(tvOS)
@testable import AppShell
#else
@testable import AppShelliOS
#endif

@MainActor
final class IPTVLibrarySelectionHostedTests: XCTestCase {
    #if os(tvOS)
    func testAccountSetupKeepsTheSourcesNavigationMounted() async throws {
        let suite = "IPTVSetupNavigationHostedTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = LiveOnlySelectionProvider()
        let registry = ProviderRegistry()
        registry.register(.iptv) { _ in provider }
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        profiles.markFirstRunProfileSetupComplete()
        let store = AccountStore(secureStore: InMemorySecureStore())
        try store.add(
            Account(id: Account.stableID(for: provider.session), from: provider.session),
            token: provider.session.accessToken
        )
        let state = AppState(
            accountStore: store, registry: registry, profilesModel: profiles,
            appAdmissionStore: AppAdmissionStore(defaults: defaults)
        )
        state.bootstrap()
        var mounts = 0
        let controller = UIHostingController(rootView:
            ReturningSourcesNavigationFixture(state: state, didMount: { mounts += 1 })
                .environment(profiles).environment(\.themePalette, ThemePalette.dark)
        )
        let sceneDeadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < sceneDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let mountDeadline = ContinuousClock.now + .seconds(5)
        while mounts == 0, ContinuousClock.now < mountDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(mounts, 1)
        state.addAccount(provider: .iptv)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(state.presentsAccountSetupOverApp)
        state.cancelAuthentication()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.state, .ready)
        XCTAssertEqual(mounts, 1)

        state.addAccount(provider: .iptv)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(state.didAuthenticate(provider.session, activateIPTVAccount: true))
        let completionDeadline = ContinuousClock.now + .seconds(5)
        while state.state != .ready, ContinuousClock.now < completionDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(state.state, .ready)
        XCTAssertEqual(mounts, 1, "Account setup must not replace the originating navigation tree.")
    }
    #endif

    func testEnrolledPlaylistAppearsOnTheAlreadyOpenSourcesScreen() async throws {
        try await assertPlaylistAppears(channelCount: 1)
    }

    func testEmptyEventPlaylistAppearsOnTheAlreadyOpenSourcesScreen() async throws {
        try await assertPlaylistAppears(channelCount: 0)
    }

    private func assertPlaylistAppears(channelCount: Int) async throws {
        let suite = "IPTVSourcesHostedTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            if FileManager.default.fileExists(atPath: directory.path) {
                do { try FileManager.default.removeItem(at: directory) }
                catch { XCTFail("Could not remove the owned Sources test cache.") }
            }
        }
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        let profile = profiles.activeProfile
        let secure = InMemorySecureStore()
        let store = LiveTVSourcesStore(secureStore: secure)
        let provider = HostedIPTVSourceProvider(channelCount: channelCount)
        let runtime = LiveTVSourcesRuntime(
            profileID: profile.id, store: store,
            approvals: LiveTVSourceApprovalStore(defaults: defaults, profileID: profile.id, namespace: nil),
            cache: LiveTVIndexedCache(
                url: directory.appendingPathComponent("catalog.sqlite"),
                namespace: profile.id, authorizationScope: "iptv-profile-v1", secureStore: secure
            ),
            loader: HostedIPTVSourceLoader(),
            preferencesStore: LiveTVPreferencesStore(defaults: defaults),
            scanCoordinator: LiveTVChannelScanCoordinator(
                store: LiveTVChannelHealthStore(defaults: defaults, namespace: profile.id)
            ),
            context: { .init(profile: profile, parentalPIN: nil, activeAccountIDs: ["iptv"]) },
            accountAuthorizationID: { "fixture" },
            serverProviderResolver: { id in
                .init(accountID: id, authorizationID: "fixture", kind: .iptv, provider: provider)
            },
            serverChoices: { [.init(id: "iptv", name: "Recovered playlist", userName: "IPTV", kind: .iptv)] }
        )
        runtime.activate()
        defer { runtime.invalidate() }
        let controller = UIHostingController(rootView:
            NavigationStack {
                ScrollView {
                    LiveTVSourcesView(store: store, catalog: runtime.catalog, presentation: .settingsPane)
                        .padding(32)
                }
            }.environment(profiles).environment(\.themePalette, ThemePalette.dark)
        )
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let enrollmentDeadline = ContinuousClock.now + .seconds(5)
        while !(await provider.requested), ContinuousClock.now < enrollmentDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(try store.load().servers.isEmpty)
        await provider.release()
        let displayDeadline = ContinuousClock.now + .seconds(5)
        var text = ""
        while ContinuousClock.now < displayDeadline {
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            if text.localizedCaseInsensitiveContains("Recovered playlist") { break }
        }
        XCTAssertEqual(try store.load().servers.map(\.accountID), ["iptv"])
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Recovered playlist"), text)
    }

    func testChannelsOnlyPlaylistContinuesWithoutAnEmptyLibraryScreen() async throws {
        let suite = "IPTVLibrarySelectionHostedTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = LiveOnlySelectionProvider()
        let account = Account(id: Account.stableID(for: provider.session), from: provider.session)
        let controller: UIViewController
        let completed: () -> Bool
        #if os(tvOS)
        let registry = ProviderRegistry()
        registry.register(.iptv) { _ in provider }
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        profiles.markFirstRunProfileSetupComplete()
        let state = AppState(
            accountStore: AccountStore(secureStore: InMemorySecureStore()),
            registry: registry, profilesModel: profiles,
            appAdmissionStore: AppAdmissionStore(defaults: defaults)
        )
        state.bootstrap()
        XCTAssertTrue(state.didAuthenticate(provider.session))
        XCTAssertEqual(state.pendingLibrarySelectionAccountIDs, [account.id])
        controller = UIHostingController(rootView:
            SelectLibrariesView(appState: state).environment(\.themePalette, ThemePalette.dark)
        )
        completed = { state.state == .ready && state.pendingLibrarySelectionAccountIDs.isEmpty }
        #else
        var continueCount = 0
        controller = UIHostingController(rootView:
            PlozziOSLibrarySelectionView(
                accounts: [.init(account: account, provider: provider)],
                visibility: .init(store: HomeLibraryVisibilityStore(defaults: defaults)),
                onContinue: { continueCount += 1 }
            ).environment(\.themePalette, ThemePalette.dark)
        )
        completed = { continueCount == 1 }
        #endif
        let sceneDeadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < sceneDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !completed(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(completed(), "A successful channels-only playlist must not require an empty library selection.")
    }
}

#if os(tvOS)
private struct ReturningSourcesNavigationFixture: View {
    let state: AppState
    let didMount: () -> Void
    @State private var path = ["Live TV", "Sources"]

    var body: some View {
        Group {
            if state.rootPresentationState == .ready {
                NavigationStack(path: $path) {
                    Text("Settings")
                        .navigationDestination(for: String.self) { Text($0) }
                }
                .onAppear(perform: didMount)
            }
        }
        .modifier(AccountSetupOverlay(appState: state, deviceColorScheme: .dark))
    }
}
#endif

private actor HostedIPTVSourceProvider: ServerLiveTVProviding {
    let channelCount: Int
    private(set) var requested = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(channelCount: Int) { self.channelCount = channelCount }

    func liveTVAvailability() async throws -> ServerLiveTVAvailability {
        requested = true
        if !released { await withCheckedContinuation { continuation = $0 } }
        return .init(status: channelCount > 0 ? .available : .noChannels, channelCount: channelCount)
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func liveTVChannels() async throws -> [ServerLiveTVChannel] { [] }
    func liveTVGuide(channelIDs: [String], from: Date, to: Date) async throws -> [ServerLiveTVProgramme] { [] }
    func openLiveTVChannel(id: String) async throws -> any LiveTVStreamLease { throw ServerLiveTVError.tunerUnavailable }
}

private struct HostedIPTVSourceLoader: LiveTVSourceLoading {
    func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport {
        XCTFail("Sources restoration must not download a playlist.")
        throw LiveTVSourceImportError.invalidResponse
    }
    func loadGuide(from url: URL, channels: [LiveTVPrototypeChannel], now: Date) async throws -> LiveTVGuideImport {
        XCTFail("Sources restoration must not download a guide.")
        throw LiveTVSourceImportError.invalidResponse
    }
}

private struct LiveOnlySelectionProvider: MediaProvider {
    let kind: ProviderKind = .iptv
    let session = UserSession(
        server: MediaServer(id: "playlist", name: "Live channels",
                            baseURL: URL(string: "https://playlist.example.test")!, provider: .iptv),
        userID: "viewer", userName: "IPTV", deviceID: "fixture", accessToken: "fixture"
    )

    func libraries() async throws -> [MediaLibrary] { [] }
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
