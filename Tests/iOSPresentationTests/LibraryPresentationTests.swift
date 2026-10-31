#if os(iOS)
import CoreModels
import CoreNetworking
import CoreUI
import FeatureHomeCore
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import AppShelliOS

@MainActor
final class LibraryPresentationTests: XCTestCase {
    private var capturedImage: CGImage?

    func testLibraryQueryMenusStayInTrailingToolbarWhileScrollingAndChangingModes() async throws {
        let appModel = PlozziOSAppModel()
        for (width, textSize) in [(390.0, DynamicTypeSize.large), (320.0, .accessibility3), (1024.0, .large)] {
            try await withLibrary(
                provider: LibraryPresentationProvider(artwork: nil), appModel: appModel,
                size: CGSize(width: width, height: 768),
                sizeClass: width > 500 ? .regular : .compact, dynamicTypeSize: textSize
            ) { window, model in
                await model.setContentMode(.titles)
                try await waitForHostedLayout(window)
                try self.assertTrailingToolbarControls(window, count: 2)
                try await self.scrollPastHeading(window)
                try self.assertTrailingToolbarControls(window, count: 2)
                _ = try self.captureImage(window, name: "library-toolbar-scrolled-\(width)-\(textSize)")
                for (mode, count) in [(LibraryContentMode.collections, 1), (.playlists, 1), (.recommended, 0), (.titles, 2)] {
                    await model.setContentMode(mode)
                    try await waitForHostedLayout(window)
                    try self.assertTrailingToolbarControls(window, count: count)
                }
            }
        }
    }

    func testWatchlistQueryMenusStayInTrailingToolbarBesideSettingsWhileScrolling() async throws {
        let appModel = PlozziOSAppModel()
        let provider = LibraryPresentationProvider(
            artwork: nil, watchlistItems: (0..<40).map {
                MediaItem(id: "saved-\($0)", title: "Saved title \($0)", kind: .movie,
                          allowsTitleBasedMetadataMatching: false)
            }
        )
        let model = HomeViewModel(
            accounts: [ResolvedAccount(account: Account(id: "fixture", from: provider.session), provider: provider)],
            profileNamespace: "watchlist-toolbar-\(UUID())",
            layoutStore: InMemoryHomeLayoutStore()
        )
        await model.load()
        XCTAssertEqual(model.state.value?.watchlist.count, 40)
        let preferences = model.watchlistBrowse.preferences
        for (width, textSize) in [(390.0, DynamicTypeSize.large), (320.0, .accessibility3), (1024.0, .large)] {
            try await withPresentation(
                PlozziOSWatchlistLandingView(appModel: appModel, viewModel: model, onShowSettings: {}),
                appModel: appModel, size: CGSize(width: width, height: 768),
                sizeClass: width > 500 ? .regular : .compact, dynamicTypeSize: textSize
            ) { window in
                try await waitForHostedLayout(window)
                try self.assertTrailingToolbarControls(window, count: 3)
                try await self.scrollPastHeading(window)
                try self.assertTrailingToolbarControls(window, count: 3)
                _ = try self.captureImage(window, name: "watchlist-toolbar-scrolled-\(width)-\(textSize)")
                XCTAssertEqual(model.watchlistBrowse.preferences, preferences)
                XCTAssertEqual(model.state.value?.watchlist.count, 40)
            }
        }
    }

