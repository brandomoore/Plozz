import Foundation
import CoreModels
import CoreNetworking
import XCTest
@testable import FeatureLiveTVCore

final class LiveTVPlaylistParserTests: XCTestCase {
    func testEmptyResponsesWithoutAPlaylistHeaderStillFail() throws {
        for input in [
            "", " \r\n\t", "# Playlist awaiting channels\n", "#EXTM3Uinvalid\n"
        ] {
            XCTAssertThrowsError(try LiveTVPlaylistParser().parse(input)) {
                XCTAssertEqual($0 as? LiveTVSourceImportError, .emptyPlaylist)
            }
            var stream = M3UPlaylistParser().makeCatalogStream()
            for byte in input.utf8 { try stream.append(byte) }
            XCTAssertThrowsError(try stream.finish()) {
                XCTAssertEqual($0 as? LiveTVSourceImportError, .emptyPlaylist)
            }
        }
    }

    func testValidEmptyEventPlaylistsAreAcceptedByBothParserModes() throws {
        for input in [
            "#EXTM3U", "\u{FEFF}#EXTM3U\r\n",
            "# Playlist name: Fixture\n# Last update: today\n\n#EXTM3U\n"
        ] {
            let result = try LiveTVPlaylistParser().parse(input)
            XCTAssertTrue(result.channels.isEmpty)
            XCTAssertEqual(result.entryCount, 0)
            XCTAssertEqual(result.skippedEntryCount, 0)
            var stream = M3UPlaylistParser().makeCatalogStream()
            for byte in input.utf8 { try stream.append(byte) }
            XCTAssertEqual(try stream.finish().entryCount, 0)
            XCTAssertTrue(stream.takeCatalogEntries().isEmpty)
        }
        let result = try LiveTVPlaylistParser().parse("#EXTM3U url-tvg=\"https://example.test/guide.xml\"\n")
        XCTAssertEqual(result.declaredGuideURLs.map(\.absoluteString), ["https://example.test/guide.xml"])
    }

    func testAHeaderCannotDisguiseInvalidContentAsAnEmptyPlaylist() throws {
        for input in ["#EXTM3U\n<html>Sign in</html>", "#EXTM3U\n{\"error\":\"expired\"}"] {
            XCTAssertThrowsError(try LiveTVPlaylistParser().parse(input)) {
                XCTAssertEqual($0 as? LiveTVSourceImportError, .invalidPlaylist)
            }
            XCTAssertThrowsError(try {
                var stream = M3UPlaylistParser().makeCatalogStream()
                try stream.append(Data(input.utf8))
                return try stream.finish()
            }()) {
                XCTAssertEqual($0 as? LiveTVSourceImportError, .invalidPlaylist)
            }
        }
    }

    func testSkippedEntriesAreNotMisreportedAsAnEmptyPlaylist() throws {
        let result = try LiveTVPlaylistParser().parse("""
        #EXTM3U
        #EXTINF:-1,Missing address
        #EXTINF:-1,Unsupported address
        ftp://example.test/live
        """)
        XCTAssertEqual(result.entryCount, 2)
        XCTAssertEqual(result.skippedEntryCount, 2)
        XCTAssertTrue(result.channels.isEmpty)
    }

    func testPlainURLListsAndHeaderlessExtendedEntriesAreAccepted() throws {
        let parser = LiveTVPlaylistParser(baseURL: URL(string: "https://example.test/lists/source"))
        let plain = try parser.parse("""
        # A basic M3U does not require EXTINF.
        https://example.test/live/one?token=fixture-private
        https://example.test/live/two
        """)
        XCTAssertEqual(plain.channels.map(\.name), ["Channel 1", "Channel 2"])
        XCTAssertEqual(plain.entryCount, 2)
        XCTAssertEqual(plain.skippedEntryCount, 0)
        XCTAssertFalse(plain.channels.contains { $0.name.contains("fixture-private") })
        let extended = try parser.parse("""
        #EXTINF:-1 tvg-name="Guide station",
        ../live/one
        #EXTINF:-1,Named
        ../live/two
        """)
        XCTAssertEqual(extended.channels.map(\.name), ["Guide station", "Named"])
        XCTAssertEqual(extended.channels.first?.streamURL?.absoluteString, "https://example.test/live/one")
        for invalid in ["<html>Sign in</html>\nhttps://example.test/live", "{\"error\":\"denied\"}", "stream.ts"] {
            XCTAssertThrowsError(try parser.parse(invalid)) {
                XCTAssertEqual($0 as? LiveTVSourceImportError, .invalidPlaylist)
            }
        }
    }

