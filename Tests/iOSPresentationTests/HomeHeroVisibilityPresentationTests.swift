#if os(iOS)
import CoreModels
import CoreUI
import FeatureHomeCore
@testable import MetadataKit
import Observation
import SwiftUI
import Synchronization
import UIKit
import Vision
import XCTest
@testable import AppShelliOS

@MainActor
final class HomeHeroVisibilityPresentationTests: XCTestCase {
    func testCompactDetailBadgesStayCloseToSynopsisAndActions() async throws {
        let app = PlozziOSAppModel()
        let original = app.profiles.activeProfileID
        let profile = app.profiles.add(name: "Detail spacing fixture", isAwaitingSetup: false)
        app.selectProfile(profile.id)
        defer {
            app.selectProfile(original)
            app.profiles.remove(profile.id)
        }
        let item = MediaItem(
            id: "spacing-fixture", title: "SIGNAL", kind: .movie,
            overview: "Across the stars.", officialRating: "PG", genres: ["Documentary"],
            allowsTitleBasedMetadataMatching: false,
            mediaInfo: .init(
                video: .init(width: 3840, height: 2160, videoRangeType: "DOVIWithHDR10"),
                audio: .init(codec: "eac3", channels: 6)
            )
        )
        let presentation = HeroPresentation(item: item, artworkStyle: .compactPortrait, surface: .detail)
        let foreground = PlozziOSDetailHeroForeground(
            item: item, rootItem: item, playableItem: item,
            sources: [], selectedSourceAccountID: nil, versions: [], selectedVersionID: nil,
            onSelectSource: { _ in }, onSelectVersion: { _ in },
            presentation: presentation, fallbackPresentation: presentation,
            style: .compactPortrait, actionHandler: SizingActions(), onPlay: { _, _ in }
        )
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(app)
        for colorScheme in [ColorScheme.dark, .light] {
            try await withWindow(
                foreground.background(colorScheme == .dark ? Color.black : Color.white),
                sizeClass: .compact, colorScheme: colorScheme
            ) { window in
                try await self.settle(window)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "compact-detail-badge-spacing-\(colorScheme)"
                attachment.lifetime = .keepAlways
                self.add(attachment)
                let frames = try HeroTextInk.frames(
                    in: image, terms: ["Across the stars", "HDR10", "Play"],
                    darkTerms: colorScheme == .dark ? ["Play"] : ["Across the stars", "HDR10"]
                )
                let synopsis = try XCTUnwrap(frames["Across the stars"])
                let badge = try XCTUnwrap(frames["HDR10"])
                let play = try XCTUnwrap(frames["Play"])
                let upperGap = badge.minY - synopsis.maxY
                let lowerGap = play.minY - badge.maxY
                XCTAssertGreaterThan(upperGap, 20, "Keep breathing room above the badges.")
                XCTAssertLessThanOrEqual(upperGap, 28, "Use 8-point padding, not a button-height slot.")
                XCTAssertGreaterThan(lowerGap, 36, "Keep breathing room below the badges.")
                XCTAssertLessThanOrEqual(lowerGap, 44, "Use 8-point padding without an extra action-row gap.")
                XCTAssertEqual(lowerGap - 14, upperGap, accuracy: 10,
                               "Allow for Play's native label inset, then keep the visible gaps balanced.")
            }
        }
    }

