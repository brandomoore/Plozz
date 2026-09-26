import CoreModels
@testable import AppShell
@testable import CoreUI
@testable import FeatureLiveTV
import FeatureLiveTVCore
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class LiveTVInitialLoadingHostedTests: XCTestCase {
    func testSavedLibraryChannelsNeverShowSetupWhileTheirCatalogIsPending() async throws {
        try await exerciseLoading(pinned: false)
    }

    func testPinnedRailKeepsLiveTVInPlaceAcrossLoadingStages() async throws {
        try await exerciseLoading(pinned: true)
    }

    func testPinnedRailKeepsLiveTVInPlaceWhenContainerSafeAreaSettles() async throws {
        try await exerciseLoading(pinned: true, changesSafeArea: true)
    }

    private func exerciseLoading(pinned: Bool, changesSafeArea: Bool = false) async throws {
        let profileID = ProfileStore.defaultProfileID
        let definitions = InitialLibraryDefinitions()
        let cache = LibraryChannelSnapshotStore(databaseURL: nil)
        let context = LibraryChannelProviderContext(
            accountID: "account", authorizationID: "fixture",
            provider: InitialLibraryProvider(), allowedLibraryIDs: ["library"]
        )
        let prepared = LibraryChannelService(profileID: profileID, store: definitions, snapshotStore: cache)
        prepared.setContexts([context])
        try await prepared.load()
        let now = Date()
        let preview = try await prepared.preview(
            recipe: LibraryChannelRecipe(name: "Saved movie channel",
                                         libraries: [.init(accountID: "account", libraryID: "library")],
                                         includesEpisodes: false),
            at: now
        )
        _ = try await prepared.publish(preview, at: now)
        let cold = LibraryChannelService(profileID: profileID, store: definitions, snapshotStore: cache)
        cold.setContexts([context])
        XCTAssertFalse(cold.isLoaded)

        let scene = try await foregroundScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let sources = InitialEmptySources()
        let name = "LiveTVInitialLoading.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let approval = LiveTVSourceApprovalContext(
            profile: Profile(id: profileID, name: "Fixture"), parentalPIN: nil, activeAccountIDs: ["account"]
        )
        let geometry = LiveTVLoadingGeometry()
        let page = LiveTVPrototypeView(
            sourceStore: sources,
            onExpandedChange: geometry.setNavigationSuppressed,
            profileID: profileID, preferencesNamespace: name,
            libraryService: cold,
            libraryHistory: LibraryChannelHistorySettings(defaults: defaults),
            sourceApprovalContext: { approval }
        ) { _ in Color.black }
        let host = UIHostingController(rootView: LiveTVPinnedLoadingFixture(pinned: pinned, geometry: geometry, content: page)
            .environment(\.observesPrototypeLayout, true)
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark))
        window.rootViewController = host
        window.makeKeyAndVisible()
        let sampling = Task { @MainActor in
            while !Task.isCancelled {
                geometry.recordPresentation(in: window)
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
            }
        }
        defer {
            sampling.cancel()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: name)
        }
        if pinned {
            try await Task.sleep(for: .milliseconds(100))
            try XCTUnwrap(geometry.interaction).requestOpen()
            try await Task.sleep(for: .milliseconds(250))
            geometry.selection = .liveTV
        }
        try await Task.sleep(for: .milliseconds(150))
        if changesSafeArea {
            let regions = host.safeAreaRegions
            host.safeAreaRegions = []
            try await Task.sleep(for: .milliseconds(150))
            host.safeAreaRegions = regions
            try await Task.sleep(for: .milliseconds(150))
        }
        geometry.cacheReady = true
        // The persisted-source read finishes first; library loading is held here.
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        let pending = try text(in: window)
        XCTAssertFalse(pending.contains("Add your channels"), pending)
        XCTAssertFalse(pending.contains("No channels available"), pending)
        XCTAssertFalse(pending.contains("Loading your channels"), pending)
        XCTAssertFalse(pending.contains("Find your next channel"), pending)
        let skeleton = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
        skeleton.name = "Live TV loading layout"
        skeleton.lifetime = .keepAlways
        add(skeleton)

        try await cold.load()
        let deadline = ContinuousClock.now + .seconds(5)
        var loaded = ""
        while ContinuousClock.now < deadline {
            await Task.yield()
            window.layoutIfNeeded()
            loaded = try text(in: window)
            if loaded.contains("Saved movie channel") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(loaded.contains("Saved movie channel"), loaded)
        XCTAssertFalse(loaded.contains("Add your channels"), loaded)
        let content = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
        content.name = "Live TV loaded layout"
        content.lifetime = .keepAlways
        add(content)
        if pinned {
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertTrue(geometry.navigationSuppressions.contains(true),
                          "Exercise the real initial-channel focus handoff, not only catalog loading.")
            XCTAssertEqual(geometry.navigationSuppressions.last, false)
            let frames = geometry.frames.values.flatMap { $0 }
            XCTAssertTrue(geometry.frames.keys.contains("storage"))
            XCTAssertTrue(geometry.frames.keys.contains("loading"))
            XCTAssertTrue(geometry.frames.keys.contains("content"))
            let positions = frames.map(\.minX)
            let minimum = try XCTUnwrap(positions.min())
            let maximum = try XCTUnwrap(positions.max())
            let history = XCTAttachment(string: String(describing: geometry.frames))
            history.name = "Pinned Live TV mounted frame history"
            history.lifetime = .keepAlways
            add(history)
            XCTAssertEqual(maximum, minimum, accuracy: 1,
                           "Pinned Live TV must not shift between mounted loading/content frames: \(geometry.frames)")
            let widths = frames.map(\.width)
            XCTAssertEqual(try XCTUnwrap(widths.max()), try XCTUnwrap(widths.min()), accuracy: 1,
                           "The guide must not resize when its container's safe area settles.")
            let presentation = geometry.presentedFrames.values.flatMap { $0 }.map(\.minX)
            let presentationHistory = XCTAttachment(string: String(describing: geometry.presentedFrames))
            presentationHistory.name = "Pinned Live TV presentation frame history"
            presentationHistory.lifetime = .keepAlways
            add(presentationHistory)
            XCTAssertEqual(try XCTUnwrap(presentation.max()), try XCTUnwrap(presentation.min()), accuracy: 1,
                           "Visible frames must stay still, not just their final layout: \(geometry.presentedFrames)")
        }

        try definitions.save([])
        try await cold.load()
        let emptyDeadline = ContinuousClock.now + .seconds(5)
        var empty = ""
        while ContinuousClock.now < emptyDeadline {
            await Task.yield()
            window.layoutIfNeeded()
            empty = try text(in: window)
            if empty.contains("Add your channels") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(empty.contains("Add your channels"), "A confirmed empty catalog must still offer setup: \(empty)")
    }

    private func text(in window: UIWindow) throws -> String {
        let image = DetailTransitionSnapshot.image(of: window)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private func foregroundScene() async throws -> UIWindowScene {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
    }
}

@MainActor @Observable
private final class LiveTVLoadingGeometry {
    let chrome = NavigationChromeModel()
    var cacheReady = false
    var selection = NavigationRailDestination.home
    @ObservationIgnored var frames: [String: [CGRect]] = [:]
    @ObservationIgnored var presentedFrames: [String: [CGRect]] = [:]
    @ObservationIgnored var interaction: PlozzPinnedSidebarInteraction?
    @ObservationIgnored var navigationSuppressions: [Bool] = []

    func setNavigationSuppressed(_ suppressed: Bool) {
        if navigationSuppressions.last != suppressed { navigationSuppressions.append(suppressed) }
        chrome.setStackDepth(suppressed ? 1 : 0)
    }

    func record(_ value: [String: CGRect]) {
        for (phase, frame) in value where frame.width > 100 && frame.height > 20 {
            if frames[phase]?.last != frame { frames[phase, default: []].append(frame) }
        }
    }

    func recordPresentation(in window: UIWindow) {
        func visit(_ view: UIView) {
            if let marker = view as? PrototypeHeroLayoutView {
                let layer = marker.layer.presentation() ?? marker.layer
                let frame = layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer)
                if frame.width > 100, frame.height > 20, presentedFrames[marker.phase]?.last != frame {
                    presentedFrames[marker.phase, default: []].append(frame)
                }
            }
            view.subviews.forEach(visit)
        }
        visit(window)
    }
}

