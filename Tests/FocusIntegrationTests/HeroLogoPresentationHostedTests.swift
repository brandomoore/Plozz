import CoreModels
@testable import AppShell
@testable import CoreUI
@testable import FeatureHome
import FeatureHomeCore
import MetadataKit
@testable import FeatureSettings
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class HeroLogoPresentationHostedTests: XCTestCase {
    func testShowcaseDisplaysServerSeriesSynopsisWithEpisodeSpoilersEnabled() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let logo = try seedLogo(size: CGSize(width: 600, height: 100))
        defer { removeSeededLogo(logo) }
        let episode = MediaItem(
            id: UUID().uuidString, title: "Secret episode title", kind: .episode,
            overview: "The secret murderer is revealed.", parentTitle: "A series",
            seriesID: "series", logoURL: logo, allowsTitleBasedMetadataMatching: false,
            sourceAccountID: "account"
        )
        let series = MediaItem(
            id: "series", title: "A series", kind: .series,
            overview: "A quiet village beside the ocean.", sourceAccountID: "account"
        )
        for mode in [SpoilerSettings.Mode.blur, .placeholder] {
            var spoilers = SpoilerSettings.default
            spoilers.isEnabled = true
            spoilers.mode = mode
            fixture.window.rootViewController = UIHostingController(rootView:
                FocusHeroHomeView(
                    rows: [.init(id: "row", itemIDs: [episode.id], leadItem: episode, items: [episode])],
                    settings: .default, spoilerSettings: spoilers,
                    navigationStyle: .rail, isFrontmost: true,
                    enrich: { items in
                        items.map {
                            var enriched = $0
                            enriched.seriesSynopsis = MediaSeriesSynopsis(series: series)
                            return enriched
                        }
                    }
                ) { _, _ in
                    Color(uiColor: .blue).frame(height: 420)
                }
                .environment(\.plozzArtworkSettings, ArtworkSettings(preference: .library))
                .environment(\.themePalette, .dark)
                .environment(\.colorScheme, .dark)
            )
            func visibleText() throws -> String {
                let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                    fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
                }
                let request = VNRecognizeTextRequest()
                try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ").lowercased()
            }
            try await waitUntil { try visibleText().contains("quiet village") }
            XCTAssertFalse(try visibleText().contains("secret"))
            XCTAssertNotNil(try redBounds(in: fixture.window), "The series logo remains visible.")
            attachPreview(in: fixture.window, name: "showcase-series-synopsis-\(mode.rawValue)")
        }
    }

    func testLogoReloadsOnAppLanguageChangeWithoutRecreatingTheRoot() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let french = try seedLogo(size: CGSize(width: 300, height: 80), color: .red)
        let english = try seedLogo(size: CGSize(width: 300, height: 80), color: .green)
        defer { removeSeededLogo(french); removeSeededLogo(english) }
        let state = LogoLanguageFixtureState()
        let item = MediaItem(id: UUID().uuidString, title: "Series", kind: .series)
        let fallback = HeroLogoFallback(for: item, localizedResolve: {
            $0 == "fr" ? french : english
        })
        fixture.window.rootViewController = UIHostingController(rootView:
            LogoLanguageFixture(state: state, fallback: fallback)
        )
        try await waitUntil { try colorBounds(in: fixture.window, channel: 1) != nil }
        state.language = "fr-CA"
        try await waitUntil { try redBounds(in: fixture.window) != nil }
        XCTAssertNil(try colorBounds(in: fixture.window, channel: 1))
        state.language = "en"
        try await waitUntil { try colorBounds(in: fixture.window, channel: 1) != nil }
        XCTAssertNil(try redBounds(in: fixture.window))
    }

    @Observable fileprivate final class LogoLanguageFixtureState {
        var language = "en"
    }

    private struct LogoLanguageFixture: View {
        let state: LogoLanguageFixtureState
        let fallback: HeroLogoFallback

        var body: some View {
            HeroLogoArtwork(
                primaryURL: nil, asyncFallbackURL: fallback,
                maxWidth: 300, maxHeight: 80, presentationPolicy: .whenResolved
            ) { Text("Fallback") }
            .environment(\.locale, Locale(identifier: state.language))
            .environment(\.colorScheme, .dark)
        }
    }

    func testDescriptionColumnMeasuresTheLiveWrappingFactsRow() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        for (count, availableWidth, expectedWidth): (Int, CGFloat, CGFloat) in [
            (2, 1400, 800), (5, 1400, 960), (8, 1400, 1200), (5, 900, 900), (2, 1400, 800)
        ] {
            fixture.window.rootViewController = UIHostingController(rootView:
                HeroDescriptionFactsLayout {
                    Color.red.frame(height: 80)
                    WrappingHStackLayout(spacing: 20, lineSpacing: 8) {
                        ForEach(0..<count, id: \.self) { _ in
                            Color(red: 0, green: 1, blue: 0).frame(width: 176, height: 40)
                        }
                    }
                    .frame(maxWidth: HeroDescriptionFactsLayout.maximumWidth, alignment: .leading)
                }
                .frame(width: availableWidth, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(80)
                .background(Color.black)
            )
            try await waitUntil { (try? redBounds(in: fixture.window)) != nil }
            let description = try XCTUnwrap(redBounds(in: fixture.window))
            let facts = try XCTUnwrap(colorBounds(in: fixture.window, channel: 1))
            XCTAssertEqual(description.width, expectedWidth, accuracy: 1)
            XCTAssertLessThanOrEqual(facts.maxX, description.maxX + 1)
            XCTAssertGreaterThan(facts.minY, description.maxY)
        }
    }

    func testDetailAdjustmentScalesEpisodeCaptionsWithoutResizingArtwork() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let url = try seedLogo(size: EpisodeColumnCard.artworkSize)
        defer { removeSeededLogo(url) }
        let item = MediaItem(
            id: "episode-typography", title: "The Hidden Room", kind: .episode,
            overview: "Across the stars.\nAn explorer follows\nThe final signal.",
            episodeNumber: 4,
            posterURL: url, allowsTitleBasedMetadataMatching: false
        )
        let suite = "EpisodeTypography.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = DetailPageSettingsModel(store: DetailPageSettingsStore(defaults: defaults))
        let host = UIHostingController(rootView:
            EpisodeColumnCard(item: item, action: {}).equatable()
                .environment(\.detailHeaderSettings, settings)
                .environment(\.plozzCardFocusStyle, .system)
                .environment(\.themePalette, .dark)
                .environment(\.colorScheme, .dark)
                .frame(width: 496, height: SeriesEpisodeBrowserLayout.episodeRailHeight, alignment: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(80)
                .background(Color.black)
        )
        fixture.window.rootViewController = host
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: fixture.window))
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        try await waitUntil { (try? redBounds(in: fixture.window)) != nil }
        var baseline: [String: CGRect] = [:]
        var artwork: CGRect?
        for step in [0, -5, 5] {
            settings.settings.textSize = HeroTextSize(rawValue: step)
            try await Task.sleep(for: .milliseconds(600))
            fixture.window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
            }
            let terms = ["The Hidden Room", "Across the stars", "The final signal"]
            let frames = try textInkFrames(in: image, terms: terms)
            let currentArtwork = try XCTUnwrap(redBounds(in: fixture.window))
            if step == 0 {
                baseline = frames
                artwork = currentArtwork
            }
            for term in terms {
                let frame = try XCTUnwrap(frames[term])
                XCTAssertEqual(frame.height, try XCTUnwrap(baseline[term]).height * settings.settings.textSize.scale,
                               accuracy: 3, "\(term), \(step)")
                XCTAssertGreaterThan(frame.minY, currentArtwork.maxY)
                XCTAssertLessThan(
                    frame.maxY, currentArtwork.minY + SeriesEpisodeBrowserLayout.episodeRailHeight,
                    "All three caption lines must fit the existing rail."
                )
            }
            XCTAssertEqual(currentArtwork.width, try XCTUnwrap(artwork).width, accuracy: 1)
            XCTAssertEqual(currentArtwork.height, try XCTUnwrap(artwork).height, accuracy: 1)
            attachPreview(in: fixture.window, name: "episode-text-\(step)")
        }
    }

    func testDetailDescriptionHasFourLinesAtDefaultAndMaximum() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let suite = "DetailDescriptionLines.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = DetailPageSettingsModel(store: DetailPageSettingsStore(defaults: defaults))
        let background = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore(
            HeroBackgroundSettings(homeTrailerEnabled: false, detailMode: .off)
        ))
        let item = MediaItem(
            id: "four-line-detail", title: "SIGNAL", kind: .movie,
            overview: "First line.\nSecond line.\nThird line.\nFourth line.\nFifth line.",
            allowsTitleBasedMetadataMatching: false
        )
        fixture.window.rootViewController = UIHostingController(rootView:
            DetailHeroView(item: item, spoilerSettings: .default, playTitle: "Play", onPlay: {})
                .environment(\.detailHeaderSettings, settings)
                .environment(background)
                .environment(HeroTrailerController())
                .environment(\.colorScheme, .dark)
                .environment(\.themePalette, .dark)
                .background(Color.black)
        )
        for step in [0, 5] {
            settings.settings.textSize = HeroTextSize(rawValue: step)
            fixture.window.layoutIfNeeded()
            try await waitUntil {
                (try? colorBounds(in: fixture.window, channel: 0, minimumChannel: 220, maximumOtherChannel: 255)) != nil
            }
            try await Task.sleep(for: .milliseconds(450))
            let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            XCTAssertTrue(text.contains("Fourth line"), text)
            XCTAssertFalse(text.contains("Fifth line"), text)
            attachPreview(in: fixture.window, name: "detail-four-lines-\(step)")
        }
    }

    func testCombinedMaximumSizesFitTogetherWithoutCrossingNavigationOrRows() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let url = try seedLogo(size: CGSize(width: 240, height: 200))
        defer { removeSeededLogo(url) }
        let item = MediaItem(
            id: "combined-sizing", title: "SIGNAL", kind: .movie,
            overview: "Across the stars. A brave explorer follows a mysterious signal across the galaxy, "
                + "discovering new worlds and unexpected friends along the way.",
            officialRating: "PG", genres: ["Documentary"], logoURL: url,
            allowsTitleBasedMetadataMatching: false
        )
        let row = FocusHeroRow(id: "combined-row", itemIDs: [item.stablePresentationID], leadItem: item, items: [item])
        var settings = HeroSettings.default
        settings.showcaseLogoSize = HeroLogoSize(rawValue: 10)
        settings.showcaseTextSize = HeroTextSize(rawValue: 5)
        fixture.window.rootViewController = UIHostingController(rootView:
            Color.black.overlay {
                Text("Documentary").font(.system(size: 23 * settings.showcaseTextSize.scale, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 900, alignment: .leading)
            }.ignoresSafeArea()
        )
        try await Task.sleep(for: .milliseconds(200))
        let referenceImage = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
            fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
        }
        let requestedTextHeight = try XCTUnwrap(textInkFrames(in: referenceImage, terms: ["Documentary"])["Documentary"]).height
        let requestedLogoHeight = HeroLogoSizing.box(for: .showcase, size: settings.showcaseLogoSize).height
        for minimumTop: CGFloat? in [nil, 120] {
            var referenceLogo: CGRect?
            var referenceText: CGRect?
            for rowHeight: CGFloat in [420, 608] {
                let model = FocusHeroModel()
                model.record(height: rowHeight, for: row.id)
                model.motion.height = rowHeight
                model.seed(from: [row])
                fixture.window.rootViewController = UIHostingController(rootView:
                    Color.black.overlay(alignment: .topLeading) {
                        FocusHeroColumn(
                            model: model, metadata: FocusHeroMetadata(), enrich: nil, settings: settings,
                            spoilerSettings: .default, navigationStyle: .rail, rows: [row], minimumDetailsTop: minimumTop
                        )
                    }
                    .environment(\.colorScheme, .dark)
                    .environment(\.themePalette, .dark)
                    .ignoresSafeArea()
                )
                try await waitUntil { (try? redBounds(in: fixture.window)) != nil }
                try await Task.sleep(for: .milliseconds(300))
                attachPreview(in: fixture.window, name: "combined-maximum-\(String(describing: minimumTop))-\(rowHeight)")
                let logo = try XCTUnwrap(redBounds(in: fixture.window))
                let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                    fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
                }
                let frames = try textInkFrames(in: image, terms: ["Documentary", "Across the stars"])
                let text = try XCTUnwrap(frames["Documentary"])
                let description = try XCTUnwrap(frames["Across the stars"])
                let commonFit = logo.height / requestedLogoHeight
                if minimumTop == nil && rowHeight == 420 {
                    XCTAssertEqual(commonFit, 1, accuracy: 0.02, "Use the requested maximum when the Home viewport has room.")
                } else if rowHeight == 608 {
                    XCTAssertLessThan(commonFit, 0.95, "Tall rows still require joint fitting.")
                }
                XCTAssertEqual(text.height, requestedTextHeight * commonFit, accuracy: 2)
                XCTAssertGreaterThanOrEqual(logo.minY, minimumTop ?? FocusHeroLayout.columnTop(for: .rail))
                XCTAssertLessThan(logo.maxY, text.minY)
                XCTAssertLessThan(text.maxY, description.minY)
                XCTAssertLessThan(description.maxY, FocusHeroLayout.rowsBottom(rowSpacing: FocusHeroLayout.rowSpacing) - rowHeight)
                if let referenceLogo, let referenceText {
                    let fit = logo.height / referenceLogo.height
                    XCTAssertLessThan(fit, 0.95, "A taller row leaves less space than a shorter row.")
                    XCTAssertEqual(text.height, referenceText.height * fit, accuracy: 2)
                    XCTAssertEqual(logo.width, referenceLogo.width * fit, accuracy: 2)
                } else {
                    referenceLogo = logo
                    referenceText = text
                }
            }
        }
    }

    func testHiddenLibraryHeaderReleasesSpaceForMaximumSizes() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let url = try seedLogo(size: CGSize(width: 240, height: 200))
        defer { removeSeededLogo(url) }
        let item = MediaItem(
            id: "header-space", title: "SIGNAL", kind: .movie, overview: "Across the stars.",
            genres: ["Documentary"], logoURL: url, allowsTitleBasedMetadataMatching: false
        )
        let row = FocusHeroRow(id: "first", itemIDs: [item.id], leadItem: item, items: [item])
        let model = FocusHeroModel()
        model.record(height: 420, for: row.id)
        model.motion.height = 420
        model.seed(from: [row])
        let visibility = ShowcaseNavigationVisibility()
        var settings = HeroSettings.default
        settings.showcaseLogoSize = HeroLogoSize(rawValue: 10)
        settings.showcaseTextSize = HeroTextSize(rawValue: 5)
        fixture.window.rootViewController = UIHostingController(rootView:
            Color.black.overlay(alignment: .topLeading) {
                FocusHeroColumn(
                    model: model, metadata: FocusHeroMetadata(), enrich: nil, settings: settings,
                    spoilerSettings: .default, navigationStyle: .tabBar, rows: [row], minimumDetailsTop: 300
                )
                .modifier(ShowcaseDetailsTopModifier(
                    visibility: visibility, rowIDs: ["first", "second"], visibleTop: 300, hiddenTop: 84
                ))
            }
            .environment(\.colorScheme, .dark)
            .environment(\.themePalette, .dark)
            .ignoresSafeArea()
        )
        var visibleLogo: CGRect?
        for rowID in ["first", "second", "first"] {
            visibility.focusedRowID = rowID
            try await waitUntil { (try? redBounds(in: fixture.window)) != nil }
            try await Task.sleep(for: .milliseconds(600))
            let logo = try XCTUnwrap(redBounds(in: fixture.window))
            XCTAssertGreaterThanOrEqual(logo.minY, rowID == "first" ? 300 : 84)
            if rowID == "second" {
                XCTAssertGreaterThan(logo.height, try XCTUnwrap(visibleLogo).height * 1.2)
                XCTAssertEqual(logo.height, HeroLogoSizing.box(for: .showcase, size: settings.showcaseLogoSize).height, accuracy: 1)
            } else if let visibleLogo {
                XCTAssertEqual(logo, visibleLogo, "Returning to the first row restores navigation clearance.")
            } else {
                visibleLogo = logo
            }
            attachPreview(in: fixture.window, name: "showcase-header-\(rowID)")
        }
    }

    func testMaximumShowcaseClearsTheTopDuringNativeRowHeightChanges() async throws {
        try await assertMaximumColumnClearsNativeMotion(libraryHeader: false)
    }

    func testMaximumRecommendedClearsReturningHeaderDuringNativeRowHeightChanges() async throws {
        try await assertMaximumColumnClearsNativeMotion(libraryHeader: true)
    }

    private func assertMaximumColumnClearsNativeMotion(libraryHeader: Bool) async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let url = try seedLogo(size: CGSize(width: 240, height: 200))
        defer { removeSeededLogo(url) }
        let item = MediaItem(
            id: "moving-space", title: "SIGNAL", kind: .movie, overview: "Across the stars.",
            genres: ["Documentary"], logoURL: url, allowsTitleBasedMetadataMatching: false
        )
        let rows = ["tall", "short"].map { FocusHeroRow(id: $0, itemIDs: [item.id], leadItem: item, items: [item]) }
        let model = FocusHeroModel()
        let visibility = ShowcaseNavigationVisibility()
        model.record(height: 608, for: "tall")
        model.record(height: 420, for: "short")
        model.seed(from: rows)
        defer { model.motion.stop() }
        var settings = HeroSettings.default
        settings.showcaseLogoSize = HeroLogoSize(rawValue: 10)
        settings.showcaseTextSize = HeroTextSize(rawValue: 5)
        fixture.window.rootViewController = UIHostingController(rootView:
            ZStack(alignment: .topLeading) {
                FocusHeroScrollingRows(rows: rows, model: model) { row, _ in
                    Color.gray.frame(height: (row.id == "tall" ? 608 : 420) + FocusHeroLayout.rowBottomTightening)
                }
                let column = FocusHeroColumn(
                    model: model, metadata: FocusHeroMetadata(), enrich: nil, settings: settings,
                    spoilerSettings: .default, navigationStyle: .rail, rows: rows,
                    minimumDetailsTop: libraryHeader ? 220 : nil
                )
                if libraryHeader {
                    column.modifier(ShowcaseDetailsTopModifier(
                        visibility: visibility, rowIDs: rows.map(\.id), visibleTop: 220, hiddenTop: 84
                    ))
                } else {
                    column
                }
            }
            .frame(width: 1920, height: 1080)
            .environment(\.colorScheme, .dark)
            .environment(\.themePalette, .dark)
            .background(Color.black)
            .ignoresSafeArea()
        )
        try await waitUntil { (try? redBounds(in: fixture.window)) != nil }
        try await Task.sleep(for: .milliseconds(450))
        let content = try XCTUnwrap(model.motion.columnContent)
        let column = try XCTUnwrap(model.motion.column)
        var destinationSizes: [String: CGSize] = [:]
        for row in [rows[1], rows[0]] {
            model.activate(row, in: rows)
            visibility.focusedRowID = row.id
            try await Task.sleep(for: .seconds(FocusHeroLayout.rowSpring.settlingDuration + 0.3))
            destinationSizes[row.id] = try XCTUnwrap(redBounds(in: fixture.window)).size
        }
        let initialLogo = try XCTUnwrap(redBounds(in: fixture.window))
        let localLogo = content.convert(initialLogo, from: fixture.window)
        for row in [rows[1], rows[0], rows[1], rows[0], rows[1]] {
            model.activate(row, in: rows)
            visibility.focusedRowID = row.id
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(20))
                // Sample both native surfaces in the same frame. Pixel scanning
                // blocks long enough for the presentation to advance afterward.
                let windowLayer = fixture.window.layer.presentation() ?? fixture.window.layer
                let contentLayer = content.layer.presentation() ?? content.layer
                let columnLayer = column.layer.presentation() ?? column.layer
                let logo = contentLayer.convert(localLogo, to: windowLayer)
                let expectedSize = try XCTUnwrap(destinationSizes[row.id])
                XCTAssertEqual(logo.width, expectedSize.width, accuracy: 2,
                               "The incoming title must start at its destination size, not grow after scrolling.")
                XCTAssertEqual(logo.height, expectedSize.height, accuracy: 2)
                let bottom = columnLayer.convert(
                    CGPoint(x: 0, y: FocusHeroLayout.lowestSlotTop - FocusHeroLayout.columnGap),
                    to: windowLayer
                ).y
                let minimumTop: CGFloat = libraryHeader ? (row.id == "tall" ? 220 : 84) : FocusHeroLayout.columnTop
                XCTAssertGreaterThanOrEqual(logo.minY, minimumTop - 2)
                XCTAssertLessThan(logo.maxY, bottom)
            }
        }
        try await Task.sleep(for: .seconds(FocusHeroLayout.rowSpring.settlingDuration + 0.3))
        let settledLogo = try XCTUnwrap(redBounds(in: fixture.window))
        XCTAssertGreaterThanOrEqual(settledLogo.minY, FocusHeroLayout.columnTop - 2)
        XCTAssertEqual(settledLogo.height,
                       HeroLogoSizing.box(for: .showcase, size: settings.showcaseLogoSize).height, accuracy: 1)
    }

    func testLargeRecommendedUsesTheVisibleLogoHeightWithScheduleAndThreeDescriptionLines() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let url = try seedLogo(size: CGSize(width: 820, height: 200))
        defer { removeSeededLogo(url) }
        _ = await HeroLogoPipeline.shared.preparedLogo(for: .remote(url))
        let identity = UUID().uuidString
        let item = MediaItem(
            id: identity, title: "Scheduled series", kind: .series,
            overview: "An unexpected encounter.\nA carefully guarded secret.\nThe story continues.",
            officialRating: "TV-MA", logoURL: url, providerIDs: ["PlexGuid": "plex://show/\(identity)"],
            allowsTitleBasedMetadataMatching: false
        )
        let row = FocusHeroRow(id: "continue", itemIDs: [item.id], leadItem: item, items: [item])
        let model = FocusHeroModel()
        model.record(height: 340, for: row.id)
        model.seed(from: [row])
        let now = Date()
        let upcoming = UpcomingEpisode(
            seriesIdentity: .external(source: "fixture", value: item.id), seasonNumber: 2, episodeNumber: 1,
            airDate: now.addingTimeInterval(7 * 86400), datePrecision: .dateOnly,
            source: .tvmaze, refreshedAt: now
        )
        await SeriesScheduleStore.shared.store(.init(
            seriesKey: MetadataQuery(item).seriesScoped.enrichmentCacheKey,
            upcomingEpisode: upcoming, upcomingEpisodes: [upcoming],
            refreshedAt: now, refreshDueAt: now.addingTimeInterval(3600)
        ))
        let schedules = HeroScheduleLines()
        await schedules.loadCached([item])
        var settings = HeroSettings.default
        settings.showcaseLogoSize = HeroLogoSize(rawValue: 10)
        settings.showcaseTextSize = HeroTextSize(rawValue: 5)
        fixture.window.rootViewController = UIHostingController(rootView:
            Color.black.overlay(alignment: .topLeading) {
                FocusHeroColumn(
                    model: model, metadata: FocusHeroMetadata(), enrich: nil, settings: settings,
                    spoilerSettings: .default, navigationStyle: .tabBar, rows: [row],
                    minimumDetailsTop: 232, schedules: schedules
                )
            }
            .environment(\.colorScheme, .dark)
            .environment(\.themePalette, .dark)
            .ignoresSafeArea()
        )
        try await waitUntil { (try? redBounds(in: fixture.window)) != nil }
        try await Task.sleep(for: .milliseconds(300))
        let logo = try XCTUnwrap(redBounds(in: fixture.window))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds, format: format).image { _ in
            fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
        }
        let frames = try textInkFrames(in: image, terms: [
            "New season", "An unexpected", "A carefully", "The story"
        ])
        let badge = try XCTUnwrap(frames["New season"])
        let lastLine = try XCTUnwrap(frames["The story"])
        XCTAssertNotNil(frames["An unexpected"])
        XCTAssertNotNil(frames["A carefully"])
        XCTAssertGreaterThanOrEqual(badge.minY, 232)
        XCTAssertLessThan(badge.minY, 252, "The scheduled title should use the space immediately below navigation.")
        XCTAssertLessThan(badge.maxY, logo.minY)
        XCTAssertLessThan(lastLine.maxY, 588)
        XCTAssertGreaterThan(lastLine.maxY, 574, "Use the available height instead of leaving a second bottom gap.")
        XCTAssertEqual(logo.width / logo.height, 4.1, accuracy: 0.05)
        let attachment = XCTAttachment(image: image)
        attachment.name = "large-recommended-scheduled-three-lines"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDetailTextSizeScalesItsMetadataWithoutResizingPlay() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let suite = "DetailTextSize.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = DetailPageSettingsModel(store: DetailPageSettingsStore(defaults: defaults))
        let background = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore(
            HeroBackgroundSettings(homeTrailerEnabled: false, detailMode: .off)
        ))
        let item = MediaItem(
            id: "detail-text-sizing", title: "SIGNAL", kind: .movie, overview: "Across the stars.",
            officialRating: "PG", genres: ["Documentary"], allowsTitleBasedMetadataMatching: false
        )
        fixture.window.rootViewController = UIHostingController(rootView:
            DetailHeroView(item: item, spoilerSettings: .default, playTitle: "Play", onPlay: {})
                .environment(\.detailHeaderSettings, settings)
                .environment(background)
                .environment(HeroTrailerController())
                .environment(\.colorScheme, .dark)
                .environment(\.themePalette, .dark)
                .background(Color.black)
        )
        var baseline: [String: CGFloat] = [:]
        for step in [0, -5, 5] {
            settings.settings.textSize = HeroTextSize(rawValue: step)
            try await Task.sleep(for: .milliseconds(450))
            fixture.window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
            }
            attachPreview(in: fixture.window, name: "detail-text-\(step)")
            let frames = try textInkFrames(in: image, terms: ["SIGNAL", "Documentary", "Across the stars", "Play"])
            for text in ["SIGNAL", "Documentary", "Across the stars", "Play"] {
                let height = try XCTUnwrap(frames[text]).height
                if step == 0 { baseline[text] = height }
                let scale = text == "Play" ? 1 : settings.settings.textSize.scale
                XCTAssertEqual(height, try XCTUnwrap(baseline[text]) * scale, accuracy: 3, "\(text), \(step)")
            }
        }
    }

    func testShowcaseAndRecommendedTextScaleInsideTheRealHostedColumn() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let item = MediaItem(
            id: "text-sizing-fixture", title: "SIGNAL", kind: .movie,
            overview: "Across the stars.", officialRating: "PG", genres: ["Documentary"],
            allowsTitleBasedMetadataMatching: false
        )
        let row = FocusHeroRow(id: "sizing-row", itemIDs: [item.stablePresentationID], leadItem: item, items: [item])
        let model = FocusHeroModel()
        model.record(height: 420, for: row.id)
        model.motion.height = 420
        model.seed(from: [row])
        for minimumTop: CGFloat? in [nil, 120] {
            var baseline: [String: CGRect] = [:]
            for step in [0, -5, 5] {
                var settings = HeroSettings.default
                settings.showcaseTextSize = HeroTextSize(rawValue: step)
                fixture.window.rootViewController = UIHostingController(rootView:
                    Color.black.overlay(alignment: .topLeading) {
                        FocusHeroColumn(
                            model: model, metadata: FocusHeroMetadata(), enrich: nil, settings: settings,
                            spoilerSettings: .default, navigationStyle: .rail, rows: [row], minimumDetailsTop: minimumTop
                        )
                    }
                    .environment(\.colorScheme, .dark)
                    .environment(\.themePalette, .dark)
                    .ignoresSafeArea()
                )
                try await waitUntil {
                    fixture.window.layoutIfNeeded()
                    let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                        fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
                    }
                    let request = VNRecognizeTextRequest()
                    request.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
                    return request.results?.contains { $0.topCandidates(1).first?.string.contains("SIGNAL") == true } == true
                }
                fixture.window.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                    fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
                }
                attachPreview(in: fixture.window, name: "hero-text-\(minimumTop == nil ? "home" : "library")-\(step)")
                let frames = try textInkFrames(in: image, terms: ["SIGNAL", "Documentary", "Across the stars"])
                if step == 0 { baseline = frames }
                let effectiveScale = step > 0
                    ? try XCTUnwrap(frames["SIGNAL"]).height / XCTUnwrap(baseline["SIGNAL"]).height
                    : settings.showcaseTextSize.scale
                if step > 0 {
                    XCTAssertGreaterThan(effectiveScale, 1)
                    XCTAssertLessThanOrEqual(effectiveScale, settings.showcaseTextSize.scale + 0.04)
                }
                for text in ["SIGNAL", "Documentary", "Across the stars"] {
                    let frame = try XCTUnwrap(frames[text])
                    XCTAssertEqual(
                        frame.height, try XCTUnwrap(baseline[text]).height * effectiveScale,
                        accuracy: 3, "\(text), step \(step)"
                    )
                    XCTAssertLessThan(frame.maxY, FocusHeroLayout.rowsBottom(rowSpacing: FocusHeroLayout.rowSpacing) - 420)
                    if let minimumTop { XCTAssertGreaterThanOrEqual(frame.minY, minimumTop) }
                }
            }
        }
    }

    func testLateScheduleKeepsLogoGeometryAndHugsTrimmedArtwork() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        for minimumTop: CGFloat? in [nil, 120] {
            for shape in [CGSize(width: 600, height: 100), CGSize(width: 200, height: 200),
                          CGSize(width: 100, height: 200)] {
                let url = try seedLogo(size: shape)
                defer { removeSeededLogo(url) }
                let preparation = await HeroLogoPipeline.shared.preparedLogo(for: .remote(url))
                let prepared = try XCTUnwrap(preparation)
                let identity = UUID().uuidString
                let item = MediaItem(
                    id: identity, title: "Late schedule fixture", kind: .series,
                    logoURL: url, providerIDs: ["PlexGuid": "plex://show/\(identity)"],
                    allowsTitleBasedMetadataMatching: false
                )
                let row = FocusHeroRow(id: "row", itemIDs: [item.stablePresentationID], leadItem: item, items: [item])
                let model = FocusHeroModel()
                model.record(height: FocusHeroLayout.rowsBottom(rowSpacing: FocusHeroLayout.rowSpacing)
                             - FocusHeroLayout.lowestSlotTop, for: row.id)
                model.seed(from: [row])
                let schedules = HeroScheduleLines()
                var settings = HeroSettings.default
                settings.showcaseLogoSize = HeroLogoSize(rawValue: 10)
                fixture.window.rootViewController = UIHostingController(rootView:
                    Color.black.overlay(alignment: .topLeading) {
                        FocusHeroColumn(
                            model: model, metadata: FocusHeroMetadata(), enrich: nil,
                            settings: settings, spoilerSettings: .default, navigationStyle: .rail,
                            rows: [row], minimumDetailsTop: minimumTop, schedules: schedules
                        )
                        .offset(y: 160)
                    }
                    .environment(\.colorScheme, .dark)
                    .environment(\.themePalette, .dark)
                    .environment(\.gradientBackgroundsEnabled, false)
                    .ignoresSafeArea()
                )
                try await waitUntil { (try? redBounds(in: fixture.window)) != nil }
                try await Task.sleep(for: .milliseconds(450))
                XCTAssertNil(schedules.line(for: item))
                let before = try XCTUnwrap(redBounds(in: fixture.window))
                let now = Date()
                let upcoming = UpcomingEpisode(
                    seriesIdentity: .external(source: "fixture", value: item.id), seasonNumber: 2, episodeNumber: 1,
                    airDate: now.addingTimeInterval(7 * 86400), datePrecision: .dateOnly,
                    source: .tvmaze, refreshedAt: now
                )
                await SeriesScheduleStore.shared.store(.init(
                    seriesKey: MetadataQuery(item).seriesScoped.enrichmentCacheKey,
                    upcomingEpisode: upcoming, upcomingEpisodes: [upcoming],
                    refreshedAt: now, refreshDueAt: now.addingTimeInterval(3600)
                ))
                await schedules.loadCached([item])
                XCTAssertNotNil(schedules.line(for: item))
                try await Task.sleep(for: .milliseconds(250))
                let after = try XCTUnwrap(redBounds(in: fixture.window))
                let context = "minimumTop=\(String(describing: minimumTop)) shape=\(shape)"
                XCTAssertEqual(after, before, "A late badge must not resize or move the logo: \(context)")
                let cached = await HeroLogoPipeline.shared.preparedLogo(for: .remote(url))
                XCTAssertTrue(cached?.image === prepared.image, "Reuse the prepared, cropped bitmap.")
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds, format: format).image { _ in
                    XCTAssertTrue(fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true))
                }
                attachPreview(in: fixture.window, name: "late-badge-\(minimumTop == nil ? "home" : "library")-\(shape.width)")
                let badge = try XCTUnwrap(textInkFrames(in: image, terms: ["New season"])["New season"])
                let gap = after.minY - badge.maxY
                let box = HeroLogoSizing.box(for: .showcase, size: settings.showcaseLogoSize)
                let unfittedWidth = shape.width * min(box.width / shape.width, box.height / shape.height)
                let fit = after.width / unfittedWidth
                XCTAssertGreaterThan(gap, 16 * fit - 1, context)
                XCTAssertLessThan(gap, 42 * fit + 1, "The badge must hug visible ink, not the nominal logo slot: \(context)")
            }
        }
    }

    func testLibrarySettingsReuseTheNativeSizeControlAndNavigationEditor() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let suite = "LibrarySettingsHosted.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LibraryPresentationSettingsModel(
            store: LibraryPresentationSettingsStore(defaults: defaults)
        )
        model.settings.logoSize = HeroLogoSize(rawValue: -10)
        let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
        let cards = CardStyleSettingsModel(
            store: CardStyleSettingsStore(defaults: defaults),
            focusStore: CardFocusStyleSettingsStore(defaults: defaults),
            captionStore: CardCaptionSettingsStore(defaults: defaults),
            artworkStore: ArtworkSettingsStore(defaults: defaults)
        )
        let host = LayoutFocusHost(rootView:
            NavigationRailFocusHost { _ in
                LibrarySettingsEnvironmentFixture(cards: cards, visibility: visibility)
            }
            .environment(model)
            .environment(\.libraryPresentationLoader, EmptyLibrarySettingsLoader())
            .frame(width: 1100)
            .environment(\.colorScheme, .dark)
            .environment(\.themePalette, .dark)
            .background(Color.black)
        )
        fixture.window.rootViewController = host
        try await waitUntil { adjustmentInput(in: host) != nil }
        fixture.window.layoutIfNeeded()
        let input = try XCTUnwrap(adjustmentInput(in: host))
        defer { input.stopRepeating() }
        let inputView = try XCTUnwrap((input as? UIViewController)?.view)
        let inputFrame = inputView.convert(inputView.bounds, to: fixture.window)
        let target = try XCTUnwrap(focusItems(in: fixture.window).filter { $0.frame.width > 300 }.min {
            abs(((try? focusFrame($0, in: fixture.window).midY) ?? 0) - inputFrame.midY)
                < abs(((try? focusFrame($1, in: fixture.window).midY) ?? 0) - inputFrame.midY)
        })
        let system = try XCTUnwrap(UIFocusSystem(for: fixture.window))
        host.target = target
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        try await waitUntil { input.ownsHorizontalNavigationInput }
        host.target = nil
        attachPreview(in: fixture.window, name: "library-customization-small")
        for index in 1..<HeroLogoSize.allSizes.count {
            input.beginPress(.right)
            input.stopRepeating()
            XCTAssertEqual(model.settings.logoSize, HeroLogoSize.allSizes[index])
            XCTAssertTrue(input.ownsHorizontalNavigationInput)
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(LibraryPresentationSettingsStore(defaults: defaults).load().logoSize.rawValue, 10)
        attachPreview(in: fixture.window, name: "library-customization-large")
        fixture.window.rootViewController = UIHostingController(rootView:
            LibraryNavigationSettingsView(model: model)
                .frame(width: 1100)
                .environment(\.colorScheme, .dark)
                .environment(\.themePalette, .dark)
                .background(Color.black)
        )
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThanOrEqual(focusItems(in: fixture.window).count, 5)
        attachPreview(in: fixture.window, name: "library-navigation-editor")
    }

    private struct LibrarySettingsEnvironmentFixture: View {
        let cards: CardStyleSettingsModel
        let visibility: HomeLibraryVisibilityModel
        @Environment(LibraryPresentationSettingsModel.self) private var model
        @Environment(\.libraryPresentationLoader) private var loader

        var body: some View {
            if let loader {
                LibraryPresentationSettingsView(
                    model: model, cards: cards, visibility: visibility, accounts: [], loader: loader
                )
            } else {
                Text("Missing library settings environment")
            }
        }
    }

    private struct EmptyLibrarySettingsLoader: LibraryPresentationLoading {
        func libraries(accounts: [ResolvedAccount]) async -> LibraryPresentationDiscovery {
            .init(libraries: [], failures: [:])
        }

        func recommendations(
            library: AggregatedLibrary, account: ResolvedAccount
        ) async -> LibraryPresentationRecommendations {
            .init(state: .empty, diagnostic: nil)
        }
    }

    func testLiveSizeChangesReuseTheResolvedLogoAndPreserveItsProportions() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let url = try seedLogo(size: CGSize(width: 600, height: 100))
        defer { removeSeededLogo(url) }
        let item = MediaItem(id: UUID().uuidString, title: "Logo sizing", kind: .movie)
        let lookup = LookupProbe()
        let model = SizingModel()
        fixture.window.rootViewController = UIHostingController(rootView: SizingFixture(
            model: model, fallback: HeroLogoFallback(for: item) { await lookup.resolve(url) }
        ))
        try await waitUntil { model.resolutions == 1 && (try? redBounds(in: fixture.window)) != nil }
        let small = try XCTUnwrap(redBounds(in: fixture.window))
        model.size = HeroLogoSize(rawValue: 10)
        try await waitUntil { (try? redBounds(in: fixture.window))?.width ?? 0 > small.width * 1.45 }
        let large = try XCTUnwrap(redBounds(in: fixture.window))
        XCTAssertEqual(large.width / small.width, 1.5, accuracy: 0.02)
        XCTAssertEqual(large.height / small.height, 1.5, accuracy: 0.03)
        XCTAssertEqual(lookup.calls, 1)
        XCTAssertEqual(model.resolutions, 1, "Resizing must not restart logo preparation.")
        model.size = .default
        try await waitUntil { abs(((try? redBounds(in: fixture.window))?.width ?? 0) - small.width) < 2 }
        XCTAssertEqual(lookup.calls, 1)
    }

    func testLogoSizePreviewCapturesAtBothEnds() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        for surface in [HeroLogoSizing.Surface.home, .showcase, .detail] {
            for step in [-10, 0, 10] {
                let host = UIHostingController(rootView:
                    SettingsControlGroup {
                        HeroLogoSizeControl(size: .constant(HeroLogoSize(rawValue: step)), surface: surface)
                    }
                        .frame(width: 900)
                        .background(PreviewCardFrame())
                        .environment(\.colorScheme, .dark)
                        .environment(\.themePalette, .dark)
                        .background(Color.black)
                )
                fixture.window.rootViewController = host
                fixture.window.layoutIfNeeded()
                let card = try XCTUnwrap(findPreviewCard(in: host.view))
                XCTAssertEqual(card.bounds.width, 900, accuracy: 1)
                XCTAssertLessThanOrEqual(card.bounds.height, surface == .detail ? 360 : 300,
                                         "Only Detail gains space for the episode-caption preview.")
                let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                    XCTAssertTrue(fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true))
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "logo-size-\(surface)-\(step)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testTVPreviewArtworkMatchesLayoutCoverageAndFade() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        for surface in [HeroLogoSizing.Surface.home, .showcase, .detail] {
            let host = UIHostingController(rootView:
                HeroLogoSizePreview(
                    size: .default, surface: surface, layout: surface == .showcase ? .showcase : .television
                )
                .frame(width: 640, height: surface == .detail ? 480 : 360)
                .background(PreviewCardFrame())
                .background(Color.black)
            )
            fixture.window.rootViewController = host
            fixture.window.layoutIfNeeded()
            let preview = try XCTUnwrap(findPreviewCard(in: host.view))
            let frame = preview.convert(preview.bounds, to: fixture.window)
            let pixels = try rgbaPixels(
                in: fixture.window, rect: CGRect(x: frame.minX, y: frame.minY + 40, width: 640, height: 1)
            )
            let blue = (0..<640).map { Int(pixels[$0 * 4 + 2]) }
            if surface == .showcase {
                XCTAssertLessThan(try XCTUnwrap(blue[16..<210].max()), 35, "Keep the title side clear.")
                XCTAssertGreaterThan(blue[340] - blue[210], 100, "Artwork should fade into the right side.")
                let jumps = (145..<340).map { abs(blue[$0 + 1] - blue[$0]) }
                XCTAssertLessThanOrEqual(try XCTUnwrap(jumps.max()), 4, "No hard vertical artwork edge.")
            } else {
                XCTAssertGreaterThan(
                    try XCTUnwrap(blue[16..<300].min()), 100, "Fullscreen artwork must reach the left edge."
                )
            }
        }
    }

    func testCompactLogoCardKeepsNativeAdjustmentFocusWhileResizing() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let model = SizingModel()
        model.size = HeroLogoSize(rawValue: -10)
        let host = UIHostingController(rootView:
            SettingsControlGroup {
                HeroLogoSizeControl(
                    size: Binding(get: { model.size }, set: { model.size = $0 }), surface: .showcase
                )
            }
            .frame(width: 900)
            .background(PreviewCardFrame())
            .environment(\.colorScheme, .dark)
            .environment(\.themePalette, .dark)
            .background(Color.black)
        )
        fixture.window.rootViewController = host
        try await waitUntil { adjustmentInput(in: host) != nil }
        let input = try XCTUnwrap(adjustmentInput(in: host))
        defer { input.stopRepeating() }
        let system = try XCTUnwrap(UIFocusSystem(for: fixture.window))
        system.requestFocusUpdate(to: input)
        system.updateFocusIfNeeded()
        try await waitUntil { input.ownsHorizontalNavigationInput }
        let focused = try XCTUnwrap(system.focusedItem)
        let frame = focused.frame
        XCTAssertEqual(frame.width, 868, accuracy: 1, "No duplicate Home/Showcase preview beside the control.")
        for (index, size) in HeroLogoSize.allSizes.enumerated() {
            if index > 0 {
                input.beginPress(.right)
                input.stopRepeating()
                try await waitUntil { model.size == size }
            }
            XCTAssertTrue(system.focusedItem === focused)
            XCTAssertEqual(system.focusedItem?.frame, frame)
        }
        input.beginPress(.right)
        input.stopRepeating()
        XCTAssertEqual(model.size.rawValue, 10)
        try await Task.sleep(for: .milliseconds(200))
        fixture.window.layoutIfNeeded()
        let card = try XCTUnwrap(findPreviewCard(in: host.view))
        XCTAssertLessThanOrEqual(card.bounds.height, 300)
        let cardFrame = card.convert(card.bounds, to: fixture.window)
        let focusFrame = try focusFrame(focused, in: fixture.window)
        XCTAssertEqual(focusFrame.minY - cardFrame.minY, SettingsFormMetrics.groupInset, accuracy: 1)
        XCTAssertEqual(cardFrame.maxX - focusFrame.maxX, SettingsFormMetrics.groupInset, accuracy: 1)
        XCTAssertLessThanOrEqual(focusFrame.height, 100, "The shorter track stays beside its label.")
        let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
            fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "logo-size-compact-focused"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLayoutPickerUpdatesOnlyTheSelectedLogo() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let model = SizingModel()
        let host = LayoutFocusHost(rootView: LayoutSizingFixture(model: model))
        fixture.window.rootViewController = host
        try await waitUntil { adjustmentInput(in: host) != nil }
        try await Task.sleep(for: .milliseconds(200))
        fixture.window.layoutIfNeeded()
        let input = try XCTUnwrap(adjustmentInput(in: host))
        defer { input.stopRepeating() }
        let system = try XCTUnwrap(UIFocusSystem(for: fixture.window))
        host.target = try XCTUnwrap(focusItems(in: fixture.window).first { $0.frame.width > 800 })
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        try await waitUntil { input.ownsHorizontalNavigationInput }
        host.target = nil
        for style in HeroStyle.allCases {
            model.layout = style
            try await Task.sleep(for: .milliseconds(200))
            fixture.window.layoutIfNeeded()
            let picker = try XCTUnwrap(findPreviewCard(in: host.view, identifier: "logo-layout-picker-frame"))
            let frame = picker.convert(picker.bounds, to: fixture.window)
            let other: HeroStyle = style == .carousel ? .followsFocus : .carousel
            let baseline = try layoutWordmarkBounds(style: style, pickerFrame: frame, in: fixture.window)
            let otherBaseline = try layoutWordmarkBounds(style: other, pickerFrame: frame, in: fixture.window)
            for _ in HeroLogoSize.default.position..<(HeroLogoSize.allSizes.count - 1) {
                input.beginPress(.right)
                input.stopRepeating()
            }
            try await Task.sleep(for: .milliseconds(200))
            let large = try layoutWordmarkBounds(style: style, pickerFrame: frame, in: fixture.window)
            XCTAssertEqual(large.width / baseline.width, 1.5, accuracy: 0.04)
            XCTAssertEqual(large.maxY, baseline.maxY, accuracy: 2)
            XCTAssertEqual(try layoutWordmarkBounds(style: other, pickerFrame: frame, in: fixture.window), otherBaseline)
            attachPreview(in: fixture.window, name: "logo-layout-live-\(style)-large")
            for _ in 1..<HeroLogoSize.allSizes.count {
                input.beginPress(.left)
                input.stopRepeating()
            }
            try await Task.sleep(for: .milliseconds(200))
            let small = try layoutWordmarkBounds(style: style, pickerFrame: frame, in: fixture.window)
            XCTAssertEqual(small.width / baseline.width, 0.5, accuracy: 0.04)
            // The fictional text includes scaled font descent; trimmed real artwork is checked separately.
            XCTAssertEqual(small.maxY, baseline.maxY, accuracy: 4)
            XCTAssertEqual(try layoutWordmarkBounds(style: other, pickerFrame: frame, in: fixture.window), otherBaseline)
            attachPreview(in: fixture.window, name: "logo-layout-live-\(style)-small")
        }
    }

    private func attachPreview(in window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func textInkFrames(in image: UIImage, terms: [String]) throws -> [String: CGRect] {
        try HeroTextInk.frames(in: image, terms: terms)
    }

    private func layoutWordmarkBounds(style: HeroStyle, pickerFrame: CGRect, in window: UIWindow) throws -> CGRect {
        let inset = PlozzTheme.Metrics.Radius.inset
        let cardWidth = (pickerFrame.width - 16) / 2
        let scale = (cardWidth - inset * 2) / 1920
        let x = pickerFrame.minX + inset + (style == .carousel ? 0 : cardWidth + 16)
        let rect = CGRect(
            x: x + 120 * scale, y: pickerFrame.minY + inset + (style == .carousel ? 400 : 100) * scale,
            width: (style == .carousel ? 1200 : 800) * scale, height: (style == .carousel ? 270 : 165) * scale
        ).integral
        let pixels = try rgbaPixels(in: window, rect: rect)
        var bounds = CGRect.null
        for y in 0..<Int(rect.height) {
            for x in 0..<Int(rect.width) {
                let offset = (y * Int(rect.width) + x) * 4
                if pixels[offset] > 225 && pixels[offset + 1] > 225 && pixels[offset + 2] > 225 {
                    bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        XCTAssertFalse(bounds.isNull, "The layout choice must contain a real preview wordmark.")
        return bounds
    }

    private func adjustmentInput(in root: UIViewController) -> (any SettingsAdjustmentRemoteInput)? {
        if let input = root as? any SettingsAdjustmentRemoteInput { return input }
        return root.children.lazy.compactMap { self.adjustmentInput(in: $0) }.first
    }

    private func focusFrame(_ item: any UIFocusItem, in window: UIWindow) throws -> CGRect {
        var environment: (any UIFocusEnvironment)? = item
        var coordinateSpace: (any UICoordinateSpace)?
        while let current = environment {
            if let container = current.focusItemContainer {
                coordinateSpace = container.coordinateSpace
                break
            }
            environment = current.parentFocusEnvironment
        }
        return try XCTUnwrap(coordinateSpace).convert(item.frame, to: window)
    }

    private func focusItems(in window: UIWindow) -> [any UIFocusItem] {
        var containers: [any UIFocusItemContainer] = [window]
        var seen = Set<ObjectIdentifier>()
        var items: [ObjectIdentifier: any UIFocusItem] = [:]
        while let container = containers.popLast() {
            guard seen.insert(ObjectIdentifier(container)).inserted else { continue }
            let frame = container.coordinateSpace.convert(window.bounds, from: window)
            for item in container.focusItems(in: frame) {
                if let child = item.focusItemContainer { containers.append(child) }
                if let view = item as? UIView { containers.append(view) }
                if item.canBecomeFocused, !(item is UIScrollView) {
                    items[ObjectIdentifier(item)] = item
                }
            }
        }
        return Array(items.values)
    }

    private func findPreviewCard(in view: UIView, identifier: String = "logo-preview-card-frame") -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        return view.subviews.lazy.compactMap { self.findPreviewCard(in: $0, identifier: identifier) }.first
    }

    private struct PreviewCardFrame: UIViewRepresentable {
        var identifier = "logo-preview-card-frame"

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.isUserInteractionEnabled = false
            view.accessibilityIdentifier = identifier
            return view
        }

        func updateUIView(_ uiView: UIView, context: Context) {}
    }

    func testShowcaseEnlargementFitsTheExistingFootprintAndKeepsRowsFixed() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let url = try seedLogo(size: CGSize(width: 600, height: 100))
        defer { removeSeededLogo(url) }
        let item = MediaItem(
            id: UUID().uuidString, title: "Sized Showcase", kind: .movie,
            overview: "A long sample description that exercises the space reserved between the logo and the row.",
            logoURL: url,
            allowsTitleBasedMetadataMatching: false
        )
        for navigation in [NavigationStyle.rail, .tabBar] {
            var baseline: CGRect?
            var previousLogo: CGRect?
            var rowFrame: CGRect?
            for step in [-10, 0, 10] {
                var settings = HeroSettings.default
                settings.showcaseLogoSize = HeroLogoSize(rawValue: step)
                fixture.window.rootViewController = UIHostingController(rootView:
                    FocusHeroHomeView(
                        rows: [.init(id: "row", itemIDs: [item.stablePresentationID], leadItem: item, items: [item])],
                        settings: settings, spoilerSettings: .default,
                        navigationStyle: navigation, isFrontmost: true
                    ) { _, _ in
                        Color(uiColor: .blue).frame(height: 420)
                    }
                    .environment(\.themePalette, .dark)
                    .environment(\.colorScheme, .dark)
                )
                try await waitUntil { (try? redBounds(in: fixture.window)) != nil }
                try await Task.sleep(for: .milliseconds(200))
                let logo = try XCTUnwrap(redBounds(in: fixture.window))
                let row = try XCTUnwrap(colorBounds(in: fixture.window, channel: 2))
                XCTAssertGreaterThanOrEqual(logo.minY, 0)
                XCTAssertLessThan(logo.maxY + 100, row.minY, "Keep room for metadata above the pinned row.")
                XCTAssertEqual(logo.width / logo.height, 6, accuracy: 0.1)
                if let previousLogo {
                    XCTAssertGreaterThan(logo.width, previousLogo.width, "Increasing Logo size must not shrink its artwork.")
                }
                previousLogo = logo
                if let baseline, let rowFrame {
                    XCTAssertLessThanOrEqual(
                        logo.width / baseline.width, HeroLogoSize(rawValue: step).scale / 0.5 + 0.04
                    )
                    XCTAssertEqual(row, rowFrame)
                } else {
                    baseline = logo
                    rowFrame = row
                }
                let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                    fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "showcase-size-\(navigation)-\(step)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    @Observable fileprivate final class SizingModel {
        var size = HeroLogoSize.default
        var resolutions = 0
        var layout = HeroStyle.carousel
        var homeSize = HeroLogoSize.default
        var showcaseSize = HeroLogoSize.default
    }

    private struct LayoutSizingFixture: View {
        let model: SizingModel

        var body: some View {
            VStack(spacing: 24) {
                HomeLayoutPicker(
                    layout: Binding(get: { model.layout }, set: { model.layout = $0 }),
                    homeLogoSize: model.homeSize, showcaseLogoSize: model.showcaseSize
                )
                .background(PreviewCardFrame(identifier: "logo-layout-picker-frame"))
                SettingsControlGroup {
                    HeroLogoSizeControl(
                        size: Binding(
                            get: { model.layout == .carousel ? model.homeSize : model.showcaseSize },
                            set: {
                                if model.layout == .carousel { model.homeSize = $0 }
                                else { model.showcaseSize = $0 }
                            }
                        ),
                        surface: model.layout == .carousel ? .home : .showcase
                    )
                }
                .background(PreviewCardFrame())
            }
            .frame(width: 900)
            .environment(\.colorScheme, .dark)
            .environment(\.themePalette, .dark)
            .background(Color.black)
        }
    }

    private final class LayoutFocusHost<Content: View>: UIHostingController<Content> {
        weak var target: (any UIFocusEnvironment)?

        override var preferredFocusEnvironments: [any UIFocusEnvironment] {
            target.map { [$0] } ?? super.preferredFocusEnvironments
        }
    }

    private struct SizingFixture: View {
        let model: SizingModel
        let fallback: HeroLogoFallback

        var body: some View {
            let box = HeroLogoSizing.box(for: .showcase, size: model.size)
            Color.black.overlay {
                HeroLogoArtwork(
                    references: [], asyncFallbackURL: fallback, maxWidth: box.width,
                    maxHeight: box.height, constrainsToBounds: true,
                    onResolve: { _ in model.resolutions += 1 }
                ) { Color.clear }
            }.ignoresSafeArea()
        }
    }

    func testSelectiveLiftPaintsOnlyInDarkShowcase() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 140), format: format).image { context in
            ("NIGHT" as NSString).draw(at: CGPoint(x: 10, y: 25), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 76),
                .foregroundColor: UIColor(red: 0.04, green: 0.05, blue: 0.18, alpha: 1)
            ])
            ("SIGNAL" as NSString).draw(at: CGPoint(x: 275, y: 25), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 76),
                .foregroundColor: UIColor(red: 0.45, green: 0.03, blue: 0.04, alpha: 1)
            ])
            UIColor.white.setFill()
            context.fill(CGRect(x: 22, y: 55, width: 6, height: 6))
        }
        let url = try cacheLogo(image)
        defer { removeSeededLogo(url) }
        for (name, style, scheme) in [
            ("original", HeroLogoHaloStyle.standard, ColorScheme.dark),
            ("showcase", .showcase, .dark),
            ("light", .showcase, .light)
        ] {
            var resolved = false
            let palette: ThemePalette = scheme == .dark ? .dark : .light
            fixture.window.rootViewController = UIHostingController(rootView:
                palette.backgroundBase.overlay {
                    HeroLogoArtwork(
                        primaryURL: url, maxWidth: 600, maxHeight: 140,
                        constrainsToBounds: true, haloStyle: style,
                        onResolve: { _ in resolved = true }
                    ) { Color.clear }
                }
                .environment(\.colorScheme, scheme)
                .environment(\.themePalette, palette)
                .environment(\.gradientBackgroundsEnabled, false)
                .ignoresSafeArea()
            )
            try await waitUntil { resolved }
            try await Task.sleep(for: .milliseconds(300))
            let blue = try colorBounds(in: fixture.window, channel: 2, minimumChannel: 200, maximumOtherChannel: 80)
            let red = try colorBounds(in: fixture.window, channel: 0, minimumChannel: 200, maximumOtherChannel: 40)
            if name == "showcase" {
                XCTAssertNotNil(blue, "Dark blue lettering must actually paint brighter, not only exist in the cache.")
                XCTAssertNotNil(red, "Dark red lettering must stay saturated red, not turn pink.")
            } else {
                XCTAssertNil(blue, "The new correction must not alter other heroes or Light mode.")
                XCTAssertNil(red)
            }
            let screenshot = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "showcase-logo-contrast-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testColdShowcaseLogoAppearsWithoutLeavingAndReturningToTheTitle() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let url = try seedLogo(size: CGSize(width: 320, height: 100))
        defer { removeSeededLogo(url) }
        let item = MediaItem(id: UUID().uuidString, title: "Cold Showcase title", kind: .movie)
        fixture.window.rootViewController = UIHostingController(rootView:
            Color.black.overlay {
                HeroLogoArtwork(
                    references: [],
                    asyncFallbackURL: HeroLogoFallback(for: item) {
                        try? await Task.sleep(for: .milliseconds(500))
                        return url
                    },
                    maxWidth: FocusHeroLayout.logoBox.width,
                    maxHeight: FocusHeroLayout.logoBox.height,
                    constrainsToBounds: true,
                    presentationPolicy: FocusHeroLayout.logoPresentationPolicy
                ) {
                    Text(verbatim: item.title).foregroundStyle(.green)
                }
            }
            .ignoresSafeArea()
        )
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(try redBounds(in: fixture.window), "This must exercise a genuinely cold lookup.")
        XCTAssertNil(try colorBounds(in: fixture.window, channel: 1),
                     "Showcase must not flash a text title before the logo arrives.")
        try await waitUntil { (try? redBounds(in: fixture.window)) != nil }
        XCTAssertNotNil(try redBounds(in: fixture.window),
                        "A slow first lookup must not require a focus change to adopt the logo.")
    }

    func testCompactSeriesLogoStaysAboveSeasonsForTallSquareAndWideArtwork() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }

        for size in [CGSize(width: 120, height: 200), CGSize(width: 200, height: 200),
                     CGSize(width: 500, height: 100)] {
            let url = try seedLogo(size: size)
            defer { removeSeededLogo(url) }
            let series = MediaItem(
                id: UUID().uuidString, title: "Series fixture", kind: .series,
                backdropURL: url, logoURL: url
            )
            let model = SeriesHeroRecedeModel()
            model.isReceded = true
            let host = UIHostingController(rootView:
                Color.black.overlay(alignment: .top) {
                    SeriesEpisodeBrowser(
                        series: series, recedeModel: model, showsSeasons: true,
                        focusAnchorID: "logo-fixture",
                        seasonContent: {
                            Color.purple.frame(height: SeriesEpisodeBrowserLayout.seasonBarHeight)
                        },
                        episodeContent: { Color.blue }
                    )
                    .padding(.top, SeriesEpisodeBrowserLayout.browserColumnTopInset)
                }
                .ignoresSafeArea()
            )
            fixture.window.rootViewController = host
            fixture.window.layoutIfNeeded()
            try await waitUntil { (try? redBounds(in: fixture.window)) != nil }
            let bounds = try XCTUnwrap(redBounds(in: fixture.window))
            XCTAssertGreaterThan(bounds.height, 50, "A missing or clipped logo is not a spacing fix.")
            XCTAssertLessThanOrEqual(bounds.height, 201, "Source shape: \(size)")
            XCTAssertGreaterThanOrEqual(
                bounds.minY,
                SeriesEpisodeBrowserLayout.browserColumnTopInset
                    - SeriesEpisodeBrowserLayout.recededLogoHeight - 1
            )
            XCTAssertLessThanOrEqual(
                bounds.maxY, SeriesEpisodeBrowserLayout.browserColumnTopInset + 1,
                "The wordmark must not draw into the Seasons row."
            )
        }
    }

    func testCachedFallbackDoesNotAppearOnADifferentTitleWithoutALogo() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let url = try seedLogo(size: CGSize(width: 200, height: 100))
        defer { removeSeededLogo(url) }
        let first = MediaItem(id: UUID().uuidString, title: "First title", kind: .series)
        let second = MediaItem(id: UUID().uuidString, title: "No logo", kind: .series)
        let model = LogoModel(fallback: HeroLogoFallback(for: first) { url })
        fixture.window.rootViewController = UIHostingController(rootView: LookupFixture(model: model))
        try await waitUntil { model.tone != nil && (try? redBounds(in: fixture.window)) != nil }

        let missing = LookupProbe()
        model.tone = nil
        model.fallback = HeroLogoFallback(for: second) { await missing.resolve(nil) }
        try await waitUntil { missing.calls > 0 }
        XCTAssertNil(try redBounds(in: fixture.window), "A reused view must clear the previous title immediately.")
        XCTAssertNil(model.tone)

        fixture.window.rootViewController = UIHostingController(rootView: LookupFixture(
            model: LogoModel(fallback: HeroLogoFallback(for: second) { nil })
        ))
        fixture.window.layoutIfNeeded()
        XCTAssertNil(try redBounds(in: fixture.window), "A new detail/card view must not reuse another title's memo.")

        let returning = LogoModel(fallback: HeroLogoFallback(for: first) { url })
        fixture.window.rootViewController = UIHostingController(rootView: LookupFixture(model: returning))
        try await waitUntil { (try? redBounds(in: fixture.window)) != nil }
    }

    func testLateCancelledLookupCannotReplaceTheNewTitlesLogo() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let oldURL = try seedLogo(size: CGSize(width: 200, height: 100))
        let newURL = try seedLogo(size: CGSize(width: 200, height: 100), color: .blue)
        defer {
            removeSeededLogo(oldURL)
            removeSeededLogo(newURL)
        }
        let first = MediaItem(id: UUID().uuidString, title: "Old title", kind: .series)
        let second = MediaItem(id: UUID().uuidString, title: "Current title", kind: .series)
        let delayed = LookupProbe()
        defer { delayed.release() }
        let model = LogoModel(fallback: HeroLogoFallback(for: first) {
            await delayed.resolve(oldURL, waitsForRelease: true)
        })
        fixture.window.rootViewController = UIHostingController(rootView: LookupFixture(model: model))
        try await waitUntil { delayed.calls > 0 }
        model.fallback = HeroLogoFallback(for: second) { newURL }
        try await waitUntil { model.tone?.blue ?? 0 > 0.9 }
        delayed.release()
        try await waitUntil { delayed.completed }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(try redBounds(in: fixture.window))
        XCTAssertNotNil(try colorBounds(in: fixture.window, channel: 2))
        XCTAssertGreaterThan(try XCTUnwrap(model.tone).blue, 0.9)
    }

    @MainActor
    @Observable
    fileprivate final class LogoModel {
        var fallback: HeroLogoFallback
        var tone: ResolvedLogoTone?

        init(fallback: HeroLogoFallback) {
            self.fallback = fallback
        }
    }

    private struct LookupFixture: View {
        let model: LogoModel

        var body: some View {
            Color.black.overlay {
                HeroLogoArtwork(
                    references: [], asyncFallbackURL: model.fallback,
                    maxWidth: 400, maxHeight: 200, constrainsToBounds: true,
                    onResolve: { model.tone = $0 }
                ) {
                    Text("Title without a logo").foregroundStyle(.white)
                }
            }
            .ignoresSafeArea()
        }
    }

    @MainActor
    private final class LookupProbe {
        var calls = 0
        var completed = false
        private var continuation: CheckedContinuation<Void, Never>?

        func resolve(_ url: URL?, waitsForRelease: Bool = false) async -> URL? {
            calls += 1
            if waitsForRelease {
                await withCheckedContinuation { continuation = $0 }
            }
            completed = true
            return url
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func seedLogo(size: CGSize, color: UIColor = .red) throws -> URL {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: size.width + 20, height: size.height + 20), format: format
        ).image { context in
            color.setFill()
            context.fill(CGRect(origin: CGPoint(x: 10, y: 10), size: size))
        }
        return try cacheLogo(image)
    }

    private func cacheLogo(_ image: UIImage) throws -> URL {
        let url = try XCTUnwrap(URL(string: "https://logo-fixture.example.test/\(UUID()).png"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
        ))
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        cache.storeCachedResponse(
            CachedURLResponse(response: response, data: try XCTUnwrap(image.pngData())),
            for: URLRequest(url: url)
        )
        return url
    }

    private func removeSeededLogo(_ url: URL) {
        ArtworkSession.shared.configuration.urlCache?.removeCachedResponse(for: URLRequest(url: url))
    }

    private func redBounds(in window: UIWindow) throws -> CGRect? {
        try colorBounds(in: window, channel: 0)
    }

    private func rgbaPixels(in window: UIWindow, rect: CGRect) throws -> [UInt8] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: rect))
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: crop.width, height: crop.height, bitsPerComponent: 8,
            bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return pixels
    }

    private func colorBounds(
        in window: UIWindow, channel: Int, minimumChannel: UInt8 = 150, maximumOtherChannel: UInt8 = 80
    ) throws -> CGRect? {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        return try Self.colorBounds(
            in: image, channel: channel, minimumChannel: minimumChannel, maximumOtherChannel: maximumOtherChannel
        )
    }

    static func colorBounds(
        in image: UIImage, channel: Int, minimumChannel: UInt8 = 150, maximumOtherChannel: UInt8 = 80
    ) throws -> CGRect? {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var bounds = CGRect.null
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if pixels[offset + channel] > minimumChannel
                    && pixels[offset + (channel + 1) % 3] < maximumOtherChannel
                    && pixels[offset + (channel + 2) % 3] < maximumOtherChannel {
                    bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return bounds.isNull ? nil : bounds
    }

    private func makeFixture() async throws -> Fixture {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        return Fixture(scene: scene)
    }

    private func waitUntil(_ condition: @MainActor () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while try !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(try condition(), "Logo fixture did not settle.")
    }

    @MainActor
    private final class Fixture {
        let window: UIWindow
        let previous: UIWindow?

        init(scene: UIWindowScene) {
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = UIViewController()
            window.makeKeyAndVisible()
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }
}
