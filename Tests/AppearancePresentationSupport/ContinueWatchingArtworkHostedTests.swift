import CoreModels
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI
@testable import MetadataKit
#if os(tvOS)
import TVUIKit
#endif

@MainActor
final class ContinueWatchingArtworkHostedTests: XCTestCase {
    private var savedProviders = MetadataProviderSettings.default

    override func setUp() async throws {
        try await super.setUp()
        let settings = MetadataProviderSettingsStore()
        savedProviders = settings.load()
        settings.save(.init(
            orderMode: .custom, enabledOrder: ["tmdb"],
            disabledOrder: MetadataEnrichmentConfig.defaultBaseOrder.filter { $0 != .tmdb }.map(\.rawValue)
        ))
    }

    override func tearDown() async throws {
        MetadataProviderSettingsStore().save(savedProviders)
        try await super.tearDown()
    }

    func testPreparationSeedsTheExactCardWinnerForEachSourcePreference() async throws {
        for preference in [ArtworkPreference.recommended, .library, .online] {
            let fixture = try await makeArtwork()
            let store = makeStore { _ in fixture.clean }
            let policy = ArtworkPresentationPolicy(
                area: .continueWatching, settings: .init(preference: preference),
                providers: MetadataProviderSettingsStore().load()
            )
            let source = ContinueWatchingArtworkSource(item: fixture.item, style: .landscape, policy: policy)
            await source.prepare(store: store)
            let references = source.references(textlessBackdrop: store.backdrop(for: fixture.item))
            let key = ArtworkResolveKey.make(
                references: references, variant: .landscapeCard, maxAspectRatio: nil,
                pinIdentity: source.pinIdentity, providerPolicyIdentity: policy.identity,
                prefersPrimaryReference: source.primaryReference(textlessBackdrop: store.backdrop(for: fixture.item)) != nil
            )
            let prepared = try XCTUnwrap(ArtworkSeedMemo.prepared(for: key, variant: .landscapeCard))
            XCTAssertEqual(prepared.reference, preference == .library
                ? fixture.item.backdropURL.map(ArtworkReference.remote) : .remote(fixture.clean))
            let renderer = ImageRenderer(content:
                FallbackAsyncImage(
                    references: references,
                    prefersPrimaryReference: source.primaryReference(textlessBackdrop: store.backdrop(for: fixture.item)) != nil,
                    variant: .landscapeCard, artworkPolicy: policy,
                    asyncFallbackURL: { nil }, pinIdentity: source.pinIdentity
                ) { Color.green }
                .frame(width: 160, height: 90)
            )
            XCTAssertNotNil(renderer.uiImage, "Rendering must not need an asynchronous view load.")
            for cardStyle in [CardStyle.borderless, .framed] {
                try await withCard(fixture.item, store: store, style: cardStyle, settings: policy.settings) { window in
                    let expected = preference == .library ? 0 : 2
                    XCTAssertGreaterThan(try coloredPixels(window)[expected], 500)
                }
            }
        }
    }

    func testCancellingPrefetchDoesNotCancelAVisibleTextlessConsumer() async throws {
        let fixture = try await makeArtwork()
        let gate = TextlessLookupGate()
        defer { Task { await gate.finish(nil) } }
        let store = makeStore { _ in await gate.lookup() }
        let prefetch = Task { await store.prepare(for: fixture.item, variant: .landscapeCard, background: true) }
        let deadline = ContinuousClock.now + .seconds(3)
        while await gate.requests == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let visible = Task { await store.prepare(for: fixture.item, variant: .landscapeCard) }
        try await waitUntil { store.preparationConsumerCount(for: fixture.item) == 2 }
        prefetch.cancel()
        await gate.finish(fixture.clean)
        await prefetch.value
        await visible.value
        XCTAssertEqual(store.backdrop(for: fixture.item), fixture.clean)
        let requests = await gate.requests
        XCTAssertEqual(requests, 1)
    }

    func testCancelledTextlessPreparationLeavesTheAnswerUnknownAndRetryable() async throws {
        let fixture = try await makeArtwork()
        let gate = TextlessLookupGate()
        defer { Task { await gate.finish(nil) } }
        let store = makeStore { _ in await gate.lookup() }
        let task = Task { await store.prepare(for: fixture.item, variant: .landscapeCard, background: true) }
        try await waitUntil { store.preparationConsumerCount(for: fixture.item) == 1 }
        task.cancel()
        try await waitUntil { store.preparationConsumerCount(for: fixture.item) == 0 }
        await gate.finish(nil)
        await task.value
        XCTAssertFalse(store.hasAnswer(for: fixture.item))
    }

