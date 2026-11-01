import Foundation
import CoreModels
import CoreNetworking
import XCTest
@testable import FeatureLiveTVCore

final class LiveTVPlaylistParserTests: XCTestCase {
    func testProviderMetadataDoesNotTurnAChannelListIntoHLS() throws {
        for metadata in [
            "#EXT-X-SESSION-DATA:DATA-ID=\"com.xui.1_5_5r2\"",
            "#EXT-X-PROVIDER-METADATA:VALUE=\"fixture\"",
            "#EXT-X-STREAM-INF-EXTRA:VALUE=\"not a rendition\""
        ] {
            let input = """
            #EXTM3U
            \(metadata)
            #EXTINF:-1 tvg-id="one",First
            https://example.test/one.m3u8
            \(metadata)
            #EXTINF:-1 tvg-id="two",Second
            https://example.test/two.ts

            """
            let parser = M3UPlaylistParser()
            let result = try parser.parse(input)
            XCTAssertEqual(result.channels.map(\.name), ["First", "Second"])
            XCTAssertEqual(result.entryCount, 2)
            XCTAssertEqual(result.skippedEntryCount, 0)
            for chunkSize in [1, 7, 65_536] {
                var stream = parser.makeCatalogStream()
                let data = Data(input.utf8)
                var names: [String] = []
                for start in stride(from: 0, to: data.count, by: chunkSize) {
                    try stream.append(data.subdata(in: start..<min(start + chunkSize, data.count)))
                    names += stream.takeCatalogEntries().map(\.channel.name)
                }
                XCTAssertEqual(try stream.finish().entryCount, 2)
                names += stream.takeCatalogEntries().map(\.channel.name)
                XCTAssertEqual(names, ["First", "Second"])
                XCTAssertFalse(stream.hasPlayableHLSTag)
                XCTAssertEqual(stream.byteCount, data.count)
            }
        }
    }

    func testHLSDirectivesStillRejectSegmentsAfterProviderMetadata() throws {
        for directive in [
            "#EXT-X-TARGETDURATION:6", "#EXT-X-STREAM-INF:BANDWIDTH=800000",
            "#EXT-X-MEDIA-SEQUENCE:1", "#EXT-X-VERSION:7", "#EXT-X-ALLOW-CACHE:YES",
            "#EXT-X-KEY:METHOD=AES-128,URI=\"key\"", "#EXT-X-MAP:URI=\"init.mp4\"",
            "#EXT-X-BYTERANGE:1024", "#EXT-X-ENDLIST", "#EXT-X-DISCONTINUITY",
            "#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1,URI=\"iframe.m3u8\"",
            "#EXT-X-MEDIA:TYPE=AUDIO,URI=\"audio.m3u8\"",
            "#EXT-X-PART:DURATION=1,URI=\"part.mp4\"",
            "#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES",
            "#ext-x-targetduration:6"
        ] {
            let input = """
            #EXTM3U
            #EXT-X-SESSION-DATA:DATA-ID="fixture"
            #EXTINF:6,First segment
            https://example.test/one.ts
            \(directive)
            #EXTINF:6,Second segment
            https://example.test/two.ts
            """
            XCTAssertThrowsError(try M3UPlaylistParser().parse(input), directive) {
                XCTAssertEqual($0 as? LiveTVSourceImportError, .streamManifest)
            }
            var stream = M3UPlaylistParser().makeCatalogStream()
            try stream.append(Data(input.utf8))
            XCTAssertThrowsError(try stream.finish(), directive) {
                XCTAssertEqual($0 as? LiveTVSourceImportError, .streamManifest)
            }
            XCTAssertTrue(stream.takeCatalogEntries().isEmpty, directive)
        }
    }

