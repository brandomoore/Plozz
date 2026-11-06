import CoreModels
import SwiftUI
import UIKit
import Vision
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

    func testPlaybackDetailsAppliesToEveryContinueWatchingLayout() async throws {
        let art = try await cacheImage(.red, size: CGSize(width: 120, height: 180))
        let backdrop = try await cacheImage(.red)
        let item = MediaItem(
            id: UUID().uuidString, title: "Movie", kind: .movie,
            runtime: 3600, resumePosition: 900, posterURL: art, backdropURL: backdrop
        )
        for presentation in ContinueWatchingArtworkStyle.allCases {
            for style in [CardStyle.borderless, .framed] {
                for details in ContinueWatchingPlaybackDetails.allCases {
                    let width = PlozzMetrics.standard.cardSlotWidth(
                        for: presentation.layout.cardStyle, cardStyle: style,
                        showsSeriesArtwork: presentation.showsSeriesArtwork
                    )
                    try await withCard(
                        item, store: makeStore { _ in nil }, style: style,
                        settings: .init(preference: .library), shape: presentation.layout.cardStyle,
                        width: width,
                        showsSeriesArtwork: presentation.showsSeriesArtwork,
                        showsResumeChip: true, artworkArea: .continueWatching,
                        captions: .init(overrides: [.home: false, .continueWatching: false]),
                        playbackDetails: details
                    ) { window in
                        try await waitUntil { try self.coloredPixels(window)[0] > 10_000 }
                        let text = try recognizedText(
                            window, attachmentName: "Playback details \(presentation) \(style) \(details)"
                        )
                        XCTAssertEqual(text.contains { $0.contains("45m") }, details == .detailed,
                                       "\(presentation) / \(style) / \(details): \(text)")
                        if details == .progressOnly {
                            let pixels = try artworkPixels(window)
                            XCTAssertGreaterThan(pixels.lightRun, 42,
                                                 "The shared white bar must replace the playback chip.")
                            XCTAssertEqual(Double(pixels.barHeight), Double(PlozzMetrics.standard.resumeChipBarHeight),
                                           accuracy: 1, "Full-width progress must match Detailed, allowing native focus scaling.")
                        }
                    }
                }
            }
        }
    }

    func testProgressOnlyPreferenceDoesNotChangeOtherCards() async throws {
        let art = try await cacheImage(.red, size: CGSize(width: 120, height: 180))
        let backdrop = try await cacheImage(.red)
        let item = MediaItem(
            id: UUID().uuidString, title: "Movie", kind: .movie,
            runtime: 3600, resumePosition: 900, posterURL: art, backdropURL: backdrop
        )
        for style in [CardStyle.borderless, .framed] {
            try await withCard(
                item, store: makeStore { _ in nil }, style: style,
                settings: .init(preference: .library),
                width: PlozzMetrics.standard.cardSlotWidth(for: .landscape, cardStyle: style),
                showsSeriesArtwork: false,
                showsResumeChip: true, artworkArea: .recommended,
                captions: .init(overrides: [.recommended: false]), captionView: .recommended,
                playbackDetails: .progressOnly
            ) { window in
                try await waitUntil {
                    try self.recognizedText(window).contains { $0.contains("45m") }
                }
            }
        }
    }

    #if os(iOS)
    func testMobilePortraitKeepsLongEpisodeAndTimeTextComplete() async throws {
        let poster = try await cacheImage(.red, size: CGSize(width: 120, height: 180))
        let item = MediaItem(
            id: UUID().uuidString, title: "Episode", kind: .episode,
            seasonNumber: 12, episodeNumber: 123, runtime: 7200, resumePosition: 300,
            seriesPosterURL: poster
        )
        for (width, density, textSize) in [
            (CGFloat(86), UIDensity.micro, DynamicTypeSize.large),
            (132, .standard, .large),
            (180, .standard, .xxxLarge)
        ] {
            for style in [CardStyle.borderless, .framed] {
                try await withCard(
                    item, store: makeStore { _ in nil }, style: style,
                    settings: .init(preference: .library), shape: .poster, width: width,
                    metrics: .touch(density: density, dynamicTypeSize: textSize),
                    captions: .init(overrides: [.home: false, .continueWatching: false])
                ) { window in
                    try await waitUntil { try self.coloredPixels(window)[0] > 5_000 }
                    let lines = try recognizedText(
                        window, attachmentName: "Complete mobile portrait text \(width) \(style) \(textSize)"
                    )
                    let text = lines.joined().replacingOccurrences(of: " ", with: "")
                    XCTAssertTrue(text.contains("12") && text.contains("123"), "\(lines)")
                    XCTAssertTrue(text.contains("1h") && text.contains("55m"), "\(lines)")
                    XCTAssertFalse(text.contains("…") || text.contains("..."), "\(lines)")
                }
            }
        }
    }
    #endif

    func testPortraitDetailedKeepsTheLandscapeLegibilityScrim() async throws {
        let poster = try await cacheImage(.red, size: CGSize(width: 120, height: 180))
        let item = MediaItem(
            id: UUID().uuidString, title: "Scrim fixture", kind: .movie,
            runtime: 3600, resumePosition: 900, posterURL: poster
        )
        let width: CGFloat = 300
        try await withCard(
            item, store: makeStore { _ in nil }, style: .borderless,
            settings: .init(preference: .library), shape: .poster, width: width
        ) { window in
            try await waitUntil { try self.coloredPixels(window)[0] > 10_000 }
            #if os(tvOS)
            // Native focus enlarges the displayed image; sample its composited bitmap.
            let image = try XCTUnwrap(nativePoster(in: window)?.image)
            let column = try self.artworkPixels(image).centerRed
            let height = CGFloat(column.count)
            let top: CGFloat = 0
            #else
            let column = try self.artworkPixels(window).centerRed
            let artworkWidth = width - 2 * PlozzMetrics.standard.borderlessCardSideMargin
            let height = artworkWidth / ContinueWatchingPlaybackDetails.detailed.cardAspectRatio
            let top = (window.bounds.height - height) / 2
            #endif
            let original = Double(column[Int(top + height * 0.45)])
            XCTAssertGreaterThan(original, 200)
            for fraction: CGFloat in [0.72, 0.80, 0.86] {
                let position = (fraction - ContinueWatchingCardShape.scrimStart)
                    / (1 - ContinueWatchingCardShape.scrimStart)
                let expected = 1 - ContinueWatchingCardShape.scrimDepth
                    * ArtworkGradientRamp.eased(position, bias: 1)
                let actual = Double(column[Int(top + height * fraction)]) / original
                XCTAssertEqual(actual, Double(expected), accuracy: 0.04,
                               "The landscape scrim must darken the picture above the reflection at \(fraction).")
            }
            _ = try recognizedText(window, attachmentName: "Portrait with landscape Detailed scrim")
        }
    }

    func testPortraitKeepsPosterAndResumeChromeWithoutTextlessLookup() async throws {
        for kind in [MediaItemKind.episode, .movie] {
            let poster = try await cacheImage(.red, size: CGSize(width: 120, height: 180), footer: true)
            let still = try await cacheImage(.green)
            let backdrop = try await cacheImage(.blue)
            let item = MediaItem(
                id: UUID().uuidString, title: "Portrait fixture", kind: kind,
                parentTitle: kind == .episode ? "Series fixture" : nil,
                seasonNumber: 1, episodeNumber: 2, runtime: 3600, resumePosition: 900,
                posterURL: kind == .episode ? still : poster,
                seriesPosterURL: kind == .episode ? poster : nil,
                backdropURL: backdrop, fallbackArtworkURL: backdrop
            )
            let gate = TextlessLookupGate()
            defer { Task { await gate.finish(nil) } }
            let store = makeStore { _ in await gate.lookup() }
            let settings = ArtworkSettings(preference: .library)
            let source = ContinueWatchingArtworkSource(
                item: item, style: .poster, policy: .init(area: .continueWatching, settings: settings)
            )
            await source.prepare(store: store)
            let key = ArtworkResolveKey.make(
                references: source.references(textlessBackdrop: nil), variant: .posterCard,
                maxAspectRatio: source.aspectGuard, pinIdentity: source.pinIdentity,
                providerPolicyIdentity: source.policy.identity
            )
            XCTAssertEqual(ArtworkSeedMemo.prepared(for: key, variant: .posterCard)?.reference, .remote(poster))
            #if os(tvOS)
            let width: CGFloat = 300
            let metrics = PlozzMetrics.standard
            #else
            let width: CGFloat = 132
            let metrics = PlozzMetrics.touch(density: .standard)
            #endif
            let presentations = ContinueWatchingPlaybackDetails.allCases.flatMap { details in
                [CardStyle.borderless, .framed].map { ($0, details) }
            }
            for (style, details) in presentations {
                try await withCard(
                    item, store: store, style: style, settings: settings,
                    shape: .poster, width: width, metrics: metrics, playbackDetails: details
                ) { window in
                    try await waitUntil { try self.coloredPixels(window)[0] > 10_000 }
                    let counts = try coloredPixels(window)
                    XCTAssertEqual(counts[1], 0, "Portrait must not show the episode still.")
                    XCTAssertEqual(counts[2], 0, "Portrait must not crop a landscape backdrop.")
                    #if os(tvOS)
                    if style == .borderless {
                        let native = try XCTUnwrap(nativePoster(in: window))
                        XCTAssertEqual(native.bounds.height / native.bounds.width,
                                       1.5, accuracy: 0.02, "Both treatments must match a normal poster.")
                    }
                    #endif
                    let text = try recognizedText(window)
                    if details == .detailed {
                        XCTAssertTrue(text.contains { $0.contains("POSTER") },
                                      "The original poster footer must remain readable above playback details: \(text)")
                    }
                    XCTAssertEqual(text.contains { $0.contains("45m") }, details == .detailed,
                                   "Only Detailed should show playback text on the poster: \(text)")
                    if details == .progressOnly {
                        try await waitUntil("Progress only must render the shared white progress bar.") {
                            try self.artworkPixels(window).lightRun > Int(width * 0.14)
                        }
                    }
                    let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    })
                    attachment.name = "Continue Watching portrait \(kind) \(style) \(details)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
            let requests = await gate.requests
            XCTAssertEqual(requests, 0)
        }
    }

    func testCaptionOverrideControlsEveryContinueWatchingStyleInBothParentViews() async throws {
        let poster = try await cacheImage(.red, size: CGSize(width: 120, height: 180))
        let backdrop = try await cacheImage(.red)
        let logo = try await cacheImage(.blue, size: CGSize(width: 160, height: 50))
        let item = MediaItem(
            id: UUID().uuidString, title: "Caption marker", kind: .episode,
            parentTitle: "Caption marker", seasonNumber: 1, episodeNumber: 2,
            runtime: 3600, resumePosition: 900, posterURL: backdrop, seriesPosterURL: poster,
            backdropURL: backdrop, logoURL: logo
        )
        let store = makeStore { _ in nil }
        #if os(tvOS)
        let metrics = PlozzMetrics.standard
        #else
        let metrics = PlozzMetrics.touch(density: .standard)
        #endif
        for parent in [CardCaptionView.home, .recommended] {
            for choice in CardCaptionView.continueWatching.customizationChoices {
                var captions = CardCaptionSettings(overrides: [.home: true, .recommended: false])
                captions.setOverride(choice, for: .continueWatching)
                let presentations = ContinueWatchingPlaybackDetails.allCases.flatMap { details in
                    [CardStyle.borderless, .framed].map { ($0, details) }
                }
                for (style, details) in presentations {
                    for artwork in ContinueWatchingArtworkStyle.allCases {
                        let width = metrics.cardSlotWidth(
                            for: artwork.layout.cardStyle, cardStyle: style,
                            showsSeriesArtwork: artwork.showsSeriesArtwork
                        )
                        try await withCard(
                            item, store: store, style: style, settings: .init(preference: .library),
                            shape: artwork.layout.cardStyle, width: width, metrics: metrics,
                            showsSeriesArtwork: artwork.showsSeriesArtwork,
                            showsResumeChip: true, artworkArea: .continueWatching,
                            captions: captions, captionView: parent, playbackDetails: details
                        ) { window in
                            try await waitUntil { try self.coloredPixels(window)[0] > 10_000 }
                            let text = try recognizedText(
                                window, attachmentName: "Captions \(artwork) \(parent) \(choice) \(style) \(details)"
                            )
                            let visible = text.contains { $0.localizedCaseInsensitiveContains("Caption marker") }
                            XCTAssertEqual(visible, choice == .automatic ? parent == .home : choice == .show,
                                           "\(artwork) / \(parent) / \(choice) / \(style): \(text)")
                        }
                    }
                }
            }
        }
    }

    func testChangingPortraitDetailsUpdatesTheMountedCard() async throws {
        let poster = try await cacheImage(.red, size: CGSize(width: 120, height: 180), footer: true)
        let item = MediaItem(
            id: UUID().uuidString, title: "Episode", kind: .episode, parentTitle: "Series",
            seasonNumber: 1, episodeNumber: 2, runtime: 3600, resumePosition: 900, seriesPosterURL: poster
        )
        let modes: [ContinueWatchingPlaybackDetails] = [.detailed, .progressOnly, .detailed]
        var step = 0
        #if os(tvOS)
        var owner: NativePosterButton?
        #endif
        try await withCard(
            item, store: makeStore { _ in nil }, style: .borderless,
            settings: .init(preference: .library), shape: .poster,
            detailsChanges: Array(modes.dropFirst())
        ) { window in
            try await waitUntil("details step \(step): \(modes[step])", timeout: .seconds(20)) {
                let text = try self.recognizedText(window)
                if modes[step] == .detailed {
                    return text.contains { $0.contains("POSTER") } && text.contains { $0.contains("45m") }
                }
                // The ordinary bar intentionally overlays the poster's bottom edge.
                return try !text.contains { $0.contains("45m") }
                    && self.artworkPixels(window).lightRun > 42
                    && self.coloredPixels(window)[0] > 10_000
            }
            _ = try recognizedText(window, attachmentName: "continue-watching-details-step-\(step)")
            #if os(tvOS)
            let current = try XCTUnwrap(nativePoster(in: window))
            if let owner { XCTAssertTrue(current === owner, "Changing details must not replace the native focus owner.") }
            owner = current
            XCTAssertEqual(current.bounds.height / current.bounds.width, 1 / modes[step].cardAspectRatio, accuracy: 0.02)
            #endif
            step += 1
        }
        XCTAssertEqual(step, modes.count)
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
            let expected = preference == .library ? 0 : 2
            let firstPaint = try XCTUnwrap(renderer.uiImage)
            XCTAssertGreaterThan(try artworkPixels(firstPaint).colors[expected], 500,
                                 "The resolver must paint the prepared winner without an asynchronous image load.")
            for cardStyle in [CardStyle.borderless, .framed] {
                try await withCard(fixture.item, store: store, style: cardStyle, settings: policy.settings) { window in
                    #if os(tvOS)
                    if cardStyle == .borderless {
                        // Native artwork composition is asynchronous even when its source bitmap is prepared.
                        try await waitUntil {
                            guard let image = self.nativePoster(in: window)?.image else { return false }
                            return try self.artworkPixels(image).colors[expected] > 500
                        }
                    }
                    #endif
                    XCTAssertGreaterThan(
                        try coloredPixels(window)[expected], 500,
                        "Prepared card winner: \(preference) / \(cardStyle)"
                    )
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
        let index = TextlessBackdropIndex(directory: directory)
        addTeardownBlock { @MainActor in
            try await index.flushForTesting()
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        return TextlessBackdropStore(store: index, resolveArtwork: resolve)
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

    private func cacheImage(
        _ color: UIColor?, size: CGSize = CGSize(width: 160, height: 90), footer: Bool = false
    ) async throws -> URL {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/textless-\(UUID()).png"))
        let data: Data
        if let color {
            data = UIGraphicsImageRenderer(size: size).pngData {
                color.setFill()
                $0.fill(CGRect(origin: .zero, size: size))
                if footer {
                    ("POSTER" as NSString).draw(
                        in: CGRect(x: 8, y: size.height - 20, width: size.width - 16, height: 18),
                        withAttributes: [.font: UIFont.boldSystemFont(ofSize: 12), .foregroundColor: UIColor.white]
                    )
                }
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
        shape: PosterCardView.Style = .landscape,
        width: CGFloat = 300,
        metrics: PlozzMetrics = .standard,
        showsSeriesArtwork: Bool = true,
        showsResumeChip: Bool? = nil,
        artworkArea: ArtworkArea? = nil,
        captions: CardCaptionSettings = .default,
        captionView: CardCaptionView = .home,
        playbackDetails: ContinueWatchingPlaybackDetails = .default,
        detailsChanges: [ContinueWatchingPlaybackDetails] = [],
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
        window.frame = CGRect(x: 0, y: 0, width: max(500, width + 200), height: shape == .poster ? 800 : 500)
        window.overrideUserInterfaceStyle = .dark
        let makeView = { (settings: ArtworkSettings, details: ContinueWatchingPlaybackDetails) in
            PosterCardView(
                item: item, style: shape, showsSeriesArtwork: showsSeriesArtwork,
                showsResumeChip: showsResumeChip ?? (shape == .poster),
                textlessBackdropStore: store, action: {}
            )
            .environment(\.plozzArtworkSettings, settings)
            .environment(\.plozzArtworkArea, artworkArea)
            .environment(\.plozzMetrics, metrics)
            .environment(\.plozzArtworkProviders, MetadataProviderSettingsStore().load())
            .environment(\.plozzCardStyle, style)
            .environment(\.plozzCardFocusStyle, focus)
            .environment(\.plozzCardCaptionView, captionView)
            .environment(\.plozzCardCaptionSettings, captions)
            .environment(\.plozzContinueWatchingPlaybackDetails, details)
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
            .frame(width: width)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
        }
        let host = UIHostingController(rootView: makeView(settings, playbackDetails))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await operation(window)
        for changedSettings in settingsChanges {
            host.rootView = makeView(changedSettings, playbackDetails)
            try await operation(window)
        }
        for changedDetails in detailsChanges {
            host.rootView = makeView(settings, changedDetails)
            try await operation(window)
        }
    }

    private func recognizedText(_ window: UIWindow, attachmentName: String? = nil) throws -> [String] {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        if let attachmentName {
            let attachment = XCTAttachment(image: image)
            attachment.name = attachmentName
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    private func coloredPixels(_ window: UIWindow) throws -> [Int] {
        try artworkPixels(window).colors
    }

    private func artworkPixels(_ window: UIWindow) throws -> (colors: [Int], lightRun: Int, barHeight: Int, centerRed: [UInt8]) {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return try artworkPixels(image)
    }

    private func artworkPixels(_ image: UIImage) throws -> (colors: [Int], lightRun: Int, barHeight: Int, centerRed: [UInt8]) {
        let cg = try XCTUnwrap(image.cgImage)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var counts = [0, 0, 0]
        var lightRun = 0
        var longestLightRun = 0
        var longestRowRun = 0
        var barHeight = 0
        for index in stride(from: 0, to: cg.width * cg.height * 4, by: 4) {
            if index % (cg.width * 4) == 0 {
                if longestRowRun > 42 { barHeight += 1 }
                lightRun = 0
                longestRowRun = 0
            }
            if (0..<3).allSatisfy({ bytes[index + $0] > 150 }) {
                lightRun += 1
                longestLightRun = max(longestLightRun, lightRun)
                longestRowRun = max(longestRowRun, lightRun)
            } else {
                lightRun = 0
            }
            for channel in 0..<3 where bytes[index + channel] > 60
                && (0..<3).filter({ $0 != channel }).allSatisfy({ bytes[index + $0] < 25 }) {
                counts[channel] += 1
            }
        }
        if longestRowRun > 42 { barHeight += 1 }
        let centerRed = (0..<cg.height).map { bytes[($0 * cg.width + cg.width / 2) * 4] }
        return (counts, longestLightRun, barHeight, centerRed)
    }

    private func waitUntil(
        _ context: String = "", timeout: Duration = .seconds(5), _ condition: () throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while try !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(try condition(), "Continue Watching did not reach the expected artwork. \(context)")
    }

    #if os(tvOS)
    private func nativePoster(in view: UIView) -> NativePosterButton? {
        (view as? NativePosterButton) ?? view.subviews.lazy.compactMap { self.nativePoster(in: $0) }.first
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
