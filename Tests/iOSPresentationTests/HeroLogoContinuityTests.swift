import CoreModels
@testable import CoreUI
import FeatureHomeCore
import MetadataKit
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import AppShelliOS

@MainActor
final class HeroLogoContinuityTests: XCTestCase {
    func testDetailNeverShowsTextWhileItsFirstLogoIsLoading() async throws {
        for style: HeroArtworkStyle in [.landscape, .compactPortrait] {
            for findsLogo in [true, false] {
                let fixture = try Fixture()
                defer { fixture.close() }
                let url = try fixture.seedLogo()
                let item = MediaItem(id: UUID().uuidString, title: "Movie title", kind: .movie)
                let lookup = LookupGate()
                defer { lookup.release(nil) }
                fixture.host.rootView = AnyView(DetailMetadataFixture(
                    state: SubjectState(item: item), root: item, style: style,
                    fallback: HeroLogoFallback(for: item) { await lookup.resolve() }
                ))
                try await waitUntil { lookup.calls == 1 }
                XCTAssertFalse(try fixture.hasTitleText(), "Text is a failed-lookup fallback, not a loading placeholder.")
                XCTAssertFalse(try fixture.hasRedLogo())
                lookup.release(findsLogo ? url : nil)
                if findsLogo {
                    try await waitUntil { try fixture.hasRedLogo() }
                    XCTAssertFalse(try fixture.hasTitleText())
                } else {
                    try await waitUntil { try fixture.hasTitleText() }
                    XCTAssertFalse(try fixture.hasRedLogo())
                }
            }
        }
    }