    func testMixedCaseDirectivesPreserveCaseSensitiveValues() throws {
        let input = """
        \u{FEFF}#extm3u X-TVG-URL="../Guide.XML"
        #extgrp:News; Local
        #extinf:-1 TVG-ID="Station.ID" TVG-NAME="Guide Name",Station
        #extvlcopt:HTTP-USER-AGENT=Fixture/One
        ../Live/Channel.TS?Token=AbC
        """
        let parser = M3UPlaylistParser(baseURL: URL(string: "https://example.test/Lists/Source"))
        let result = try parser.parse(input)
        let channel = try XCTUnwrap(result.channels.first)
        XCTAssertEqual(result.entryCount, 1)
        XCTAssertEqual(channel.name, "Station")
        XCTAssertEqual(channel.guideID, "Station.ID")
        XCTAssertEqual(channel.groups, ["News", "Local"])
        XCTAssertEqual(channel.httpHeaders, ["User-Agent": "Fixture/One"])
        XCTAssertEqual(channel.streamURL?.absoluteString, "https://example.test/Live/Channel.TS?Token=AbC")
        XCTAssertEqual(result.declaredGuideURLs.map(\.absoluteString), ["https://example.test/Guide.XML"])
        var stream = parser.makeCatalogStream()
        for byte in input.utf8 { try stream.append(byte) }
        _ = try stream.finish()
        let indexed = try XCTUnwrap(stream.takeCatalogEntries().first?.channel)
        XCTAssertEqual(indexed.id, channel.id)
        XCTAssertEqual(indexed.httpHeaders, channel.httpHeaders)
        XCTAssertEqual(indexed.streamURL, channel.streamURL)
        XCTAssertEqual(indexed.groups, channel.groups)
    }

    func testQuotedVLCHeadersAreUnwrappedAndRemainEntryScoped() throws {
        let input = """
        #EXTM3U
        #EXTVLCOPT: http-user-agent = "Before/1.0"
        #EXTINF:-1,First
        #EXTVLCOPT:http-referrer='https://example.test/Watch?ID=AbC'
        https://example.test/one
        #EXTINF:-1,Override
        #EXTVLCOPT:http-user-agent="Directive/2.0"
        https://example.test/two|User-Agent=Pipe%2F3.0
        #EXTINF:-1,Unconfigured
        https://example.test/three
        """
        let channels = try M3UPlaylistParser().parse(input).channels
        XCTAssertEqual(channels[0].httpHeaders, [
            "User-Agent": "Before/1.0", "Referer": "https://example.test/Watch?ID=AbC"
        ])
        XCTAssertEqual(channels[1].httpHeaders, ["User-Agent": "Pipe/3.0"])
        XCTAssertTrue(channels[2].httpHeaders.isEmpty)
    }

    func testMetadataAliasesRespectPrimaryValuesAndPreserveChannelIdentity() throws {
        let parser = M3UPlaylistParser(baseURL: URL(string: "https://example.test/lists/source"))
        let original = "#EXTM3U\n#EXTINF:-1,Station\nhttps://example.test/live\n"
        let aliased = original.replacingOccurrences(
            of: "#EXTINF:-1,", with: "#EXTINF:-1 channel-id=\"guide.alias\" channel-number=\"42\" logo=\"../Logo.png\","
        )
        let channel = try XCTUnwrap(parser.parse(aliased).channels.first)
        XCTAssertEqual(channel.id, try parser.parse(original).channels.first?.id)
        XCTAssertEqual(channel.number, 42)
        XCTAssertEqual(channel.logoURL?.absoluteString, "https://example.test/Logo.png")
        XCTAssertEqual(channel.guideID, "guide.alias")
        let primary = aliased.replacingOccurrences(
            of: "#EXTINF:-1", with: "#EXTINF:-1 tvg-id=\"primary\" tvg-chno=\"7\" tvg-logo=\"/Primary.png\""
        )
        let preferred = try XCTUnwrap(parser.parse(primary).channels.first)
        XCTAssertEqual(preferred.number, 7)
        XCTAssertEqual(preferred.guideID, "primary")
        XCTAssertEqual(preferred.logoURL?.absoluteString, "https://example.test/Primary.png")
    }

    func testQuotedVLCValuesCannotBypassHeaderValidationOrAuthenticationAdmission() throws {
        let input = """
        #EXTM3U
        #EXTINF:-1,Invalid headers
        #EXTVLCOPT:http-user-agent="Bad\u{7}Value"
        #EXTVLCOPT:http-referrer="file:///private"
        #EXTVLCOPT:http-host="other.test"
        https://example.test/one
        #EXTINF:-1,Account headers
        #EXTVLCOPT:http-cookie="session=fixture"
        #EXTVLCOPT:http-authorization='Bearer fixture'
        https://example.test/two
        #EXTINF:-1,No inherited headers
        https://example.test/three
        """
        for permitsAuthentication in [false, true] {
            let channels = try M3UPlaylistParser(permitsAuthenticationHeaders: permitsAuthentication).parse(input).channels
            XCTAssertTrue(channels[0].httpHeaders.isEmpty)
            XCTAssertEqual(channels[1].httpHeaders, permitsAuthentication
                ? ["Cookie": "session=fixture", "Authorization": "Bearer fixture"] : [:])
            XCTAssertTrue(channels[2].httpHeaders.isEmpty)
        }
    }