    func testKnownTextlessArtworkBeatsGenericMetadataForEveryRenderer() async throws {
        for kind in [MediaItemKind.episode, .movie] {
            let fixture = try await makeArtwork(kind: kind)
            let store = makeStore()
            store.recordForTesting(.available(fixture.clean), for: fixture.item)
            for style in [CardStyle.borderless, .framed] {
                for focus in CardFocusStyle.allCases {
                    try await withCard(fixture.item, store: store, style: style, focus: focus) { window in
                        try await waitUntil { try self.coloredPixels(window)[2] > 500 }
                        let counts = try coloredPixels(window)
                        XCTAssertEqual(counts[0], 0, "Library artwork must not displace the textless background.")
                        XCTAssertEqual(counts[1], 0, "Generic metadata artwork must not displace the textless background.")
                    }
                }
            }
        }
    }

    func testColdTextlessLookupDoesNotPinTheGenericBackground() async throws {
        for style in [CardStyle.borderless, .framed] {
            let fixture = try await makeArtwork()
            let gate = TextlessLookupGate()
            defer { Task { await gate.finish(nil) } }
            let store = makeStore { _ in await gate.lookup() }
            try await withCard(fixture.item, store: store, style: style) { window in
                let deadline = ContinuousClock.now + .seconds(3)
                while await gate.requests == 0, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                let requests = await gate.requests
                XCTAssertEqual(requests, 1, "The card must start its own textless lookup, without row prefetch.")
                #if os(tvOS)
                let poster = nativePoster(in: window)
                if style == .borderless { XCTAssertNotNil(poster) }
                #endif
                let before = try coloredPixels(window)
                XCTAssertEqual(before[0], 0)
                XCTAssertEqual(before[1], 0, "Do not paint and pin the generic background while textless art is pending.")
                await gate.finish(fixture.clean)
                try await waitUntil { try self.coloredPixels(window)[2] > 500 }
                #if os(tvOS)
                if let poster { XCTAssertTrue(nativePoster(in: window) === poster, "Keep the native focus owner mounted.") }
                #endif
            }
            await gate.finish(nil)
        }
    }

    func testLibraryOverrideSkipsTextlessLookupAndKeepsCuratedArtwork() async throws {
        let fixture = try await makeArtwork()
        let gate = TextlessLookupGate()
        let store = makeStore { _ in await gate.lookup() }
        store.recordForTesting(.available(fixture.clean), for: fixture.item)
        for style in [CardStyle.borderless, .framed] {
            try await withCard(
                fixture.item, store: store, style: style,
                settings: .init(overrides: [.continueWatching: .library])
            ) { window in
                try await waitUntil { try self.coloredPixels(window)[0] > 500 }
                let counts = try coloredPixels(window)
                XCTAssertEqual(counts[1], 0)
                XCTAssertEqual(counts[2], 0)
            }
        }
        let count = await gate.requests
        XCTAssertEqual(count, 0)
        await gate.finish(nil)
    }

    func testRecommendedKeepsLibraryBackdropWhenOnlyMetadataPosterExists() async throws {
        for kind in [MediaItemKind.episode, .movie] {
            let fixture = try await makeArtwork(kind: kind, hasProviderBackdrop: false)
            let store = makeStore { _ in nil }
            for style in [CardStyle.borderless, .framed] {
                try await withCard(fixture.item, store: store, style: style) { window in
                    try await waitUntil { try self.coloredPixels(window)[0] > 500 }
                    XCTAssertEqual(try coloredPixels(window)[1], 0, "Do not crop a titled provider poster over a library backdrop.")
                }
            }
        }
    }

    func testMissingLibraryBackdropStillFallsBackToMetadataPoster() async throws {
        for kind in [MediaItemKind.episode, .movie] {
            for hasLibraryBackdrop in [true, false] {
                var fixture = try await makeArtwork(kind: kind, hasProviderBackdrop: false)
                let missing = try await cacheImage(nil)
                fixture.item.backdropURL = hasLibraryBackdrop ? missing : nil
                fixture.item.fallbackArtworkURL = hasLibraryBackdrop ? missing : nil
                let store = makeStore { _ in nil }
                for style in [CardStyle.borderless, .framed] {
                    try await withCard(fixture.item, store: store, style: style) { window in
                        try await waitUntil("\(kind) / library \(hasLibraryBackdrop) / \(style)") {
                            try self.coloredPixels(window)[1] > 500
                        }
                        XCTAssertEqual(try coloredPixels(window)[0], 0)
                    }
                }
            }
        }
    }

    func testChangingRecommendedToMetadataAndBackReplacesThePinnedArtwork() async throws {
        let fixture = try await makeArtwork(hasProviderBackdrop: false)
        let store = makeStore { _ in nil }
        for style in [CardStyle.borderless, .framed] {
            var appearance = 0
            try await withCard(
                fixture.item, store: store, style: style,
                settingsChanges: [.init(overrides: [.continueWatching: .online]), .default]
            ) { window in
                let expectedChannel = appearance == 1 ? 1 : 0
                try await waitUntil { try self.coloredPixels(window)[expectedChannel] > 500 }
                XCTAssertEqual(try coloredPixels(window)[1 - expectedChannel], 0)
                appearance += 1
            }
        }
    }