    func testActiveFilterHasVisibleIndicatorInIconOnlyToolbar() async throws {
        let appModel = PlozziOSAppModel()
        var unfilteredPixels: Data?
        for count in [0, 1] {
            try await withPresentation(
                Color.clear
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            BrowseFilterMenu(activeCount: count, summary: count == 0 ? "" : "Movies") {
                                Text("All")
                            }
                            .labelStyle(.iconOnly)
                        }
                    },
                appModel: appModel, size: CGSize(width: 390, height: 844), sizeClass: .compact
            ) { window in
                try await waitForHostedLayout(window)
                let bar = try XCTUnwrap(self.navigationBar(in: window))
                let button = try XCTUnwrap(self.descendants(bar).compactMap { $0 as? UIButton }.first)
                _ = try self.captureImage(window, name: "toolbar-filter-active-\(count)")
                let pixels = try self.imagePixels(in: button.convert(button.bounds, to: window).integral)
                if count == 0 {
                    unfilteredPixels = pixels
                } else {
                    XCTAssertNotEqual(pixels, unfilteredPixels, "An active filter must remain visible without its text label.")
                }
            }
        }
    }

    func testWatchlistQueryControlsFitPhoneTabletAndAccessibilityLayouts() async throws {
        let appModel = PlozziOSAppModel()
        let cases: [(WatchlistMediaFilter, SortField, String, String)] = [
            (.all, .dateAdded, "All", "Date Added"),
            (.movies, .name, "Movies", "Name"),
            (.shows, .releaseDate, "TV Shows", "Release Date")
        ]
        for (width, textSize) in [(390.0, DynamicTypeSize.large), (320.0, .accessibility3), (1024.0, .large)] {
            for (filter, sort, filterLabel, sortLabel) in cases {
                let preferences = WatchlistBrowsePreferences(
                    filter: filter, sort: .init(field: sort, direction: sort.defaultDirection)
                )
                try await withPresentation(
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            WatchlistBrowseControls(preferences: .constant(preferences))
                                .padding(.horizontal)
                            WatchlistEmptyStateView(isFiltered: filter != .all, clearFilters: {})
                        }
                        .padding(.vertical)
                    }
                    .navigationTitle("Watchlist"),
                    appModel: appModel, size: CGSize(width: width, height: 1100),
                    sizeClass: width > 500 ? .regular : .compact, dynamicTypeSize: textSize
                ) { window in
                    try await waitForHostedLayout(window)
                    let text = try self.capture(window, name: "watchlist-\(width)-\(textSize)-\(filter.rawValue)", scale: 2)
                        .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    XCTAssertTrue(text.contains(filterLabel), text)
                    XCTAssertTrue(text.contains(sortLabel), text)
                    XCTAssertFalse(text.contains("Filter:"), text)
                    XCTAssertFalse(text.contains("Sort:"), text)
                    if filter != .all { XCTAssertTrue(text.contains("Clear Filters"), text) }
                    let scroll = try XCTUnwrap(self.scrollViews(in: window).first)
                    XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                }
            }
        }
    }

    func testSharedFilterLabelsShowSelectionsAndCompactCompoundFilters() async throws {
        let appModel = PlozziOSAppModel()
        let compound = LibraryFilters(filter: .unwatched, genre: "Drama", year: 2024)
        let summary = compound.summary(in: Locale(identifier: "en_US"))
        let cases: [(CGFloat, Int, String, String)] = [
            (600, 0, "", "All"),
            (600, compound.activeCount, summary, "Unwatched"),
            (120, compound.activeCount, summary, "3"),
            (600, 1, "Playback", "Playback")
        ]
        for (width, count, summary, expected) in cases {
            try await withPresentation(
                BrowseFilterMenu(activeCount: count, summary: summary) {
                    Text("All")
                }
                .font(.title2)
                .frame(width: width)
                .frame(maxWidth: .infinity, maxHeight: .infinity),
                appModel: appModel, size: CGSize(width: 768, height: 1024), sizeClass: .regular
            ) { window in
                try await waitForHostedLayout(window)
                let image = try self.captureImage(window, name: "filter-label-\(width)-\(count)-\(expected)", scale: 2)
                // A lone digit is too small for reliable OCR of the full tablet canvas.
                let labelRegion = try XCTUnwrap(image.cropping(to: CGRect(
                    x: 0, y: CGFloat(image.height) / 2 - 120, width: CGFloat(image.width), height: 240
                )))
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: labelRegion).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                XCTAssertTrue(text.contains(expected), "Expected \(expected), recognized: \(text)")
                if width == 600, count == 3 {
                    XCTAssertTrue(text.contains("Drama"), text)
                    XCTAssertTrue(text.contains("2024"), text)
                }
                XCTAssertFalse(text.contains("Filter"), text)
            }
        }
    }

    func testDedicatedCollectionDirectoryOpensTheGridWithoutLibrarySubtabs() async throws {
        let appModel = PlozziOSAppModel()
        let artwork = try await seedArtwork(size: CGSize(width: 400, height: 225))
        let library = MediaLibrary(
            id: "jellyfin:collections", title: "Collections", kind: .collection, synthesizedName: .collections
        ).taggingSource("fixture")
        let route = PlozziOSLibraryRoute(library: library, accountID: "fixture")
        XCTAssertEqual(route.browseScope, .library)
        XCTAssertEqual(route.containerKind, .collection)
        XCTAssertEqual(route.accountID, "fixture")
        try await withLibrary(
            provider: LibraryPresentationProvider(artwork: artwork), appModel: appModel,
            size: CGSize(width: 390, height: 844), sizeClass: .compact, library: library
        ) { window, model in
            XCTAssertEqual(model.availableContentModes, [.titles])
            XCTAssertEqual(model.state, .loaded(24))
            XCTAssertFalse(model.showsFilterMenu)
            XCTAssertEqual(model.item(at: 0)?.kind, .collection)
            try await waitForHostedLayout(window)
            let text = try self.capture(window, name: "dedicated-collections")
                .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            XCTAssertTrue(text.contains("Collections"), text)
            XCTAssertFalse(text.contains("Recommended"), text)
            XCTAssertFalse(text.contains("Playlists"), text)
        }
    }

    func testCollectionCoversDisplayLandscapeAndSquareArtworkWithoutCropping() async throws {
        let appModel = PlozziOSAppModel()
        for size in [CGSize(width: 400, height: 225), CGSize(width: 300, height: 300)] {
            let artwork = try await seedArtwork(size: size, edgeMarkers: true)
            try await withLibrary(
                provider: LibraryPresentationProvider(artwork: artwork), appModel: appModel,
                size: CGSize(width: 390, height: 844), sizeClass: .compact
            ) { window, model in
                await model.setContentMode(.collections)
                try await waitForHostedLayout(window)
                _ = try self.capture(window, name: "collection-cover-\(Int(size.width))x\(Int(size.height))")
                let image = try XCTUnwrap(self.capturedImage)
                var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
                try pixels.withUnsafeMutableBytes {
                    let context = try XCTUnwrap(CGContext(
                        data: $0.baseAddress, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: image.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    ))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                var leftEdge = 0, rightEdge = 0
                for index in stride(from: 0, to: pixels.count, by: 4) {
                    if pixels[index] > 150, pixels[index + 1] < 100, pixels[index + 2] > 150 { leftEdge += 1 }
                    if pixels[index] < 100, pixels[index + 1] > 150, pixels[index + 2] < 100 { rightEdge += 1 }
                }
                XCTAssertGreaterThan(leftEdge, 100, "The collection cover's left edge must not be rejected or cropped.")
                XCTAssertGreaterThan(rightEdge, 100, "The collection cover's right edge must not be rejected or cropped.")
            }
        }
    }

    func testCollectionProgressKeepsCardsVisibleAndFailureOffersDetails() async throws {
        let appModel = PlozziOSAppModel()
        let artwork = try await seedArtwork()
        for (width, textSize) in [(390.0, DynamicTypeSize.large), (320.0, .accessibility2)] {
            let gate = LibraryPresentationCollectionGate()
            let provider = LibraryPresentationProvider(artwork: artwork, collectionGate: gate)
            try await withLibrary(
                provider: provider, appModel: appModel, size: CGSize(width: width, height: 900),
                sizeClass: .compact, dynamicTypeSize: textSize, preload: false
            ) { window, model in
                let loading = Task { await model.setContentMode(.collections) }
                await gate.waitUntilHeld()
                do {
                    try await waitForHostedLayout(window)
                    XCTAssertEqual(model.state, .loaded(4))
                    let progressText = try self.capture(window, name: "collection-progress-\(width)")
                        .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    XCTAssertTrue(progressText.contains("Checking collections"), progressText)
                    XCTAssertTrue(progressText.contains("checked"), progressText)
                } catch {
                    await gate.release()
                    await loading.value
                    throw error
                }
                await gate.release()
                await loading.value
                try await waitForHostedLayout(window)
                XCTAssertEqual(model.state, .loaded(4))
                XCTAssertEqual(model.pageError, .serverUnreachable)
                let failedText = try self.capture(window, name: "collection-incomplete-\(width)")
                    .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                XCTAssertTrue(failedText.contains("incomplete"), failedText)
                XCTAssertTrue(failedText.contains("Details"), failedText)
                XCTAssertTrue(failedText.contains("Try Again"), failedText)
                XCTAssertFalse(failedText.contains("same network"), failedText)
                let scroll = try XCTUnwrap(self.scrollViews(in: window).first)
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
            }
        }
    }

    func testRecommendationHeadingsTruncateNormallyAndWrapAtAccessibilitySizes() async throws {
        let appModel = PlozziOSAppModel()
        let title = "More like Avatar Aang: The Last Airbender"
        for textSize in [DynamicTypeSize.large, .xxxLarge, .accessibility3, .accessibility5] {
            let row = PlozziOSLibraryRecommendationRow(
                section: LibrarySection(id: "similar", title: title, items: []),
                spoilerSettings: SpoilerSettings(),
                showsSeriesArtwork: false,
                onSelect: { _ in }
            )
            try await withPresentation(
                ScrollView { row },
                appModel: appModel, size: CGSize(width: 390, height: 1200),
                sizeClass: .compact, dynamicTypeSize: textSize
            ) { window in
                let observations = try self.capture(window, name: "recommendation-heading-\(textSize)", scale: 2)
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                let rendered = lines.joined(separator: " ")
                XCTAssertTrue(rendered.hasPrefix("More like"), rendered)
                if textSize.isAccessibilitySize {
                    XCTAssertGreaterThan(lines.count, 1)
                    XCTAssertEqual(rendered, title, "Large accessibility text must retain the complete movie title.")
                } else {
                    XCTAssertEqual(lines.count, 1, "Normal text sizes must not wrap recommendation headings.")
                    XCTAssertFalse(rendered.contains("Airbender"), rendered)
                    XCTAssertTrue(rendered.hasSuffix("…") || rendered.hasSuffix("..."), rendered)
                }
            }
        }
    }

    func testPartialRecommendationFailuresOfferDetailsWithoutReplacingLoadedRows() async throws {
        let appModel = PlozziOSAppModel()
        for (width, textSize) in [(390.0, DynamicTypeSize.large), (320.0, .accessibility3)] {
            let provider = LibraryPresentationProvider(artwork: nil, hubError: .decoding)
            try await withLibrary(
                provider: provider, appModel: appModel, size: CGSize(width: width, height: 844),
                sizeClass: .compact, dynamicTypeSize: textSize
            ) { window, model in
                XCTAssertEqual(model.recommendationState.value?.map(\.id), ["continueWatching", "recentlyAdded"])
                XCTAssertEqual(model.recommendationDiagnostic?.failures.map(\.section), [.recommendations])
                let text = try self.capture(window, name: "library-partial-failure-\(width)")
                    .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                XCTAssertTrue(text.contains("Details"), text)
                XCTAssertTrue(text.contains("Try Again"), text)
                let scroll = try XCTUnwrap(self.scrollViews(in: window).first)
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
            }
        }
    }

    func testLibraryModesOnPhoneAndTablet() async throws {
        let artwork = try await seedArtwork()
        let appModel = PlozziOSAppModel()
        for (name, size, sizeClass) in [
            ("narrow-phone", CGSize(width: 320, height: 568), UserInterfaceSizeClass.compact),
            ("phone", CGSize(width: 390, height: 844), .compact),
            ("phone-landscape", CGSize(width: 844, height: 390), .compact),
            ("pad", CGSize(width: 768, height: 1024), .regular),
            ("pad-landscape", CGSize(width: 1024, height: 768), .regular),
            ("pad-split", CGSize(width: 507, height: 768), .compact)
        ] {
            let provider = LibraryPresentationProvider(artwork: artwork)
            try await withLibrary(provider: provider, appModel: appModel, size: size, sizeClass: sizeClass) { window, model in
                for mode in model.availableContentModes {
                    await model.setContentMode(mode)
                    try await waitForHostedLayout(window)
                    let scroll = try XCTUnwrap(self.scrollViews(in: window).first)
                    XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                    let text = try self.capture(window, name: "\(name)-\(mode.rawValue)")
                    try self.assertSelectedTab(mode, observations: text, window: window)
                    try self.assertArtworkKeyline(sizeClass: sizeClass, isGrid: mode != .recommended, window: window)
                    if mode == .recommended {
                        let heading = try XCTUnwrap(text.first {
                            $0.topCandidates(1).first?.string == "Continue Watching"
                        })
                        try self.assertHeadingKeyline(heading, sizeClass: sizeClass)
                    }
                    if mode == .titles {
                        scroll.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
                        try await waitForHostedLayout(window)
                        let offset = scroll.contentOffset.y
                        await model.loadFirstPageIfNeeded()
                        try await waitForHostedLayout(window)
                        XCTAssertEqual(scroll.contentOffset.y, offset, accuracy: 1,
                                       "An unchanged library must not jump on return.")
                    } else {
                        XCTAssertEqual(scroll.contentOffset.y + scroll.adjustedContentInset.top, 0, accuracy: 0.5,
                                       "Changing mode returns to the true scroll edge.")
                    }
                }
            }
        }
    }

    func testLargeTextLightAndDarkAndFramedCardsKeepNavigationUsable() async throws {
        let artwork = try await seedArtwork()
        let appModel = PlozziOSAppModel()
        for light in [false, true] {
            for (sizeClass, textSize) in [
                (UserInterfaceSizeClass.compact, DynamicTypeSize.accessibility3),
                (.compact, .accessibility5),
                (.regular, .accessibility3)
            ] {
                let size = sizeClass == .compact ? CGSize(width: 320, height: 740) : CGSize(width: 768, height: 1024)
                try await withLibrary(
                    provider: LibraryPresentationProvider(artwork: artwork), appModel: appModel,
                    size: size, sizeClass: sizeClass, dynamicTypeSize: textSize,
                    light: light, cardStyle: .framed
                ) { window, model in
                    for mode in model.availableContentModes {
                        await model.setContentMode(mode)
                        try await waitForHostedLayout(window)
                        let page = try XCTUnwrap(self.scrollViews(in: window).first)
                        XCTAssertLessThanOrEqual(page.contentSize.width, page.bounds.width + 1)
                        let text = try self.capture(window, name: "large-text-\(sizeClass)-\(textSize)-\(light)-\(mode.rawValue)")
                        try self.assertSelectedTab(mode, observations: text, window: window)
                        if mode == .titles {
                            let strings = text.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                            try self.assertTrailingToolbarControls(window, count: 2)
                            XCTAssertFalse(strings.contains("Sort:"), strings)
                            XCTAssertFalse(strings.contains("Filter:"), strings)
                        }
                    }
                }
            }
        }
    }

    func testModeChangesKeepTabPositionAndNavigationSeparatorStable() async throws {
        let appModel = PlozziOSAppModel()
        for (sizeClass, light) in [
            (UserInterfaceSizeClass.compact, false), (.compact, true),
            (.regular, false), (.regular, true)
        ] {
            let size = sizeClass == .compact ? CGSize(width: 390, height: 844) : CGSize(width: 768, height: 1024)
            try await withLibrary(
                provider: LibraryPresentationProvider(artwork: nil), appModel: appModel,
                size: size, sizeClass: sizeClass, light: light, preload: false, pushed: true
            ) { window, model in
                let scrolls = self.scrollViews(in: window)
                let page = try XCTUnwrap(scrolls.first)
                let tabs = try XCTUnwrap(scrolls.dropFirst().first)
                let initialFrame = tabs.convert(tabs.bounds, to: window)
                let initialOffset = page.contentOffset.y + page.adjustedContentInset.top
                XCTAssertEqual(initialOffset, 0, accuracy: 0.5)
                let bar = try XCTUnwrap(self.navigationBar(in: window))
                let borderY = bar.convert(bar.bounds, to: window).maxY
                _ = try self.captureImage(window, name: "header-\(sizeClass)-\(light)-initial")
                let initialBorder = try self.headerPixels(y: borderY)
                var measurements = ["initial tabs=\(initialFrame) offset=\(initialOffset)"]
                for mode in [LibraryContentMode.titles, .collections, .playlists, .recommended, .titles] {
                    if mode == .collections {
                        page.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
                        try await waitForHostedLayout(window)
                    }
                    await model.setContentMode(mode)
                    try await waitForHostedLayout(window)
                    let currentTabs = try XCTUnwrap(self.scrollViews(in: window).dropFirst().first)
                    let frame = currentTabs.convert(currentTabs.bounds, to: window)
                    let offset = page.contentOffset.y + page.adjustedContentInset.top
                    measurements.append("\(mode) tabs=\(frame) offset=\(offset)")
                    _ = try self.captureImage(window, name: "header-\(sizeClass)-\(light)-\(mode.rawValue)")
                    XCTAssertEqual(frame.minY, initialFrame.minY, accuracy: 0.5,
                                   "The tab row must not move when query controls appear or disappear.")
                    XCTAssertEqual(frame.height, initialFrame.height, accuracy: 0.5)
                    XCTAssertEqual(offset, initialOffset, accuracy: 0.5)
                    XCTAssertEqual(bar.convert(bar.bounds, to: window).maxY, borderY, accuracy: 0.5)
                    XCTAssertEqual(try self.headerPixels(y: borderY), initialBorder,
                                   "The title's separator must have the same appearance in every mode.")
                }
                let attachment = XCTAttachment(string: measurements.joined(separator: "\n"))
                attachment.name = "Library header geometry \(sizeClass), light: \(light)"
                attachment.lifetime = .keepAlways
                self.add(attachment)
            }
        }
    }

    func testLibraryAndSeriesUseTheSameNativeTabPresentation() async throws {
        let appModel = PlozziOSAppModel()
        let provider = LibraryPresentationProvider(artwork: nil)
        let modes = [LibraryContentMode.recommended, .titles, .collections, .playlists]
        // Identical labels let us compare actual pixels, not just similar styles.
        let seasons = modes.enumerated().map { index, mode in
            MediaItem(id: mode.rawValue, title: String(localized: mode.displayName),
                      kind: .season, seasonNumber: index + 1)
        }
        for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
            let size = sizeClass == .compact ? CGSize(width: 390, height: 844) : CGSize(width: 768, height: 1024)
            for light in [false, true] {
                for selection in [LibraryContentMode.recommended, .playlists] {
                    var libraryPixels = Data()
                    var libraryHeight: CGFloat = 0
                    try await withLibrary(provider: provider, appModel: appModel, size: size,
                                          sizeClass: sizeClass, light: light) { window, model in
                        await model.setContentMode(selection)
                        try await self.settle(window)
                        let tabs = try XCTUnwrap(self.scrollViews(in: window).dropFirst().first)
                        let frame = tabs.convert(tabs.bounds, to: window)
                        let text = try self.capture(window, name: "shared-library-\(sizeClass)-\(light)-\(selection)")
                        try self.assertSelectedTab(selection, observations: text, window: window)
                        libraryPixels = try self.imagePixels(in: frame)
                        libraryHeight = frame.height
                    }
                    let model = ItemDetailViewModel(provider: provider, itemID: "series")
                    let browser = PlozziOSInlineSeriesBrowser(
                        viewModel: model, seasons: seasons, looseEpisodes: [],
                        initialSeasonID: selection.rawValue, initialEpisode: nil,
                        onPlayTargetChange: { _ in }, onHeroShowsSeriesChange: { _ in }, onPlay: { _, _ in }
                    )
                    try await withPresentation(
                        ScrollView { browser.padding(.top, 8) }.navigationTitle("Cinema")
                            .navigationBarTitleDisplayMode(.inline),
                        appModel: appModel, size: size, sizeClass: sizeClass, light: light
                    ) { window in
                        let tabs = try XCTUnwrap(self.scrollViews(in: window).dropFirst().first)
                        let frame = tabs.convert(tabs.bounds, to: window)
                        let text = try self.capture(window, name: "shared-seasons-\(sizeClass)-\(light)-\(selection)")
                        try self.assertSelectedTab(selection, observations: text, window: window)
                        XCTAssertEqual(frame.height, libraryHeight, accuracy: 0.5)
                        XCTAssertGreaterThanOrEqual(frame.height, 44)
                        let seasonPixels = try self.imagePixels(in: frame)
                        XCTAssertEqual(seasonPixels.count, libraryPixels.count)
                        // Independent native material captures can round in opposite directions by one 8-bit step.
                        let maximumDifference = zip(seasonPixels, libraryPixels)
                            .map { abs(Int($0.0) - Int($0.1)) }.max() ?? 0
                        XCTAssertLessThanOrEqual(maximumDifference, 2,
                                                 "Library and season tabs must have the same rendered geometry and style.")
                    }
                }
            }
        }
    }

    func testSharedTabsRevealSelectionAfterOptionsTextSizeAndViewportChanges() async throws {
        let appModel = PlozziOSAppModel()
        for reduceTransparency in [false, true] {
            let state = ContentTabsFixtureState()
            let fixture = ContentTabsFixture(state: state)
                .environment(\.plozzReduceTransparency, reduceTransparency)
            try await withPresentation(fixture, appModel: appModel, size: CGSize(width: 390, height: 844),
                                       sizeClass: .compact) { window in
                for selection in [19, 0, 10] {
                    state.selection = selection
                    try await self.settle(window)
                    try self.assertFixtureSelection(state, window: window, name: "selection-\(selection)-\(reduceTransparency)")
                }
                state.options = Array((0..<20).reversed())
                try await self.settle(window)
                try self.assertFixtureSelection(state, window: window, name: "reordered-\(reduceTransparency)")
                state.textSize = .accessibility5
                try await self.settle(window)
                try self.assertFixtureSelection(state, window: window, name: "large-text-\(reduceTransparency)")
                state.width = 320
                try await self.settle(window)
                try self.assertFixtureSelection(state, window: window, name: "narrow-\(reduceTransparency)")
            }
        }
    }

    private func assertFixtureSelection(_ state: ContentTabsFixtureState, window: UIWindow, name: String) throws {
        let text = try capture(window, name: "shared-tabs-\(name)", scale: 2)
        let expected = "Season \(state.selection + 1)"
        let selected = try recognizedLabelBounds(expected, in: text)
        let scroll = try XCTUnwrap(scrollViews(in: window).first)
        let frame = scroll.convert(scroll.bounds, to: window)
        XCTAssertGreaterThanOrEqual(frame.height, 52)
        XCTAssertGreaterThanOrEqual(selected.boundingBox.minX * window.bounds.width, frame.minX)
        XCTAssertLessThanOrEqual(selected.boundingBox.maxX * window.bounds.width, frame.maxX)
        XCTAssertGreaterThanOrEqual((1 - selected.boundingBox.maxY) * window.bounds.height, frame.minY)
        XCTAssertLessThanOrEqual((1 - selected.boundingBox.minY) * window.bounds.height, frame.maxY)
    }

    private func navigationBar(in view: UIView) -> UINavigationBar? {
        (view as? UINavigationBar) ?? view.subviews.lazy.compactMap { self.navigationBar(in: $0) }.first
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func assertTrailingToolbarControls(_ window: UIWindow, count: Int) throws {
        let bar = try XCTUnwrap(navigationBar(in: window))
        let buttons = descendants(bar).compactMap { $0 as? UIButton }
        let customActions = descendants(bar).filter {
            String(describing: type(of: $0)).hasPrefix("UIKitBarItemHost<")
        }.filter { host in !buttons.contains { $0.isDescendant(of: host) } }
        let controls: [UIView] = buttons + customActions
        XCTAssertEqual(controls.count, count)
        if !controls.isEmpty {
            let group = controls.reduce(CGRect.null) { $0.union($1.convert($1.bounds, to: window)) }
            XCTAssertGreaterThan(group.midX, window.bounds.midX)
        }
        for control in controls {
            let frame = control.convert(control.bounds, to: window)
            XCTAssertGreaterThanOrEqual(frame.minX, window.bounds.minX)
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertLessThanOrEqual(frame.maxX, window.bounds.maxX)
            XCTAssertLessThanOrEqual(frame.maxY, bar.convert(bar.bounds, to: window).maxY)
            let hit = try XCTUnwrap(window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil))
            XCTAssertTrue(hit.isDescendant(of: bar), "Toolbar actions must remain reachable after scrolling.")
            if let button = control as? UIButton { XCTAssertTrue(button.isEnabled) }
        }
    }

    private func scrollPastHeading(_ window: UIWindow) async throws {
        let scroll = try XCTUnwrap(scrollViews(in: window).first {
            $0.contentSize.height > $0.bounds.height + 200
        })
        let before = scroll.contentOffset.y
        let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        scroll.setContentOffset(CGPoint(x: 0, y: min(before + 600, bottom)), animated: false)
        try await waitForHostedLayout(window)
        XCTAssertGreaterThan(scroll.contentOffset.y, before + 100)
    }

    private func headerPixels(y: CGFloat) throws -> Data {
        let image = try XCTUnwrap(capturedImage)
        let rect = CGRect(x: 0, y: y - 2, width: CGFloat(image.width), height: 4).integral
        return try imagePixels(in: rect)
    }

    private func imagePixels(in rect: CGRect) throws -> Data {
        let crop = try XCTUnwrap(capturedImage?.cropping(to: rect.integral))
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        return Data(bytes)
    }

    func testLoadingEmptyAndFailedPagesRetainModeNavigation() async throws {
        let appModel = PlozziOSAppModel()
        for outcome in [LibraryPresentationProvider.Outcome.empty, .failed, .loading] {
            for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
                let size = sizeClass == .compact ? CGSize(width: 390, height: 844) : CGSize(width: 768, height: 1024)
                try await withLibrary(
                    provider: LibraryPresentationProvider(artwork: nil, outcome: outcome),
                    appModel: appModel, size: size, sizeClass: sizeClass, preload: outcome != .loading
                ) { window, model in
                    for mode in model.availableContentModes {
                        let task = Task { await model.setContentMode(mode) }
                        if outcome != .loading { await task.value }
                        try await self.settle(window)
                        let text = try self.capture(window, name: "\(outcome)-\(sizeClass)-\(mode.rawValue)")
                        try self.assertSelectedTab(mode, observations: text, window: window)
                        let strings = text.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                        switch outcome {
                        case .empty:
                            XCTAssertTrue(strings.lowercased().contains(mode == .titles ? "empty" : "no "), strings)
                        case .failed:
                            XCTAssertTrue(strings.contains("Unable to load"), strings)
                            XCTAssertTrue(strings.contains("Try Again"), strings)
                            XCTAssertTrue(strings.contains("Details"), strings)
                        case .loading:
                            XCTAssertTrue(strings.contains("Loading"), strings)
                        case .loaded:
                            XCTFail("This test requires a non-content state.")
                        }
                        task.cancel()
                        await task.value
                    }
                }
            }
        }
    }

    func testCollectionAndPlaylistMembersDoNotOfferRootTabsOrSorting() async throws {
        let appModel = PlozziOSAppModel()
        let artwork = try await seedArtwork()
        for scope in [LibraryBrowseScope.collectionMembers, .playlistMembers] {
            for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
                let size = sizeClass == .compact ? CGSize(width: 390, height: 844) : CGSize(width: 768, height: 1024)
                try await withLibrary(
                    provider: LibraryPresentationProvider(artwork: artwork), appModel: appModel,
                    size: size, sizeClass: sizeClass, scope: scope
                ) { window, model in
                    XCTAssertEqual(model.availableContentModes, [.titles])
                    XCTAssertTrue(model.availableSortFields.isEmpty)
                    let text = try self.capture(window, name: "\(scope)-\(sizeClass)")
                        .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    XCTAssertFalse(text.contains("Recommended"), text)
                    XCTAssertFalse(text.contains("Name"), text)
                    try self.assertArtworkKeyline(sizeClass: sizeClass, isGrid: true, window: window)
                    if scope == .playlistMembers {
                        XCTAssertEqual(model.playlistOrigin(at: 0)?.index, 0)
                    }
                }
            }
        }
    }

    private func assertSelectedTab(
        _ mode: LibraryContentMode, observations: [VNRecognizedTextObservation], window: UIWindow
    ) throws {
        let label = String(localized: mode.displayName)
        let tab = try recognizedLabelBounds(label, in: observations)
        XCTAssertGreaterThanOrEqual(tab.boundingBox.minX, 0)
        XCTAssertLessThanOrEqual(tab.boundingBox.maxX, 1)
        XCTAssertLessThan((1 - tab.boundingBox.midY) * window.bounds.height, 230,
                          "Navigation remains at the top through every content state.")
    }

    private func recognizedLabelBounds(
        _ label: String, in observations: [VNRecognizedTextObservation]
    ) throws -> VNRectangleObservation {
        // Vision can combine adjacent tabs; require the complete selected label, not an entire OCR line.
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: label))\\b"
        let matches = try observations.compactMap { observation -> VNRectangleObservation? in
            guard let candidate = observation.topCandidates(1).first,
                  let range = candidate.string.range(of: pattern, options: .regularExpression)
            else { return nil }
            return try candidate.boundingBox(for: range)
        }
        return try XCTUnwrap(matches.first, "Selected \(label) must be fully visible.")
    }

    private func assertArtworkKeyline(sizeClass: UserInterfaceSizeClass, isGrid: Bool, window: UIWindow) throws {
        let image = try XCTUnwrap(capturedImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var minX = image.width
        var maxX = 0
        let bar = try XCTUnwrap(navigationBar(in: window))
        let contentTop = Int(ceil(bar.convert(bar.bounds, to: window).maxY))
        for y in max(0, contentTop)..<image.height {
            for x in 0..<image.width {
                let index = (y * image.width + x) * 4
                let r = Int(bytes[index]), g = Int(bytes[index + 1]), b = Int(bytes[index + 2])
                if b - r > 35, g - r > 20, b < 150 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
        }
        let inset = PlozziOSPageLayout.horizontalInset(for: sizeClass)
        XCTAssertEqual(CGFloat(minX), inset, accuracy: 2, "Artwork and section headings share the page keyline.")
        if isGrid {
            XCTAssertEqual(CGFloat(image.width - 1 - maxX), inset, accuracy: 2,
                           "Grids keep a matching trailing margin rather than overflowing.")
        }
    }

    private func assertHeadingKeyline(
        _ heading: VNRecognizedTextObservation, sizeClass: UserInterfaceSizeClass
    ) throws {
        let image = try XCTUnwrap(capturedImage)
        let rect = CGRect(
            x: 0, y: (1 - heading.boundingBox.maxY) * CGFloat(image.height),
            width: CGFloat(image.width), height: heading.boundingBox.height * CGFloat(image.height)
        ).integral
        let crop = try XCTUnwrap(image.cropping(to: rect))
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        let firstInk = (0..<crop.width).first { x in
            (0..<crop.height).contains { y in
                let index = (y * crop.width + x) * 4
                return bytes[index] > 180 && bytes[index + 1] > 180 && bytes[index + 2] > 180
            }
        }
        XCTAssertEqual(CGFloat(try XCTUnwrap(firstInk)),
                       PlozziOSPageLayout.horizontalInset(for: sizeClass), accuracy: 2)
    }

    private func withLibrary(
        provider: LibraryPresentationProvider,
        appModel: PlozziOSAppModel,
        size: CGSize,
        sizeClass: UserInterfaceSizeClass,
        dynamicTypeSize: DynamicTypeSize = .large,
        light: Bool = false,
        cardStyle: CardStyle = .borderless,
        scope: LibraryBrowseScope = .library,
        preload: Bool = true,
        pushed: Bool = false,
        library: MediaLibrary = .init(id: "cinema", title: "Cinema", kind: .movie),
        exercise: (UIWindow, LibraryBrowseViewModel) async throws -> Void
    ) async throws {
        let suite = "LibraryPresentation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: library.id, containerKind: library.kind,
            defaults: defaults, sourceAccountID: "fixture", browseScope: scope
        )
        if preload { await model.loadFirstPageIfNeeded() }
        defer { model.cancelPendingQuery() }
        try await withPresentation(
            PlozziOSLibraryGridView(
                viewModel: model, title: library.title, provider: provider, settings: appModel.settings
            ),
            appModel: appModel, size: size, sizeClass: sizeClass, dynamicTypeSize: dynamicTypeSize,
            light: light, cardStyle: cardStyle, pushed: pushed
        ) { window in
            try await exercise(window, model)
        }
    }

    private func withPresentation<Content: View>(
        _ content: Content,
        appModel: PlozziOSAppModel,
        size: CGSize,
        sizeClass: UserInterfaceSizeClass,
        dynamicTypeSize: DynamicTypeSize = .large,
        light: Bool = false,
        cardStyle: CardStyle = .borderless,
        pushed: Bool = false,
        exercise: (UIWindow) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = light ? .light : .dark
        let page = content.background(light ? ThemePalette.light.backgroundBase : ThemePalette.dark.backgroundBase)
        window.rootViewController = UIHostingController(rootView:
            NavigationStack(path: .constant(pushed ? [true] : [])) {
                if pushed {
                    Color.clear
                        .navigationTitle("Home")
                        .toolbarBackground(.hidden, for: .navigationBar)
                        .navigationDestination(for: Bool.self) { _ in page }
                } else {
                    page
                }
            }
            .environment(appModel)
            .environment(\.horizontalSizeClass, sizeClass)
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            .environment(\.plozzMetrics, PlozzMetrics.touch(density: .standard, dynamicTypeSize: dynamicTypeSize))
            .environment(\.plozzCardStyle, cardStyle)
            .environment(\.themePalette, light ? .light : .dark)
            .environment(\.colorScheme, light ? .light : .dark)
            .environment(\.locale, Locale(identifier: "en_US"))
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await settle(window)
        try await exercise(window)
    }

    private func settle(_ window: UIWindow) async throws {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        window.layoutIfNeeded()
    }

    private func capture(_ window: UIWindow, name: String, scale: CGFloat = 1) throws -> [VNRecognizedTextObservation] {
        let image = try captureImage(window, name: name, scale: scale)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results ?? []
    }

    private func captureImage(_ window: UIWindow, name: String, scale: CGFloat = 1) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "library-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        capturedImage = try XCTUnwrap(image.cgImage)
        return try XCTUnwrap(capturedImage)
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func seedArtwork(size: CGSize = CGSize(width: 300, height: 450), edgeMarkers: Bool = false) async throws -> URL {
        let url = try XCTUnwrap(URL(string: "https://library-fixture.example.test/\(UUID()).png"))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.12, green: 0.32, blue: 0.42, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.85, green: 0.58, blue: 0.3, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 70, y: 85, width: 160, height: 160))
            UIColor(red: 0.06, green: 0.18, blue: 0.26, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 310, width: 300, height: 140))
            if edgeMarkers {
                UIColor.magenta.setFill()
                context.fill(CGRect(x: 0, y: 0, width: size.width * 0.15, height: size.height))
                UIColor.green.setFill()
                context.fill(CGRect(x: size.width * 0.85, y: 0, width: size.width * 0.15, height: size.height))
            }
        }
        let bytes = try XCTUnwrap(image.pngData())
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        for variant in ArtworkImageVariant.allCases {
            let requestURL = variant.requestURL(for: url)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: requestURL, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
            ))
            cache.storeCachedResponse(CachedURLResponse(response: response, data: bytes), for: URLRequest(url: requestURL))
            let decoded = await ArtworkImageCache.shared.image(for: url, variant: variant)
            _ = try XCTUnwrap(decoded)
        }
        return url
    }
}