private struct LiveTVPinnedLoadingFixture<Content: View>: View {
    let pinned: Bool
    let geometry: LiveTVLoadingGeometry
    let content: Content

    var body: some View {
        @Bindable var geometry = geometry
        Group {
            if pinned {
                NavigationRailShell(
                    profile: Profile(id: "fixture", name: "Fixture"), entries: [],
                    destinations: [.home, .liveTV, .settings], selection: $geometry.selection,
                    onOpenProfileSwitcher: {}, chrome: geometry.chrome,
                    content: retainedContent, contentDestination: geometry.selection
                )
            } else {
                loadingContent
            }
        }
        .overlayPreferenceValue(PrototypeHeroBoundsKey.self) { anchors in
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                let frames = anchors.mapValues { proxy[$0].offsetBy(dx: origin.x, dy: origin.y) }
                Color.clear
                    .onChange(of: frames, initial: true) { _, frames in geometry.record(frames) }
                    .allowsHitTesting(false)
            }
        }
    }

    private var retainedContent: some View {
        let active = geometry.selection == .liveTV
        return ZStack {
            Color.clear
            RetainedLiveTVDestination(isActive: active) { loadingContent }
                .opacity(active ? 1 : 0)
                .disabled(!active)
        }
        .background { LiveTVLoadingInteractionCapture(geometry: geometry) }
    }

    @ViewBuilder private var loadingContent: some View {
        if geometry.cacheReady { content }
        else { LiveTVLoadingSkeleton() }
    }
}

private struct LiveTVLoadingInteractionCapture: View {
    let geometry: LiveTVLoadingGeometry
    @Environment(\.plozzPinnedSidebarInteraction) private var interaction

    var body: some View {
        Color.clear
            .onAppear { geometry.interaction = interaction }
    }
}

private final class InitialEmptySources: LiveTVSourcesStoring, @unchecked Sendable {
    func load() throws -> LiveTVSourcesConfiguration { .empty }
    func save(_ configuration: LiveTVSourcesConfiguration) throws {}
}

private final class InitialLibraryDefinitions: LibraryChannelDefinitionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var definitions: [LibraryChannelDefinition] = []
    func load() throws -> [LibraryChannelDefinition] { lock.withLock { definitions } }
    func save(_ values: [LibraryChannelDefinition]) throws { lock.withLock { definitions = values } }
}

private struct InitialLibraryProvider: LibraryChannelCatalogProviding {
    let kind = ProviderKind.jellyfin
    let session = UserSession(
        server: MediaServer(id: "fixture", name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!, provider: .jellyfin),
        userID: "fixture", userName: "Fixture", deviceID: "fixture", accessToken: "fixture"
    )
    func libraryChannelItems(in libraryID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        var item = MediaItem(id: "movie", title: "Fixture movie", kind: .movie, runtime: 3600)
        item.libraryID = libraryID
        return MediaPage(items: [item], startIndex: page.startIndex, totalCount: 1)
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage { throw AppError.notFound }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
