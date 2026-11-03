import XCTest
@testable import CoreModels

final class ExternalMediaLinkTests: XCTestCase {
    func testRealMediaIsPreferredOverALocalExternalLink() {
        let external = MediaSourceRef(accountID: "share", itemID: "link", locality: .local,
                                      versions: [.init(id: "movie.strmlnk", container: "strmlnk")])
        let playable = MediaSourceRef(accountID: "plex", itemID: "movie", locality: .remote)
        let best = CrossSourceSelector.bestSelection(from: [external, playable], capabilities: .init())
        XCTAssertEqual(best?.source.accountID, "plex")
        let onlyLink = CrossSourceSelector.bestSelection(from: [external], capabilities: .init())
        XCTAssertEqual(onlyLink?.source.accountID, "share")
    }

    func testSupportedOfficialTitleLinksAndBOM() throws {
        let examples: [(String, ExternalMediaLink.Service)] = [
            ("https://tv.apple.com/us/movie/example/umc.example", .appleTV),
            ("https://www.primevideo.com/detail/B012345678", .primeVideo),
            ("https://www.amazon.com/gp/video/detail/B012345678", .primeVideo),
            ("https://www.youtube.com/watch?v=abcdefghijk", .youTube),
            ("https://youtu.be/abcdefghijk", .youTube),
            ("https://moviesanywhere.com/movie/example", .moviesAnywhere),
            ("https://athome.fandango.com/content/browse/details/Example/123", .fandango)
        ]
        for (url, service) in examples {
            let link = try ExternalMediaLink(contents: Data("\u{FEFF}\(url)\r\n".utf8))
            XCTAssertEqual(link.service, service)
            XCTAssertEqual(link.url.absoluteString, url)
            let decoded = try JSONDecoder().decode(ExternalMediaLink.self, from: JSONEncoder().encode(link))
            XCTAssertEqual(decoded, link)
        }
    }

    func testUntrustedSchemesHostsCredentialsAndOversizedFilesAreRejected() {
        for text in [
            "", "https://tv.apple.com/", "file:///etc/passwd", "javascript:alert(1)",
            "http://tv.apple.com/us/movie/example/id",
            "https://tv.apple.com.evil.example/us/movie/example/id",
            "https://tv.apple.com@evil.example/us/movie/example/id",
            "https://user:password@tv.apple.com/us/movie/example/id",
            "https://tv.apple.com:444/us/movie/example/id",
            "https://www.youtube.com/watch", "https://youtu.be/invalid",
            "https://tv.apple.com/us/movie/\u{0000}id",
            "https://tv.apple.com/us/movie/example/id\nhttps://www.youtube.com/watch?v=x"
        ] {
            XCTAssertThrowsError(try ExternalMediaLink(contents: Data(text.utf8)), text)
        }
        XCTAssertThrowsError(try ExternalMediaLink(contents: Data(repeating: 65, count: 8_193)))
        XCTAssertThrowsError(try ExternalMediaLink(contents: Data([0xFF, 0xFE])))
        let invalid = Data(#"{"url":"https://evil.example/movie","service":"appleTV"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ExternalMediaLink.self, from: invalid))
    }

    func testExternalSelectionPreservesOwnershipAndHasNoResumeOrDownloadAction() throws {
        let link = try ExternalMediaLink(contents: Data("https://tv.apple.com/us/movie/example/id".utf8))
        let external = MediaVersion(id: "movie.strmlnk", container: "strmlnk", externalLink: link)
        let file = MediaVersion(id: "movie.mkv", height: 1080, container: "mkv")
        var item = MediaItem(id: "movie:a", title: "Movie", kind: .movie, runtime: 120,
                             resumePosition: 60, versions: [external, file])
        XCTAssertFalse(item.opensExternalSource)
        XCTAssertEqual(item.versions.sortedForPicker().first?.id, file.id)
        item = item.selectingVersion(external.id)
        XCTAssertTrue(item.opensExternalSource)
        XCTAssertNil(item.resumeProgressFraction)
        XCTAssertNil(item.resumeRemainingText)
        XCTAssertEqual(String(localized: item.playActionTitle), "Open in Apple TV")
        XCTAssertFalse(MediaItemActionCatalog.actions(
            for: item, supportsWatchState: true, downloadState: .some(nil)
        ).contains(.startDownload))
        let qualified = external.qualified(accountID: "share-account", itemID: "movie:a")
        XCTAssertEqual(qualified.externalLink, link)
        XCTAssertEqual(qualified.playbackMediaSourceID, "movie.strmlnk")
        let roundTrip = try JSONDecoder().decode(MediaVersion.self, from: JSONEncoder().encode(qualified))
        XCTAssertEqual(roundTrip, qualified)
        XCTAssertTrue(MediaVersion.PickerPresentation(external).badges.isEmpty)
    }
}
