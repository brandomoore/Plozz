import CoreModels
import CoreNetworking
import Foundation
@testable import ProviderIPTV
import XCTest

final class IPTVProviderTests: XCTestCase {
    func testArrayStreamingAcrossEveryByteBoundary() throws {
        let input = Data(#"[{"name":"quote \" and } [","id":1},{"name":"雪","id":"2"}]"#.utf8)
        for size in 1...input.count {
            var parser = IPTVJSONArrayStream()
            var values: [Data] = []
            for start in stride(from: 0, to: input.count, by: size) {
                try parser.append(input.subdata(in: start..<min(start + size, input.count))) { values.append($0) }
            }
            try parser.finish()
            XCTAssertEqual(values.count, 2)
            XCTAssertEqual(try JSONDecoder().decode(IPTVObject.self, from: values[1]).text("name"), "雪")
        }
    }

    func testArrayStreamRejectsTruncationTrailingDataAndTrailingComma() throws {
        for input in [#"[{"id":1}"#, #"[{"id":1},]"#, #"[{"id":1}] false"#, #"[{"id":1}{"id":2}]"#] {
            XCTAssertThrowsError(try {
                var parser = IPTVJSONArrayStream()
                try parser.append(Data(input.utf8)) { _ in }
                try parser.finish()
            }())
        }
    }

    func testCatalogStreamDoesNotRejectOrAccumulateMoreThanOneHundredThousandEntries() throws {
        var parser = M3UPlaylistParser().makeCatalogStream()
        try parser.append(Data("#EXTM3U\n".utf8))
        let entry = Data("#EXTINF:-1,Channel\nhttps://provider.example/live/1.ts\n".utf8)
        var count = 0
        for _ in 0...M3UPlaylistParser.maximumEntries {
            try parser.append(entry)
            let entries = parser.takeCatalogEntries()
            XCTAssertLessThanOrEqual(entries.count, 1)
            count += entries.count
        }
        let result = try parser.finish()
        XCTAssertEqual(count, 100_001)
        XCTAssertEqual(result.entryCount, count)
        XCTAssertTrue(result.channels.isEmpty)
    }

    func testPlaylistMapsLiveMoviesAndEpisodesSeparately() throws {
        var parser = M3UPlaylistParser().makeCatalogStream()
        try parser.append(Data("""
        #EXTM3U
        #EXTINF:-1 tvg-id="news",News
        https://provider.example/live/u/p/1.ts
        #EXTINF:-1,Movie
        https://provider.example/movie/u/p/2.mkv
        #EXTINF:-1,Series S02E03
        https://provider.example/series/u/p/3.mp4

        """.utf8))
        _ = try parser.finish()
        let records = parser.takeCatalogEntries().flatMap(IPTVMapping.playlistEntry)
        XCTAssertEqual(records.map(\.item.kind), [.video, .movie, .series, .season, .episode])
        XCTAssertEqual(records.filter(\.isLive).count, 1)
        XCTAssertEqual(records.last?.item.seasonNumber, 2)
        XCTAssertEqual(records.last?.item.episodeNumber, 3)
        XCTAssertEqual(records.last?.item.seriesID, records[2].item.id)
    }

    func testCatalogStreamExceedsLegacyByteLimitWithBoundedLineStorage() throws {
        var parser = M3UPlaylistParser().makeCatalogStream()
        try parser.append(Data("#EXTM3U\n".utf8))
        let comment = Data(("#" + String(repeating: "x", count: 65_534) + "\n").utf8)
        while parser.byteCount <= M3UPlaylistParser.maximumBytes {
            try parser.append(comment)
            XCTAssertLessThanOrEqual(parser.bufferedByteCount, M3UPlaylistParser.maximumLineBytes + 3)
            XCTAssertTrue(parser.takeCatalogEntries().isEmpty)
        }
        try parser.append(Data("#EXTINF:-1,News\nhttps://provider.example/live/news.ts\n".utf8))
        let result = try parser.finish()
        XCTAssertEqual(result.entryCount, 1)
        XCTAssertEqual(parser.takeCatalogEntries().count, 1)
        XCTAssertGreaterThan(parser.byteCount, 128 * 1_024 * 1_024)
    }

    func testCatalogAcceptsOversizedOptionalHeaderWithoutRetainingIt() throws {
        var parser = M3UPlaylistParser().makeCatalogStream()
        try parser.append(Data(("#EXTM3U " + String(repeating: "x", count: 70_000)
            + "\n#EXTINF:-1,News\nhttps://provider.example/live/news.ts\n").utf8))
        XCTAssertEqual(try parser.finish().entryCount, 1)
        XCTAssertEqual(parser.takeCatalogEntries().count, 1)
    }

    func testRedirectsRemoveHeadersAndRejectCopiedSecretsAndDowngrades() throws {
        let origin = try XCTUnwrap(URL(string: "https://provider.example/list?password=fixture-secret"))
        var original = URLRequest(url: origin)
        original.setValue("Bearer fixture-token", forHTTPHeaderField: "Authorization")
        original.setValue("session=fixture-cookie", forHTTPHeaderField: "Cookie")
        original.setValue("private", forHTTPHeaderField: "X-Provider-Key")
        var redirected = original
        redirected.url = URL(string: "https://cdn.example/video?signature=new-cdn-grant")
        redirected.setValue("bytes=10-", forHTTPHeaderField: "Range")
        let safe = try XCTUnwrap(IPTVRedirectPolicy.request(redirected, previous: origin, original: original))
        XCTAssertNil(safe.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(safe.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(safe.value(forHTTPHeaderField: "X-Provider-Key"))
        XCTAssertEqual(safe.value(forHTTPHeaderField: "Range"), "bytes=10-")
        for destination in [
            "http://provider.example/video", "https://cdn.example/fixture-secret",
            "https://cdn.example/fixture-token"
        ] {
            redirected.url = URL(string: destination)
            XCTAssertNil(IPTVRedirectPolicy.request(redirected, previous: origin, original: original))
        }
        redirected.url = URL(string: "https://cdn.example/movie/user/xtream-password/10.mp4")
        XCTAssertNil(IPTVRedirectPolicy.request(
            redirected, previous: origin, original: original, sensitiveValues: ["xtream-password"]
        ))
    }

    func testDiscardedImportDoesNotReplaceVisibleRecordsForAnotherConnection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credential = try IPTVCredential(mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.example/list")))
        let url = root.appendingPathComponent("catalog.sqlite")
        let first = try IPTVCatalog(url: url, key: credential.catalogKey)
        let second = try IPTVCatalog(url: url, key: credential.catalogKey)
        try first.insert(IPTVRecord(item: MediaItem(id: "movie:old", title: "Original", kind: .movie, libraryID: "movies")))
        try first.beginImport()
        try first.insert(IPTVRecord(item: MediaItem(id: "movie:new", title: "Replacement", kind: .movie, libraryID: "movies")), into: .incoming)
        XCTAssertEqual(try second.count(where: "1 = 1"), 1)
        XCTAssertEqual(try second.record("movie:old").item.title, "Original")
        try second.beginImport()
        try second.insert(IPTVRecord(item: MediaItem(id: "live:1", title: "News", kind: .video, libraryID: "live")), into: .incoming)
        try second.commitImport(library: "live", scope: "live")
        first.discardImport()
        second.discardImport()
        XCTAssertEqual(try first.count(where: "1 = 1"), 2)
        XCTAssertThrowsError(try first.record("movie:new"))
    }

    func testCredentialMovesUserInfoIntoHeaderAndKeepsItOutOfDescription() throws {
        let credential = try IPTVCredential(
            mode: .playlist, address: XCTUnwrap(URL(string: "https://viewer:private-pass@provider.example/list.m3u"))
        )
        XCTAssertNil(credential.address.user)
        XCTAssertNil(credential.address.password)
        XCTAssertEqual(credential.headers["Authorization"], "Basic " + Data("viewer:private-pass".utf8).base64EncodedString())
        XCTAssertFalse(credential.description.contains("private-pass"))
        XCTAssertEqual(credential, try IPTVCredential.decode(credential.encoded()))
        XCTAssertTrue(try credential.headers(for: XCTUnwrap(URL(string: "https://cdn.example/stream"))).isEmpty)
        XCTAssertTrue(try credential.headers(for: XCTUnwrap(URL(string: "http://provider.example/stream"))).isEmpty)
    }

    func testCredentialRejectsInjectedAndHopByHopHeaders() throws {
        for headers in [["Cookie": "a=b\r\nInjected: yes"], ["Host": "foreign.example"], ["X-Key": "one", "x-key": "two"]] {
            XCTAssertThrowsError(try IPTVCredential(
                mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.example/list")), headers: headers
            ))
        }
    }

    func testCatalogPersistsSealedDeliveryAndReturnsStablePages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credential = try IPTVCredential(mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.example/list")))
        let url = root.appendingPathComponent("catalog.sqlite")
        do {
            let catalog = try IPTVCatalog(url: url, key: credential.catalogKey)
            for index in 0..<101 {
                try catalog.insert(IPTVRecord(
                    item: MediaItem(id: "movie:\(index)", title: String(format: "%03d", index), kind: .movie, libraryID: "movies"),
                    streamURL: XCTUnwrap(URL(string: "https://provider.example/movie/private-password/\(index).mp4"))
                ))
            }
            XCTAssertEqual(try catalog.records(where: "library = ?", values: ["movies"], start: 60, limit: 30).count, 30)
            XCTAssertEqual(try catalog.count(where: "library = ?", values: ["movies"]), 101)
        }
        let bytes = try Data(contentsOf: url)
        XCTAssertNil(bytes.range(of: Data("private-password".utf8)))
        let restored = try IPTVCatalog(url: url, key: credential.catalogKey)
        XCTAssertEqual(try restored.record("movie:4").streamURL?.lastPathComponent, "4.mp4")
    }

    func testM3UHeaderAuthenticationIsOptInAndPreservedByCatalogParser() throws {
        let input = """
        #EXTM3U
        #EXTINF:-1,Private
        https://provider.example/live/1.ts|Authorization=Bearer%20fixture&Cookie=session%3Dfixture&X-Provider-Key=fixture

        """
        var parser = M3UPlaylistParser(permitsAuthenticationHeaders: true).makeCatalogStream()
        try parser.append(Data(input.utf8))
        _ = try parser.finish()
        let entry = try XCTUnwrap(parser.takeCatalogEntries().first)
        XCTAssertEqual(entry.channel.httpHeaders["Authorization"], "Bearer fixture")
        XCTAssertEqual(entry.channel.httpHeaders["Cookie"], "session=fixture")
        XCTAssertEqual(entry.channel.httpHeaders["X-Provider-Key"], "fixture")
        XCTAssertTrue(try M3UPlaylistParser().parse(input).channels[0].httpHeaders.isEmpty)
    }
}