    func testMixedCaseOversizedMetadataKeepsCatalogLimitsAndSkippedEntryAccounting() throws {
        var stream = M3UPlaylistParser().makeCatalogStream()
        try stream.append(Data(("#extm3u x-tvg-url=\"" + String(repeating: "x", count: 65_536) + "\"\n").utf8))
        try stream.append(Data(("#extinf:-1," + String(repeating: "x", count: 65_536) + "\n").utf8))
        try stream.append(Data("https://example.test/skipped\n#extinf:-1,Kept\nhttps://example.test/kept\n".utf8))
        let result = try stream.finish()
        XCTAssertEqual(result.entryCount, 2)
        XCTAssertEqual(result.skippedEntryCount, 1)
        XCTAssertEqual(stream.takeCatalogEntries().map(\.channel.name), ["Kept"])
        XCTAssertLessThanOrEqual(stream.bufferedByteCount, M3UPlaylistParser.maximumLineBytes + 3)
    }

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

    func testDiscoversAllHeaderConventionsAndPreservesCountryAndLanguages() throws {
        let input = """
        #EXTM3U url-tvg="../guide.xml.gz, https://other.test/extra.xml" x-tvg-url="../guide.xml.gz" tvg-url="../third.xml"
        #EXTINF:-1 tvg-id="station" tvg-language="English;Spanish" tvg-country="US,CA",Station
        https://example.test/live.m3u8
        """
        let parsed = try LiveTVPlaylistParser(baseURL: URL(string: "https://example.test/lists/catalog.m3u")).parse(input)
        XCTAssertEqual(parsed.declaredGuideURLs.map(\.absoluteString), [
            "https://example.test/guide.xml.gz", "https://other.test/extra.xml", "https://example.test/third.xml"
        ])
        XCTAssertEqual(parsed.channels.first?.languages, ["English", "Spanish"])
        XCTAssertEqual(parsed.channels.first?.countries, ["US", "CA"])
    }

    func testTVGURLAliasRetainsURLValidationDeduplicationAndIncrementalParsing() throws {
        let input = """
        #EXTM3U TVG-URL="../Guide.XML, ../Guide.XML, ftp://example.test/guide.xml, javascript:bad"
        #EXTINF:-1 tvg-id="stable",Station
        https://example.test/live.m3u8

        """
        let parser = LiveTVPlaylistParser(baseURL: URL(string: "https://example.test/lists/catalog.m3u"))
        let whole = try parser.parse(input)
        var stream = parser.makeStream()
        for byte in input.utf8 { try stream.append(Data([byte])) }
        let incremental = try stream.finish()
        XCTAssertEqual(whole.declaredGuideURLs.map(\.absoluteString), ["https://example.test/Guide.XML"])
        XCTAssertEqual(incremental.declaredGuideURLs, whole.declaredGuideURLs)
        XCTAssertEqual(incremental.channels.map(\.id), whole.channels.map(\.id))
    }