    func testUnresponsiveTextlessLookupFallsBackWithoutReplacingTheNativePoster() async throws {
        let fixture = try await makeArtwork()
        let gate = TextlessLookupGate()
        defer { Task { await gate.finish(nil) } }
        let store = makeStore { _ in await gate.lookup() }
        try await withCard(fixture.item, store: store, style: .borderless) { window in
            window.layoutIfNeeded()
            #if os(tvOS)
            let poster = try XCTUnwrap(nativePoster(in: window))
            #endif
            try await waitUntil { try self.coloredPixels(window)[0] > 500 }
            #if os(tvOS)
            XCTAssertTrue(nativePoster(in: window) === poster)
            #endif
        }
        await gate.finish(nil)
    }

    private func makeStore(
        resolve: (@Sendable (MediaItem) async -> URL?)? = nil
    ) -> TextlessBackdropStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("textless-hosted-\(UUID())")
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        return TextlessBackdropStore(store: TextlessBackdropIndex(directory: directory), resolveArtwork: resolve)
    }

    private func makeArtwork(
        kind: MediaItemKind = .episode, hasProviderBackdrop: Bool = true
    ) async throws -> (item: MediaItem, clean: URL) {
        let library = try await cacheImage(.red)
        let generic = try await cacheImage(.green)
        let clean = try await cacheImage(.blue)
        let id = UUID().uuidString
        let item = MediaItem(
            id: id, title: "Artwork fixture \(id)", kind: kind,
            parentTitle: "Series \(id)", seasonNumber: 1, episodeNumber: 2,
            seriesID: "series-\(id)", isPlayed: true,
            backdropURL: library, fallbackArtworkURL: library
        )
        let query = MetadataQuery(ArtworkRouter.seriesArtworkItem(for: item))
        for artworkKind in [ArtworkKind.hero, .poster, .thumbnail, .logo] {
            await MetadataDiskCache.shared.store(
                artworkKind == .logo || (artworkKind == .hero && !hasProviderBackdrop) ? nil : generic,
                for: ArtworkRouter.providerCacheKey(query: query, kind: artworkKind, source: .tmdb)
            )
        }
        return (item, clean)
    }

    private func cacheImage(_ color: UIColor?) async throws -> URL {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/textless-\(UUID()).png"))
        let data: Data
        if let color {
            data = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 90)).pngData {
                color.setFill()
                $0.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
            }
        } else {
            data = Data([0])
        }
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        let request = URLRequest(url: url)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
        ))
        cache.storeCachedResponse(CachedURLResponse(response: response, data: data), for: request)
        addTeardownBlock { cache.removeCachedResponse(for: request) }
        let image = await ArtworkImageCache.shared.image(for: url, variant: .landscapeCard)
        if color == nil {
            XCTAssertNil(image)
        } else {
            _ = try XCTUnwrap(image)
        }
        return url
    }

    private func withCard(
        _ item: MediaItem, store: TextlessBackdropStore, style: CardStyle,
        focus: CardFocusStyle = .system, settings: ArtworkSettings = .default,
        settingsChanges: [ArtworkSettings] = [],
        operation: (UIWindow) async throws -> Void
    ) async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 500, height: 500)
        let makeView = { (settings: ArtworkSettings) in
            PosterCardView(
                item: item, style: .landscape, showsSeriesArtwork: true,
                textlessBackdropStore: store, action: {}
            )
            .environment(\.plozzArtworkSettings, settings)
            .environment(\.plozzArtworkProviders, MetadataProviderSettingsStore().load())
            .environment(\.plozzCardStyle, style)
            .environment(\.plozzCardFocusStyle, focus)
            .environment(\.themePalette, .dark)
            .frame(width: 300)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
        }
        let host = UIHostingController(rootView: makeView(settings))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await operation(window)
        for changedSettings in settingsChanges {
            host.rootView = makeView(changedSettings)
            try await operation(window)
        }
    }

    private func coloredPixels(_ window: UIWindow) throws -> [Int] {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let cg = try XCTUnwrap(image.cgImage)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var counts = [0, 0, 0]
        for index in stride(from: 0, to: cg.width * cg.height * 4, by: 4) {
            for channel in 0..<3 where bytes[index + channel] > 60
                && (0..<3).filter({ $0 != channel }).allSatisfy({ bytes[index + $0] < 25 }) {
                counts[channel] += 1
            }
        }
        return counts
    }

    private func waitUntil(_ context: String = "", _ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(try condition(), "Continue Watching did not reach the expected artwork. \(context)")
    }

    #if os(tvOS)
    private func nativePoster(in view: UIView) -> TVPosterView? {
        (view as? TVPosterView) ?? view.subviews.lazy.compactMap { self.nativePoster(in: $0) }.first
    }
    #endif
}

private actor TextlessLookupGate {
    private(set) var requests = 0
    private var continuation: CheckedContinuation<URL?, Never>?

    func lookup() async -> URL? {
        requests += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish(_ url: URL?) {
        continuation?.resume(returning: url)
        continuation = nil
    }
}