    func testUnnamedChannelIdentityDoesNotDependOnPlaylistOrder() throws {
        let parser = LiveTVPlaylistParser()
        let first = try parser.parse("https://example.test/one\nhttps://example.test/two").channels
        let second = try parser.parse("https://example.test/two\nhttps://example.test/one").channels
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: first.map { ($0.streamURL, $0.id) }),
            Dictionary(uniqueKeysWithValues: second.map { ($0.streamURL, $0.id) })
        )
    }

    func testEXTGRPGroupsPersistWithEntryOverridesAndCanBeCleared() throws {
        let result = try LiveTVPlaylistParser().parse("""
        #EXTM3U
        #EXTGRP:News; Local
        #EXTINF:-1,First
        https://example.test/one
        #EXTINF:-1 group-title="Sports",Override
        https://example.test/two
        #EXTINF:-1,Default
        https://example.test/three
        #EXTGRP:
        https://example.test/four
        """)
        XCTAssertEqual(result.channels.map(\.groups), [["News", "Local"], ["Sports"], ["News", "Local"], []])
    }

    func testInlineRequestHeadersHaveBoundedValuesAndExplicitPrecedence() throws {
        let result = try LiveTVPlaylistParser().parse("""
        #EXTM3U
        #EXTINF:-1 user-agent="Inline" referrer="https://example.test/watch",Inline
        https://example.test/one
        #EXTINF:-1 user-agent="Inline" referrer="https://example.test/watch",Override
        #EXTVLCOPT:http-user-agent=Directive
        https://example.test/two|User-Agent=Pipe
        #EXTINF:-1 http-user-agent="Alias" http-referer="https://example.test/alias",Aliases
        https://example.test/three
        #EXTINF:-1 user-agent="\(String(repeating: "x", count: 4_097))" referrer="file:///private",Invalid
        https://example.test/four
        #EXTINF:-1,No headers
        https://example.test/five
        """)
        XCTAssertEqual(result.channels[0].httpHeaders, ["User-Agent": "Inline", "Referer": "https://example.test/watch"])
        XCTAssertEqual(result.channels[1].httpHeaders, ["User-Agent": "Pipe", "Referer": "https://example.test/watch"])
        XCTAssertEqual(result.channels[2].httpHeaders, ["User-Agent": "Alias", "Referer": "https://example.test/alias"])
        XCTAssertTrue(result.channels[3].httpHeaders.isEmpty)
        XCTAssertTrue(result.channels[4].httpHeaders.isEmpty)
    }

    func testRequestDirectivesBeforePlainURLsApplyOnlyToTheNextEntry() throws {
        let result = try LiveTVPlaylistParser().parse("""
        #EXTVLCOPT:http-user-agent=Plain
        https://example.test/one
        https://example.test/two
        """)
        XCTAssertEqual(result.channels[0].httpHeaders, ["User-Agent": "Plain"])
        XCTAssertTrue(result.channels[1].httpHeaders.isEmpty)
    }

    func testMalformedExtendedEntryIsNotRescuedAsAnUnnamedChannel() throws {
        let result = try LiveTVPlaylistParser().parse("""
        #EXTINF:-1 missing-comma
        #EXTVLCOPT:http-user-agent=MustNotLeak
        https://example.test/skipped
        https://example.test/kept
        """)
        XCTAssertEqual(result.entryCount, 2)
        XCTAssertEqual(result.skippedEntryCount, 1)
        XCTAssertEqual(result.channels.map(\.streamURL?.path), ["/kept"])
        XCTAssertTrue(result.channels[0].httpHeaders.isEmpty)
    }

    func testPlainURLListsStillEnforceEntryLimits() throws {
        var stream = LiveTVPlaylistParser().makeStream()
        for index in 0..<LiveTVPlaylistParser.maximumEntries {
            try stream.append(Data("https://example.test/\(index)\n".utf8))
        }
        XCTAssertThrowsError(try stream.append(Data("https://example.test/overflow\n".utf8))) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .responseTooLarge)
        }
    }

    func testIncrementalParsingPreservesSplitUnicodeHeadersAndRelativeAddresses() throws {
        let input = "\u{FEFF}#EXTM3U x-tvg-url=\"../guide.xml\"\r\n"
            + "#EXTINF:-1 tvg-id=\"station\",Caf\u{E9}\u{2028}"
            + "#EXTVLCOPT:http-user-agent=Fixture\r"
            + "../live.m3u8|Referer=https://example.test/watch"
        let parser = LiveTVPlaylistParser(baseURL: URL(string: "https://example.test/lists/source.m3u"))
        var stream = parser.makeStream()
        for byte in input.utf8 { try stream.append(byte) }
        let result = try stream.finish()
        XCTAssertEqual(result.channels.count, 1)
        XCTAssertEqual(result.channels.first?.name, "Caf\u{E9}")
        XCTAssertEqual(result.channels.first?.streamURL?.absoluteString, "https://example.test/live.m3u8")
        XCTAssertEqual(result.channels.first?.httpHeaders, [
            "User-Agent": "Fixture", "Referer": "https://example.test/watch"
        ])
        XCTAssertEqual(result.declaredGuideURLs.map(\.absoluteString), ["https://example.test/guide.xml"])
    }

    func testIncrementalBufferDoesNotGrowWithOversizedLines() throws {
        var stream = LiveTVPlaylistParser().makeStream()
        try stream.append(Data("#EXTM3U\n#EXTINF:-1,".utf8))
        for _ in 0..<100 {
            try stream.append(Data(repeating: 65, count: 4_096))
            XCTAssertLessThanOrEqual(stream.bufferedByteCount, LiveTVPlaylistParser.maximumLineBytes + 3)
        }
        try stream.append(Data("\nhttps://example.test/skipped\n#EXTINF:-1,Valid\nhttps://example.test/live".utf8))
        let imported = try stream.finish()
        XCTAssertEqual(imported.entryCount, 2)
        XCTAssertEqual(imported.skippedEntryCount, 1)
        XCTAssertEqual(imported.channels.map(\.name), ["Valid"])
    }

    func testIncrementalParserRetainsLatinOneCompatibility() throws {
        var data = Data("#EXTM3U\n#EXTINF:-1,Caf".utf8)
        data.append(0xE9)
        data.append(Data("\nhttps://example.test/live\n".utf8))
        XCTAssertEqual(try LiveTVPlaylistParser().parse(data).channels.first?.name, "Caf\u{E9}")
    }

    func testIncrementalParserRecognizesEveryASCIINewlineWithoutCombiningLines() throws {
        for separator in ["\n", "\r", "\r\n", "\u{B}", "\u{C}"] {
            var lines = ["#EXTM3U"]
            for index in 0..<2_000 {
                lines += ["#EXTINF:-1,Channel \(index)", "https://example.test/live/\(index)"]
            }
            let input = lines.joined(separator: separator)
            XCTAssertGreaterThan(input.utf8.count, LiveTVPlaylistParser.maximumLineBytes)
            XCTAssertEqual(try LiveTVPlaylistParser().parse(input).channels.count, 2_000)
        }
    }

    func testManyOptionalGuideDeclarationsDoNotRejectValidChannels() throws {
        let guides = (0..<101).map { "https://example.test/guide/\($0).xml" }
        let input = """
        #EXTM3U x-tvg-url="\(guides.joined(separator: ","))" url-tvg="\(guides[0])"
        #EXTINF:-1,Station
        https://example.test/live.m3u8
        """
        let parsed = try LiveTVPlaylistParser().parse(input)
        XCTAssertEqual(parsed.channels.map(\.name), ["Station"])
        XCTAssertEqual(parsed.entryCount, 1)
        XCTAssertEqual(parsed.skippedEntryCount, 0)
        XCTAssertEqual(parsed.declaredGuideURLs.map(\.absoluteString), guides)
    }

    func testDiscoversBothHeaderConventionsAndPreservesCountryAndLanguages() throws {
        let input = """
        #EXTM3U url-tvg="../guide.xml.gz, https://other.test/extra.xml" x-tvg-url="../guide.xml.gz"
        #EXTINF:-1 tvg-id="station" tvg-language="English;Spanish" tvg-country="US,CA",Station
        https://example.test/live.m3u8
        """
        let parsed = try LiveTVPlaylistParser(baseURL: URL(string: "https://example.test/lists/catalog.m3u")).parse(input)
        XCTAssertEqual(parsed.declaredGuideURLs.map(\.absoluteString), [
            "https://example.test/guide.xml.gz", "https://other.test/extra.xml"
        ])
        XCTAssertEqual(parsed.channels.first?.languages, ["English", "Spanish"])
        XCTAssertEqual(parsed.channels.first?.countries, ["US", "CA"])
    }

    func testGuideDiscoveryOriginPolicyRejectsCrossOriginCredentialsAndDowngrades() throws {
        let origin = try XCTUnwrap(URL(string: "https://example.test/source"))
        for address in [
            "https://evil.test/guide", "http://example.test/guide", "https://example.test:8443/guide",
            "https://name:password@example.test/guide", "https://example.test.evil.test/guide"
        ] {
            XCTAssertFalse(LiveTVSourceOriginPolicy.permits(try XCTUnwrap(URL(string: address)), from: origin))
        }
        XCTAssertTrue(LiveTVSourceOriginPolicy.permits(try XCTUnwrap(URL(string: "https://example.test/guide")), from: origin))
        XCTAssertTrue(LiveTVSourceOriginPolicy.permits(
            origin, from: try XCTUnwrap(URL(string: "http://example.test/source"))
        ))
    }

    func testRejectsHLSMediaSegmentsInsteadOfImportingThemAsChannels() {
        let input = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6,First segment
        https://example.com/segment-1.ts
        #EXTINF:6,Second segment
        https://example.com/segment-2.ts
        """
        XCTAssertThrowsError(try LiveTVPlaylistParser().parse(input)) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .streamManifest)
        }
    }

    func testRejectsHLSMasterAsAChannelList() {
        let input = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000
        https://example.com/media.m3u8
        """
        XCTAssertThrowsError(try LiveTVPlaylistParser().parse(input)) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .streamManifest)
        }
    }

    func testM3U8ChannelListStillAcceptsHLSChannelURLs() throws {
        let input = """
        #EXTM3U
        #EXTINF:-1,News
        https://example.com/live.m3u8
        """
        let parser = LiveTVPlaylistParser(baseURL: URL(string: "https://example.com/channels.m3u8"))
        XCTAssertEqual(try parser.parse(input).channels.map(\.name), ["News"])
    }

    func testParsesAttributesCommasRelativeURLsAndScopedHeaders() throws {
        let input = """
        #EXTM3U
        #EXTINF:-1 tvg-id="news.id" tvg-chno="42" tvg-name="News Name" tvg-logo="/logo.png" group-title="News, Local",News, City
        #EXTVLCOPT:http-referrer=https://example.com/watch
        #EXTVLCOPT:http-user-agent=Test Player/1.0
        stream/one.m3u8
        #EXTINF:-1 group-title="Sports",Next
        https://media.example/next.m3u8
        """
        let parser = LiveTVPlaylistParser(
            baseURL: URL(string: "https://example.com/lists/us.m3u")!
        )
        let result = try parser.parse(input)

        XCTAssertEqual(result.entryCount, 2)
        XCTAssertEqual(result.skippedEntryCount, 0)
        XCTAssertEqual(result.channels.map(\.number), [42, 2])
        XCTAssertEqual(result.channels[0].name, "News, City")
        XCTAssertEqual(result.channels[0].category, "News, Local")
        XCTAssertEqual(
            result.channels[0].streamURL?.absoluteString,
            "https://example.com/lists/stream/one.m3u8"
        )
        XCTAssertEqual(
            result.channels[0].logoURL?.absoluteString,
            "https://example.com/logo.png"
        )
        XCTAssertEqual(result.channels[0].guideID, "news.id")
        XCTAssertEqual(result.channels[0].guideName, "News Name")
        XCTAssertEqual(result.channels[0].httpHeaders["Referer"], "https://example.com/watch")
        XCTAssertEqual(result.channels[0].httpHeaders["User-Agent"], "Test Player/1.0")
        XCTAssertTrue(result.channels[1].httpHeaders.isEmpty)
    }

    func testPipeSuffixHeadersAreStrippedFromURLAndApplied() throws {
        let input = """
        #EXTM3U
        #EXTINF:-1,Piped
        #EXTVLCOPT:http-user-agent=Overridden/1.0
        https://media.example/live.m3u8?token=a|User-Agent=Mozilla%2F5.0%20(Fixture)&referer=https://example.com/&X-Ignored=1
        #EXTINF:-1,Raw
        https://media.example/raw.m3u8|user-agent=Raw Player/2.0
        #EXTINF:-1,Injected
        https://media.example/bad.m3u8|User-Agent=Bad%0D%0AX-Evil: 1
        """
        let result = try LiveTVPlaylistParser().parse(input)

        XCTAssertEqual(result.channels.map(\.streamURL?.absoluteString), [
            "https://media.example/live.m3u8?token=a",
            "https://media.example/raw.m3u8",
            "https://media.example/bad.m3u8",
        ])
        XCTAssertEqual(result.channels[0].httpHeaders, [
            "User-Agent": "Mozilla/5.0 (Fixture)",
            "Referer": "https://example.com/",
        ])
        XCTAssertEqual(result.channels[1].httpHeaders, ["User-Agent": "Raw Player/2.0"])
        XCTAssertTrue(result.channels[2].httpHeaders.isEmpty)
    }

    func testStableUniqueIDsUseIdentityAndURLNotPlaylistOrder() throws {
        let first = """
        #EXTM3U
        #EXTINF:-1 tvg-id="same",One
        https://example.com/a.m3u8
        #EXTINF:-1 tvg-id="same",One
        https://example.com/b.m3u8
        """
        let reversed = """
        #EXTM3U
        #EXTINF:-1 tvg-id="same",One
        https://example.com/b.m3u8
        #EXTINF:-1 tvg-id="same",One
        https://example.com/a.m3u8
        """
        let parser = LiveTVPlaylistParser()
        let original = try parser.parse(first).channels
        let reordered = try parser.parse(reversed).channels

        XCTAssertEqual(Set(original.map(\.id)).count, 2)
        XCTAssertEqual(Set(original.map(\.id)), Set(reordered.map(\.id)))
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: original.map {
                ($0.streamURL!.absoluteString, $0.id)
            }),
            Dictionary(uniqueKeysWithValues: reordered.map {
                ($0.streamURL!.absoluteString, $0.id)
            })
        )
    }

    func testBOMAndSingleQuotedMetadataDoNotLoseTheFirstAttribute() throws {
        let input = "\u{FEFF}" + """
        #EXTM3U
        #EXTINF:-1 tvg-id='station' group-title='News, Local',Station
        https://example.com/live.m3u8
        """
        let channel = try XCTUnwrap(LiveTVPlaylistParser().parse(input).channels.first)
        XCTAssertEqual(channel.guideID, "station")
        XCTAssertEqual(channel.category, "News, Local")
    }
    func testExactDuplicateEntryIsExplicitlySkipped() throws {
        let input = """
        #EXTM3U
        #EXTINF:-1 tvg-id="same",One
        https://example.com/a.m3u8
        #EXTINF:-1 tvg-id="same",One
        https://example.com/a.m3u8
        """
        let result = try LiveTVPlaylistParser().parse(input)
        XCTAssertEqual(result.entryCount, 2)
        XCTAssertEqual(result.channels.count, 1)
        XCTAssertEqual(result.skippedEntryCount, 1)
    }

    func testKnownTransparentWhiteLogosKeepTheirContrastHint() throws {
        let input = """
        #EXTM3U
        #EXTINF:-1 tvg-logo="https://i.imgur.com/xP7Ehn8.png",Station
        https://example.com/live.m3u8
        """
        let imported = try XCTUnwrap(LiveTVPlaylistParser().parse(input).channels.first)
        XCTAssertTrue(imported.logoNeedsDarkBackground)
    }

    func testUsesPrimaryCategoryAndPreservesAllGroupLabels() throws {
        let input = """
        #EXTM3U
        #EXTINF:-1 group-title="Animation; Kids;Religious",Kids Network
        https://example.com/kids.m3u8
        """
        let channel = try LiveTVPlaylistParser().parse(input).channels[0]
        XCTAssertEqual(channel.category, "Animation")
        XCTAssertEqual(channel.tagline, "Animation • Kids • Religious")
    }

    func testMalformedAndUnsafeEntriesAreCountedInsteadOfTrapping() throws {
        let input = """
        #EXTM3U
        #EXTINF:-1,Missing URL
        #EXTINF:-1,Bad Scheme
        file:///private/movie.ts
        #EXTINF:-1,Credentials
        https://user:secret@example.com/live.m3u8
        #EXTINF:-1,Good
        https://example.com/live.m3u8
        #EXTINF:-1,Trailing
        """
        let result = try LiveTVPlaylistParser().parse(input)
        XCTAssertEqual(result.entryCount, 5)
        XCTAssertEqual(result.channels.map(\.name), ["Good"])
        XCTAssertEqual(result.skippedEntryCount, 4)
    }

    func testRejectsNonM3UAndOversizedInput() {
        let diagnostics = PlaylistLimitRecorder()
        XCTAssertThrowsError(try LiveTVPlaylistParser().parse("not a playlist")) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .invalidPlaylist)
        }
        let data = Data(
            repeating: 65,
            count: LiveTVPlaylistParser.maximumBytes + 1
        )
        XCTAssertThrowsError(try LiveTVPlaylistParser().parse(data)) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .responseTooLarge)
        }
        XCTAssertEqual(diagnostics.values, [.init(
            limit: .inputBytes, observed: Int64(data.count), maximum: Int64(LiveTVPlaylistParser.maximumBytes)
        )])
    }

    func testRejectsEntryOverflow() {
        let diagnostics = PlaylistLimitRecorder()
        var input = "#EXTM3U\n"
        for index in 0...LiveTVPlaylistParser.maximumEntries {
            input += "#EXTINF:-1,Channel \(index)\nhttps://example.com/\(index).m3u8\n"
        }
        XCTAssertThrowsError(try LiveTVPlaylistParser().parse(input)) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .responseTooLarge)
        }
        XCTAssertEqual(diagnostics.values, [.init(
            limit: .entries, observed: Int64(LiveTVPlaylistParser.maximumEntries) + 1,
            maximum: Int64(LiveTVPlaylistParser.maximumEntries)
        )])
    }

    func testHeaderAndDecodedSizeFailuresHaveDistinctNumericDiagnostics() {
        let diagnostics = PlaylistLimitRecorder()
        let header = "#EXTM3U " + String(repeating: "x", count: LiveTVPlaylistParser.maximumLineBytes)
        XCTAssertThrowsError(try LiveTVPlaylistParser().parse(header))
        let text = String(repeating: "é", count: LiveTVPlaylistParser.maximumBytes / 2 + 1)
        XCTAssertThrowsError(try LiveTVPlaylistParser().parse(text))
        XCTAssertEqual(diagnostics.values, [
            .init(limit: .headerLineBytes, observed: Int64(header.utf8.count),
                  maximum: Int64(LiveTVPlaylistParser.maximumLineBytes)),
            .init(limit: .decodedBytes, observed: Int64(text.utf8.count),
                  maximum: Int64(LiveTVPlaylistParser.maximumBytes))
        ])
    }
}

final class PlaylistLimitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [LiveTVPlaylistLimitDiagnostic] = []
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: LiveTVPlaylistLimitDiagnostic.notification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let self, let diagnostic = notification.object as? LiveTVPlaylistLimitDiagnostic else { return }
            self.lock.withLock { self.recorded.append(diagnostic) }
        }
    }

    var values: [LiveTVPlaylistLimitDiagnostic] { lock.withLock { recorded } }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
