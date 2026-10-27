#if os(tvOS)
import CoreModels
@testable import CoreUI
import FeatureHomeCore
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import FeatureHome

@MainActor
final class DetailPrimaryFocusHostedTests: XCTestCase {
    func testActualTVHeroTrailerButtonsNeverShowText() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let model = PrimaryFocusModel(mode: .ready)
        for discovery in [false, true] {
            for external in [false, true] {
                let trailer = external
                    ? MediaItem.youTubeTrailer(videoID: "dQw4w9WgXcQ", title: "Fixture")
                    : MediaItem(id: "local", title: "Fixture", kind: .video)
                host.rootView = AnyView(
                    DetailHeroView(
                        item: MediaItem(id: "feature", title: "Feature fixture", kind: .movie,
                                        allowsTitleBasedMetadataMatching: false),
                        spoilerSettings: .default, playTitle: "Play", onPlay: {},
                        onPlayTrailer: {}, trailerItem: trailer,
                        isDiscoveryItem: discovery, requestCTA: .request, onRequest: {}
                    )
                    .environment(model.trailer)
                    .environment(model.background)
                    .mediaItemActionHandler(model.actions)
                    .environment(\.themePalette, .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .environment(\.scenePhase, .active)
                    .preferredColorScheme(.dark)
                )
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(500))
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "actual-tv-trailer-icon-only-\(discovery)-\(external)"
                attachment.lifetime = .keepAlways
                add(attachment)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                XCTAssertTrue(text.contains(discovery ? "Request" : "Play"), text)
                XCTAssertFalse(text.localizedCaseInsensitiveContains("YouTube"), text)
                XCTAssertFalse(text.localizedCaseInsensitiveContains("Trailer"), text)
            }
        }
    }

    func testLoadingPlayOwnsEntryBeforePlaybackIsReady() async throws {
        try await verifyEntry(.loading)
    }

    func testEarlySelectRunsAsSoonAsTargetIsReady() async throws {
        try await verifyEntry(.loading, queueDuringEntrance: true)
    }

    func testReadySelectDoesNotWaitForTheEntranceAnimation() async throws {
        try await verifyEntry(.ready, queueDuringEntrance: true)
    }

    func testReadyPlayOwnsEntryFromTrailingInfo() async throws {
        try await verifyEntry(.ready)
    }

    func testRequestOwnsEntryFromTrailingInfo() async throws {
        try await verifyEntry(.request)
    }

    func testUnreleasedRequestStatusOwnsEntryFromTrailingInfo() async throws {
        try await verifyEntry(.awaitingRelease)
    }

    func testLoadingSeasonsOwnsEntryFromTrailingInfo() async throws {
        try await verifyEntry(.seasons)
    }

    func testSeasonLookupFailureRetainsThePrimaryButton() async throws {
        try await verifyEntry(.seasonFailure)
    }

    func testSeededSeriesFocusDoesNotWaitForProviderDetails() async throws {
        try await verifyEntry(.seriesPage)
    }

    func testSeededMovieFocusDoesNotWaitForProviderDetails() async throws {
        try await verifyEntry(.moviePage)
    }

    func testSeededEpisodeFocusDoesNotWaitForProviderDetails() async throws {
        try await verifyEntry(.episodePage)
    }

    func testLateSeriesPlaybackDoesNotStealFocusFromWatchlist() async throws {
        try await verifyEntry(.seriesPage, moveToSecondary: true)
    }

    private func verifyEntry(
        _ mode: PrimaryFocusMode, moveToSecondary: Bool = false, queueDuringEntrance: Bool = false
    ) async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let model = PrimaryFocusModel(mode: mode, usesEntrance: queueDuringEntrance)
        let host = PrimaryFocusHost(rootView: PrimaryFocusRoot(model: model).environment(\.scenePhase, .active))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = host
        let recorder = PrimaryFocusRecorder(window: window)
        window.makeKeyAndVisible()
        defer {
            model.entrance?.finishImmediately()
            Task { await model.gate.release() }
            NotificationCenter.default.removeObserver(recorder)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { model.infoFocused }
        recorder.focusFrames.removeAll()
        model.path.append(1)
        try await waitUntil { model.detailAppeared && !recorder.focusFrames.isEmpty }
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        let first = try XCTUnwrap(recorder.focusFrames.first)
        XCTAssertLessThan(first.minX, 150, "The first native target must be the leading action, not Watchlist: \(recorder.focusFrames)")
        let openingItem = try XCTUnwrap(system.focusedItem)
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            let frame = try XCTUnwrap(system.focusedItem.flatMap { nativeFrame($0, in: window) })
            XCTAssertLessThan(frame.minX, 150, "Entry must stay on the primary slot while metadata is pending.")
        }
        capture(window, name: "detail-primary-pending-\(mode)")
        if let detail = model.detail {
            XCTAssertFalse(detail.state.value?.childrenLoaded ?? true, "Provider work must still be pending.")
            var expectedItem = openingItem
            if moveToSecondary {
                let firstFrame = try XCTUnwrap(nativeFrame(openingItem, in: window))
                let secondary = try XCTUnwrap(focusItems(in: window).first {
                    guard let frame = nativeFrame($0, in: window) else { return false }
                    return frame.minX > firstFrame.maxX && abs(frame.midY - firstFrame.midY) < 40
                })
                host.target = secondary
                system.requestFocusUpdate(to: host)
                system.updateFocusIfNeeded()
                try await waitUntil { system.focusedItem === secondary }
                host.target = nil
                expectedItem = secondary
            }
            await model.gate.release()
            try await waitUntil { detail.state.value?.childrenLoaded == true }
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertTrue(system.focusedItem === expectedItem, "Late provider data must not redirect native focus.")
        }
        if mode == .loading || queueDuringEntrance {
            if let entrance = model.entrance {
                final class SelectPress: UIPress {
                    override var type: UIPress.PressType { .select }
                }
                entrance.resolvedDestinationArtwork(UIGraphicsImageRenderer(size: window.bounds.size).image { context in
                    UIColor.darkGray.setFill()
                    context.fill(window.bounds)
                })
                entrance.attach(to: window, enabled: true, waitsForPageAppearance: true, waitsForBackdrop: true)
                entrance.pageAppeared()
                let guardView = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? DetailTransitionInputGuard }.first)
                XCTAssertTrue(system.focusedItem === openingItem)
                let press = SelectPress()
                for _ in 0..<(mode == .loading ? 2 : 1) {
                    guardView.pressesBegan([press], with: UIPressesEvent())
                    guardView.pressesEnded([press], with: UIPressesEvent())
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertEqual(entrance.primaryActionPressGeneration, 1)
                if mode == .loading {
                    XCTAssertTrue(entrance.blocksNavigation)
                    XCTAssertEqual(model.playCount, 0)
                }
            }
            model.ready = true
            if let entrance = model.entrance {
                try await waitUntil(timeout: .seconds(1)) { model.playCount == 1 }
                XCTAssertFalse(entrance.blocksNavigation, "A ready action must complete the visual entrance, not wait five seconds for it.")
            } else {
                try await Task.sleep(for: .milliseconds(300))
            }
            XCTAssertTrue(system.focusedItem === openingItem, "Loading must update the same focused button.")
        } else if mode == .seasons || mode == .seasonFailure {
            model.ready = true
            try await Task.sleep(for: .milliseconds(300))
            let frame = try XCTUnwrap(system.focusedItem.flatMap { nativeFrame($0, in: window) })
            XCTAssertLessThan(frame.minX, 150, "The resolved request menu must retain the primary slot.")
            XCTAssertTrue(system.focusedItem === openingItem, "Readiness/failure must update the same request button.")
        }
        capture(window, name: "detail-primary-ready-\(mode)")
    }

    private func capture(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func focusItems(in window: UIWindow) -> [any UIFocusItem] {
        var containers: [any UIFocusItemContainer] = [window]
        var seen = Set<ObjectIdentifier>()
        var items: [ObjectIdentifier: any UIFocusItem] = [:]
        while let container = containers.popLast() {
            guard seen.insert(ObjectIdentifier(container)).inserted else { continue }
            for item in container.focusItems(in: container.coordinateSpace.convert(window.bounds, from: window)) {
                if let child = item.focusItemContainer { containers.append(child) }
                if let view = item as? UIView { containers.append(view) }
                if item.canBecomeFocused, !(item is UIScrollView) { items[ObjectIdentifier(item)] = item }
            }
        }
        return Array(items.values)
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

@MainActor
private func nativeFrame(_ item: any UIFocusItem, in window: UIWindow) -> CGRect? {
    var environment: (any UIFocusEnvironment)? = item
    while let current = environment {
        if let container = current.focusItemContainer {
            return container.coordinateSpace.convert(item.frame, to: window)
        }
        environment = current.parentFocusEnvironment
    }
    return nil
}

@MainActor
private final class PrimaryFocusHost<Content: View>: UIHostingController<Content> {
    weak var target: (any UIFocusEnvironment)?

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        target.map { [$0] } ?? super.preferredFocusEnvironments
    }
}

@MainActor
private final class PrimaryFocusRecorder: NSObject {
    var focusFrames: [CGRect] = []
    weak var window: UIWindow?

    init(window: UIWindow) {
        self.window = window
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(didUpdateFocus(_:)),
            name: UIFocusSystem.didUpdateNotification, object: nil
        )
    }

    @objc private func didUpdateFocus(_ notification: Notification) {
        guard let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
            as? UIFocusUpdateContext else { return }
        if let item = context.nextFocusedItem, let window,
           let frame = nativeFrame(item, in: window) {
            focusFrames.append(frame)
        }
    }
}