    func testSourceRedirectOriginPolicyRejectsCrossOriginCredentialsAndDowngrades() throws {
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

    func testDuplicateCategoriesMergeWithoutChangingFirstEntryMetadataOrCounts() throws {
        let first = """
        #EXTM3U
        #EXTINF:-1 tvg-id="same" tvg-chno="42" tvg-name="Guide One" tvg-logo="https://i.imgur.com/xP7Ehn8.png" tvg-language="English" tvg-country="US" group-title="News",One
        #EXTVLCOPT:http-user-agent="Fixture/1.0"
        https://example.test/a.m3u8
        """
        let input = first + "\n" + """
        #EXTINF:-1 tvg-id="same" tvg-chno="99" tvg-name="Changed" tvg-logo="https://example.test/changed.png" tvg-language="French" tvg-country="FR" group-title="news; Kids",One
        https://example.test/a.m3u8|User-Agent=Fixture%2F1.0&Referer=file%3A%2F%2F%2Fprivate
        #EXTINF:-1 tvg-id="other",Other
        https://example.test/other.m3u8
        #EXTINF:-1 tvg-id="same" group-title="KIDS; Local",One
        #EXTVLCOPT:http-user-agent=Fixture/1.0
        https://example.test/a.m3u8
        """
        let parser = LiveTVPlaylistParser()
        let original = try XCTUnwrap(parser.parse(first).channels.first)
        var expected = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
        )
        expected["groups"] = ["News", "Kids", "Local"]
        var results = [try parser.parse(input)]
        let data = Data(input.utf8)
        for chunkSize in [1, 7, 65_536] {
            var stream = parser.makeStream()
            for start in stride(from: 0, to: data.count, by: chunkSize) {
                try stream.append(data.subdata(in: start..<min(start + chunkSize, data.count)))
            }
            results.append(try stream.finish())
        }
        for result in results {
            XCTAssertEqual(result.entryCount, 4)
            XCTAssertEqual(result.skippedEntryCount, 2)
            XCTAssertEqual(result.channels.map(\.name), ["One", "Other"])
            XCTAssertEqual(result.channels.map(\.number), [42, 3])
            let retained = try XCTUnwrap(result.channels.first)
            let actual = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(retained)) as? [String: Any]
            )
            XCTAssertEqual(actual as NSDictionary, expected as NSDictionary)
            XCTAssertTrue(try XCTUnwrap(result.channels.last).httpHeaders.isEmpty)
        }
    }

    func testDuplicateCategoriesDoNotCrossHeaderOrFullURLBoundaries() throws {
        for duplicateSuffix in ["|User-Agent=Different", ""] {
            let result = try LiveTVPlaylistParser().parse("""
            #EXTM3U
            #EXTINF:-1 tvg-id="same" group-title="News",One
            https://example.test/live.m3u8?variant=one|User-Agent=Original
            #EXTINF:-1 tvg-id="same" group-title="Sports",One
            https://example.test/live.m3u8?variant=one\(duplicateSuffix)
            #EXTINF:-1 tvg-id="same" group-title="Kids",One
            https://example.test/live.m3u8?variant=two|User-Agent=Original
            """)
            XCTAssertEqual(result.entryCount, 3)
            XCTAssertEqual(result.skippedEntryCount, 1)
            XCTAssertEqual(result.channels.map(\.groups), [["News"], ["Kids"]])
            XCTAssertEqual(Set(result.channels.map(\.id)).count, 2)
            XCTAssertEqual(result.channels.map(\.streamURL?.absoluteString), [
                "https://example.test/live.m3u8?variant=one",
                "https://example.test/live.m3u8?variant=two"
            ])
            XCTAssertEqual(result.channels.map(\.httpHeaders), [
                ["User-Agent": "Original"], ["User-Agent": "Original"]
            ])
        }
    }

    func testCatalogStreamingKeepsDuplicateCategoryRowsSeparate() throws {
        let data = Data("""
        #EXTM3U
        #EXTINF:-1 tvg-id="same" group-title="News",One
        https://example.test/live.m3u8
        #EXTINF:-1 tvg-id="same" group-title="Kids",One
        https://example.test/live.m3u8
        #EXTINF:-1 tvg-id="same" group-title="News",One
        https://example.test/live.m3u8
        """.utf8)
        for chunkSize in [1, 7, 65_536] {
            var stream = M3UPlaylistParser().makeCatalogStream()
            var groups: [[String]] = []
            for start in stride(from: 0, to: data.count, by: chunkSize) {
                try stream.append(data.subdata(in: start..<min(start + chunkSize, data.count)))
                groups += stream.takeCatalogEntries().map(\.channel.groups)
            }
            let result = try stream.finish()
            groups += stream.takeCatalogEntries().map(\.channel.groups)
            XCTAssertEqual(groups, [["News"], ["Kids"], ["News"]])
            XCTAssertEqual(result.entryCount, 3)
            XCTAssertEqual(result.skippedEntryCount, 0)
            XCTAssertTrue(result.channels.isEmpty)
        }
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
