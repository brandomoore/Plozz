#if os(tvOS)
import CoreModels
@testable import TopShelfKit
import TVServices
import UIKit
import XCTest

final class TopShelfContentBuilderTests: XCTestCase {
    func testPosterPresentationKeepsSectionsShapeAndBothExistingActions() throws {
        let item = entry(account: "plex")
        let content = try XCTUnwrap(TopShelfContentBuilder.makeContent(from: snapshot(item: item))
            as? TVTopShelfSectionedContent)
        XCTAssertEqual(content.sections.map(\.title), ["Continue Watching", "Recently Added"])
        let poster = try XCTUnwrap(content.sections.first?.items.first)
        XCTAssertEqual(poster.imageShape, .poster)
        XCTAssertEqual(poster.imageURL(for: .screenScale1x), item.imageURL)
        XCTAssertEqual(poster.playAction?.url, TopShelf.itemDeepLink(id: item.id, accountID: "plex"))
        XCTAssertEqual(poster.displayAction?.url, poster.playAction?.url)
    }

    func testFullscreenUsesNativeDetailsAndDeduplicatesOnlyMatchingAccounts() throws {
        let item = entry(account: "plex")
        let content = try XCTUnwrap(TopShelfContentBuilder.makeContent(from: snapshot(item: item, fullScreen: true))
            as? TVTopShelfCarouselContent)
        XCTAssertEqual(content.style, .details)
        XCTAssertEqual(content.items.map(\.identifier), ["plex:123", "jellyfin:123"])
        let first = try XCTUnwrap(content.items.first)
        XCTAssertEqual(first.title, item.title)
        XCTAssertEqual(first.contextTitle, "Continue Watching · S1 · E2")
        XCTAssertEqual(first.summary, item.summary)
        XCTAssertEqual(first.genre, "Drama")
        XCTAssertEqual(first.duration, 3600)
        XCTAssertEqual(first.imageURL(for: .screenScale2x), item.imageURL)
        XCTAssertEqual(first.playAction?.url, TopShelf.itemDeepLink(id: "123", accountID: "plex"))
        XCTAssertEqual(content.items.last?.playAction?.url, TopShelf.itemDeepLink(id: "123", accountID: "jellyfin"))
        XCTAssertEqual(first.displayAction?.url,
                       TopShelf.itemDeepLink(id: "123", accountID: "plex", action: .details))
        XCTAssertNotEqual(first.displayAction?.url, first.playAction?.url)
        XCTAssertNil(first.previewVideoURL)
        XCTAssertNil(first.cinemagraphURL)
    }

    func testEmptySnapshotClearsBothStylesAndInvalidDurationIsNotExposed() throws {
        for fullScreen in [false, true] {
            XCTAssertNil(TopShelfContentBuilder.makeContent(from: .init(usesFullScreen: fullScreen, sections: [])))
            XCTAssertNil(TopShelfContentBuilder.makeContent(from: .init(
                usesFullScreen: fullScreen, sections: [.init(id: "empty", title: "Empty", items: [])]
            )))
        }
        var item = entry(account: "plex")
        item.duration = -.infinity
        let content = try XCTUnwrap(TopShelfContentBuilder.makeContent(from: snapshot(item: item, fullScreen: true))
            as? TVTopShelfCarouselContent)
        XCTAssertEqual(content.items.first?.duration, 0)
    }