private enum PrimaryFocusMode {
    case loading, ready, request, awaitingRelease, seasons, seasonFailure
    case seriesPage, moviePage, episodePage

    var pageKind: MediaItemKind? {
        switch self {
        case .seriesPage: .series
        case .moviePage: .movie
        case .episodePage: .episode
        default: nil
        }
    }
}

@MainActor @Observable
private final class PrimaryFocusModel {
    let mode: PrimaryFocusMode
    var path: [Int] = []
    var infoFocused = false
    var detailAppeared = false
    var ready = false
    var playCount = 0
    let entrance: TVDetailEntranceSession?
    let trailer = HeroTrailerController()
    let background = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore(
        HeroBackgroundSettings(homeTrailerEnabled: false, detailMode: .off)
    ))
    let actions = PrimaryFocusActions()
    let gate = PrimaryFocusLoadGate()
    let detail: ItemDetailViewModel?

    init(mode: PrimaryFocusMode, usesEntrance: Bool = false) {
        self.mode = mode
        var timing = DetailEntranceTiming()
        timing.zoom = 5
        entrance = usesEntrance ? TVDetailEntranceSession(timing: timing) : nil
        if let kind = mode.pageKind {
            let provider = PrimaryFocusProvider(kind: kind, gate: gate)
            detail = ItemDetailViewModel(
                provider: provider, itemID: provider.seed.id, initialItem: provider.seed,
                sourceAccountID: "fixture", onlineTrailerResolver: { _ in [] },
                playableVideoIDResolver: { _ in nil }, trailerCache: TrailerResolutionCache()
            )
        } else {
            detail = nil
        }
    }
}