    func testDetailWithoutLogoSourcesShowsItsTitle() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let item = MediaItem(id: UUID().uuidString, title: "Movie title", kind: .movie)
        fixture.host.rootView = AnyView(DetailMetadataFixture(state: SubjectState(item: item), root: item))
        try await waitUntil { try fixture.hasTitleText() }
        XCTAssertFalse(try fixture.hasRedLogo())
    }

    func testArtworkPolicyChangesAndRemovedIdentityCannotRetainALogo() {
        let original = MediaItem(
            id: "movie", title: "Movie", kind: .movie, productionYear: 2020,
            providerIDs: ["Tmdb": "123"], sourceAccountID: "server"
        )
        func key(
            _ item: MediaItem, prefersOnlineArtwork: Bool = false,
            providerPolicyIdentity: String = "default"
        ) -> HeroLogoMemo.Key {
            HeroLogoMemo.Key(
                references: [], fallback: HeroLogoFallback(for: item) { nil }.identity,
                prefersOnlineArtwork: prefersOnlineArtwork,
                providerPolicyIdentity: providerPolicyIdentity
            )
        }
        let baseline = key(original)
        XCTAssertTrue(baseline.canRetainImage(from: baseline))
        XCTAssertFalse(key(original, prefersOnlineArtwork: true).canRetainImage(from: baseline))
        XCTAssertFalse(key(original, providerPolicyIdentity: "changed").canRetainImage(from: baseline))
        var changed = original
        changed.productionYear = 2021
        XCTAssertFalse(key(changed).canRetainImage(from: baseline))
        changed = original
        changed.productionYear = nil
        XCTAssertFalse(key(changed).canRetainImage(from: baseline))
        changed = original
        changed.providerIDs = [:]
        XCTAssertFalse(key(changed).canRetainImage(from: baseline))
        changed = original
        changed.kind = .series
        XCTAssertFalse(key(changed).canRetainImage(from: baseline))
    }

    func testAddedAnimeIdentityCanRetainLogoButCorrectionsCannot() {
        let show = MediaItem(
            id: "show", title: "Show", kind: .series,
            providerIDs: ["Tmdb": "123"], sourceAccountID: "server"
        )
        func key(_ item: MediaItem) -> HeroLogoMemo.Key {
            HeroLogoMemo.key(for: [], fallback: HeroLogoFallback(for: item) { nil })
        }
        var enriched = show
        enriched.providerIDs["AniList"] = "456"
        XCTAssertNotEqual(key(enriched), key(show), "Richer identity must still trigger a fresh lookup.")
        XCTAssertTrue(key(enriched).canRetainImage(from: key(show)))
        XCTAssertFalse(key(show).canRetainImage(from: key(enriched)), "Removing an established ID is not enrichment.")
        var corrected = enriched
        corrected.providerIDs["AniList"] = "789"
        XCTAssertFalse(key(corrected).canRetainImage(from: key(enriched)))
        corrected = enriched
        corrected.providerIDs["Tmdb"] = "321"
        XCTAssertFalse(key(corrected).canRetainImage(from: key(show)))
    }

    func testTabletDetailKeepsShowLogoWhenItsPlayEpisodeArrives() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let url = try fixture.seedLogo()
        let show = MediaItem(
            id: "show", title: "Show", kind: .series, logoURL: url,
            allowsTitleBasedMetadataMatching: false, sourceAccountID: "server"
        )
        let state = SubjectState(item: show)
        fixture.host.rootView = AnyView(DetailMetadataFixture(state: state, root: show))
        try await waitUntil { try fixture.hasRedLogo() }
        let episode = MediaItem(
            id: "episode", title: "Episode", kind: .episode,
            parentTitle: show.title, seriesID: show.id,
            allowsTitleBasedMetadataMatching: false, sourceAccountID: "server"
        )
        for item in [episode, show, episode] {
            state.item = item
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(try fixture.hasRedLogo(), "The show identity must not follow the Play episode.")
        }
    }

    func testVisibleLogoSurvivesAdditiveMetadataWhileReplacementResolves() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let url = try fixture.seedLogo()
        let original = MediaItem(id: UUID().uuidString, title: "Movie", kind: .movie, sourceAccountID: "server")
        let state = LookupState(fallback: HeroLogoFallback(for: original) { url })
        fixture.host.rootView = AnyView(LookupFixture(state: state))
        try await waitUntil { try state.resolutions == 1 && fixture.hasRedLogo() }

        var enriched = original
        enriched.productionYear = 2026
        enriched.providerIDs["Tmdb"] = "123"
        let lookup = LookupGate()
        defer { lookup.release(url) }
        state.fallback = HeroLogoFallback(for: enriched) { await lookup.resolve() }
        try await waitUntil { lookup.calls == 1 }
        XCTAssertTrue(try fixture.hasRedLogo(), "Adding identity metadata must not flash the text fallback.")
        lookup.release(url)
        try await waitUntil { state.resolutions == 2 }
        XCTAssertTrue(try fixture.hasRedLogo())
    }

    func testEpisodeContextKeepsShowLogoWhenGenresArrive() async throws {
        for style: HeroArtworkStyle in [.landscape, .compactPortrait] {
            let fixture = try Fixture()
            defer { fixture.close() }
            let url = try fixture.seedLogo()
            let show = MediaItem(
                id: UUID().uuidString, title: "Animated show", kind: .series,
                providerIDs: ["Tmdb": "123"], sourceAccountID: "server"
            )
            let episode = MediaItem(
                id: UUID().uuidString, title: "New episode", kind: .episode,
                parentTitle: show.title, seriesID: show.id, sourceAccountID: "server"
            )
            let state = SubjectState(item: episode)
            fixture.host.rootView = AnyView(DetailMetadataFixture(
                state: state, root: show, style: style,
                fallback: HeroLogoFallback(for: show) { url }
            ))
            try await waitUntil { try fixture.hasRedLogo() }

            let enriched = DetailMetadataResolver.applying(
                MetadataEnrichment(genres: .init(value: ["Anime"], source: .tmdb)),
                to: show
            )
            XCTAssertEqual(ContentClassifier.classify(show), .tvShow)
            XCTAssertEqual(ContentClassifier.classify(enriched), .anime)
            let lookup = LookupGate()
            defer { lookup.release(url) }
            fixture.host.rootView = AnyView(DetailMetadataFixture(
                state: state, root: enriched, style: style,
                fallback: HeroLogoFallback(for: enriched) { await lookup.resolve() }
            ))
            try await waitUntil { lookup.calls == 1 }
            XCTAssertTrue(try fixture.hasRedLogo(), "Genre enrichment must not remove the same show's visible logo.")
            XCTAssertFalse(try fixture.hasTitleText())
            lookup.release(url)
            try await waitUntil { try fixture.hasRedLogo() }
        }
    }

    func testChangedSubjectOrCorrectedIdentityCannotKeepThePreviousLogo() async throws {
        for change in ["item", "account", "provider", "language", "title"] {
            let fixture = try Fixture()
            defer { fixture.close() }
            let url = try fixture.seedLogo()
            let original = MediaItem(
                id: UUID().uuidString, title: "Movie", kind: .movie,
                providerIDs: ["Tmdb": "123"], sourceAccountID: "server"
            )
            let state = LookupState(fallback: HeroLogoFallback(for: original) { url })
            fixture.host.rootView = AnyView(LookupFixture(state: state))
            try await waitUntil { try state.resolutions == 1 && fixture.hasRedLogo() }
            var changed = original
            switch change {
            case "item": changed.id = "different"
            case "account": changed.sourceAccountID = "another-server"
            case "provider": changed.providerIDs["Tmdb"] = "456"
            case "title": changed.title = "Corrected movie"
            default: break
            }
            let lookup = LookupGate()
            defer { lookup.release(nil) }
            state.fallback = HeroLogoFallback(for: changed) { await lookup.resolve() }
            if change == "language" { state.language = "fr" }
            try await waitUntil { lookup.calls == 1 }
            XCTAssertFalse(try fixture.hasRedLogo(), change)
            lookup.release(nil)
        }
    }

    func testConfirmedMissingReplacementFallsBackToText() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let url = try fixture.seedLogo()
        let original = MediaItem(id: UUID().uuidString, title: "Movie", kind: .movie)
        let state = LookupState(fallback: HeroLogoFallback(for: original) { url })
        fixture.host.rootView = AnyView(LookupFixture(state: state))
        try await waitUntil { try state.resolutions == 1 && fixture.hasRedLogo() }
        var enriched = original
        enriched.providerIDs["Tmdb"] = "123"
        let lookup = LookupGate()
        defer { lookup.release(nil) }
        state.fallback = HeroLogoFallback(for: enriched) { await lookup.resolve() }
        try await waitUntil { lookup.calls == 1 }
        lookup.release(nil)
        try await waitUntil { try !fixture.hasRedLogo() }
    }

    private func waitUntil(_ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(try condition())
    }

    @Observable fileprivate final class SubjectState {
        var item: MediaItem
        init(item: MediaItem) { self.item = item }
    }

    private struct DetailMetadataFixture: View {
        let state: SubjectState
        let root: MediaItem
        var style: HeroArtworkStyle = .landscape
        var fallback: HeroLogoFallback? = nil
        var body: some View {
            PlozziOSHeroMetadata(
                presentation: HeroPresentation(item: state.item, artworkStyle: style, surface: .detail),
                style: style, mode: .detail,
                fallbackPresentation: HeroPresentation(item: root, artworkStyle: style, surface: .detail),
                logoFallback: fallback,
                content: .identity
            )
            .environment(\.themePalette, .dark)
            .environment(\.plozzArtworkSettings, ArtworkSettings(preference: .library))
            .frame(width: 400, height: 250)
            .background(.black)
        }
    }

    @Observable fileprivate final class LookupState {
        var fallback: HeroLogoFallback
        var language = "en"
        var resolutions = 0
        init(fallback: HeroLogoFallback) { self.fallback = fallback }
    }

    private struct LookupFixture: View {
        let state: LookupState
        var body: some View {
            HeroLogoArtwork(
                references: [], asyncFallbackURL: state.fallback,
                maxWidth: 300, maxHeight: 100, constrainsToBounds: true,
                onResolve: { _ in state.resolutions += 1 }
            ) {
                Text("Text fallback").foregroundStyle(.white)
            }
            .environment(\.locale, Locale(identifier: state.language))
            .frame(width: 400, height: 250)
            .background(.black)
        }
    }

    private final class LookupGate {
        var calls = 0
        private var continuation: CheckedContinuation<URL?, Never>?
        func resolve() async -> URL? {
            calls += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        func release(_ url: URL?) {
            continuation?.resume(returning: url)
            continuation = nil
        }
    }

    private final class Fixture {
        let window: UIWindow
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        let previous: UIWindow?
        private var urls: [URL] = []

        init() throws {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 400, height: 250)
            host.safeAreaRegions = []
            window.rootViewController = host
            window.makeKeyAndVisible()
        }

        func seedLogo() throws -> URL {
            let url = try XCTUnwrap(URL(string: "https://logo-continuity.invalid/\(UUID()).png"))
            let image = UIGraphicsImageRenderer(size: CGSize(width: 220, height: 80)).image {
                UIColor.red.setFill()
                $0.fill(CGRect(x: 10, y: 10, width: 200, height: 60))
            }
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
            ))
            let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
            cache.storeCachedResponse(
                CachedURLResponse(response: response, data: try XCTUnwrap(image.pngData())),
                for: URLRequest(url: url)
            )
            urls.append(url)
            return url
        }

        func hasRedLogo() throws -> Bool {
            try hasVisiblePixels { $0 > 180 && $1 < 70 && $2 < 70 }
        }

        func hasTitleText() throws -> Bool {
            try hasVisiblePixels { $0 > 180 && $1 > 180 && $2 > 180 }
        }

        private func hasVisiblePixels(_ matches: (UInt8, UInt8, UInt8) -> Bool) throws -> Bool {
            window.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let cgImage = try XCTUnwrap(image.cgImage)
            var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
            try bytes.withUnsafeMutableBytes {
                let context = try XCTUnwrap(CGContext(
                    data: $0.baseAddress, width: cgImage.width, height: cgImage.height,
                    bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            }
            return stride(from: 0, to: bytes.count, by: 4).filter {
                matches(bytes[$0], bytes[$0 + 1], bytes[$0 + 2])
            }.count > 300
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            for url in urls {
                ArtworkSession.shared.configuration.urlCache?.removeCachedResponse(for: URLRequest(url: url))
            }
        }
    }
}