    func testOldSnapshotDefaultsToPostersAndNewSnapshotRoundTrips() throws {
        let decoder = JSONDecoder()
        let old = try decoder.decode(TopShelfSnapshot.self, from: Data(#"""
        {"generatedAt":0,"sections":[{"id":"continue","title":"Continue Watching","items":[{"id":"1","title":"Old"}]}]}
        """#.utf8))
        XCTAssertFalse(old.usesFullScreen)
        XCTAssertNil(old.sections.first?.items.first?.summary)
        let new = snapshot(item: entry(account: "plex"), fullScreen: true)
        XCTAssertEqual(try decoder.decode(TopShelfSnapshot.self, from: JSONEncoder().encode(new)), new)
    }

    func testFullscreenUsesBackdropAndRespectsSpoilerProtectionAndLimits() async throws {
        let episode = MediaItem(
            id: "episode", title: "Revealing title", kind: .episode, overview: "Revealing summary",
            parentTitle: "Series", seasonNumber: 1, episodeNumber: 2,
            genres: ["Drama"], runtime: 3600,
            posterURL: URL(string: "https://example.com/episode.jpg"),
            fallbackArtworkURL: URL(string: "https://example.com/series.jpg"), sourceAccountID: "jellyfin"
        )
        let protected = await TopShelfPublisher.makeSnapshot(
            continueWatching: [episode, episode], latest: [episode, episode],
            settings: .init(usesFullScreen: true, continueWatchingItems: 1, recentlyAddedItems: 1),
            locale: Locale(identifier: "en_US"), spoilerSettings: .init(isEnabled: true),
            resolveArtwork: { _ in XCTFail("Fullscreen must not resolve poster artwork"); return nil }
        )
        let result = try XCTUnwrap(protected)
        XCTAssertTrue(result.usesFullScreen)
        XCTAssertEqual(result.sections.map { $0.items.count }, [1, 1])
        let published = try XCTUnwrap(result.sections.first?.items.first)
        XCTAssertEqual(published.imageURL, episode.fallbackArtworkURL)
        XCTAssertEqual(published.title, "Series — Episode 2")
        XCTAssertEqual(published.summary, "Series · S1 E2")
        XCTAssertEqual(published.genre, "Drama")
        XCTAssertEqual(published.duration, 3600)
        let native = try XCTUnwrap(TopShelfContentBuilder.makeContent(from: result) as? TVTopShelfCarouselContent)
        XCTAssertEqual(native.items.first?.summary, published.summary)
        let unprotected = await TopShelfPublisher.makeSnapshot(
            continueWatching: [episode], latest: [], settings: .init(usesFullScreen: true)
        )
        XCTAssertEqual(unprotected?.sections.first?.items.first?.summary, episode.overview)
    }

    func testDisabledFullscreenDoesNotResolveEitherArtworkType() async throws {
        let snapshot = await TopShelfPublisher.makeSnapshot(
            continueWatching: [MediaItem(id: "1", title: "Example", kind: .movie)], latest: [],
            settings: .init(isEnabled: false, usesFullScreen: true),
            resolveArtwork: { _ in XCTFail("Unexpected poster resolution"); return nil },
            resolveBackdrop: { _ in XCTFail("Unexpected backdrop resolution"); return nil }
        )
        XCTAssertTrue(try XCTUnwrap(snapshot).sections.isEmpty)
    }

    @MainActor
    func testOnlySelectedArtworkIsResolvedAndCancellationDropsFullscreenSnapshot() async throws {
        let item = MediaItem(id: "1", title: "Example", kind: .movie)
        var requests = 0
        let snapshot = await TopShelfPublisher.makeSnapshot(
            continueWatching: [item, item], latest: [],
            settings: .init(usesFullScreen: true, continueWatchingItems: 1),
            resolveArtwork: { _ in XCTFail("Poster resolver must stay idle"); return nil },
            resolveBackdrop: { _ in requests += 1; return nil }
        )
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(try XCTUnwrap(snapshot).usesFullScreen)
        let cancelled = Task {
            await TopShelfPublisher.makeSnapshot(
                continueWatching: [item], latest: [item], settings: .init(usesFullScreen: true),
                resolveBackdrop: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return nil
                }
            )
        }
        let result = await cancelled.value
        XCTAssertNil(result)
    }

    func testBackdropOutputIsBoundedLandscapeIncludingPlaceholderAndPortraitFallback() throws {
        for size in [CGSize(width: 1600, height: 900), CGSize(width: 400, height: 600)] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let source = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
                UIColor.red.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            let data = try XCTUnwrap(TopShelfBackdropComposer.imageData(data: source))
            XCTAssertLessThan(data.count, 1_000_000)
            let image = try XCTUnwrap(UIImage(data: data))
            XCTAssertEqual(image.size, CGSize(width: 1920, height: 1080))
        }
        let placeholder = try XCTUnwrap(TopShelfBackdropComposer.imageData(data: nil))
        XCTAssertEqual(UIImage(data: placeholder)?.size, CGSize(width: 1920, height: 1080))
    }

    func testNativeMetadataUsesMutuallyExclusiveBadgesAndAtMostFourAttributes() throws {
        var item = entry(account: "plex")
        item.releaseDate = MediaItem.calendarDayReleaseDate(from: "2022-09-12")
        item.mediaOptions = [.hd, .ultraHD, .hdr, .dolbyVision, .dolbyAtmos, .closedCaptions, .sdh]
        item.namedAttributes = (1...5).map { .init(name: "Field \($0)", values: ["Value \($0)"]) }
        let content = try XCTUnwrap(TopShelfContentBuilder.makeContent(from: snapshot(item: item, fullScreen: true))
            as? TVTopShelfCarouselContent)
        let native = try XCTUnwrap(content.items.first)
        XCTAssertEqual(native.creationDate,
                       item.releaseDate.flatMap { TopShelfContentBuilder.releaseDateForDisplay($0) })
        XCTAssertEqual(native.mediaOptions, [
            .videoResolution4K, .videoColorSpaceDolbyVision, .audioDolbyAtmos,
            .audioTranscriptionClosedCaptioning, .audioTranscriptionSDH
        ])
        XCTAssertEqual(native.namedAttributes.map(\.name), ["Field 1", "Field 2", "Field 3", "Field 4"])
        XCTAssertEqual(native.namedAttributes.first?.values, ["Value 1"])
        let roundTrip = try JSONDecoder().decode(TopShelfSnapshot.Item.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(roundTrip, item)
    }

    func testNativeReleaseDateRetainsCalendarDayAcrossTimeZones() throws {
        let date = try XCTUnwrap(MediaItem.calendarDayReleaseDate(from: "2022-01-01"))
        for offset in [-12 * 3600, 0, 14 * 3600] {
            let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: offset))
            let native = try XCTUnwrap(TopShelfContentBuilder.releaseDateForDisplay(date, timeZone: timeZone))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: native),
                           DateComponents(year: 2022, month: 1, day: 1))
        }
        XCTAssertNil(TopShelfContentBuilder.releaseDateForDisplay(Date(timeIntervalSince1970: .nan)))
    }

    private func entry(account: String) -> TopShelfSnapshot.Item {
        .init(id: "123", accountID: account, title: "Example", subtitle: "S1 · E2",
              imageURL: URL(string: "file:///tmp/backdrop.jpg"), summary: "Server synopsis", genre: "Drama", duration: 3600)
    }

    private func snapshot(item: TopShelfSnapshot.Item, fullScreen: Bool = false) -> TopShelfSnapshot {
        .init(usesFullScreen: fullScreen, sections: [
            .init(id: "continue", title: "Continue Watching", items: [item]),
            .init(id: "latest", title: "Recently Added", items: [item, entry(account: "jellyfin")])
        ])
    }
}
#endif