private struct PrimaryFocusRoot: View {
    @Bindable var model: PrimaryFocusModel
    @FocusState private var infoFocused: Bool

    var body: some View {
        NavigationStack(path: $model.path) {
            HStack(spacing: 24) {
                Button("Play") {}
                Button("Watchlist") {}
                Button("Info") { model.path.append(1) }
                    .focused($infoFocused)
            }
            .defaultFocus($infoFocused, true)
            .onChange(of: infoFocused) { _, value in model.infoFocused = value }
            .navigationDestination(for: Int.self) { _ in
                destination
                    .environment(\.detailEntranceSession, model.entrance)
                    .environment(model.trailer)
                    .environment(model.background)
                    .mediaItemActionHandler(model.actions)
                    .onAppear { model.detailAppeared = true }
            }
        }
        .environment(\.themePalette, .dark)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var destination: some View {
        if let detail = model.detail {
            ItemDetailView(viewModel: detail, onPlay: { _ in }, onSelectChild: { _ in })
        } else {
            DetailHeroView(
                item: MediaItem(
                    id: "primary-focus", title: "Primary action fixture",
                    kind: model.mode == .loading || model.mode == .seasons || model.mode == .seasonFailure ? .series : .movie,
                    allowsTitleBasedMetadataMatching: false, sourceAccountID: "fixture"
                ),
                spoilerSettings: .default,
                playTitle: model.mode == .ready || model.ready ? "Play" : nil,
                onPlay: model.mode == .ready || model.ready ? { model.playCount += 1 } : nil,
                showsPlayPlaceholder: model.mode == .loading && !model.ready,
                onPlayTrailer: {},
                isDiscoveryItem: model.mode == .request || model.mode == .awaitingRelease
                    || model.mode == .seasons || model.mode == .seasonFailure,
                requestCTA: model.mode == .awaitingRelease ? .awaitingRelease : .request,
                onRequest: {},
                seasonRequestAvailability: model.mode == .seasons && model.ready
                    ? MediaRequestAvailability(status: .unknown, seasons: [
                        .init(number: 1, title: "Season 1", status: .unknown)
                    ]) : nil,
                seasonRequestAvailabilityResolved: model.ready,
                seasonRequestAvailabilityFailed: model.mode == .seasonFailure && model.ready,
                onRequestSeasons: { _ in },
                onRetrySeasonRequestAvailability: {}
            )
        }
    }
}

@MainActor
private final class PrimaryFocusActions: MediaItemActionHandling {
    func actions(for item: MediaItem, context: MediaItemActionContext) -> [MediaItemAction] {
        [.addToWatchlist]
    }
    func perform(_ action: MediaItemAction, on item: MediaItem, context: MediaItemActionContext) {}
}

private actor PrimaryFocusLoadGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

private struct PrimaryFocusProvider: MediaProvider {
    let mediaKind: MediaItemKind
    let gate: PrimaryFocusLoadGate