    func testSeriesDetailsKeepSeriesMetadataAcrossEntryRoutesAndSizeClasses() async throws {
        let app = PlozziOSAppModel()
        let original = app.profiles.activeProfileID
        let profile = app.profiles.add(name: "Series header fixture", isAwaitingSetup: false)
        app.selectProfile(profile.id)
        app.settings.heroBackground.settings.detailMode = .off
        app.settings.spoilers.settings = .default
        defer {
            app.selectProfile(original)
            app.profiles.remove(profile.id)
        }
        let provider = SeriesHeaderMobileProvider()
        for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
            for item in [provider.show, provider.season, provider.episode] {
                let content = NavigationStack {
                    PlozziOSItemDetailView(appModel: app, provider: provider, item: item)
                }
                .environment(app)
                .environment(HeroTrailerController())
                .environment(PlozziOSSidebarGeometryModel())
                try await withWindow(content, sizeClass: sizeClass) { window in
                    let deadline = ContinuousClock.now.advanced(by: .seconds(12))
                    var text = ""
                    repeat {
                        try await self.settle(window)
                        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                        }
                        let request = VNRecognizeTextRequest()
                        request.recognitionLanguages = ["en-US"]
                        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
                        text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                        if text.contains("quiet village") && text.contains("8.7") { break }
                    } while ContinuousClock.now < deadline
                    XCTAssertTrue(text.contains("quiet village"), "\(sizeClass), \(item.kind): \(text)")
                    XCTAssertTrue(text.contains("8.7"), "\(sizeClass), \(item.kind): \(text)")
                    XCTAssertFalse(text.contains("2.3"), "Episode ratings must not replace the series ratings: \(text)")
                }
            }
        }
    }

    func testHomeLogoWidthExpandsTheReadingColumnWithinTheViewport() async throws {
        let app = PlozziOSAppModel()
        let original = app.profiles.activeProfileID
        let profile = app.profiles.add(name: "Hero width fixture", isAwaitingSetup: false)
        app.selectProfile(profile.id)
        defer {
            app.selectProfile(original)
            app.profiles.remove(profile.id)
        }

        let item = MediaItem(
            id: "width-fixture", title: "Across the stars", kind: .movie,
            overview: String(repeating: "An expedition beyond the stars. ", count: 20),
            allowsTitleBasedMetadataMatching: false
        )
        for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
            let style: HeroArtworkStyle = sizeClass == .compact ? .compactPortrait : .landscape
            let content = HomeWidthFixture(item: item, style: style).environment(app)
            try await withWindow(content, sizeClass: sizeClass) { window in
                var widths: [Int: CGFloat] = [:]
                for size in [-10, 0, 10] {
                    app.settings.hero.settings.logoSize = .init(rawValue: size)
                    for text in [0, 5] {
                        app.settings.hero.settings.textSize = .init(rawValue: text)
                        try await self.settle(window)
                        let probe = try XCTUnwrap(self.find("reading-column", in: window))
                        let frame = probe.convert(probe.bounds, to: window)
                        XCTAssertGreaterThanOrEqual(frame.minX, 0)
                        XCTAssertLessThanOrEqual(frame.maxX, window.bounds.width)
                        if let width = widths[size] {
                            XCTAssertEqual(frame.width, width, accuracy: 1, "Text size alone must not widen the column.")
                        } else {
                            widths[size] = frame.width
                        }
                    }
                }
                XCTAssertEqual(try XCTUnwrap(widths[-10]), try XCTUnwrap(widths[0]), accuracy: 1)
                if sizeClass == .regular {
                    XCTAssertEqual(try XCTUnwrap(widths[0]), 480, accuracy: 1)
                    XCTAssertEqual(try XCTUnwrap(widths[10]), 720, accuracy: 1)
                } else {
                    XCTAssertEqual(try XCTUnwrap(widths[10]), try XCTUnwrap(widths[0]), accuracy: 1)
                }
            }
        }
    }

    func testDetailActionsPreservePlaybackAndStandaloneSubjects() async throws {
        let app = PlozziOSAppModel()
        let provider = SeriesHeaderMobileProvider()
        var playable = provider.episode
        playable.id = "alternate-playback-copy"
        let movie = MediaItem(id: "movie", title: "Movie", kind: .movie)
        for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
            for item in [provider.show, provider.episode, movie] {
                let actions = RecordingSeriesActions()
                let content = PlozziOSDetailHeroSection(
                    item: item, backdropItem: item, playableItem: playable,
                    sources: [], selectedSourceAccountID: nil, versions: [], selectedVersionID: nil,
                    onSelectSource: { _ in }, onSelectVersion: { _ in },
                    actionHandler: actions, onPlay: { _, _ in }
                )
                .environment(app)
                .environment(HeroTrailerController())
                .environment(PlozziOSSidebarGeometryModel())
                try await withWindow(content, sizeClass: sizeClass) { window in
                    try await self.settle(window)
                    XCTAssertEqual(actions.requestedSubjects.first?.id, item.kind == .series ? playable.id : item.id)
                    XCTAssertTrue(actions.requestedSubjects.contains(where: { $0.id == item.id }))
                }
            }
        }
    }

    private final class RecordingSeriesActions: MediaItemActionHandling {
        var requestedSubjects: [MediaItem] = []
        func actions(for item: MediaItem, context: MediaItemActionContext) -> [MediaItemAction] {
            requestedSubjects.append(item)
            return item.kind == .episode ? [.markWatched] : [.addToWatchlist]
        }

        func perform(_ action: MediaItemAction, on item: MediaItem, context: MediaItemActionContext) {}
    }

    func testHomeAndDetailTextSizingChangesMetadataAndDescriptionButNotActionText() async throws {
        let app = PlozziOSAppModel()
        let original = app.profiles.activeProfileID
        let profile = app.profiles.add(name: "Text sizing fixture", isAwaitingSetup: false)
        app.selectProfile(profile.id)
        defer {
            app.selectProfile(original)
            app.profiles.remove(profile.id)
        }
        let item = MediaItem(
            id: "text-sizing-fixture", title: "SIGNAL", kind: .movie,
            overview: "Across the stars.", officialRating: "PG", genres: ["Documentary"],
            allowsTitleBasedMetadataMatching: false
        )
        for detail in [false, true] {
            for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
                let style: HeroArtworkStyle = sizeClass == .compact ? .compactPortrait : .landscape
                app.settings.hero.settings.textSize = .default
                app.settings.detailPage.settings.textSize = .default
                let foreground = Group {
                    if detail {
                        PlozziOSDetailHeroSection(
                            item: item, backdropItem: item, playableItem: item,
                            sources: [], selectedSourceAccountID: nil, versions: [], selectedVersionID: nil,
                            onSelectSource: { _ in }, onSelectVersion: { _ in },
                            actionHandler: SizingActions(), onPlay: { _, _ in }
                        )
                        .environment(HeroTrailerController())
                    } else {
                        PlozziOSHomeHeroForeground(
                            item: item, detailItem: item, watchlistItem: item,
                            presentation: HeroPresentation(item: item, artworkStyle: style, surface: .home),
                            style: style, onPlay: { _ in }
                        )
                        .padding(24)
                    }
                }
                .environment(app)
                .environment(PlozziOSSidebarGeometryModel())
                try await withWindow(foreground, sizeClass: sizeClass) { window in
                    var baseline: [String: CGFloat] = [:]
                    for step in [0, -5, 5] {
                        app.settings.hero.settings.textSize = HeroTextSize(rawValue: step)
                        app.settings.detailPage.settings.textSize = HeroTextSize(rawValue: step)
                        try await self.settle(window)
                        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                        }
                        let attachment = XCTAttachment(image: image)
                        attachment.name = "mobile-\(detail ? "detail" : "home")-text-\(sizeClass)-\(step)"
                        attachment.lifetime = .keepAlways
                        self.add(attachment)
                        let frames = try HeroTextInk.frames(
                            in: image, terms: ["SIGNAL", "Documentary", "Across the stars", "Play"], darkTerms: ["Play"]
                        )
                        for text in ["SIGNAL", "Documentary", "Across the stars", "Play"] {
                            let height = try XCTUnwrap(frames[text], "Missing \(text), \(sizeClass), step \(step)").height
                            if step == 0 { baseline[text] = height }
                            let scale = text == "Play" ? 1 : app.settings.hero.settings.textSize.scale
                            XCTAssertEqual(
                                height, try XCTUnwrap(baseline[text]) * scale, accuracy: 2, "\(text), \(step)")
                        }
                    }
                }
            }
        }
    }

    private final class SizingActions: MediaItemActionHandling {
        func actions(for item: MediaItem, context: MediaItemActionContext) -> [MediaItemAction] { [] }
        func perform(_ action: MediaItemAction, on item: MediaItem, context: MediaItemActionContext) {}
    }

    func testActualHomeRemovesCompletedEmptyHeroWithoutChangingItsSettings() async throws {
        let app = PlozziOSAppModel()
        let original = app.profiles.activeProfileID
        let profile = app.profiles.add(name: "Empty Hero fixture", isAwaitingSetup: false)
        app.selectProfile(profile.id)
        defer {
            app.selectProfile(original)
            app.profiles.remove(profile.id)
        }
        let provider = EmptyHeroHomeProvider()
        let model = HomeViewModel(
            accounts: [ResolvedAccount(account: provider.account, provider: provider)],
            layoutStore: InMemoryHomeLayoutStore(),
            currentVisibility: { app.settings.homeVisibility.visibility }
        )
        await model.load()
        XCTAssertNotNil(model.state.value)
        app.settings.hero.settings.sources = [.collection]
        app.settings.hero.settings.collections = []
        app.settings.hero.settings.isEnabled = false
        for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
            let home = NavigationStack {
                PlozziOSHomeView(appModel: app, viewModel: model, onAddServer: {}, onShowSettings: {})
            }
            .environment(app)
            .environment(HeroTrailerController())
            try await withWindow(home, sizeClass: sizeClass) { window in
                let scroll = try XCTUnwrap(self.scrollViews(in: window).first)
                let rowsHeight = scroll.contentSize.height
                let rowsInset = scroll.adjustedContentInset.top
                app.settings.hero.settings.isEnabled = true
                try await self.settle(window)
                try await Task.sleep(for: .milliseconds(500))
                window.layoutIfNeeded()
                XCTAssertEqual(scroll.contentSize.height, rowsHeight, accuracy: 1,
                               "An empty curation must remove the Hero and its reserved height.")
                XCTAssertEqual(scroll.adjustedContentInset.top, rowsInset, accuracy: 1)
                XCTAssertTrue(app.settings.hero.settings.isEnabled)
                XCTAssertEqual(app.settings.hero.settings.sources, [.collection])

                app.settings.hero.settings.collections = [
                    HeroCollectionSelection(
                        accountID: "unavailable-account", libraryID: "movies",
                        collectionID: "missing-collection", title: "Unavailable collection"
                    )
                ]
                try await self.settle(window)
                try await Task.sleep(for: .milliseconds(500))
                window.layoutIfNeeded()
                XCTAssertEqual(scroll.contentSize.height, rowsHeight, accuracy: 1,
                               "An unavailable saved collection must also finish without a placeholder.")
                XCTAssertEqual(app.settings.hero.settings.collections.count, 1,
                               "Presentation must not erase saved collection choices.")
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "empty-hero-\(sizeClass)"
                attachment.lifetime = .keepAlways
                self.add(attachment)
                app.settings.hero.settings.isEnabled = false
                app.settings.hero.settings.collections = []
            }
        }
    }

    func testPortraitAndLandscapeFirstPaintIdentitiesCannotReuseEachOthersPinnedArtwork() {
        let identity = "home:movie"
        XCTAssertEqual(PlozziOSHeroArtworkFallback.cacheIdentity(identity, style: .landscape), identity)
        XCTAssertNotEqual(
            PlozziOSHeroArtworkFallback.cacheIdentity(identity, style: .compactPortrait),
            PlozziOSHeroArtworkFallback.cacheIdentity(identity, style: .landscape)
        )
        XCTAssertEqual(PlozziOSHeroArtworkFallback.cacheIdentity(identity, style: .compactPortrait),
                       "\(identity)|portrait-hero-v1")
    }

    func testOnlyCompactHeroesRequestThePortraitSelectionRegardlessOfLogoTiming() async throws {
        let portrait = try XCTUnwrap(URL(string: "https://metadata.example.test/clean-portrait.jpg"))
        let landscape = try XCTUnwrap(URL(string: "https://metadata.example.test/clean-landscape.jpg"))
        let cache = MetadataDiskCache(directory: nil)
        let router = heroArtworkRouter(settings: HeroArtworkProviderSettings(), cache: cache)
        var item = MediaItem(id: "movie", title: "Movie", kind: .movie, providerIDs: ["Tmdb": "42"])
        for (prefersPortrait, artwork) in [(true, portrait), (false, landscape)] {
            await cache.store(artwork, for: ArtworkRouter.providerCacheKey(
                query: MetadataQuery(item), kind: .hero, source: .tmdb, prefersPortraitHero: prefersPortrait
            ))
        }
        for hasLogo in [false, true] {
            item.logoURL = hasLogo ? URL(string: "https://library.example.test/logo.png") : nil
            for surfaceRole in [HeroTrailerSurfaceRole.home, .detail] {
                for style in [HeroArtworkStyle.compactPortrait, .landscape] {
                    let resolved = await PlozziOSHeroArtworkFallback.resolve(
                        for: item, style: style, surfaceRole: surfaceRole, router: router
                    )
                    XCTAssertEqual(resolved, style == .compactPortrait ? portrait : landscape)
                }
            }
        }
    }

    func testExternalHeroFallbackPlacementsMatchTheLibraryArtworkLadder() throws {
        let poster = try XCTUnwrap(URL(string: "https://library.example.test/poster.jpg"))
        let backdrop = try XCTUnwrap(URL(string: "https://library.example.test/backdrop.jpg"))
        let logo = try XCTUnwrap(URL(string: "https://library.example.test/logo.png"))
        for surfaceRole in [HeroTrailerSurfaceRole.home, .detail] {
            for style in [HeroArtworkStyle.compactPortrait, .landscape] {
                for hasLogo in [false, true] {
                    let item = MediaItem(
                        id: "hero-ladder", title: "Movie", kind: .movie,
                        posterURL: poster, backdropURL: backdrop, logoURL: hasLogo ? logo : nil
                    )
                    let presentation = HeroPresentation(
                        item: item, artworkStyle: style, surface: surfaceRole == .home ? .home : .detail
                    )
                    let placements = PlozziOSHeroArtworkFallback.placements(
                        surfaceRole: surfaceRole
                    )
                    let backdropPlacement: ArtworkPlacement = surfaceRole == .home ? .homeHero : .detailBackdrop
                    XCTAssertEqual(
                        placements, [backdropPlacement, .poster]
                    )
                    XCTAssertEqual(
                        presentation.artworkReferences,
                        placements.flatMap { item.artworkReferences(for: $0) }
                    )
                    XCTAssertFalse(placements.contains(.episodeThumbnail))
                }
            }
        }
    }

    func testExternalPosterOnlyHeroesRemainAvailableUntilTheirProviderIsDisabled() async throws {
        let poster = try XCTUnwrap(URL(string: "https://metadata.example.test/poster-only.jpg"))
        let settings = HeroArtworkProviderSettings()
        let router = heroArtworkRouter(settings: settings)
        for surfaceRole in [HeroTrailerSurfaceRole.home, .detail] {
            for style in [HeroArtworkStyle.compactPortrait, .landscape] {
                var item = MediaItem(
                    id: "poster-only", title: "Poster Only", kind: .movie, posterURL: poster
                )
                item.metadataProvenance[.posterURL] = MetadataAttribution(source: .tmdb)
                let presentation = HeroPresentation(
                    item: item, artworkStyle: style, surface: surfaceRole == .home ? .home : .detail
                )
                XCTAssertTrue(presentation.artworkReferences.isEmpty, "External art must not bypass the router.")
                settings.save(.init(orderMode: .custom, enabledOrder: ["tmdb"]))
                let resolved = await PlozziOSHeroArtworkFallback.resolve(
                    for: item, style: style, surfaceRole: surfaceRole, router: router
                )
                XCTAssertEqual(resolved, poster)
                settings.save(.init(orderMode: .custom, disabledOrder: ["tmdb"]))
                let disabled = await PlozziOSHeroArtworkFallback.resolve(
                    for: item, style: style, surfaceRole: surfaceRole, router: router
                )
                XCTAssertNil(disabled, "Do not restore disabled-provider posters through a raw URL fallback.")
            }
        }
    }

    func testExternalHeroFallbackIsIndependentOfWhetherTheLogoHasResolved() async throws {
        let poster = try XCTUnwrap(URL(string: "https://metadata.example.test/poster.jpg"))
        let backdrop = try XCTUnwrap(URL(string: "https://metadata.example.test/backdrop.jpg"))
        let logo = try XCTUnwrap(URL(string: "https://library.example.test/logo.png"))
        let router = heroArtworkRouter(settings: HeroArtworkProviderSettings())
        for surfaceRole in [HeroTrailerSurfaceRole.home, .detail] {
            for style in [HeroArtworkStyle.compactPortrait, .landscape] {
                for hasLogo in [false, true] {
                    var item = MediaItem(
                        id: "both-placements", title: "Movie", kind: .movie,
                        posterURL: poster, backdropURL: backdrop, logoURL: hasLogo ? logo : nil
                    )
                    item.metadataProvenance[.posterURL] = MetadataAttribution(source: .tmdb)
                    item.metadataProvenance[.backdropURL] = MetadataAttribution(source: .tmdb)
                    let presentation = HeroPresentation(
                        item: item, artworkStyle: style, surface: surfaceRole == .home ? .home : .detail
                    )
                    XCTAssertTrue(presentation.artworkReferences.isEmpty)
                    let resolved = await PlozziOSHeroArtworkFallback.resolve(
                        for: item, style: style, surfaceRole: surfaceRole, router: router
                    )
                    XCTAssertEqual(resolved, backdrop)
                }
            }
        }
    }

    func testExternalHeroPosterFallbackDoesNotUseAnEpisodesCachedStill() async throws {
        let still = try XCTUnwrap(URL(string: "https://metadata.example.test/episode-still.jpg"))
        var item = MediaItem(id: "episode", title: "Episode", kind: .episode, posterURL: still)
        item.parentTitle = "Show"
        item.seriesID = "show"
        item.metadataProvenance[.posterURL] = MetadataAttribution(source: .tmdb)
        let router = heroArtworkRouter(settings: HeroArtworkProviderSettings())
        for surfaceRole in [HeroTrailerSurfaceRole.home, .detail] {
            for style in [HeroArtworkStyle.compactPortrait, .landscape] {
                let resolved = await PlozziOSHeroArtworkFallback.resolve(
                    for: item, style: style, surfaceRole: surfaceRole, router: router
                )
                XCTAssertNil(resolved, "A show-level hero fallback must never reinterpret an episode still as a poster.")
            }
        }
    }

    private func heroArtworkRouter(
        settings: HeroArtworkProviderSettings, cache: MetadataDiskCache = MetadataDiskCache(directory: nil)
    ) -> ArtworkRouter {
        ArtworkRouter(
            config: .init(tmdb: .disabled),
            cache: cache,
            enrichmentBaseline: .init(order: [.tmdb], priority: .init(rules: [])),
            settingsStore: settings
        )
    }

    func testHeroSettingRemovesPlaceholderAndContentWithoutLeavingSpace() async throws {
        for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
            for showsContent in [false, true] {
                let model = HeroFixtureModel()
                let style: HeroArtworkStyle = sizeClass == .compact ? .compactPortrait : .landscape
                let fixture = HeroFixture(model: model, style: style, showsContent: showsContent)
                try await withWindow(fixture, sizeClass: sizeClass) { window in
                    try self.assertHeroVisible(in: window)

                    model.settings.isEnabled = false
                    try await self.settle(window)
                    try self.assertRowsOnly(in: window)

                    model.settings.isEnabled = true
                    model.settings.sources = []
                    try await self.settle(window)
                    try self.assertRowsOnly(in: window)

                    model.settings.sources = HeroSettings.default.sources
                    try await self.settle(window)
                    try self.assertHeroVisible(in: window)
                }
            }
        }
    }

    func testEmptyAndPendingHeroSlotsUseTheSamePhoneAndTabletGeometry() async throws {
        for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
            let model = HeroFixtureModel()
            model.settings.sources = [.collection]
            model.settings.collections = []
            let style: HeroArtworkStyle = sizeClass == .compact ? .compactPortrait : .landscape
            try await withWindow(HeroFixture(model: model, style: style, showsContent: false), sizeClass: sizeClass) {
                window in
                try self.assertRowsOnly(in: window)
                model.settings.collections = [
                    .init(accountID: "account", collectionID: "collection", title: "Collection")
                ]
                try await self.settle(window)
                try self.assertHeroVisible(in: window)
                model.recomputeComplete = true
                try await self.settle(window)
                try self.assertRowsOnly(in: window)
                model.hasItems = true
                try await self.settle(window)
                try self.assertHeroVisible(in: window)
            }
        }
    }

    func testColdLoadingScreenOmitsHeroOnFirstPaintAndRespondsToSettings() async throws {
        let app = PlozziOSAppModel()
        let original = app.profiles.activeProfileID
        let profile = app.profiles.add(name: "Cold Hero fixture", isAwaitingSetup: false)
        app.selectProfile(profile.id)
        defer {
            app.selectProfile(original)
            app.profiles.remove(profile.id)
        }
        app.settings.homeVisibility.applyRows(
            .init(enabled: [.global(.recentlyAdded)],
                  disabled: [.global(.continueWatching), .global(.watchlist), .libraries]),
            choices: HomeRowChoice.shared
        )
        let provider = EmptyHeroHomeProvider()
        for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
            let model = HomeViewModel(
                accounts: [ResolvedAccount(account: provider.account, provider: provider)],
                layoutStore: InMemoryHomeLayoutStore(), contentStore: NoOpHomeContentStore(),
                currentVisibility: { app.settings.homeVisibility.visibility },
                isLoadingAllowed: { false }
            )
            defer { model.invalidate() }
            app.settings.hero.settings.sources = [.recentlyAdded]
            app.settings.hero.settings.isEnabled = false
            let home = PlozziOSHomeView(appModel: app, viewModel: model, onAddServer: {}, onShowSettings: {})
                .environment(app)
                .environment(HeroTrailerController())
                .environment(PlozziOSSidebarGeometryModel())
            try await withWindow(home, sizeClass: sizeClass) { window in
                let scroll = try XCTUnwrap(self.scrollViews(in: window).first)
                let rowsHeight = scroll.contentSize.height
                let rowsTop = scroll.convert(.zero, to: window).y - scroll.contentOffset.y
                XCTAssertGreaterThanOrEqual(rowsTop, window.safeAreaInsets.top + 44 - 1)

                app.settings.hero.settings.isEnabled = true
                try await self.settle(window)
                let heroHeight = PlozziOSHeroMetrics.height(
                    style: sizeClass == .compact ? .compactPortrait : .landscape,
                    surfaceRole: .home, dynamicTypeSize: .large, containerHeight: window.bounds.height
                )
                XCTAssertEqual(scroll.contentSize.height - rowsHeight, heroHeight + 32, accuracy: 1)

                app.settings.hero.settings.sources = []
                try await self.settle(window)
                XCTAssertEqual(scroll.contentSize.height, rowsHeight, accuracy: 1)

                app.settings.hero.settings.sources = [.collection]
                app.settings.hero.settings.collections = []
                try await self.settle(window)
                XCTAssertEqual(scroll.contentSize.height, rowsHeight, accuracy: 1,
                               "Known-empty Collections must not reserve a Hero even on the first Home load.")
            }
        }
    }

    func testActualHomeKeepsHeroAndScrollThroughPreparationAndPartialProviderResponses() async throws {
        let app = PlozziOSAppModel()
        let original = app.profiles.activeProfileID
        let profile = app.profiles.add(name: "Progressive Hero fixture", isAwaitingSetup: false)
        app.selectProfile(profile.id)
        defer {
            app.selectProfile(original)
            app.profiles.remove(profile.id)
        }
        app.settings.hero.settings.sources = [.recentlyAdded]
        app.settings.hero.settings.isEnabled = true
        app.settings.hero.settings.autoAdvance = false
        app.settings.homeVisibility.applyRows(
            .init(enabled: [.global(.recentlyAdded)],
                  disabled: [.global(.continueWatching), .global(.watchlist), .libraries]),
            choices: HomeRowChoice.shared
        )
        for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
            for cached in [false, true] {
                let preparation = HomeHeroLoadingGate()
                let response = HomeHeroLoadingGate()
                let provider = EmptyHeroHomeProvider(latestGate: response)
                let store = InMemoryHomeContentStore()
                if cached {
                    store.saveHero((0..<2).map {
                        MediaItem(
                            id: "cached-\($0)", title: $0 == 0 ? "Cached sunrise" : "Cached sunset", kind: .movie,
                            allowsTitleBasedMetadataMatching: false
                        )
                    }, for: HeroConfigurationKey(settings: app.settings.hero.effectiveSettings))
                }
                let model = HomeViewModel(
                    accounts: [ResolvedAccount(account: provider.account, provider: provider)],
                    layoutStore: InMemoryHomeLayoutStore(), contentStore: store,
                    currentVisibility: { app.settings.homeVisibility.visibility },
                    prepareVisibility: { await preparation.wait() }
                )
                defer {
                    preparation.opened.withLock { $0 = true }
                    response.opened.withLock { $0 = true }
                    model.invalidate()
                }
                let home = PlozziOSHomeView(appModel: app, viewModel: model, onAddServer: {}, onShowSettings: {})
                    .environment(app)
                    .environment(HeroTrailerController())
                    .environment(PlozziOSSidebarGeometryModel())
                try await withWindow(home, sizeClass: sizeClass) { window in
                    let scroll = try XCTUnwrap(self.scrollViews(in: window).first)
                    let initialHeight = scroll.contentSize.height
                    let initialInset = scroll.adjustedContentInset.top
                    XCTAssertNil(model.state.value)
                    let initialText = try self.renderedText(in: window)
                    XCTAssertEqual(initialText.localizedCaseInsensitiveContains("Cached sunrise"), cached,
                                   "The durable carousel must paint before row preparation: \(initialText)")
                    let loading = Task { await model.load() }
                    defer { loading.cancel() }
                    preparation.opened.withLock { $0 = true }
                    let deadline = ContinuousClock.now + .seconds(3)
                    while model.state.value == nil, ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    XCTAssertNotNil(model.state.value)
                    XCTAssertTrue(model.loadingRows.contains(.recentlyAdded))
                    try await Task.sleep(for: .milliseconds(500))
                    try await self.settle(window)
                    XCTAssertTrue(self.scrollViews(in: window).first === scroll,
                                  "The first publication must not replace the native scroll view.")
                    XCTAssertEqual(scroll.contentSize.height, initialHeight, accuracy: 1,
                                   "An incomplete empty curation must not collapse the hero.")
                    XCTAssertEqual(scroll.adjustedContentInset.top, initialInset, accuracy: 1)
                    let pendingText = try self.renderedText(in: window)
                    XCTAssertEqual(pendingText.localizedCaseInsensitiveContains("Cached sunrise"), cached, pendingText)
                    let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    })
                    attachment.name = "home-progressive-\(sizeClass)-cached-\(cached)"
                    attachment.lifetime = .keepAlways
                    self.add(attachment)
                    response.opened.withLock { $0 = true }
                    await loading.value
                    try await self.settle(window)
                    XCTAssertFalse(model.isRefreshing)
                    XCTAssertTrue(self.scrollViews(in: window).first === scroll)
                }
            }
        }
    }

    private func assertRowsOnly(in window: UIWindow) throws {
        XCTAssertNil(find("hero", in: window), "A disabled hero must not mount its content or placeholder.")
        let row = try XCTUnwrap(find("first-row", in: window))
        let frame = row.convert(row.bounds, to: window)
        XCTAssertEqual(frame.minY, window.safeAreaInsets.top + 44, accuracy: 1,
                       "The first row must start below navigation, without a hero-sized gap.")
    }

    private func renderedText(in window: UIWindow) throws -> String {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func assertHeroVisible(in window: UIWindow) throws {
        let hero = try XCTUnwrap(find("hero", in: window))
        let row = try XCTUnwrap(find("first-row", in: window))
        let heroFrame = hero.convert(hero.bounds, to: window)
        let rowFrame = row.convert(row.bounds, to: window)
        XCTAssertEqual(heroFrame.minY, 0, accuracy: 1, "Enabled heroes remain full bleed.")
        XCTAssertEqual(rowFrame.minY, heroFrame.maxY + 32, accuracy: 1)
    }

    private func find(_ identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        return view.subviews.lazy.compactMap { self.find(identifier, in: $0) }.first
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func settle(_ window: UIWindow) async throws {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        window.layoutIfNeeded()
    }

    private func withWindow<Content: View>(
        _ content: Content,
        sizeClass: UserInterfaceSizeClass,
        colorScheme: ColorScheme = .dark,
        exercise: (UIWindow) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let size = sizeClass == .compact
            ? CGSize(width: 390, height: 844)
            : CGSize(width: 1024, height: 768)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: content
            .environment(\.horizontalSizeClass, sizeClass)
            .environment(\.dynamicTypeSize, .large)
            .environment(\.plozziOSHeroContainerHeight, size.height)
            .environment(\.themePalette, colorScheme == .dark ? ThemePalette.dark : .light))
        host.additionalSafeAreaInsets.top = 44
        host.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await settle(window)
        try await exercise(window)
    }
}