@Observable
private final class ContentTabsFixtureState {
    var options = Array(0..<20)
    var selection = 19
    var textSize = DynamicTypeSize.large
    var width: CGFloat = 390
}

private struct ContentTabsFixture: View {
    let state: ContentTabsFixtureState

    var body: some View {
        PlozzContentTabs(
            options: state.options, id: \.self, selection: state.selection,
            horizontalInset: 22,
            title: { Text(verbatim: "Season \($0 + 1)") },
            tabIdentifier: { "fixture-season-\($0)" },
            onSelect: { state.selection = $0 }
        )
        .environment(\.dynamicTypeSize, state.textSize)
        .frame(width: state.width)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct LibraryPresentationProvider: MediaProvider, CapabilityReporting, MediaLibraryQueryProviding, WatchlistProviding {
    enum Outcome: Sendable { case loaded, empty, failed, loading }
    let artwork: URL?
    var outcome = Outcome.loaded
    var hubError: AppError?
    var collectionGate: LibraryPresentationCollectionGate?
    var kind: ProviderKind = .jellyfin
    var watchlistItems: [MediaItem] = []
    let capabilities: ProviderCapability = [.video, .libraryCollections, .videoPlaylists]
    var session: UserSession {
        UserSession(
            server: MediaServer(id: "fixture", name: "Cinema", baseURL: URL(string: "https://library.example.test")!, provider: kind),
            userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
        )
    }

    private func titles(kind: MediaItemKind, count: Int = 24) -> [MediaItem] {
        if outcome == .empty { return [] }
        let names = ["Northern Lights", "The Last Voyage", "Into the Wild", "A Quiet Morning", "Beyond the Horizon", "Nightfall"]
        return (0..<count).map { index in
            MediaItem(
                id: "\(kind.rawValue)-\(index)", title: names[index % names.count], kind: kind,
                productionYear: 2024, runtime: 5400, resumePosition: 1200,
                posterURL: artwork, backdropURL: artwork,
                allowsTitleBasedMetadataMatching: false, libraryID: "cinema"
            )
        }
    }

    private func page(kind: MediaItemKind, request: PageRequest) async throws -> MediaPage {
        try await prepare()
        let items = titles(kind: kind)
        return MediaPage(items: Array(items.dropFirst(request.startIndex).prefix(request.limit)),
                         startIndex: request.startIndex, totalCount: items.count)
    }

    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        try await self.page(kind: kind, request: page)
    }
    func collections(in libraryID: String, page: PageRequest) async throws -> MediaPage {
        try await self.page(kind: .collection, request: page)
    }
    func collections(
        in libraryID: String, page: PageRequest,
        progress: @escaping @Sendable (LibraryCollectionProgress) async -> Void
    ) async throws -> MediaPage {
        if let collectionGate {
            await progress(.init(items: Array(titles(kind: .collection).prefix(4)), checked: 8, total: 40))
            await collectionGate.hold()
            throw AppError.serverUnreachable
        }
        return try await collections(in: libraryID, page: page)
    }
    func videoPlaylists(in libraryID: String, page: PageRequest) async throws -> MediaPage {
        try await self.page(kind: .playlist, request: page)
    }
    func collectionMembers(of collectionID: String, page: PageRequest) async throws -> MediaPage {
        try await self.page(kind: .movie, request: page)
    }
    func videoPlaylistMembers(of playlistID: String, page: PageRequest) async throws -> MediaPage {
        try await self.page(kind: .movie, request: page)
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func watchlist() async throws -> [MediaItem] { watchlistItems }
    func setWatchlisted(_ on: Bool, item: MediaItem) async throws { throw AppError.notFound }
    func continueWatching(limit: Int) async throws -> [MediaItem] {
        try await prepare()
        return Array(titles(kind: .movie).prefix(6))
    }
    func libraryHubs(libraryID: String, kind: MediaItemKind, limit: Int) async throws -> [LibrarySection] {
        try await prepare()
        if let hubError { throw hubError }
        return [LibrarySection(id: "top-rated", title: "Top Rated", items: Array(titles(kind: kind).prefix(limit)))]
    }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { artwork }
    func supportedSortFields(in containerID: String, kind: MediaItemKind) -> [SortField] {
        [.name, .dateAdded]
    }
    func libraryQueryCapabilities(in containerID: String, kind: MediaItemKind) -> LibraryQueryCapabilities {
        if kind == .collection { return .init(nativeSortFields: [.name, .dateAdded]) }
        return .init(filters: [.all, .unwatched], nativeFilters: [.all, .unwatched],
              supportsGenres: true, supportsYears: true, nativeFacets: true)
    }
    func libraryQueryFacets(in containerID: String, kind: MediaItemKind) async throws -> LibraryQueryFacets {
        .init(genres: ["Adventure"], years: [2024])
    }
    private func prepare() async throws {
        if outcome == .failed { throw AppError.serverUnreachable }
        if outcome == .loading { try await Task.sleep(for: .seconds(20)) }
    }
}

private actor LibraryPresentationCollectionGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func hold() async {
        await withCheckedContinuation {
            waiter = $0
            observer?.resume()
            observer = nil
        }
    }
    func waitUntilHeld() async {
        if waiter != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() {
        waiter?.resume()
        waiter = nil
    }
}
#endif