    init(kind: MediaItemKind, gate: PrimaryFocusLoadGate) {
        mediaKind = kind
        self.gate = gate
    }

    var kind: ProviderKind { .jellyfin }
    var session: UserSession {
        UserSession(
            server: MediaServer(id: "fixture", name: "Fixture",
                               baseURL: URL(string: "https://fixture.invalid")!, provider: kind),
            userID: "fixture", userName: "Fixture", deviceID: "fixture", accessToken: ""
        )
    }
    var seed: MediaItem {
        MediaItem(id: "primary-page", title: "Primary page", kind: mediaKind,
                  parentTitle: mediaKind == .episode ? "Fixture Show" : nil,
                  seriesID: mediaKind == .episode ? "fixture-show" : nil,
                  runtime: 1800, allowsTitleBasedMetadataMatching: false, sourceAccountID: "fixture")
    }
    func item(id: String) async throws -> MediaItem {
        await gate.wait()
        try Task.checkCancellation()
        return seed
    }
    func children(of itemID: String) async throws -> [MediaItem] {
        await gate.wait()
        try Task.checkCancellation()
        guard mediaKind == .series else { return [] }
        return [MediaItem(
            id: "primary-episode", title: "First episode", kind: .episode,
            seasonNumber: 1, episodeNumber: 1, seriesID: seed.id,
            runtime: 1800, allowsTitleBasedMetadataMatching: false, sourceAccountID: "fixture"
        )]
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
#endif