private final class HeroArtworkProviderSettings: MetadataProviderSettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value = MetadataProviderSettings(orderMode: .custom, enabledOrder: ["tmdb"])

    func load() -> MetadataProviderSettings {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func save(_ value: MetadataProviderSettings) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
}

@MainActor
@Observable
private final class HeroFixtureModel {
    var settings = HeroSettings.default
    var recomputeComplete = false
    var hasItems = false
}

private struct HeroFixture: View {
    let model: HeroFixtureModel
    let style: HeroArtworkStyle
    let showsContent: Bool

    var body: some View {
        let slot = HomeHeroSlotState.resolve(
            settings: model.settings, hasItems: showsContent || model.hasItems,
            recomputeComplete: model.recomputeComplete
        )
        PlozziOSHomeScrollView(heroActive: slot != .hidden) {
            Group {
                if slot == .content {
                    Color.blue.frame(height: 500)
                } else {
                    PlozziOSHomeHeroSkeleton(style: style)
                }
            }
            .background(FrameProbe(identifier: "hero"))
        } rows: {
            Color.red.frame(height: 120)
                .background(FrameProbe(identifier: "first-row"))
            Color.clear.frame(height: 1200)
        }
    }
}

private struct FrameProbe: UIViewRepresentable {
    let identifier: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.accessibilityIdentifier = identifier
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct HomeWidthFixture: View {
    @Environment(PlozziOSAppModel.self) private var app
    let item: MediaItem
    let style: HeroArtworkStyle

    var body: some View {
        PlozziOSHomeHeroForeground(
            item: item, detailItem: item, watchlistItem: item,
            presentation: HeroPresentation(item: item, artworkStyle: style, surface: .home),
            style: style, onPlay: { _ in }
        )
        .background(FrameProbe(identifier: "reading-column"))
        .plozziOSHeroForegroundPlacement(style: style, logoSize: app.settings.hero.settings.logoSize)
    }
}

struct SeriesHeaderMobileProvider: MediaProvider {
    var artworkURL: URL? = nil
    var kind: ProviderKind { .jellyfin }
    var session: UserSession {
        UserSession(
            server: .init(id: "header-fixture", name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!,
                          provider: kind),
            userID: "fixture", userName: "Fixture", deviceID: "fixture", accessToken: ""
        )
    }
    var show: MediaItem {
        MediaItem(
            id: "show", title: "Village stories", kind: .series,
            overview: "A quiet village beside the ocean.",
            posterURL: artworkURL, backdropURL: artworkURL,
            ratings: [.init(source: .imdb, value: 8.7, scale: .outOfTen)],
            allowsTitleBasedMetadataMatching: false, sourceAccountID: "header-fixture"
        )
    }
    var season: MediaItem {
        MediaItem(
            id: "season", title: "Season two", kind: .season, parentTitle: show.title,
            seasonNumber: 2, seriesID: show.id, allowsTitleBasedMetadataMatching: false,
            sourceAccountID: "header-fixture"
        )
    }
    var episode: MediaItem {
        MediaItem(
            id: "episode", title: "Secret doorway", kind: .episode, overview: "A secret doorway opens.",
            parentTitle: show.title, seasonNumber: 2, episodeNumber: 4, seriesID: show.id, seasonID: season.id,
            runtime: 1800, resumePosition: 120, ratings: [.init(source: .imdb, value: 2.3, scale: .outOfTen)],
            allowsTitleBasedMetadataMatching: false, sourceAccountID: "header-fixture"
        )
    }
    func item(id: String) async throws -> MediaItem {
        guard let item = [show, season, episode].first(where: { $0.id == id }) else { throw AppError.notFound }
        return item
    }
    func children(of itemID: String) async throws -> [MediaItem] {
        itemID == show.id ? [season] : itemID == season.id ? [episode] : []
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [episode] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

private struct EmptyHeroHomeProvider: MediaProvider {
    var latestGate: HomeHeroLoadingGate? = nil
    let kind: ProviderKind = .jellyfin
    let account = Account(
        id: "empty-hero-account",
        server: MediaServer(
            id: "empty-hero-server", name: "Fixture",
            baseURL: URL(string: "https://fixture.invalid")!, provider: .jellyfin
        ),
        userID: "viewer", userName: "Viewer", deviceID: "fixture"
    )
    var session: UserSession { account.session(token: "fixture") }

    func libraries() async throws -> [MediaLibrary] {
        [MediaLibrary(id: "movies", title: "Movies", kind: .movie)]
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] {
        await latestGate?.wait()
        return [MediaItem(id: "movie", title: "Available movie", kind: .movie,
                          allowsTitleBasedMetadataMatching: false)]
    }

    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: 0, totalCount: 0)
    }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

private final class HomeHeroLoadingGate: Sendable {
    let opened = Mutex(false)

    func wait() async {
        while !opened.withLock({ $0 }) {
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { return }
        }
    }
}
#endif
