#if os(iOS)
import CoreModels
import CoreNetworking
import CoreUI
import FeatureHomeCore
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import AppShelliOS

@MainActor
final class LibraryPresentationTests: XCTestCase {
    private var capturedImage: CGImage?

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
                    try await self.settle(window)
                    let scroll = try XCTUnwrap(self.scrollViews(in: window).first)
                    XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                    let text = try self.capture(window, name: "\(name)-\(mode.rawValue)")
                    try self.assertSelectedTab(mode, observations: text, window: window)
                    try self.assertArtworkKeyline(sizeClass: sizeClass, isGrid: mode != .recommended)
                    if mode == .recommended {
                        let heading = try XCTUnwrap(text.first {
                            $0.topCandidates(1).first?.string == "Continue Watching"
                        })
                        try self.assertHeadingKeyline(heading, sizeClass: sizeClass)
                    }
                    if mode == .titles {
                        scroll.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
                        try await self.settle(window)
                        let offset = scroll.contentOffset.y
                        await model.loadFirstPageIfNeeded()
                        try await self.settle(window)
                        XCTAssertEqual(scroll.contentOffset.y, offset, accuracy: 1,
                                       "An unchanged library must not jump on return.")
                    } else {
                        XCTAssertLessThanOrEqual(scroll.contentOffset.y, 1, "Changing mode returns to its header.")
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
                        try await self.settle(window)
                        let page = try XCTUnwrap(self.scrollViews(in: window).first)
                        XCTAssertLessThanOrEqual(page.contentSize.width, page.bounds.width + 1)
                        let text = try self.capture(window, name: "large-text-\(sizeClass)-\(textSize)-\(light)-\(mode.rawValue)")
                        try self.assertSelectedTab(mode, observations: text, window: window)
                        if mode == .titles {
                            let strings = text.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                            XCTAssertTrue(strings.contains("Sort: Name"), strings)
                            XCTAssertTrue(strings.contains("Filter"), strings)
                            XCTAssertFalse(strings.contains("Fil-"), strings)
                        }
                    }
                }
            }
        }
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
                    XCTAssertFalse(text.contains("Sort:"), text)
                    try self.assertArtworkKeyline(sizeClass: sizeClass, isGrid: true)
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
        let tab = try XCTUnwrap(observations.first { $0.topCandidates(1).first?.string == label },
                               "Selected \(label) must be fully visible.")
        XCTAssertGreaterThanOrEqual(tab.boundingBox.minX, 0)
        XCTAssertLessThanOrEqual(tab.boundingBox.maxX, 1)
        XCTAssertLessThan((1 - tab.boundingBox.midY) * window.bounds.height, 230,
                          "Navigation remains at the top through every content state.")
    }

    private func assertArtworkKeyline(sizeClass: UserInterfaceSizeClass, isGrid: Bool) throws {
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
        for y in 0..<image.height {
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
        exercise: (UIWindow, LibraryBrowseViewModel) async throws -> Void
    ) async throws {
        let suite = "LibraryPresentation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "cinema", containerKind: .movie,
            defaults: defaults, sourceAccountID: "fixture", browseScope: scope
        )
        if preload { await model.loadFirstPageIfNeeded() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = light ? .light : .dark
        window.rootViewController = UIHostingController(rootView:
            NavigationStack {
                PlozziOSLibraryGridView(
                    viewModel: model, title: "Cinema", provider: provider, settings: appModel.settings
                )
                .background(light ? ThemePalette.light.backgroundBase : ThemePalette.dark.backgroundBase)
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
            model.cancelPendingQuery()
        }
        try await settle(window)
        try await exercise(window, model)
    }

    private func settle(_ window: UIWindow) async throws {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        window.layoutIfNeeded()
    }

    private func capture(_ window: UIWindow, name: String) throws -> [VNRecognizedTextObservation] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "library-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        capturedImage = try XCTUnwrap(image.cgImage)
        try VNImageRequestHandler(cgImage: XCTUnwrap(capturedImage)).perform([request])
        return request.results ?? []
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func seedArtwork() async throws -> URL {
        let url = try XCTUnwrap(URL(string: "https://library-fixture.example.test/\(UUID()).png"))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 450), format: format).image { context in
            UIColor(red: 0.12, green: 0.32, blue: 0.42, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 450))
            UIColor(red: 0.85, green: 0.58, blue: 0.3, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 70, y: 85, width: 160, height: 160))
            UIColor(red: 0.06, green: 0.18, blue: 0.26, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 310, width: 300, height: 140))
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

private struct LibraryPresentationProvider: MediaProvider, CapabilityReporting, MediaLibraryQueryProviding {
    enum Outcome: Sendable { case loaded, empty, failed, loading }
    let artwork: URL?
    var outcome = Outcome.loaded
    var kind: ProviderKind = .jellyfin
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
    func continueWatching(limit: Int) async throws -> [MediaItem] {
        try await prepare()
        return Array(titles(kind: .movie).prefix(6))
    }
    func libraryHubs(libraryID: String, kind: MediaItemKind, limit: Int) async throws -> [LibrarySection] {
        try await prepare()
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
        .init(filters: [.all, .unwatched], nativeFilters: [.all, .unwatched],
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
#endif
