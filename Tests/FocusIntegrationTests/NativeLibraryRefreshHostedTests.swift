#if os(tvOS)
import CoreModels
@testable import CoreUI
@testable import AppShell
@testable import FeatureHome
import FeatureHomeCore
import MetadataKit
import SwiftUI
import TVUIKit
import UIKit
import Vision
import XCTest

@MainActor
final class NativeLibraryRefreshHostedTests: XCTestCase {
    private var savedProviders = MetadataProviderSettings.default

    func testLibraryShowcaseKeepsScheduleAndLogoBelowNavigationAtEverySize() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 500, height: 250), format: format).image { _ in
            ("SILO" as NSString).draw(at: CGPoint(x: 10, y: 0), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 200), .foregroundColor: UIColor.red
            ])
        }
        let url = try XCTUnwrap(URL(string: "https://library-logo.example.test/\(UUID()).png"))
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
        ))
        cache.storeCachedResponse(
            CachedURLResponse(response: response, data: try XCTUnwrap(image.pngData())), for: URLRequest(url: url)
        )
        defer { cache.removeCachedResponse(for: URLRequest(url: url)) }
        let item = MediaItem(
            id: UUID().uuidString, title: "Schedule layout fixture", kind: .series,
            overview: "A long description exercises the space between the logo, title information and recommended rows.",
            logoURL: url, allowsTitleBasedMetadataMatching: false
        )
        let now = Date()
        let upcoming = UpcomingEpisode(
            seriesIdentity: .external(source: "fixture", value: item.id), seasonNumber: 2, episodeNumber: 1,
            airDate: now.addingTimeInterval(7 * 86400), datePrecision: .dateOnly, source: .tvmaze, refreshedAt: now
        )
        await SeriesScheduleStore.shared.store(.init(
            seriesKey: MetadataQuery(item).seriesScoped.enrichmentCacheKey,
            upcomingEpisode: upcoming, upcomingEpisodes: [upcoming],
            refreshedAt: now, refreshDueAt: now.addingTimeInterval(3600)
        ))
        for style in [NavigationStyle.tabBar, .sidebar, .rail] {
            try await withNavigatedLibrary(style: style, heroItem: item) { root, window, model in
                let controller = try XCTUnwrap(window.rootViewController)
                let header = try XCTUnwrap(self.findController(NativeLibraryHeaderController.self, in: controller))
                let source = try XCTUnwrap(self.findSource(item.stablePresentationID, in: root))
                var rowFrame: CGRect?
                var previousLogo: CGRect?
                for step in [-10, 0, 10] {
                    model.presentation.settings.logoSize = HeroLogoSize(rawValue: step)
                    try await waitForHostedLayout(window)
                    let navigationBottom = try XCTUnwrap(self.focusItems(in: header.host.view).compactMap {
                        NavigationRowFocusRequester.frame(of: $0, relativeTo: window)?.maxY
                    }.max())
                    let capture = self.capture(window, name: "library-logo-\(style)-\(step)", drawsHierarchy: true)
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(cgImage: XCTUnwrap(capture.cgImage)).perform([request])
                    let results = request.results ?? []
                    let badge = try XCTUnwrap(results.first {
                        $0.topCandidates(1).first?.string.localizedCaseInsensitiveContains("New season") == true
                    }, "A new-season badge must remain visible below \(style) library navigation.")
                    let logo = try XCTUnwrap(HeroLogoPresentationHostedTests.colorBounds(in: capture, channel: 0))
                    func frame(_ observation: VNRecognizedTextObservation) -> CGRect {
                        let box = observation.boundingBox
                        return CGRect(
                            x: box.minX * window.bounds.width, y: (1 - box.maxY) * window.bounds.height,
                            width: box.width * window.bounds.width, height: box.height * window.bounds.height
                        )
                    }
                    XCTAssertGreaterThan(frame(badge).minY, navigationBottom + 16,
                                         "Measure clearance from the controls, excluding the header's bottom padding.")
                    XCTAssertGreaterThan(logo.minY, frame(badge).maxY + 10)
                    XCTAssertLessThan(logo.minY - frame(badge).maxY, 42,
                                      "The badge follows the fitted logo, not the top of its sizing slot.")
                    let currentRow = try XCTUnwrap(source.reference?.geometry(in: window)?.frame)
                    XCTAssertLessThan(logo.maxY, currentRow.minY - 40)
                    if let rowFrame { XCTAssertEqual(currentRow, rowFrame) }
                    rowFrame = currentRow
                    if let previousLogo {
                        if style == .sidebar, step == 10 {
                            // The sidebar page button leaves room for roughly the
                            // default logo. Larger sizes must cap before the badge
                            // reaches navigation, not force the rows down.
                            XCTAssertGreaterThanOrEqual(logo.height, previousLogo.height - 1)
                            XCTAssertLessThan(logo.height, previousLogo.height * 1.5 - 3)
                        } else {
                            let ratio: CGFloat = step == 0 ? 2 : 1.5
                            XCTAssertEqual(logo.height, previousLogo.height * ratio, accuracy: 3,
                                           "Allow the rasterized wordmark's antialiased edge, not OCR padding.")
                        }
                    }
                    previousLogo = logo
                }
            }
        }
    }

    func testLibraryHeaderShowcaseAndEveryGridShareVisibleLeadingEdge() async throws {
        continueAfterFailure = false
        for navigationInset: CGFloat in [64, 0] {
            for focusStyle: CardFocusStyle in [.system, .highlight] {
                for cardStyle: CardStyle in [.borderless, .framed] {
                    let provider = RefreshLibraryProvider(
                        kind: .jellyfin, supportsModes: true, recommendationHub: true
                    )
                    let name = "LibraryKeyline.\(UUID())"
                    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
                    defer { defaults.removePersistentDomain(forName: name) }
                    let model = LibraryBrowseViewModel(
                        provider: provider, containerID: "library", containerKind: .movie, defaults: defaults
                    )
                    await model.loadRecommendationsIfNeeded()
                    try await withLibrary(
                        model: model, focusStyle: focusStyle, cardStyle: cardStyle, navigationInset: navigationInset
                    ) { root, window in
                        let owner = try XCTUnwrap(window.rootViewController as? LibraryFocusFixtureController)
                        let header = try XCTUnwrap(self.findController(NativeLibraryHeaderController.self, in: owner))
                        let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
                        let controls = self.focusItems(in: header.host.view).sorted {
                            (NavigationRowFocusRequester.frame(of: $0, relativeTo: window)?.minX ?? .infinity)
                                < (NavigationRowFocusRequester.frame(of: $1, relativeTo: window)?.minX ?? .infinity)
                        }
                        XCTAssertEqual(controls.count, model.availableContentModes.count)
                        let firstControl = try XCTUnwrap(controls.first)
                        let originalFrame = try XCTUnwrap(
                            NavigationRowFocusRequester.frame(of: firstControl, relativeTo: window)
                        )
                        let keyline = originalFrame.minX - 6
                        for mode: LibraryContentMode in [.recommended, .titles, .collections, .playlists, .recommended] {
                            let index = try XCTUnwrap(model.availableContentModes.firstIndex(of: mode))
                            owner.target = controls[index]
                            focus.requestFocusUpdate(to: owner)
                            focus.updateFocusIfNeeded()
                            XCTAssertTrue(focus.focusedItem === controls[index])
                            owner.target = nil
                            await model.setContentMode(mode)
                            try await Task.sleep(for: .milliseconds(300))
                            window.layoutIfNeeded()
                            XCTAssertTrue(focus.focusedItem === controls[index])
                            let controlFrame = try XCTUnwrap(
                                NavigationRowFocusRequester.frame(of: firstControl, relativeTo: window)
                            )
                            XCTAssertEqual(controlFrame, originalFrame, "Navigation must not move or resize.")
                            let item = try XCTUnwrap(mode == .recommended
                                ? model.recommendationState.value?.first?.items.first : model.item(at: 0))
                            let source = try XCTUnwrap(self.findSource(item.stablePresentationID, in: root))
                            let artwork = try XCTUnwrap(source.reference?.geometry(in: window)?.frame)
                            let visibleLeading = artwork.minX - (cardStyle == .framed ? PlozzMetrics.standard.cardInset : 0)
                            let context = "\(mode) inset=\(navigationInset) focus=\(focusStyle) card=\(cardStyle)"
                            print("LIBRARY_KEYLINE \(context) header=\(keyline) visibleCard=\(visibleLeading)")
                            if navigationInset > 0, focusStyle == .system, cardStyle == .borderless {
                                self.capture(window, name: "library-keyline-\(mode)", drawsHierarchy: true)
                            }
                            XCTAssertEqual(visibleLeading, keyline, accuracy: 1,
                                           "\(context): measure the visible card, not its padded layout slot.")
                        }
                    }
                }
            }
        }
    }

    func testTraversalDiagnosticsRecordNativeFocusWithoutAddingAFocusTarget() async throws {
        let model = LibraryBrowseViewModel(
            provider: RefreshLibraryProvider(), containerID: "library", containerKind: .series
        )
        await model.loadFirstPage()
        try await withLibrary(model: model) { root, window in
            let controller = try XCTUnwrap(self.findController(
                NativeLibraryGridController.self, in: XCTUnwrap(window.rootViewController)
            ))
            XCTAssertNil(controller.traversalSnapshot, "Ordinary browsing must not collect benchmark history.")
            controller.enableTraversalRecording()
            let probe = try XCTUnwrap(self.find(NativeLibraryTraversalProbe.self, in: root))
            XCTAssertTrue(probe.isAccessibilityElement)
            XCTAssertFalse(probe.canBecomeFocused)
            let collection = try XCTUnwrap(self.find(UICollectionView.self, in: root))
            let first = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? NativeTVLibraryCell)
            let second = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 6, section: 0)) as? NativeTVLibraryCell)
            @MainActor func focus(_ cell: NativeTVLibraryCell) async throws {
                XCTAssertTrue(cell.onRequestFocus?() == true)
                let deadline = ContinuousClock.now + .seconds(2)
                while !cell.isFocused, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertTrue(cell.isFocused)
            }
            try await focus(second)
            try await focus(first)
            let before = try XCTUnwrap(controller.traversalSnapshot)
            let start = ProcessInfo.processInfo.systemUptime
            try await focus(second)
            try await focus(first)
            let end = ProcessInfo.processInfo.systemUptime
            let value = try XCTUnwrap(probe.accessibilityValue)
            let after = try JSONDecoder().decode(LibraryTraversalSnapshot.self, from: Data(value.utf8))
            let evidence = try LibraryTraversalValidation.validate(
                before: before, after: after, start: start, end: end, mode: .stepped(path: [0, 6])
            )
            XCTAssertEqual(evidence.transitions, 2)
            XCTAssertEqual(evidence.deepestRow, 1)
        }
    }

    func testLiveScanBannerReservesSpaceAndAlignsWithUnfocusedArtwork() async throws {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .series
        )
        await model.loadFirstPage()
        let status = ShareScanStatusModel()
        try await withLibrary(model: model, scanStatus: status, navigationInset: 64) { root, window in
            let collection = try XCTUnwrap(self.find(UICollectionView.self, in: root))
            for pass in 0..<2 {
                status.scanStarted(shareID: "fixture", name: "Media")
                status.scanProgress(shareID: "fixture", directoriesScanned: 700, itemsFound: 970)
                try await Task.sleep(for: .milliseconds(250))
                let header = try XCTUnwrap(collection.supplementaryView(
                    forElementKind: UICollectionView.elementKindSectionHeader,
                    at: IndexPath(item: 0, section: 0)
                ))
                let banner = try XCTUnwrap(self.find(TVCardView.self, in: header))
                let bannerFrame = banner.contentView.convert(banner.contentView.bounds, to: window)
                let cells = collection.visibleCells.compactMap { $0 as? NativeTVLibraryCell }
                    .filter { (collection.indexPath(for: $0)?.item ?? .max) < 6 }
                    .sorted { $0.frame.minX < $1.frame.minX }
                let first = try XCTUnwrap(cells.first)
                let last = try XCTUnwrap(cells.last)
                let firstView = try self.libraryArtwork(in: first)
                let lastView = try self.libraryArtwork(in: last)
                let firstArtwork = firstView.convert(firstView.bounds, to: window)
                let lastArtwork = lastView.convert(lastView.bounds, to: window)
                XCTAssertFalse(banner.isFocused)
                XCTAssertEqual(try XCTUnwrap(header.subviews.first).frame, header.bounds)
                XCTAssertLessThan(bannerFrame.maxY, firstArtwork.minY,
                                  "A live status update must reserve space without focusing the banner.")
                XCTAssertEqual(bannerFrame.minX, firstArtwork.minX, accuracy: 1)
                XCTAssertEqual(bannerFrame.maxX, lastArtwork.maxX, accuracy: 1)
                self.capture(window, name: "unfocused-scan-banner-\(pass)")
                let bounds = header.bounds
                let surfaceInHeader = banner.contentView.convert(banner.contentView.bounds, to: header)
                let owner = try XCTUnwrap(self.findController(
                    NativeLibraryFocusHostController.self, in: XCTUnwrap(window.rootViewController)
                ))
                let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
                owner.requestFocus(to: banner, using: system)
                try await Task.sleep(for: .milliseconds(250))
                XCTAssertTrue(system.focusedItem === banner)
                XCTAssertEqual(header.bounds, bounds, "Focus must not repair or change the header's reserved size.")
                XCTAssertEqual(try XCTUnwrap(header.subviews.first).frame, bounds)
                XCTAssertTrue(first.onRequestFocus?() == true)
                try await Task.sleep(for: .milliseconds(250))
                XCTAssertEqual(banner.contentView.convert(banner.contentView.bounds, to: header), surfaceInHeader)
                status.scanFinished(shareID: "fixture")
                try await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        let store = MetadataProviderSettingsStore()
        savedProviders = store.load()
        store.save(.init(orderMode: .custom, disabledOrder: MetadataEnrichmentConfig.defaultBaseOrder.map(\.rawValue)))
    }

    override func tearDown() async throws {
        MetadataProviderSettingsStore().save(savedProviders)
        try await super.tearDown()
    }

    func testLibraryHeaderClearanceAndFullBleedArtworkFollowNavigation() async throws {
        for style in [NavigationStyle.sidebar, .tabBar, .rail] {
            try await withNavigatedLibrary(style: style) { root, window, model in
                let artwork = try XCTUnwrap(self.findView(named: "HeroWipeContainerView", in: root))
                let frame = artwork.convert(artwork.bounds, to: window)
                let controller = try XCTUnwrap(window.rootViewController)
                let header = try XCTUnwrap(self.findController(NativeLibraryHeaderController.self, in: controller))
                let headerFrame = header.view.convert(header.view.bounds, to: window)
                self.capture(window, name: "library-native-\(style)", drawsHierarchy: true)
                let log = XCTAttachment(string: "\(style) artwork=\(frame) header=\(headerFrame) safeArea=\(window.safeAreaInsets)")
                log.name = "library-\(style)-geometry"
                log.lifetime = .keepAlways
                self.add(log)
                XCTAssertEqual(frame.maxX, window.bounds.maxX, accuracy: 1, "\(style): artwork must reach the physical trailing edge.")
                XCTAssertEqual(frame.minY, window.bounds.minY, accuracy: 1, "\(style): artwork must start at the physical top edge.")
                let expectedTop = window.safeAreaInsets.top + (style == .sidebar ? 60 : 0)
                XCTAssertEqual(headerFrame.minY, expectedTop, accuracy: 1,
                               "Only a visible native sidebar page button needs extra header clearance.")
                XCTAssertEqual(headerFrame.minX, window.safeAreaInsets.left, accuracy: 1)
                XCTAssertEqual(headerFrame.maxX, window.bounds.maxX - window.safeAreaInsets.right, accuracy: 1,
                               "Full-bleed artwork must not remove the controls' trailing safety margin.")
                let firstControl = try XCTUnwrap(self.focusItems(in: header.host.view).compactMap {
                    NavigationRowFocusRequester.frame(of: $0, relativeTo: window)
                }.min { $0.minX < $1.minX })
                XCTAssertEqual(firstControl.minX,
                               window.safeAreaInsets.left
                                   + (style == .rail ? LibraryNavigationLayoutFixture.railInset : 0) + 6,
                               accuracy: 1, "Pinned rail clearance must remain on the foreground, not the artwork.")
                for mode: LibraryContentMode in [.titles, .collections, .playlists, .recommended] {
                    await model.setContentMode(mode)
                    try await Task.sleep(for: .milliseconds(150))
                    window.layoutIfNeeded()
                    let current = try XCTUnwrap(self.findController(NativeLibraryHeaderController.self, in: controller))
                    XCTAssertTrue(current === header, "Mode switches must keep the mounted header.")
                    let currentFrame = current.view.convert(current.view.bounds, to: window)
                    XCTAssertEqual(currentFrame.minY, expectedTop, accuracy: 1, "\(style), \(mode)")
                    XCTAssertEqual(currentFrame.maxX, headerFrame.maxX, accuracy: 1, "\(style), \(mode)")
                    self.capture(window, name: "library-\(style)-\(mode)", drawsHierarchy: true)
                }
            }
        }
    }

    func testPinnedNavigationRestoresRecommendedLibraryControls() async throws {
        try await withNavigatedLibrary(style: .rail, pinnedHandoff: true) { root, window, _ in
            let controller = try XCTUnwrap(window.rootViewController)
            let header = try XCTUnwrap(self.findController(NativeLibraryHeaderController.self, in: controller))
            let owner = try XCTUnwrap(self.findController(NativeLibraryFocusHostController.self, in: controller))
            let shellOwner = try XCTUnwrap(self.findController(NavigationRailFocusHostController.self, in: controller))
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let observer = try XCTUnwrap(window.gestureRecognizers?
                .compactMap { $0 as? NavigationRailEdgeCatcher.LeftPressRecognizer }.first)
            let fixture = try XCTUnwrap(controller as? LibraryFocusFixtureController)
            var disabledHeaderDuringOpening = false
            fixture.onFocusUpdate = { context in
                if let item = context.nextFocusedItem,
                   let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                   frame.maxX < 500, self.focusItems(in: header.host.view).isEmpty {
                    disabledHeaderDuringOpening = true
                }
            }
            defer { fixture.onFocusUpdate = nil }
            var seen = Set<ObjectIdentifier>()
            let controls = self.focusItems(in: header.host.view).filter {
                seen.insert(ObjectIdentifier($0)).inserted
            }.sorted {
                (NavigationRowFocusRequester.frame(of: $0, relativeTo: window)?.minX ?? .infinity)
                    < (NavigationRowFocusRequester.frame(of: $1, relativeTo: window)?.minX ?? .infinity)
            }
            XCTAssertGreaterThanOrEqual(controls.count, 2)
            let card = try XCTUnwrap(self.find(NativePosterButton.self, in: root))
            let sources: [any UIFocusItem] = Array(controls.prefix(2)) + [card]
            for source in sources {
                owner.requestFocus(to: source, using: system)
                try await Task.sleep(for: .milliseconds(50))
                XCTAssertTrue(system.focusedItem === source)
                observer.onOpenNavigation?()
                let opened = ContinuousClock.now + .seconds(3)
                while !observer.railHasFocus, ContinuousClock.now < opened {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertTrue(observer.railHasFocus)
                XCTAssertFalse(shellOwner.allowsFocusUpdate(heading: .right),
                               "Native Right must not choose another control before source restoration.")
                observer.onLeaveNavigation?()
                let returned = ContinuousClock.now + .seconds(3)
                while (observer.railHasFocus || self.focusItems(in: header.host.view).isEmpty
                       || system.focusedItem !== source), ContinuousClock.now < returned {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertFalse(observer.railHasFocus)
                XCTAssertFalse(self.focusItems(in: header.host.view).isEmpty,
                               "Closing navigation must re-enable the actual library header.")
                XCTAssertTrue(system.focusedItem === source,
                              "Return must restore \(source), not \(String(describing: system.focusedItem)).")
                XCTAssertTrue(shellOwner.allowsFocusUpdate(heading: .right))
            }
            XCTAssertFalse(disabledHeaderDuringOpening,
                           "Opening navigation must not disable and rebuild the library's controls.")
        }
    }

    func testPinnedNavigationPresentsAReplacementLibraryStack() async throws {
        try await withNavigatedLibrary(style: .rail, pinnedHandoff: true, stagedLibraryEntry: true) {
            root, window, _ in
            XCTAssertNotNil(self.find(NativePosterButton.self, in: root))
            XCTAssertNotNil(UIFocusSystem.focusSystem(for: window)?.focusedItem)
        }
    }

    func testPinnedNavigationPresentsAShareLibraryStack() async throws {
        try await withNavigatedLibrary(
            style: .rail, pinnedHandoff: true, stagedLibraryEntry: true, shareLibrary: true
        ) { root, _, _ in
            XCTAssertNotNil(self.find(UICollectionView.self, in: root))
        }
    }

    func testPinnedNavigationWaitsForColdLibraryContent() async throws {
        for shareLibrary in [false, true] {
            try await withNavigatedLibrary(
                style: .rail, pinnedHandoff: true, stagedLibraryEntry: true,
                shareLibrary: shareLibrary, delayedContent: true
            ) { _, window, _ in
                XCTAssertNotNil(UIFocusSystem.focusSystem(for: window)?.focusedItem)
            }
        }
    }

    private func withNavigatedLibrary(
        style: NavigationStyle,
        artwork: ArtworkSettings = .default,
        posterURL: URL? = nil,
        heroItem: MediaItem? = nil,
        pinnedHandoff: Bool = false,
        stagedLibraryEntry: Bool = false,
        shareLibrary: Bool = false,
        delayedContent: Bool = false,
        body: (UIView, UIWindow, LibraryBrowseViewModel) async throws -> Void
    ) async throws {
        let provider = RefreshLibraryProvider(
            kind: shareLibrary ? .mediaShare : .jellyfin,
            supportsModes: !shareLibrary, recommendationHub: !shareLibrary, posterURL: posterURL, heroItem: heroItem
        )
        let name = "LibraryNativeNavigation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, defaults: defaults)
        if delayedContent {
            if shareLibrary { await provider.holdNextPage(at: 0) } else { await provider.holdNextRecommendations() }
        } else if shareLibrary {
            await model.loadFirstPage()
        } else {
            await model.loadRecommendationsIfNeeded()
        }
        defer {
            if delayedContent {
                Task {
                    await provider.releasePage()
                    await provider.releaseRecommendations()
                }
            }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let switcher = stagedLibraryEntry ? LibraryNavigationSwitch() : nil
        let host = UIHostingController(rootView: LibraryNavigationLayoutFixture(
            model: model, style: style, artwork: artwork, pinnedHandoff: pinnedHandoff,
            switcher: switcher
        ))
        let container = LibraryFocusFixtureController()
        container.addChild(host)
        container.view.addSubview(host.view)
        host.view.frame = window.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: container)
        window.rootViewController = container
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .seconds(1))
        if let switcher {
            XCTAssertNil(findController(NativeLibraryHeaderController.self, in: host))
            let observer = try XCTUnwrap(window.gestureRecognizers?
                .compactMap { $0 as? NavigationRailEdgeCatcher.LeftPressRecognizer }.first)
            observer.onOpenNavigation?()
            let opened = ContinuousClock.now + .seconds(3)
            while !observer.railHasFocus, ContinuousClock.now < opened {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(observer.railHasFocus)
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let shell = try XCTUnwrap(findController(NavigationRailFocusHostController.self, in: host))
            var seenTargets = Set<ObjectIdentifier>()
            let railTargets = focusItems(in: host.view).filter {
                seenTargets.insert(ObjectIdentifier($0)).inserted
                    && (NavigationRowFocusRequester.frame(of: $0, relativeTo: window)?.maxX ?? .infinity) < 500
            }.sorted {
                (NavigationRowFocusRequester.frame(of: $0, relativeTo: window)?.midY ?? .infinity)
                    < (NavigationRowFocusRequester.frame(of: $1, relativeTo: window)?.midY ?? .infinity)
            }
            XCTAssertEqual(railTargets.count, 4)
            let profile = try XCTUnwrap(railTargets.first)
            let profileFrame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: profile, relativeTo: window))
            let destination = try XCTUnwrap(railTargets.last)
            shell.requestFocus(to: destination, using: system)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertTrue(system.focusedItem === destination)
            var focusedProfileDuringHandoff = false
            var transitions: [String] = []
            container.onFocusUpdate = { context in
                if let item = context.nextFocusedItem,
                   let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                   frame.maxX < 500, abs(frame.midY - profileFrame.midY) < 1 {
                    focusedProfileDuringHandoff = true
                }
                transitions.append(String(describing: context.nextFocusedItem))
            }
            defer { container.onFocusUpdate = nil }
            switcher.handoff.begin(.settings)
            switcher.selection = .settings
            switcher.presented = .settings
            if delayedContent {
                let loading = ContinuousClock.now + .seconds(5)
                while !(await provider.isHoldingEntryContent), ContinuousClock.now < loading {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertTrue(shareLibrary ? model.state.isLoading : model.recommendationState.isLoading)
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertTrue(observer.railHasFocus, "Loading must retain the destination row, not enter Browse.")
                let request = try XCTUnwrap(find(NavigationContentFocusRequester.RequestView.self, in: host.view))
                XCTAssertNotNil(request.request, "The content-entry request must wait for the provider.")
                if shareLibrary { await provider.releasePage() } else { await provider.releaseRecommendations() }
            }
            let presented = ContinuousClock.now + .seconds(5)
            while switcher.handoff.isWaiting || observer.railHasFocus, ContinuousClock.now < presented {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(switcher.handoff.isWaiting, "The newly selected stack must finish presentation.")
            XCTAssertFalse(observer.railHasFocus, "Selection must automatically transfer focus out of navigation.")
            window.layoutIfNeeded()
            let first: any UIFocusItem
            if shareLibrary {
                let collection = try XCTUnwrap(find(UICollectionView.self, in: host.view))
                first = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 0, section: 0)))
            } else {
                first = try XCTUnwrap(find(NativePosterButton.self, in: host.view))
            }
            XCTAssertTrue(UIFocusSystem.focusSystem(for: window)?.focusedItem === first,
                          "Entry must focus the first media item without help from the fixture.")
            XCTAssertFalse(focusedProfileDuringHandoff, "Profile must never receive intermediate focus: \(transitions)")
            try await body(host.view, window, model)
            return
        }
        let header = try XCTUnwrap(findController(NativeLibraryHeaderController.self, in: host))
        let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        let target = try XCTUnwrap(focusItems(in: header.host.view).first)
        for _ in 0..<50 where focus.focusedItem == nil {
            focus.requestFocusUpdate(to: host)
            focus.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        container.target = target
        for _ in 0..<50 {
            focus.requestFocusUpdate(to: container)
            focus.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            if focus.focusedItem === target { break }
        }
        XCTAssertTrue(focus.focusedItem === target, "\(style): focus must enter the library header.")
        container.target = nil
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        try await body(host.view, window, model)
    }

    private func findView(named name: String, in view: UIView) -> UIView? {
        if String(describing: type(of: view)) == name { return view }
        return view.subviews.lazy.compactMap { self.findView(named: name, in: $0) }.first
    }

    func testRecommendedShowcaseUsesItsCaptionOverrideInsteadOfHome() async throws {
        let provider = RefreshLibraryProvider(kind: .jellyfin, supportsModes: true, recommendationHub: true)
        let name = "RecommendedCaptionScope.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, defaults: defaults
        )
        await model.loadRecommendationsIfNeeded()
        XCTAssertEqual(model.contentMode, .recommended)
        try await withLibrary(model: model) { root, _ in
            XCTAssertNotNil(find(NativePosterButton.self, in: root))
            XCTAssertNil(find(SystemPosterCaption.CaptionView.self, in: root),
                         "Recommended must hide labels in the actual Showcase, not ordinary library browsing.")
        }
        for visible in [false, true] {
            let settings = CardCaptionSettings(
                showsLabels: !visible, overrides: [.home: !visible, .recommended: visible]
            )
            try await withLibrary(model: model, captions: settings) { root, window in
                XCTAssertNotNil(find(NativePosterButton.self, in: root), "The real recommended media row must be mounted.")
                XCTAssertEqual(find(SystemPosterCaption.CaptionView.self, in: root) != nil, visible)
                capture(window, name: "recommended-labels-\(visible)")
            }
        }
    }

    func testNativeGridHonorsBrowseOverrideAndRemovesHiddenCaptionSpace() async throws {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(provider: provider, containerID: "library", containerKind: .movie)
        await model.loadFirstPage()
        for visible in [false, true] {
            let settings = CardCaptionSettings(showsLabels: !visible, overrides: [.browse: visible])
            try await withLibrary(model: model, captions: settings) { root, window in
                let collection = try XCTUnwrap(find(UICollectionView.self, in: root))
                let path = IndexPath(item: 0, section: 0)
                let cell = try XCTUnwrap(collection.cellForItem(at: path) as? NativeTVLibraryCell)
                let caption = try XCTUnwrap(find(SystemPosterCaption.CaptionView.self, in: cell))
                XCTAssertEqual(caption.isHidden, !visible)
                XCTAssertNotNil(cell.accessibilityLabel)
                var environment = EnvironmentValues()
                environment.plozzCardStyle = .borderless
                environment.plozzCardCaptionSettings = settings
                environment.plozzCardCaptionView = .browse
                XCTAssertEqual(
                    cell.bounds.height,
                    NativeTVLibraryCell.height(for: cell.bounds.width, environment: environment),
                    accuracy: 1
                )
                if visible {
                    let artwork = try self.libraryArtwork(in: cell)
                    XCTAssertEqual(caption.frame.minY - artwork.frame.maxY, 8, accuracy: 1)
                }
                let frame = caption.frame
                XCTAssertTrue(cell.onRequestFocus?() == true)
                try await Task.sleep(for: .milliseconds(250))
                XCTAssertTrue(cell.isFocused)
                XCTAssertEqual(caption.frame, frame, "Focus must not reflow the caption slot.")
                capture(window, name: "library-labels-\(visible)")
            }
        }
    }

    func testLibraryControlsScrollWithBothGridStylesAndRemainFocusableOnReturn() async throws {
        for style: CardFocusStyle in [.system, .highlight] {
            let provider = RefreshLibraryProvider(kind: .jellyfin, supportsModes: true, supportsFilters: true)
            let name = "LibraryScrollingHeader.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let model = LibraryBrowseViewModel(
                provider: provider, containerID: "library", containerKind: .movie,
                defaults: defaults, initialContentMode: .titles
            )
            await model.loadFirstPage()
            try await withLibrary(model: model, focusStyle: style) { root, window in
                let scroll = try XCTUnwrap(self.find(UIScrollView.self, in: root))
                let controls = self.focusItems(in: window).compactMap { item -> (any UIFocusItem, CGRect)? in
                    guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                          frame.midY < window.bounds.height * 0.2 else { return nil }
                    return (item, frame)
                }
                XCTAssertEqual(controls.count, model.availableContentModes.count + 2)
                let origin = scroll.contentOffset.y
                scroll.setContentOffset(CGPoint(x: 0, y: origin + 320), animated: true)
                for _ in 0..<25 {
                    try await Task.sleep(for: .milliseconds(20))
                    let displacement = scroll.contentOffset.y - origin
                    for (item, before) in controls {
                        let frame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: item, relativeTo: window))
                        XCTAssertEqual(frame.minY, before.minY - displacement, accuracy: 2,
                                       "\(style): the controls must travel with the posters, including intermediate frames.")
                    }
                }
                XCTAssertEqual(scroll.contentOffset.y, origin + 320, accuracy: 1)
                for (item, _) in controls {
                    let frame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: item, relativeTo: window))
                    XCTAssertLessThan(frame.maxY, 0, "The controls must leave the screen instead of covering posters.")
                }
                scroll.setContentOffset(CGPoint(x: 0, y: origin), animated: true)
                try await Task.sleep(for: .milliseconds(500))
                let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
                let controller = try XCTUnwrap(window.rootViewController as? LibraryFocusFixtureController)
                for (item, before) in controls {
                    let frame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: item, relativeTo: window))
                    XCTAssertEqual(frame.minY, before.minY, accuracy: 1)
                    controller.target = item
                    system.requestFocusUpdate(to: controller)
                    system.updateFocusIfNeeded()
                    controller.target = nil
                    XCTAssertTrue(system.focusedItem === item, "Every restored tab and menu must accept native focus.")
                }
            }
        }
    }

    func testCollectionControlsStayScrolledAwayAfterNavigationReturn() async throws {
        for style: CardFocusStyle in [.system, .highlight] {
            let provider = RefreshLibraryProvider(kind: .jellyfin, supportsModes: true)
            let name = "CollectionHeaderReturn.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let model = LibraryBrowseViewModel(
                provider: provider, containerID: "library", containerKind: .movie,
                defaults: defaults, initialContentMode: .collections
            )
            await model.loadFirstPage()
            try await withLibrary(model: model, focusStyle: style) { root, window in
                let scroll = try XCTUnwrap(self.find(UIScrollView.self, in: root))
                let controller = try XCTUnwrap(window.rootViewController as? LibraryFocusFixtureController)
                let header = try XCTUnwrap(self.findController(NativeLibraryHeaderController.self, in: controller))
                let controls = self.focusItems(in: header.view)
                XCTAssertFalse(controls.isEmpty)
                scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentOffset.y + 640), animated: false)
                try await Task.sleep(for: .milliseconds(300))
                let poster = try XCTUnwrap(self.focusItems(in: window).first { item in
                    guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window) else { return false }
                    return frame.minY > 0 && frame.maxY < window.bounds.maxY
                })
                controller.target = poster
                let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
                system.requestFocusUpdate(to: controller)
                system.updateFocusIfNeeded()
                try await Task.sleep(for: .milliseconds(500))
                let retainedOffset = scroll.contentOffset.y
                let positions = try controls.map {
                    try XCTUnwrap(NavigationRowFocusRequester.frame(of: $0, relativeTo: window))
                }
                XCTAssertTrue(positions.allSatisfy { $0.maxY < 0 })
                let detail = UIViewController()
                detail.modalPresentationStyle = .fullScreen
                detail.view.backgroundColor = .black
                let back = UIButton(type: .system)
                back.setTitle("Back", for: .normal)
                back.frame = CGRect(x: 100, y: 100, width: 200, height: 80)
                detail.view.addSubview(back)
                controller.present(detail, animated: false)
                try await Task.sleep(for: .milliseconds(400))
                XCTAssertTrue(controller.presentedViewController === detail)
                controller.dismiss(animated: false)
                try await Task.sleep(for: .milliseconds(400))
                XCTAssertNil(controller.presentedViewController)
                let restorationScroll = scroll.contentOffset.y - retainedOffset
                XCTAssertLessThan(abs(restorationScroll), 20, "Focus restoration must not reset the viewport.")
                for (item, before) in zip(controls, positions) {
                    let after = try XCTUnwrap(NavigationRowFocusRequester.frame(of: item, relativeTo: window))
                    XCTAssertEqual(after.minY, before.minY - restorationScroll, accuracy: 1,
                                   "\(style): returning must keep the header attached to the actual viewport.")
                    XCTAssertLessThan(after.maxY, 0, "Returning must not overlay controls on scrolled posters.")
                }
                controller.target = nil
            }
        }
    }

    func testNativeBrowseKeepsPartiallyVisibleRowsMountedUntilTheyLeaveTheScreen() async throws {
        let poster = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        }
        let data = try XCTUnwrap(poster.pngData())
        let server = try IPTVTestHTTPServer { _ in
            .init(data: data, headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"])
        }
        addTeardownBlock { await server.stop() }
        let url = try await server.start().appendingPathComponent("poster.png")
        let loaded = await ArtworkImageCache.shared.image(for: url, variant: .posterCard)
        XCTAssertNotNil(loaded)
        for style in [NavigationStyle.sidebar, .tabBar, .rail] {
            try await withNavigatedLibrary(style: style, artwork: .init(preference: .online), posterURL: url) {
                root, window, model in
                await model.setContentMode(.titles)
                try await Task.sleep(for: .milliseconds(300))
                window.layoutIfNeeded()
                let collection = try XCTUnwrap(self.find(UICollectionView.self, in: root))
                let path = IndexPath(item: 2, section: 0)
                let cell = try XCTUnwrap(collection.cellForItem(at: path) as? NativeTVLibraryCell)
                @MainActor func hasDecodedArtwork() throws -> Bool {
                    guard let image = (try self.libraryArtwork(in: cell) as? UIImageView)?.image,
                          let bitmap = image.cgImage else { return false }
                    let center = try self.pixel(image, at: CGPoint(x: bitmap.width / 2, y: bitmap.height / 2))
                    return center[0] > 180 && center[1] < 30 && center[2] < 30
                }
                let deadline = ContinuousClock.now + .seconds(5)
                while try !hasDecodedArtwork(), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertTrue(try hasDecodedArtwork(),
                              "Compare actual artwork, not a system placeholder whose shading follows the viewport.")
                let itemID = try XCTUnwrap(cell.item?.id)
                let artworkFrame = try self.libraryArtwork(in: cell).frame
                let initialFrame = cell.convert(artworkFrame, to: window)
                let sample = CGPoint(x: initialFrame.midX, y: initialFrame.maxY - 20)
                let beforePixel = try self.pixel(
                    self.capture(window, name: "browse-before-scroll-\(style)", drawsHierarchy: true), at: sample)
                XCTAssertGreaterThan(beforePixel[0], 180)
                XCTAssertLessThan(beforePixel[1], 30)
                XCTAssertLessThan(beforePixel[2], 30)
                // Let neighbours finish their off-main composites first, so the probe samples
                // the scroll itself rather than a main thread busy applying them.
                try await Task.sleep(for: .milliseconds(500))
                window.layoutIfNeeded()
                let origin = collection.contentOffset.y
                let target = origin + initialFrame.maxY - 80
                let movement = ScrollMountProbe()
                // UIScrollView's animated bounds updates are not guaranteed to emit contentOffset KVO.
                movement.start {
                    let offset = collection.contentOffset.y
                    guard offset > origin + 1, offset < target - 1 else { return }
                    movement.intermediateFrames += 1
                    XCTAssertTrue(cell.window === window)
                    XCTAssertFalse(cell.isHidden)
                    XCTAssertEqual(cell.alpha, 1, accuracy: 0.01)
                }
                defer { movement.stop() }
                collection.setContentOffset(CGPoint(x: 0, y: target), animated: true)
                for _ in 0..<25 {
                    try await Task.sleep(for: .milliseconds(20))
                    XCTAssertTrue(cell.window === window)
                    XCTAssertFalse(cell.isHidden)
                    XCTAssertEqual(cell.alpha, 1, accuracy: 0.01)
                }
                movement.stop()
                XCTAssertGreaterThan(movement.intermediateFrames, 0, "Exercise the moving viewport, not only its endpoint.")
                collection.layoutIfNeeded()

                let attributes = try XCTUnwrap(collection.layoutAttributesForItem(at: path))
                let expectedFrame = collection.convert(artworkFrame.offsetBy(
                    dx: attributes.frame.minX, dy: attributes.frame.minY), to: window)
                let viewport = collection.convert(collection.bounds, to: window)
                let image = self.capture(window, name: "browse-partial-row-\(style)", drawsHierarchy: true)
                let geometry = XCTAttachment(string:
                    "\(style): artwork=\(expectedFrame), viewport=\(viewport), safeArea=\(collection.safeAreaInsets)")
                geometry.name = "browse-partial-row-geometry-\(style)"
                geometry.lifetime = .keepAlways
                self.add(geometry)
                XCTAssertEqual(expectedFrame.maxY, 80, accuracy: 1)
                XCTAssertEqual(viewport.minY, window.bounds.minY, accuracy: 1)
                XCTAssertEqual(viewport.maxY, window.bounds.maxY, accuracy: 1)
                XCTAssertTrue(expectedFrame.intersects(window.bounds))
                XCTAssertTrue(collection.cellForItem(at: path) === cell,
                              "\(style): recycle only after screen exit; row=\(expectedFrame), viewport=\(viewport)")
                XCTAssertTrue(cell.window === window, "\(style): the partially visible card must remain mounted.")
                XCTAssertEqual(cell.item?.id, itemID, "\(style): screen-visible artwork must not be reused.")
                let afterPixel = try self.pixel(image, at: CGPoint(x: expectedFrame.midX, y: expectedFrame.maxY - 20))
                for channel in 0..<3 {
                    XCTAssertEqual(Int(afterPixel[channel]), Int(beforePixel[channel]), accuracy: 3,
                                   "\(style): artwork must remain rendered, not just mounted.")
                }
                let distant = IndexPath(item: 120, section: 0)
                collection.scrollToItem(at: distant, at: .centeredVertically, animated: false)
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertFalse(collection.indexPathsForVisibleItems.contains(path),
                               "Offscreen rows must still leave the displayed set.")
                XCTAssertLessThan(collection.visibleCells.count, 50, "Do not keep the entire library mounted.")
                collection.setContentOffset(CGPoint(x: 0, y: origin), animated: true)
                let returnDeadline = ContinuousClock.now + .seconds(5)
                while abs(collection.contentOffset.y - origin) > 0.5, ContinuousClock.now < returnDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertEqual(collection.contentOffset.y, origin, accuracy: 0.5,
                               "Measure the returning row after its native scroll reaches the original offset.")
                collection.layoutIfNeeded()
                let restored = try await self.waitForGridItem(itemID, at: path, in: collection)
                let restoredArtwork = try self.libraryArtwork(in: restored)
                XCTAssertEqual(restoredArtwork.convert(restoredArtwork.bounds, to: window).minY,
                               initialFrame.minY, accuracy: 1)
                XCTAssertTrue(restored.onRequestFocus?() == true, "A returning card must retain native focus behavior.")
            }
        }
    }

    @MainActor
    private final class ScrollMountProbe: NSObject {
        var intermediateFrames = 0
        private var displayLink: CADisplayLink?
        private var sample: (() -> Void)?

        func start(sample: @escaping () -> Void) {
            self.sample = sample
            let link = CADisplayLink(target: self, selector: #selector(sampleFrame))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
            sample = nil
        }

        @objc private func sampleFrame() {
            sample?()
        }
    }

    func testRemovingEarlierHubKeepsFocusedHubMounted() async throws {
        let provider = RefreshLibraryProvider(kind: .jellyfin, supportsModes: true, recommendationHub: true)
        await provider.setSecondaryRecommendationHub(true)
        let name = "LibraryRecommendationHub.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, defaults: defaults)
        await model.loadRecommendationsIfNeeded()
        try await withLibrary(model: model) { _, window in
            let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let controller = try XCTUnwrap(window.rootViewController as? LibraryFocusFixtureController)
            let first = try XCTUnwrap(self.focusItems(in: window).compactMap { item -> (any UIFocusItem, CGRect)? in
                guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                      frame.midY > window.bounds.height * 0.3, frame.width > 100 else { return nil }
                return (item, frame)
            }.min { $0.1.midY < $1.1.midY })
            controller.target = first.0
            focus.requestFocusUpdate(to: controller)
            focus.updateFocusIfNeeded()
            controller.target = nil
            try await Task.sleep(for: .milliseconds(200))
            let next = try XCTUnwrap(self.focusItems(in: window).compactMap { item -> (any UIFocusItem, CGRect)? in
                guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                      frame.width > 100, frame.midY > first.1.midY + 100 else { return nil }
                return (item, frame)
            }.min { $0.1.midY < $1.1.midY })
            controller.target = next.0
            focus.requestFocusUpdate(to: controller)
            focus.updateFocusIfNeeded()
            XCTAssertTrue(focus.focusedItem === next.0)
            controller.target = nil
            try await Task.sleep(for: .milliseconds(300))
            let before = try XCTUnwrap(focus.focusedItem)
            let rowID = try XCTUnwrap(model.recommendationState.value?.first { $0.title == "Secondary" }?.id)
            for hasHub in [false, true] {
                await provider.setRecommendationHub(hasHub)
                await model.loadRecommendations()
                try await Task.sleep(for: .milliseconds(500))
                window.layoutIfNeeded()
                XCTAssertEqual(model.recommendationState.value?.first { $0.title == "Secondary" }?.id, rowID)
                XCTAssertTrue(focus.focusedItem === before)
            }
        }
    }

    func testRecommendedRowChangesReconcileHeaderWithoutMovingFocus() async throws {
        let provider = RefreshLibraryProvider(kind: .jellyfin, supportsModes: true, recommendationHub: true)
        let name = "LibraryRecommendationRows.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, defaults: defaults)
        await model.loadRecommendationsIfNeeded()
        try await withLibrary(model: model) { _, window in
            let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let controller = try XCTUnwrap(window.rootViewController as? LibraryFocusFixtureController)
            let first = try XCTUnwrap(self.focusItems(in: window).compactMap { item -> (any UIFocusItem, CGRect)? in
                guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                      frame.midY > window.bounds.height * 0.3, frame.width > 100 else { return nil }
                return (item, frame)
            }.min { $0.1.midY < $1.1.midY })
            controller.target = first.0
            focus.requestFocusUpdate(to: controller)
            focus.updateFocusIfNeeded()
            controller.target = nil
            try await Task.sleep(for: .milliseconds(200))
            let next = try XCTUnwrap(self.focusItems(in: window).compactMap { item -> (any UIFocusItem, CGRect)? in
                guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                      frame.width > 100, frame.midY > first.1.midY + 100 else { return nil }
                return (item, frame)
            }.min { $0.1.midY < $1.1.midY })
            controller.target = next.0
            focus.requestFocusUpdate(to: controller)
            focus.updateFocusIfNeeded()
            XCTAssertTrue(focus.focusedItem === next.0)
            controller.target = nil
            try await Task.sleep(for: .milliseconds(200))
            let focusedBeforeRefresh = try XCTUnwrap(focus.focusedItem)
            for hasHub in [false, true] {
                await provider.setRecommendationHub(hasHub)
                await model.loadRecommendations()
                try await Task.sleep(for: .milliseconds(300))
                window.layoutIfNeeded()
                XCTAssertEqual(model.recommendationState.value?.count, hasHub ? 2 : 1)
                XCTAssertTrue(focus.focusedItem === focusedBeforeRefresh)
                let headers = self.focusItems(in: window).filter { item in
                    guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window) else { return false }
                    return frame.midY < window.bounds.height * 0.2 && frame.height < 150
                        && frame.maxX < window.bounds.width * 0.6
                }
                XCTAssertEqual(headers.count, hasHub ? 0 : model.availableContentModes.count)
            }
        }
    }

    func testRecommendedRefreshKeepsTheFocusedNativeCardMounted() async throws {
        let provider = RefreshLibraryProvider(kind: .jellyfin, supportsModes: true, recommendationHub: true)
        let name = "LibraryRecommendationRefresh.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, defaults: defaults)
        await model.loadRecommendationsIfNeeded()
        try await withLibrary(model: model) { _, window in
            let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let controller = try XCTUnwrap(window.rootViewController as? LibraryFocusFixtureController)
            let card = try XCTUnwrap(self.focusItems(in: window).compactMap { item -> (any UIFocusItem, CGRect)? in
                guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                      frame.midY > window.bounds.height * 0.3, frame.width > 100 else { return nil }
                return (item, frame)
            }.min { $0.1.midY < $1.1.midY }?.0)
            controller.target = card
            focus.requestFocusUpdate(to: controller)
            focus.updateFocusIfNeeded()
            controller.target = nil
            XCTAssertTrue(focus.focusedItem === card)

            await provider.holdNextPage(at: 0)
            let refresh = Task { await model.loadRecommendations() }
            await self.waitForHeldPage(provider)
            window.layoutIfNeeded()
            XCTAssertNotNil(model.recommendationState.value)
            XCTAssertTrue(focus.focusedItem === card, "An in-flight refresh must not replace the row with loading UI.")
            await provider.releasePage()
            await refresh.value
            try await Task.sleep(for: .milliseconds(200))
            window.layoutIfNeeded()
            XCTAssertTrue(focus.focusedItem === card, "Unchanged recommendation cards must retain native focus.")
        }
    }

    func testShareNameFillsHeaderOnlyWhenModeTabsAreAbsent() async throws {
        for hasTabs in [false, true] {
            let provider = RefreshLibraryProvider(
                kind: hasTabs ? .jellyfin : .mediaShare, supportsModes: hasTabs, supportsFilters: true
            )
            let name = "ShareHeader.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let model = LibraryBrowseViewModel(
                provider: provider, containerID: "library", containerKind: .movie,
                defaults: defaults, initialContentMode: .titles
            )
            await model.loadFirstPage()
            try await withLibrary(model: model, title: Text(verbatim: "Family Media")) { _, window in
                let image = self.capture(window, name: hasTabs ? "library-mode-header" : "share-name-header")
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                request.regionOfInterest = CGRect(x: 0, y: 0.8, width: 1, height: 0.2)
                try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                XCTAssertEqual(text.contains("Family Media"), !hasTabs, text)
                let controls = self.focusItems(in: window).compactMap { item -> CGRect? in
                    guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                          frame.midY < window.bounds.height * 0.2 else { return nil }
                    return frame
                }.sorted { $0.minX < $1.minX }
                XCTAssertEqual(controls.count, hasTabs ? model.availableContentModes.count + 2 : 2,
                               "The share name must not become a focusable control.")
                XCTAssertLessThanOrEqual(try XCTUnwrap(controls.last).maxX, window.bounds.width)
                if !hasTabs {
                    XCTAssertGreaterThan(try XCTUnwrap(controls.first).minX, window.bounds.width / 2,
                                         "Filter and Sort must remain on the right of the share name.")
                }
            }
        }
    }

    func testLongCombinedFilterFitsHeaderWithoutReplacingFocusedControl() async throws {
        let provider = RefreshLibraryProvider(kind: .jellyfin, supportsModes: true, supportsFilters: true)
        let name = "LibraryAdaptiveFilter.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie,
            defaults: defaults, initialContentMode: .titles
        )
        await model.loadFirstPage()
        try await withLibrary(model: model) { _, window in
            @MainActor func controls() -> [(any UIFocusItem, CGRect)] {
                self.focusItems(in: window).compactMap { item in
                    guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                          frame.midY < window.bounds.height * 0.2 else { return nil }
                    return (item, frame)
                }.sorted { $0.1.minX < $1.1.minX }
            }
            let initial = controls()
            XCTAssertEqual(initial.count, model.availableContentModes.count + 2)
            guard initial.count >= 2 else { return }
            let filter = initial[initial.count - 2].0
            let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let controller = try XCTUnwrap(window.rootViewController as? LibraryFocusFixtureController)
            controller.target = filter
            focus.requestFocusUpdate(to: controller)
            focus.updateFocusIfNeeded()
            controller.target = nil
            var widths: [CGFloat] = []
            for selection in [
                LibraryFilters(filter: .unwatched),
                LibraryFilters(filter: .unwatched, genre: "Drama", year: 2024),
                LibraryFilters(filter: .unwatched, genre: "Adapted From A Live-Action Movie", year: 2024),
                LibraryFilters(filter: .unwatched, genre: "Drama", year: 2024),
            ] {
                await model.setFilters(selection)
                try await Task.sleep(for: .milliseconds(200))
                window.layoutIfNeeded()
                let current = controls()
                XCTAssertEqual(current.count, initial.count)
                XCTAssertTrue(focus.focusedItem === filter, "Changing label representation must keep the same native Menu.")
                guard current.count == initial.count else { continue }
                widths.append(current[current.count - 2].1.width)
                for (index, entry) in current.enumerated() {
                    XCTAssertGreaterThanOrEqual(entry.1.minX, 0)
                    XCTAssertLessThanOrEqual(entry.1.maxX, window.bounds.width)
                    XCTAssertEqual(entry.1.midY, initial[index].1.midY, accuracy: 1)
                    if index > 0 { XCTAssertGreaterThanOrEqual(entry.1.minX, current[index - 1].1.maxX) }
                }
                XCTAssertEqual(current.last!.1.maxX, initial.last!.1.maxX, accuracy: 1)
            }
            XCTAssertEqual(widths.count, 4)
            guard widths.count == 4 else { return }
            XCTAssertGreaterThan(widths[1], widths[0], "A short combined selection must still display its names.")
            XCTAssertLessThan(widths[2], widths[0], "Only the overflowing selection should collapse to its count.")
            XCTAssertEqual(widths[3], widths[1], accuracy: 1, "Names must return when the selection fits again.")
        }
    }

    func testSameFilterSummaryUsesNamesAgainWhenMoreHeaderSpaceIsAvailable() async throws {
        let name = "LibraryAdaptiveFilterWidth.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var widths: [CGFloat] = []
        for supportsModes in [true, false] {
            let provider = RefreshLibraryProvider(kind: .jellyfin, supportsModes: supportsModes, supportsFilters: true)
            let model = LibraryBrowseViewModel(
                provider: provider, containerID: "library-\(supportsModes)", containerKind: .movie,
                defaults: defaults, initialContentMode: .titles
            )
            await model.setFilters(.init(filter: .unwatched, genre: "Adapted From A Live-Action Movie", year: 2024))
            try await withLibrary(model: model) { _, window in
                let controls = self.focusItems(in: window).compactMap { item -> CGRect? in
                    guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                          frame.midY < window.bounds.height * 0.2 else { return nil }
                    return frame
                }.sorted { $0.minX < $1.minX }
                XCTAssertEqual(controls.count, model.availableContentModes.count + 2)
                guard controls.count >= 2 else { return }
                widths.append(controls[controls.count - 2].width)
                XCTAssertLessThanOrEqual(controls.last!.maxX, window.bounds.width)
                XCTAssertGreaterThanOrEqual(controls.first!.minX, 0)
            }
        }
        XCTAssertEqual(widths.count, 2)
        guard widths.count == 2 else { return }
        XCTAssertGreaterThan(widths[1], widths[0] * 2,
                             "The same long selection must use available room, not a character-count cutoff.")
    }

    func testFilterSharesHeaderLineAndRetainsNativeFocusAfterSelection() async throws {
        let provider = RefreshLibraryProvider(kind: .jellyfin, supportsModes: true, supportsFilters: true)
        await provider.enableAlphabet()
        let name = "LibraryFilterFocus.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie,
            defaults: defaults, initialContentMode: .titles
        )
        await model.loadFirstPage()
        try await withLibrary(model: model) { _, window in
            let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let controller = try XCTUnwrap(window.rootViewController as? LibraryFocusFixtureController)
            let controls = self.focusItems(in: window).compactMap { item -> (any UIFocusItem, CGRect)? in
                guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                      frame.midY < window.bounds.height * 0.2 else { return nil }
                return (item, frame)
            }.sorted { $0.1.minX < $1.1.minX }
            XCTAssertEqual(controls.count, model.availableContentModes.count + 2,
                           "Alphabet navigation must not add a separate header control.")
            guard controls.count >= 3 else { return }
            let filter = controls[controls.count - 2]
            let sort = try XCTUnwrap(controls.last)
            XCTAssertEqual(filter.1.midY, sort.1.midY, accuracy: 1)
            XCTAssertEqual(sort.1.minX - filter.1.maxX, PlozzTheme.Spacing.medium, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(controls.first).1.midY, sort.1.midY, accuracy: 1)
            controller.target = filter.0
            focus.requestFocusUpdate(to: controller)
            focus.updateFocusIfNeeded()
            XCTAssertTrue(focus.focusedItem === filter.0)
            controller.target = nil
            await model.setFilters(.init(filter: .unwatched))
            try await Task.sleep(for: .milliseconds(200))
            window.layoutIfNeeded()
            XCTAssertTrue(focus.focusedItem === filter.0, "Selecting a filter must retain the actual header control.")
            _ = self.capture(window, name: "named-active-library-filter")
        }
    }

    func testSortKeepsHeaderFocusWhenScrollingAlphabetEligibilityChanges() async throws {
        let provider = RefreshLibraryProvider(kind: .jellyfin, supportsModes: true)
        await provider.enableAlphabet()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie,
            defaults: UserDefaults(suiteName: UUID().uuidString)!, initialContentMode: .titles
        )
        await model.loadFirstPage()
        try await withLibrary(model: model) { _, window in
            let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let controller = try XCTUnwrap(window.rootViewController as? LibraryFocusFixtureController)
            let sort = try XCTUnwrap(self.focusItems(in: window).compactMap { item -> (any UIFocusItem, CGRect)? in
                guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                      frame.midY < window.bounds.height * 0.2 else { return nil }
                return (item, frame)
            }.max { $0.1.maxX < $1.1.maxX }?.0)
            controller.target = sort
            focus.requestFocusUpdate(to: controller)
            focus.updateFocusIfNeeded()
            XCTAssertTrue(focus.focusedItem === sort)
            controller.target = nil

            for field: SortField in [.runtime, .name] {
                await model.setSort(CoreModels.SortDescriptor(field: field, direction: field.defaultDirection))
                try await Task.sleep(for: .milliseconds(200))
                window.layoutIfNeeded()
                XCTAssertEqual(model.alphabet.isVisible, field == .name)
                XCTAssertTrue(focus.focusedItem === sort,
                              "Changing alphabet eligibility must not move focus out of Sort.")
            }
        }
    }

    func testIndexedFilterKeepsHeaderPositionAndCentersProgressInContent() async throws {
        let provider = RefreshLibraryProvider(kind: .jellyfin, supportsModes: true, supportsFilters: true)
        let name = "LibraryQueryGeometry.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie,
            defaults: defaults, initialContentMode: .titles
        )
        await model.loadFirstPage()
        try await withLibrary(model: model) { root, window in
            @MainActor func headerFrames() -> [CGRect] {
                self.focusItems(in: window).compactMap {
                    NavigationRowFocusRequester.frame(of: $0, relativeTo: window)
                }.filter { $0.midY < window.bounds.height * 0.2 }.sorted { $0.minX < $1.minX }
            }
            let before = headerFrames()
            XCTAssertEqual(before.count, model.availableContentModes.count + 2)
            await provider.holdNextPage(at: 0)
            let query = Task { await model.setFilters(.init(filter: .dolbyVision)) }
            await self.waitForHeldPage(provider)
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
            let during = headerFrames()
            XCTAssertEqual(during.count, before.count, "Loading must not relocate the header out of its top band.")
            for (old, current) in zip(before, during) {
                XCTAssertEqual(current.midY, old.midY, accuracy: 1)
            }
            let progress = self.find(UIProgressView.self, in: root)
            let progressFrame = progress.map { $0.convert($0.bounds, to: window) }
            _ = self.capture(window, name: "indexed-filter-fixed-header")
            await provider.releasePage()
            await query.value
            let bar = try XCTUnwrap(progressFrame, "Measure the actual rendered progress bar, not its enclosing screen.")
            let contentTop = try XCTUnwrap(during.last).maxY + PlozzTheme.Spacing.large
            XCTAssertEqual(bar.midY, (contentTop + window.safeAreaLayoutGuide.layoutFrame.maxY) / 2, accuracy: 3)
            window.layoutIfNeeded()
            let after = headerFrames()
            XCTAssertEqual(after.count, before.count)
            for (old, current) in zip(before, after) {
                XCTAssertEqual(current.midY, old.midY, accuracy: 1)
            }
        }
    }

    func testLibraryModeSwitchKeepsFocusOnSelectedTab() async throws {
        let provider = RefreshLibraryProvider(kind: .jellyfin, supportsModes: true)
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie,
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        await model.loadRecommendationsIfNeeded()
        try await withLibrary(model: model) { _, window in
            let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let controller = try XCTUnwrap(window.rootViewController as? LibraryFocusFixtureController)
            let headerControls = self.focusItems(in: window).compactMap { item -> (any UIFocusItem, CGRect)? in
                guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                      frame.midY < window.bounds.height * 0.2,
                      frame.maxX < window.bounds.width * 0.6 else { return nil }
                return (item, frame)
            }.sorted { $0.1.minX < $1.1.minX }
            XCTAssertEqual(headerControls.count, model.availableContentModes.count)
            guard headerControls.count == model.availableContentModes.count else { return }
            for mode: LibraryContentMode in [.titles, .collections, .playlists, .recommended] {
                let index = try XCTUnwrap(model.availableContentModes.firstIndex(of: mode))
                let control = headerControls[index].0
                controller.target = control
                focus.requestFocusUpdate(to: controller)
                focus.updateFocusIfNeeded()
                XCTAssertTrue(focus.focusedItem === control, "\(mode) must be focused before selection")
                controller.target = nil

                await model.setContentMode(mode)
                try await Task.sleep(for: .milliseconds(120))
                window.layoutIfNeeded()
                XCTAssertTrue(focus.focusedItem === control, "\(mode) must retain actual focus after selection")
            }
        }
    }

    func testRecommendedShowcaseHidesNavigationBelowFirstRowAndRestoresItOnReturn() async throws {
        let provider = RefreshLibraryProvider(kind: .jellyfin, supportsModes: true, recommendationHub: true)
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie,
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        await model.loadRecommendationsIfNeeded()
        try await withLibrary(model: model) { _, window in
            let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let controller = try XCTUnwrap(window.rootViewController as? LibraryFocusFixtureController)
            @MainActor func headerControls() -> [any UIFocusItem] {
                self.focusItems(in: window).filter { item in
                    guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window) else {
                        return false
                    }
                    return frame.midY < window.bounds.height * 0.2 && frame.height < 150 &&
                        frame.maxX < window.bounds.width * 0.6
                }
            }
            let cards = focusItems(in: window).compactMap { item -> (any UIFocusItem, CGRect)? in
                guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                      frame.midY > window.bounds.height * 0.3,
                      frame.width > 100 else { return nil }
                return (item, frame)
            }.sorted { $0.1.midY < $1.1.midY }
            let originalHeaders = headerControls()
            XCTAssertEqual(originalHeaders.count, model.availableContentModes.count)
            let first = try XCTUnwrap(cards.first)
            controller.target = first.0
            focus.requestFocusUpdate(to: controller)
            focus.updateFocusIfNeeded()
            XCTAssertTrue(focus.focusedItem === first.0, "Enter the first row before navigating below it.")
            controller.target = nil
            try await Task.sleep(for: .milliseconds(200))
            let next = try XCTUnwrap(focusItems(in: window).compactMap { item -> (any UIFocusItem, CGRect)? in
                guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                      frame.width > 100, frame.midY > first.1.midY + 100 else { return nil }
                return (item, frame)
            }.min { $0.1.midY < $1.1.midY })

            var nextCard = next.0
            for isFirstRow in [false, true, false, true] {
                let card = isFirstRow ? first.0 : nextCard
                let expectedHeaderCount = isFirstRow ? model.availableContentModes.count : 0
                controller.target = card
                focus.requestFocusUpdate(to: controller)
                focus.updateFocusIfNeeded()
                XCTAssertTrue(focus.focusedItem === card, "The requested Showcase row must receive focus")
                controller.target = nil
                for _ in 0..<50 {
                    window.layoutIfNeeded()
                    if headerControls().count == expectedHeaderCount, focus.focusedItem is UIControl { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let restoredHeaders = headerControls()
                XCTAssertEqual(restoredHeaders.count, expectedHeaderCount)
                if !isFirstRow, !(nextCard is UIControl) {
                    // A lazy row initially enters through a temporary SwiftUI focus proxy.
                    nextCard = try XCTUnwrap(focus.focusedItem)
                    XCTAssertTrue(nextCard is UIControl, "The row must realize its native poster.")
                    XCTAssertFalse(nextCard === first.0)
                }
                XCTAssertTrue(focus.focusedItem === (isFirstRow ? first.0 : nextCard),
                              "Changing header eligibility must not steal row focus.")
                if expectedHeaderCount > 0 {
                    XCTAssertTrue(originalHeaders.allSatisfy { original in
                        restoredHeaders.contains { $0 === original }
                    }, "Returning to the first row must restore the existing controls, not recreate them.")
                }
            }
            for control in originalHeaders {
                controller.target = control
                focus.requestFocusUpdate(to: controller)
                focus.updateFocusIfNeeded()
                controller.target = nil
                XCTAssertTrue(focus.focusedItem === control, "Every restored mode must accept native focus.")
            }
        }
    }

    func testWatchlistAndJumpToastsShareOpaqueThemeSurfaceAndHeight() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for (name, palette) in [("dark", ThemePalette.dark), ("light", .light), ("black", .pureBlack)] {
            let presenter = TransientStatusPresenter(announcement: { _ in })
            var frame = CGRect.zero
            func fixture(background: Color) -> some View {
                TransientStatusView(presenter: presenter, palette: palette)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(background)
                    .environment(\.colorScheme, palette.isLight ? .light : .dark)
            }
            let host = UIHostingController(rootView: fixture(background: .red))
            window.rootViewController = host
            window.makeKeyAndVisible()
            presenter.present(icon: "bookmark.fill", text: "Added to Watchlist")
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            let watchlistFrame = frame
            XCTAssertGreaterThan(watchlistFrame.width, 200)
            let watchlistImage = capture(window, name: "watchlist-toast-\(name)")
            let surfacePoint = CGPoint(x: frame.midX, y: frame.minY + 6)
            let watchlistSurface = try pixel(watchlistImage, at: surfacePoint)

            host.rootView = fixture(background: .blue)
            presenter.present(icon: "magnifyingglass", text: "Jumping to U…", isProgress: true)
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            XCTAssertEqual(frame.height, watchlistFrame.height, accuracy: 1,
                           "The spinner must not enlarge the shared capsule")
            let progressImage = capture(window, name: "jump-toast-\(name)")
            let progressSurface = try pixel(progressImage, at: CGPoint(x: frame.midX, y: frame.minY + 6))
            XCTAssertEqual(progressSurface, watchlistSurface,
                           "The same opaque theme surface must ignore different artwork behind it")
            presenter.dismiss()
        }
    }

    func testJumpUsesSharedToastBeforeMenuDismissalWithoutAddingFocusTargets() async throws {
        for light in [false, true] {
            let provider = RefreshLibraryProvider()
            await provider.enableAlphabet(letters: ["A", "U"])
            let model = LibraryBrowseViewModel(
                provider: provider, containerID: "library", containerKind: .movie,
                defaults: UserDefaults(suiteName: UUID().uuidString)!)
            await model.loadFirstPage()
            await provider.holdNextPage(at: 112)
            let presenter = TransientStatusPresenter(announcement: { _ in })
            try await withLibrary(model: model, palette: light ? .light : .dark, presenter: presenter) { _, window in
                let host = try XCTUnwrap(window.rootViewController)
                let menu = UIAlertController(title: "Letters", message: nil, preferredStyle: .alert)
                menu.addAction(UIAlertAction(title: "U", style: .default))
                await withCheckedContinuation { continuation in
                    host.present(menu, animated: true) { continuation.resume() }
                }
                let id = UUID()
                let jump = try XCTUnwrap(model.beginLetterJump("U", menuPresentationID: id))
                XCTAssertEqual(model.alphabet.jumpingTo, "U")
                defer {
                    model.cancelLetterJump()
                    Task { await provider.releasePage() }
                }
                await waitForHeldPage(provider)
                try await Task.sleep(for: .milliseconds(40))
                XCTAssertEqual(presenter.message?.isProgress, true, "Status is available while the menu is still presented")
                XCTAssertEqual(presenter.message.map { String(localized: $0.text) }, "Jumping to U…")
                XCTAssertNil(model.alphabet.destination)
                await withCheckedContinuation { continuation in
                    menu.dismiss(animated: true) { continuation.resume() }
                }
                model.alphabet.menuDidDismiss(id)
                try await Task.sleep(for: .milliseconds(250))
                window.layoutIfNeeded()
                let footerTargets = focusItems(in: window).compactMap { item -> CGRect? in
                    guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                          window.bounds.contains(frame),
                          frame.midY > window.bounds.height * 0.75, frame.height < 100 else { return nil }
                    return frame
                }
                XCTAssertTrue(footerTargets.isEmpty, "The toast must not add an inaccessible Cancel focus target")
                capture(window, name: light ? "alphabet-shared-toast-light" : "alphabet-shared-toast-dark")
                model.cancelLetterJump()
                await provider.releasePage()
                _ = await jump.value
                try await Task.sleep(for: .milliseconds(50))
                XCTAssertNil(model.alphabet.destination)
                XCTAssertNil(presenter.message)
            }
        }
    }

    func testMenuSelectionCommitsOnlyAfterPresentedControllerDismisses() async throws {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(provider: provider, containerID: "library", containerKind: .movie)
        await model.loadFirstPage()
        try await withLibrary(model: model) { root, window in
            let host = try XCTUnwrap(window.rootViewController)
            let completion = LibraryAlphabetMenuCompletion.Controller()
            host.addChild(completion)
            root.addSubview(completion.view)
            completion.didMove(toParent: host)
            defer {
                completion.update(selection: nil, onCommit: nil)
                completion.willMove(toParent: nil)
                completion.view.removeFromSuperview()
                completion.removeFromParent()
            }
            let menu = UIAlertController(title: "Letters", message: nil, preferredStyle: .alert)
            menu.addAction(UIAlertAction(title: "M", style: .default))
            await withCheckedContinuation { continuation in
                host.present(menu, animated: true) { continuation.resume() }
            }
            var committed: [UUID] = []
            let id = UUID()
            let finished = expectation(description: "Menu selection committed after dismissal")
            completion.update(selection: id) { selection in
                committed.append(selection)
                finished.fulfill()
            }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(committed.isEmpty, "The menu still owns focus")
            await withCheckedContinuation { continuation in
                menu.dismiss(animated: true) { continuation.resume() }
            }
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertEqual(committed, [id])
            completion.update(selection: nil, onCommit: nil)
        }
    }

    func testManualScrollingKeepsViewportAndFocusWhenPendingRowsArrive() async throws {
        let provider = RefreshLibraryProvider()
        await provider.enableAlphabet(letters: LibraryLetterIndex.railLetters)
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie,
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await model.loadFirstPage()
        await provider.holdNextPage(at: 112)
        defer { Task { await provider.releasePage() } }
        try await withGrid(model: model) { collection in
            let path = IndexPath(item: 140, section: 0)
            collection.scrollToItem(at: path, at: .centeredVertically, animated: false)
            collection.layoutIfNeeded()
            await waitForHeldPage(provider)
            let cell = try XCTUnwrap(collection.cellForItem(at: path) as? NativeTVLibraryCell)
            XCTAssertNil(cell.item)
            XCTAssertTrue(cell.onRequestFocus?() == true)
            try await Task.sleep(for: .milliseconds(250))
            let offset = collection.contentOffset
            XCTAssertNil(model.alphabet.positionLetter,
                         "A pending viewport must not claim an earlier letter: top=\(String(describing: model.topVisibleIndex)) visible=\(collection.indexPathsForVisibleItems.sorted()) offset=\(offset)")
            XCTAssertTrue(model.alphabet.isPositionLoading)
            capture(try XCTUnwrap(collection.window), name: "alphabet-manual-pending")
            await provider.releasePage()
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(collection.contentOffset.x, offset.x, accuracy: 2)
            XCTAssertEqual(collection.contentOffset.y, offset.y, accuracy: 2)
            XCTAssertTrue(cell.isFocused)
            XCTAssertTrue(UIFocusSystem(for: cell)?.focusedItem === cell)
            XCTAssertEqual(cell.item?.title, "Movie 140")
            XCTAssertNil(model.alphabet.destination)
            capture(try XCTUnwrap(collection.window), name: "alphabet-manual-loaded")
        }
    }

    func testCustomGridAlphabetJumpTransfersRealFocus() async throws {
        let provider = RefreshLibraryProvider()
        await provider.enableAlphabet()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie,
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await model.loadFirstPage()
        try await withLibrary(model: model, focusStyle: .highlight) { root, window in
            let index = await model.jumpToLetter("M")
            XCTAssertEqual(index, 140)
            try await Task.sleep(for: .milliseconds(800))
            let focused = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem)
            let item = try XCTUnwrap(model.item(at: 140))
            let source = try XCTUnwrap(findSource(item.stablePresentationID, in: root))
            let frame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: focused, relativeTo: source))
            XCTAssertTrue(frame.contains(CGPoint(x: source.bounds.midX, y: source.bounds.midY)),
                          "The real SwiftUI focus item must enclose the destination artwork")
            XCTAssertTrue(window.bounds.intersects(source.convert(source.bounds, to: window)))
            XCTAssertEqual(source.reference?.isFocused, true, "The destination must also draw its focus highlight")
        }
    }

    func testRailPreviewScrollDoesNotStealFocusFromItsControl() async throws {
        let provider = RefreshLibraryProvider()
        await provider.enableAlphabet()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie,
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await model.loadFirstPage()
        try await withLibrary(model: model) { root, window in
            let railControl = UIButton(type: .system)
            railControl.setTitle("M", for: .normal)
            railControl.frame = CGRect(x: root.bounds.maxX - 100, y: 400, width: 80, height: 70)
            root.addSubview(railControl)
            defer { railControl.removeFromSuperview() }
            window.layoutIfNeeded()
            let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let controller = try XCTUnwrap(window.rootViewController as? LibraryFocusFixtureController)
            controller.target = railControl
            focus.requestFocusUpdate(to: controller)
            focus.updateFocusIfNeeded()
            XCTAssertTrue(focus.focusedItem === railControl)
            controller.target = nil
            _ = await model.jumpToLetter("M", focusesItem: false)
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertTrue(focus.focusedItem === railControl, "Rail navigation only previews the new window")
            let collection = try XCTUnwrap(find(UICollectionView.self, in: root))
            XCTAssertTrue(collection.indexPathsForVisibleItems.contains(IndexPath(item: 140, section: 0)))
        }
    }

    func testDeferredAlphabetJumpScrollsToLoadedNativeCardAndRetainsUsableFocus() async throws {
        let provider = RefreshLibraryProvider()
        await provider.enableAlphabet()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie,
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await model.loadFirstPage()
        var selected: MediaItem?
        try await withGrid(model: model, onSelect: { selected = $0 }) { collection in
            XCTAssertTrue(model.alphabet.isVisible, "Alphabet indexing must remain available without a header button.")
            let window = try XCTUnwrap(collection.window)
            let controller = try XCTUnwrap(window.rootViewController as? LibraryFocusFixtureController)
            let headerTarget = try XCTUnwrap(focusItems(in: window).compactMap { item -> (any UIFocusItem, CGRect)? in
                guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                      frame.midY < window.bounds.height * 0.2 else { return nil }
                return (item, frame)
            }.max { $0.1.maxX < $1.1.maxX }?.0)
            let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            controller.target = headerTarget
            focus.requestFocusUpdate(to: controller)
            focus.updateFocusIfNeeded()
            XCTAssertTrue(focus.focusedItem === headerTarget, "Begin with the remaining Sort control focused.")
            controller.target = nil
            let index = await model.jumpToLetter("M")
            XCTAssertEqual(index, 140)
            try await Task.sleep(for: .milliseconds(700))
            collection.layoutIfNeeded()
            let path = IndexPath(item: 140, section: 0)
            XCTAssertTrue(collection.indexPathsForVisibleItems.contains(path))
            let cell = try XCTUnwrap(collection.cellForItem(at: path) as? NativeTVLibraryCell)
            XCTAssertEqual(cell.item?.title, "Movie 140")
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(cell.isFocused, "A committed alphabet jump must transfer actual focus, not just scroll")
            XCTAssertTrue(UIFocusSystem(for: cell)?.focusedItem === cell)
            collection.delegate?.collectionView?(collection, didSelectItemAt: path)
            XCTAssertEqual(selected?.id, "Before-140")
        }
    }

    func testNativeScrollIndexFollowsAlphabetRailWithoutAFramePollingController() async throws {
        let model = LibraryBrowseViewModel(
            provider: RefreshLibraryProvider(), containerID: "library", containerKind: .movie
        )
        await model.loadFirstPage()
        let controller = NativeLibraryGridController()
        defer { controller.stopObserving() }
        for hidden in [false, true, false, true] {
            controller.update(
                model: model, total: model.totalCount, generation: model.contentGeneration,
                spoilerSettings: .default, environment: EnvironmentValues(),
                leadingInset: 40, trailingInset: 40, header: AnyView(Text("Library")),
                hidesScrollIndicator: hidden, onSelect: { _, _ in }, onLoaded: { _ in }
            )
            let collection = try XCTUnwrap(find(UICollectionView.self, in: controller.view))
            XCTAssertEqual(collection.showsVerticalScrollIndicator, !hidden)
            XCTAssertEqual(collection.indexDisplayMode, hidden ? .alwaysHidden : .automatic)
            XCTAssertFalse(controller.children.contains { $0 is ScrollIndicatorHiderController })
        }
    }

    func testNativeCellRepeatedLayoutDoesNotResizeItsHostedArtwork() async throws {
        let model = LibraryBrowseViewModel(
            provider: RefreshLibraryProvider(), containerID: "library", containerKind: .movie
        )
        await model.loadFirstPage()
        try await withLibrary(model: model) { root, window in
            let collection = try XCTUnwrap(self.find(UICollectionView.self, in: root))
            let cell = try XCTUnwrap(collection.visibleCells.compactMap { $0 as? NativeTVLibraryCell }.first)
            let artwork = try self.libraryArtwork(in: cell)
            XCTAssertTrue(artwork.superview === cell, "Native projection must keep the focused cell as its direct owner.")
            XCTAssertEqual(cell.contentView.frame, cell.bounds, "UIKit must retain full-cell content geometry.")
            let layer = artwork.layer
            let bounds = layer.bounds
            let probe = ArtworkBoundsProbe()
            let observation = layer.observe(\.bounds, options: [.old, .new]) { _, change in
                MainActor.assumeIsolated {
                    if let old = change.oldValue, let new = change.newValue, old.size != new.size {
                        probe.sizes.append(new.size)
                    }
                }
            }
            defer { observation.invalidate() }
            layer.bounds = bounds.insetBy(dx: -1, dy: -1)
            layer.bounds = bounds
            XCTAssertEqual(probe.sizes.count, 2, "The bounds observer must detect real size changes.")
            window.layoutIfNeeded()
            probe.sizes.removeAll()
            for _ in 0..<5 {
                cell.setNeedsLayout()
                cell.layoutIfNeeded()
                window.layoutIfNeeded()
            }
            let attachment = XCTAttachment(string: probe.sizes.map(String.init(describing:)).joined(separator: "\n"))
            attachment.name = "native-library-repeated-layout-bounds"
            attachment.lifetime = .keepAlways
            self.add(attachment)
            XCTAssertTrue(probe.sizes.isEmpty, "Stable layout must not briefly resize artwork to the full captioned cell: \(probe.sizes)")
            XCTAssertTrue(cell.onRequestFocus?() == true)
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertTrue(UIFocusSystem.focusSystem(for: window)?.focusedItem === cell)
            XCTAssertEqual(artwork.bounds, bounds, "Native focus must enlarge the projection, not the layout bounds.")
            let projected = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: artwork, in: window))
            XCTAssertGreaterThan(projected.width, bounds.width)
            XCTAssertGreaterThan(projected.height, bounds.height)
            let marker = try XCTUnwrap(self.find(DetailTransitionSourceView.self, in: cell))
            XCTAssertEqual(marker.frame, artwork.frame)
            XCTAssertTrue(marker.reference?.nativeArtworkView === artwork)
            XCTAssertEqual(marker.reference?.geometry(in: window)?.frame, projected)
        }
    }

    private final class ArtworkBoundsProbe {
        var sizes: [CGSize] = []
    }

    private func libraryArtwork(in cell: NativeTVLibraryCell) throws -> UIView {
        try XCTUnwrap(find(DetailTransitionSourceView.self, in: cell)?.reference?.nativeArtworkView)
    }

    func testCorrectedPageTotalsPreserveScrollAndExistingCells() async throws {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(provider: provider, containerID: "library", containerKind: .movie)
        await model.loadFirstPage()
        let controller = NativeLibraryGridController()
        defer { controller.stopObserving() }
        func update() {
            controller.update(
                model: model, total: model.totalCount, generation: model.contentGeneration,
                spoilerSettings: .default, environment: EnvironmentValues(),
                leadingInset: 40, trailingInset: 40, header: AnyView(Text("Library")),
                hidesScrollIndicator: false, onSelect: { _, _ in }, onLoaded: { _ in }
            )
        }
        update()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        controller.view.layoutIfNeeded()
        let collection = try XCTUnwrap(find(UICollectionView.self, in: controller.view))
        collection.layoutIfNeeded()
        collection.setContentOffset(CGPoint(x: 0, y: 4000), animated: false)
        collection.layoutIfNeeded()
        let before = collection.contentOffset.y
        XCTAssertGreaterThan(before, 3000)
        let visible = try XCTUnwrap(collection.indexPathsForVisibleItems.sorted().first)
        let cell = try XCTUnwrap(collection.cellForItem(at: visible))

        for (count, index) in [(245, 100), (230, 170)] {
            await provider.change(total: count, prefix: "Before")
            await model.itemAppeared(at: index, generation: model.contentGeneration)
            XCTAssertEqual(model.totalCount, count)
            update()
            collection.layoutIfNeeded()
            XCTAssertEqual(collection.numberOfItems(inSection: 0), count)
            XCTAssertEqual(collection.contentOffset.y, before, accuracy: 1)
            XCTAssertTrue(collection.cellForItem(at: visible) === cell)
        }
        for count in [5, 0] {
            await provider.change(total: count, prefix: "Before")
            await model.refreshAfterCatalogChange()
            update()
            collection.layoutIfNeeded()
            XCTAssertEqual(collection.numberOfItems(inSection: 0), count)
            XCTAssertLessThanOrEqual(collection.contentOffset.y, max(0, collection.contentSize.height - collection.bounds.height))
        }
    }

    func testSameCountCatalogRefreshUpdatesVisibleNativeCellsAndSelection() async throws {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, pageSize: 240
        )
        await model.loadFirstPage()
        var selected: MediaItem?
        try await withGrid(model: model, onSelect: { selected = $0 }) { collection in
            let path = IndexPath(item: 0, section: 0)
            let first = try XCTUnwrap(collection.cellForItem(at: path) as? NativeTVLibraryCell)
            let slot = model.slot(at: 0)
            XCTAssertEqual(first.item?.title, "Before 0")
            let generation = model.contentGeneration
            await provider.change(total: 240, prefix: "After")
            await model.refreshAfterCatalogChange()
            try await Task.sleep(for: .milliseconds(200))
            let refreshed = try XCTUnwrap(collection.cellForItem(at: path) as? NativeTVLibraryCell)
            XCTAssertTrue(refreshed === first)
            XCTAssertTrue(model.slot(at: 0) === slot)
            XCTAssertEqual(model.contentGeneration, generation)
            XCTAssertEqual(refreshed.item?.title, "After 0")
            collection.delegate?.collectionView?(collection, didSelectItemAt: path)
            XCTAssertEqual(selected?.id, refreshed.item?.id)
            XCTAssertEqual(selected?.title, refreshed.item?.title)
        }
    }

    func testCatalogCountChangesKeepScrolledNativeFocus() async throws {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, pageSize: 240
        )
        await model.loadFirstPage()
        try await withGrid(model: model) { collection in
            let path = IndexPath(item: 60, section: 0)
            collection.scrollToItem(at: path, at: .centeredVertically, animated: false)
            collection.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let focused = try XCTUnwrap(collection.cellForItem(at: path) as? NativeTVLibraryCell)
            XCTAssertTrue(focused.onRequestFocus?() == true)
            try await Task.sleep(for: .milliseconds(600))
            let offset = collection.contentOffset.y
            XCTAssertGreaterThan(offset, 2000)
            for count in [245, 230] {
                await provider.change(total: count, prefix: "Count \(count)")
                await model.refreshAfterCatalogChange()
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertEqual(collection.numberOfItems(inSection: 0), count)
                XCTAssertTrue(collection.cellForItem(at: path) === focused)
                XCTAssertTrue(focused.isFocused)
                XCTAssertEqual(focused.item?.title, "Count \(count) 60")
                XCTAssertEqual(collection.contentOffset.y, offset, accuracy: 2)
            }
        }
    }

    func testFailedCatalogRefreshKeepsExistingPagingCallbacksValid() async {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(provider: provider, containerID: "library", containerKind: .movie)
        await model.loadFirstPage()
        let generation = model.contentGeneration
        let slot = model.slot(at: 0)
        await provider.setFailure(true)
        await model.refreshAfterCatalogChange()
        await provider.setFailure(false)
        XCTAssertEqual(model.contentGeneration, generation)
        XCTAssertTrue(model.slot(at: 0) === slot)
        await model.itemAppeared(at: 100, generation: generation)
        XCTAssertNotNil(model.item(at: 100))
    }

    func testCatalogRefreshReloadsPreviouslyLoadedOffscreenPageInLargeLibrary() async {
        let provider = RefreshLibraryProvider()
        await provider.change(total: 2_178, prefix: "Before")
        let model = LibraryBrowseViewModel(provider: provider, containerID: "library", containerKind: .movie)
        await model.loadFirstPage()
        let generation = model.contentGeneration
        await model.itemAppeared(at: 1_750, generation: generation)
        let slot = model.slot(at: 1_750)
        XCTAssertEqual(slot?.item?.id, "Before-1750")
        model.itemDisappeared(at: 1_750, generation: generation)

        await provider.change(total: 2_178, prefix: "After")
        await model.refreshAfterCatalogChange()

        XCTAssertEqual(model.totalCount, 2_178)
        XCTAssertEqual(model.contentGeneration, generation)
        XCTAssertTrue(model.slot(at: 1_750) === slot)
        XCTAssertNil(slot?.item, "An off-screen page is invalidated, not treated as already loaded.")
        await model.itemAppeared(at: 1_750, generation: generation)
        XCTAssertEqual(slot?.item?.id, "After-1750", "Returning must refill the existing slot without reopening the grid.")
        XCTAssertEqual(model.item(at: 1_791)?.id, "After-1791", "The entire 42-item page must reload.")
        XCTAssertNil(model.pageError)
    }

    func testLargeNativeGridRefillsOffscreenPageAfterMidScanRefresh() async throws {
        let provider = RefreshLibraryProvider()
        await provider.change(total: 2_178, prefix: "Before")
        let model = LibraryBrowseViewModel(provider: provider, containerID: "library", containerKind: .movie)
        await model.loadFirstPage()
        var selected: MediaItem?
        try await withGrid(model: model, onSelect: { selected = $0 }) { collection in
            let path = IndexPath(item: 1_750, section: 0)
            collection.scrollToItem(at: path, at: .centeredVertically, animated: false)
            collection.layoutIfNeeded()
            _ = try await waitForGridItem("Before-1750", at: path, in: collection)
            let slot = model.slot(at: path.item)
            let generation = model.contentGeneration

            collection.scrollToItem(at: IndexPath(item: 0, section: 0), at: .top, animated: false)
            collection.layoutIfNeeded()
            _ = try await waitForGridItem("Before-0", at: IndexPath(item: 0, section: 0), in: collection)
            XCTAssertNil(collection.cellForItem(at: path), "The regression requires a previously loaded off-screen page.")
            await provider.change(total: 2_178, prefix: "After")
            await model.refreshAfterCatalogChange()
            XCTAssertTrue(model.slot(at: path.item) === slot)
            XCTAssertNil(slot?.item)
            XCTAssertEqual(model.contentGeneration, generation)

            await provider.holdNextPage(at: 1_750)
            defer { Task { await provider.releasePage() } }
            collection.scrollToItem(at: path, at: .centeredVertically, animated: false)
            collection.layoutIfNeeded()
            await waitForHeldPage(provider)
            let loading = try XCTUnwrap(collection.cellForItem(at: path) as? NativeTVLibraryCell)
            XCTAssertNil(loading.item)
            await provider.releasePage()
            let loaded = try await waitForGridItem("After-1750", at: path, in: collection)
            XCTAssertTrue(loaded === loading, "The on-screen placeholder must update without recycling or reopening.")
            XCTAssertEqual(slot?.item?.id, "After-1750")
            collection.delegate?.collectionView?(collection, didSelectItemAt: path)
            XCTAssertEqual(selected?.id, "After-1750")
        }
    }

    func testRefreshIncludesViewportThatMovedWhileFirstPageWasPending() async throws {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, pageSize: 10
        )
        await model.loadFirstPage()
        let generation = model.contentGeneration
        await provider.holdNextPage(at: 0)
        let refresh = Task { await model.refreshAfterCatalogChange() }
        await waitForHeldPage(provider)
        await model.itemAppeared(at: 30, generation: generation)
        XCTAssertNotNil(model.item(at: 30), "The visible snapshot must remain pageable during refresh.")
        let slot = model.slot(at: 30)
        await provider.change(total: 240, prefix: "Moved")
        await provider.releasePage()
        await refresh.value
        XCTAssertEqual(model.contentGeneration, generation)
        XCTAssertTrue(model.slot(at: 30) === slot)
        XCTAssertEqual(model.item(at: 30)?.title, "Moved 30")
        XCTAssertEqual(model.topVisibleIndex, 30)
    }

    func testInFlightPageSurvivesFailedRefresh() async {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, pageSize: 10
        )
        await model.loadFirstPage()
        let generation = model.contentGeneration
        await provider.holdNextPage(at: 30)
        let paging = Task { await model.itemAppeared(at: 30, generation: generation) }
        await waitForHeldPage(provider)
        await provider.setFailure(true)
        await model.refreshAfterCatalogChange()
        await provider.setFailure(false)
        await provider.releasePage()
        await paging.value
        XCTAssertEqual(model.contentGeneration, generation)
        XCTAssertNotNil(model.item(at: 30))
    }

    func testLatePageCannotOverwriteSuccessfulRefresh() async {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, pageSize: 10
        )
        await model.loadFirstPage()
        await provider.holdNextPage(at: 30)
        let paging = Task { await model.itemAppeared(at: 30, generation: model.contentGeneration) }
        await waitForHeldPage(provider)
        await provider.change(total: 240, prefix: "After")
        await model.refreshAfterCatalogChange()
        XCTAssertEqual(model.item(at: 30)?.title, "After 30")
        await provider.releasePage()
        await paging.value
        XCTAssertEqual(model.item(at: 30)?.title, "After 30")
    }

    func testShortRefreshClearsUnreturnedItemsWithinTheRefreshedPage() async {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, pageSize: 10
        )
        await model.loadFirstPage()
        let slot = model.slot(at: 5)
        XCTAssertNotNil(slot?.item)
        await provider.setPageCap(3)
        await model.refreshAfterCatalogChange()
        XCTAssertTrue(model.slot(at: 5) === slot)
        XCTAssertNotNil(model.item(at: 2))
        XCTAssertNil(model.item(at: 3))
        XCTAssertNil(model.item(at: 5))
    }

    private func withGrid(
        model: LibraryBrowseViewModel,
        onSelect: @escaping (MediaItem) -> Void = { _ in },
        body: (UICollectionView) async throws -> Void
    ) async throws {
        try await withLibrary(model: model, onSelect: onSelect) { root, _ in
            try await body(XCTUnwrap(find(UICollectionView.self, in: root)))
        }
    }

    private func withLibrary(
        model: LibraryBrowseViewModel,
        title: Text = Text("Library"),
        focusStyle: CardFocusStyle = .system,
        cardStyle: CardStyle = .borderless,
        palette: ThemePalette = .dark,
        captions: CardCaptionSettings = .default,
        scanStatus: ShareScanStatusModel = ShareScanStatusModel(),
        navigationInset: CGFloat = 0,
        presenter: TransientStatusPresenter = TransientStatusPresenter(announcement: { _ in }),
        onSelect: @escaping (MediaItem) -> Void = { _ in },
        body: (UIView, UIWindow) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(
            rootView:
                LibraryBrowseView(viewModel: model, title: title, onSelect: onSelect)
                .environment(\.plozzCardFocusStyle, focusStyle)
                .environment(\.plozzCardStyle, cardStyle)
                .environment(\.themePalette, palette)
                .environment(\.plozzCardCaptionSettings, captions)
                .environment(scanStatus)
                .environment(\.plozzNavigationContentInset, navigationInset)
                .environment(\.plozzPinnedSidebarActive, navigationInset > 0)
                .preferredColorScheme(palette.isLight ? .light : .dark)
                .transientStatusOverlay(presenter: presenter, palette: palette)
        )
        let container = LibraryFocusFixtureController()
        container.addChild(host)
        container.view.addSubview(host.view)
        host.view.frame = window.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: container)
        window.rootViewController = container
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(400))
        try await body(container.view, window)
    }

    private func waitForHeldPage(_ provider: RefreshLibraryProvider) async {
        for _ in 0..<100 {
            if await provider.isHoldingPage { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected the fixture page request to reach its gate.")
    }

    private func waitForGridItem(
        _ id: String, at path: IndexPath, in collection: UICollectionView
    ) async throws -> NativeTVLibraryCell {
        for _ in 0..<200 {
            if let cell = collection.cellForItem(at: path) as? NativeTVLibraryCell, cell.item?.id == id {
                return cell
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let cell = try XCTUnwrap(collection.cellForItem(at: path) as? NativeTVLibraryCell)
        XCTAssertEqual(cell.item?.id, id, "The displayed page did not finish loading.")
        return cell
    }

    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let result = view as? T { return result }
        for child in view.subviews {
            if let result = find(type, in: child) { return result }
        }
        return nil
    }

    private func findSource(_ itemKey: String, in view: UIView) -> DetailTransitionSourceView? {
        if let source = view as? DetailTransitionSourceView, source.reference?.itemKey == itemKey { return source }
        return view.subviews.lazy.compactMap { self.findSource(itemKey, in: $0) }.first
    }

    private func findController<T: UIViewController>(_ type: T.Type, in controller: UIViewController) -> T? {
        if let result = controller as? T { return result }
        for child in controller.children {
            if let result = findController(type, in: child) { return result }
        }
        return nil
    }

    private func focusItems(in root: UIView) -> [any UIFocusItem] {
        var containers: [any UIFocusItemContainer] = [root]
        var seen = Set<ObjectIdentifier>()
        var result: [any UIFocusItem] = []
        while let container = containers.popLast() {
            guard seen.insert(ObjectIdentifier(container)).inserted else { continue }
            let frame = container.coordinateSpace.convert(root.bounds, from: root)
            for item in container.focusItems(in: frame) {
                if let children = item.focusItemContainer { containers.append(children) }
                if let view = item as? UIView { containers.append(view) }
                if item.canBecomeFocused, !(item is UIScrollView) { result.append(item) }
            }
        }
        return result
    }

    @discardableResult
    private func capture(_ window: UIWindow, name: String, drawsHierarchy: Bool = false) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image {
            if drawsHierarchy {
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            } else {
                window.layer.render(in: $0.cgContext)
            }
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [UInt8] {
        let image = try XCTUnwrap(image.cgImage)
        let rect = CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1)
        let cropped = try XCTUnwrap(image.cropping(to: rect))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}

@MainActor @Observable
private final class LibraryNavigationSwitch {
    var selection = NavigationRailDestination.home
    var presented = NavigationRailDestination.home
    let handoff = NavigationDestinationFocusHandoff()
}

private struct LibraryNavigationLayoutFixture: View {
    static let railInset: CGFloat = 128
    let model: LibraryBrowseViewModel
    let style: NavigationStyle
    let artwork: ArtworkSettings
    var pinnedHandoff = false
    var switcher: LibraryNavigationSwitch?
    @State private var path: [Int] = []
    @State private var selection = NavigationRailDestination.home
    @State private var chrome = NavigationChromeModel()

    var body: some View {
        Group {
            if pinnedHandoff {
                NavigationRailShell(
                    profile: Profile(name: "Viewer"), entries: [], destinations: [.home, .music, .settings],
                    selection: Binding(
                        get: { switcher?.selection ?? selection },
                        set: { if let switcher { switcher.selection = $0 } else { selection = $0 } }
                    ), onOpenProfileSwitcher: {}, chrome: chrome,
                    content: pinnedContent, contentDestination: switcher?.presented ?? selection,
                    destinationFocus: switcher?.handoff ?? NavigationDestinationFocusHandoff()
                )
            } else if style == .rail {
                NavigationStack { library }
                    .environment(\.plozzNavigationContentInset, Self.railInset)
                    .environment(\.plozzPinnedSidebarActive, true)
            } else if style == .sidebar {
                tabs.tabViewStyle(.sidebarAdaptable)
            } else {
                tabs.tabViewStyle(.tabBarOnly)
            }
        }
        .environment(\.plozzNavigationStyle, style)
        .environment(\.plozzCardFocusStyle, .system)
        .environment(\.plozzCardStyle, .borderless)
        .environment(\.plozzArtworkSettings, artwork)
        .preferredColorScheme(.dark)
    }

    private var pinnedContent: AnyView {
        if switcher?.presented == .home {
            return AnyView(NavigationStack { Button("Home") {} }.id("home"))
        }
        return AnyView(NavigationStack { library }.id("library"))
    }

    private var tabs: some View {
        TabView(selection: .constant(0)) {
            Tab("Movies", systemImage: "film", value: 0) {
                NavigationStack(path: $path) {
                    if style == .sidebar {
                        library
                    } else {
                        Button("Open Library") { path.append(1) }
                            .navigationDestination(for: Int.self) { _ in library }
                            .task { if path.isEmpty { path.append(1) } }
                    }
                }
            }
            Tab("Search", systemImage: "magnifyingglass", value: 1) {
                Button("Search") {}
            }
        }
    }

    private var library: some View {
        LibraryBrowseView(viewModel: model, title: Text("Movies"), onSelect: { _ in })
    }
}

private final class LibraryFocusFixtureController: UIViewController {
    weak var target: (any UIFocusEnvironment)?
    var onFocusUpdate: ((UIFocusUpdateContext) -> Void)?
    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        target.map { [$0] } ?? super.preferredFocusEnvironments
    }
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        onFocusUpdate?(context)
    }
}

private actor RefreshLibraryProvider: MediaLibraryQueryProviding, CapabilityReporting {
    nonisolated let kind: ProviderKind
    nonisolated let session: UserSession
    nonisolated let capabilities: ProviderCapability
    private var recommendationHub: Bool
    private var secondaryRecommendationHub = false
    nonisolated let supportsFilters: Bool
    private let posterURL: URL?
    private let heroItem: MediaItem?
    init(kind: ProviderKind = .mediaShare, supportsModes: Bool = false, recommendationHub: Bool = false,
         supportsFilters: Bool = false, posterURL: URL? = nil, heroItem: MediaItem? = nil) {
        self.kind = kind
        self.capabilities = supportsModes ? [.libraryCollections, .videoPlaylists] : []
        self.recommendationHub = recommendationHub
        self.supportsFilters = supportsFilters
        self.posterURL = posterURL
        self.heroItem = heroItem
        self.session = UserSession(
            server: MediaServer(
                id: "fixture", name: "Fixture", baseURL: URL(string: "https://fixture.test")!,
                provider: kind
            ),
            userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
        )
    }
    private var total = 240
    private var prefix = "Before"
    private var fails = false
    private var pageCap: Int?
    private var alphabetEnabled = false
    private var alphabetLetters = ["A", "M"]
    private var heldStart: Int?
    private var heldPage: CheckedContinuation<Void, Never>?
    private var holdsRecommendations = false
    private var heldRecommendations: CheckedContinuation<Void, Never>?
    var isHoldingPage: Bool { heldPage != nil }
    var isHoldingEntryContent: Bool { heldPage != nil || heldRecommendations != nil }

    nonisolated func supportedSortFields(in containerID: String, kind: MediaItemKind) -> [SortField] {
        SortField.legacyFields
    }
    nonisolated func libraryQueryCapabilities(in containerID: String, kind: MediaItemKind) -> LibraryQueryCapabilities {
        .init(filters: supportsFilters ? [.all, .unwatched, .dolbyVision] : [.all], nativeFilters: [.all, .unwatched],
              supportsGenres: supportsFilters, supportsYears: supportsFilters, nativeFacets: true)
    }
    func libraryQueryFacets(in containerID: String, kind: MediaItemKind) async throws -> LibraryQueryFacets {
        .init()
    }

    func enableAlphabet(letters: [String] = ["A", "M"]) {
        alphabetEnabled = true
        alphabetLetters = letters
    }
    func letterIndex(in containerID: String, kind: MediaItemKind,
                     sort: CoreModels.SortDescriptor) async throws -> [LibraryLetterIndexEntry] {
        alphabetEnabled && sort.field == .name ? alphabetLetters.map { .init(letter: $0) } : []
    }
    func letterPosition(in containerID: String, kind: MediaItemKind, letter: String,
                        sort: CoreModels.SortDescriptor) async throws -> Int? {
        letter == "A" ? 0 : 140
    }

    func change(total: Int, prefix: String) {
        self.total = total
        self.prefix = prefix
    }
    func setFailure(_ value: Bool) { fails = value }
    func setRecommendationHub(_ value: Bool) { recommendationHub = value }
    func setSecondaryRecommendationHub(_ value: Bool) { secondaryRecommendationHub = value }
    func setPageCap(_ value: Int) { pageCap = value }
    func holdNextPage(at start: Int) { heldStart = start }
    func releasePage() {
        heldPage?.resume()
        heldPage = nil
    }
    func holdNextRecommendations() { holdsRecommendations = true }
    func releaseRecommendations() {
        heldRecommendations?.resume()
        heldRecommendations = nil
    }

    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        if fails { throw AppError.invalidResponse }
        let end = min(total, page.startIndex + min(page.limit, pageCap ?? page.limit))
        let response = MediaPage(
            items: (min(page.startIndex, end)..<end).map {
                MediaItem(id: "\(prefix)-\($0)",
                          title: "\(alphabetEnabled ? ($0 < 140 ? "Alpha" : "Movie") : prefix) \($0)", kind: .movie,
                          posterURL: posterURL)
            }, startIndex: page.startIndex, totalCount: total)
        if heldStart == page.startIndex {
            heldStart = nil
            await withCheckedContinuation { heldPage = $0 }
        }
        return response
    }
    func collections(in libraryID: String, page: PageRequest) async throws -> MediaPage {
        try await items(in: libraryID, kind: .collection, page: page)
    }
    func videoPlaylists(in libraryID: String, page: PageRequest) async throws -> MediaPage {
        try await items(in: libraryID, kind: .playlist, page: page)
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func libraryHubs(libraryID: String, kind: MediaItemKind, limit: Int) async throws -> [LibrarySection] {
        if holdsRecommendations {
            holdsRecommendations = false
            await withCheckedContinuation { heldRecommendations = $0 }
        }
        var result: [LibrarySection] = []
        if recommendationHub { result.append(LibrarySection(
            id: "featured", title: "Featured",
            items: heroItem.map { [$0] }
                ?? (0..<4).map { MediaItem(id: "Featured-\($0)", title: "Featured \($0)", kind: .movie) }
        )) }
        if secondaryRecommendationHub { result.append(LibrarySection(
            id: "secondary", title: "Secondary",
            items: (0..<4).map { MediaItem(id: "Secondary-\($0)", title: "Secondary \($0)", kind: .movie) }
        )) }
        return result
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
#endif
