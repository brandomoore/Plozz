#if DEBUG
import CoreNetworking
import Foundation
import XCTest
import zlib
@testable import FeatureLiveTVCore

final class LiveTVXMLTVParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_225_600)

    func testExternalCancellationInterruptsPlainAndCompressedInputWithoutCancellingTask() throws {
        final class CancellationBudget: @unchecked Sendable {
            private let lock = NSLock()
            private var remaining = 20
            func check() -> Bool { lock.withLock { remaining -= 1; return remaining <= 0 } }
        }
        let inputs = [
            "<!--" + String(repeating: " ", count: 1_000_000) + "--><tv/>",
            "<tv>" + String(repeating: "<programme channel=\"unmatched\"/>", count: 1_000) + "</tv>"
        ]
        for xml in inputs {
            for compressed in [false, true] {
                let budget = CancellationBudget()
                let parser = LiveTVXMLTVParser(isCancelled: { budget.check() })
                let data = Data(xml.utf8)
                XCTAssertThrowsError(try parser.parseIndexed(
                    data: compressed ? gzip(data) : data, channels: [], now: now, sink: { _ in
                        XCTFail("No programmes in this input should be retained.")
                    }
                ), "compressed=\(compressed)") {
                    XCTAssertEqual($0 as? LiveTVSourceImportError, .cancelled)
                }
                XCTAssertFalse(Task.isCancelled)
            }
        }
    }

    func testLargeChannelDirectoryRetainsOnlyTheRequestedSchedule() throws {
        let declarations = (0..<20_001).map { "<channel id=\"g\($0)\"/>" }.joined()
        let xml = Data("""
        <tv>\(declarations)
        <programme channel="g20000" start="20260101000000 +0000" stop="20260101010000 +0000"><title>Selected</title></programme>
        <programme channel="g0" start="20260101000000 +0000" stop="20260101010000 +0000"><title>Unrequested</title></programme>
        </tv>
        """.utf8)
        let channels = [makeChannel(id: "app", name: "Selected", guideID: "g20000")]
        for result in [
            try LiveTVXMLTVParser().parseXML(data: xml, channels: channels, now: now),
            try LiveTVXMLTVParser().parse(gzipData: gzip(xml), channels: channels, now: now)
        ] {
            XCTAssertEqual(result.guideChannelCount, 20_001)
            XCTAssertEqual(result.programs.map(\.title), ["Selected"])
        }
    }

    func testProgrammeOnlyFeedMatchesExactIDsWithoutGuessingNamesOrCase() throws {
        let xml = Data("""
        <tv>
          <programme channel="station" start="20260101000000 +00:00" stop="20260101010000 +00:00"><title>Listing</title></programme>
          <programme channel="other" start="20260101000000 +0000" stop="20260101010000 +0000"><title>Other</title></programme>
        </tv>
        """.utf8)
        let channels = [
            makeChannel(id: "sd", name: "Station SD", guideID: "station"),
            makeChannel(id: "hd", name: "Station HD", guideID: "station"),
            makeChannel(id: "name-only", name: "station", guideID: nil),
            makeChannel(id: "case-only", name: "station", guideID: "STATION")
        ]
        let plain = try LiveTVXMLTVParser().parseXML(data: xml, channels: channels, now: now)
        let compressed = try LiveTVXMLTVParser().parse(gzipData: gzip(xml), channels: channels, now: now)
        XCTAssertEqual(Set(plain.programs.map(\.channelID)), ["sd", "hd"])
        XCTAssertEqual(plain.matches["sd"]?.method, .exactID)
        XCTAssertEqual(plain.guideChannels["station"], [])
        XCTAssertEqual(plain.guideChannelCount, 2)
        XCTAssertEqual(plain.programs.map(\.id), compressed.programs.map(\.id))
        let overridden = try LiveTVXMLTVParser().parseXML(
            data: xml, channels: channels, now: now, overrides: ["sd": "missing"]
        )
        XCTAssertNil(overridden.matches["sd"])
    }

    func testColonOffsetsAreEquivalentAndMalformedOffsetsStayInvalid() {
        for (colon, compact) in [
            ("+08:00", "+0800"), ("-05:30", "-0530"), ("+00:00", "+0000"), ("-00:30", "-0030")
        ] {
            let actual = XMLTVDateParser.date(from: "20260101010000 \(colon)")
            XCTAssertNotNil(actual, colon)
            XCTAssertEqual(actual, XMLTVDateParser.date(from: "20260101010000 \(compact)"))
        }
        for offset in ["+24:00", "-05:60", "+8:00", "+008:00", "+00:000", "+0:000", "+00::00",
                       "+00:0x", "+٠٠:٠٠", "+000:0", "00:00", "CST", "+00:00 trailing"] {
            XCTAssertNil(XMLTVDateParser.date(from: "20260101010000 \(offset)"), offset)
        }
        XCTAssertNil(XMLTVDateParser.date(from: "20260230010000 +00:00"))
    }

    func testProgrammeReferencesRespectChannelAndRetainedTextBudgets() {
        for ids in [
            (0...LiveTVXMLTVParser.maximumGuideChannels).map(String.init),
            (0..<8_193).map { String(repeating: "x", count: 4_090) + String(format: "%06d", $0) }
        ] {
            let xml = "<tv>" + ids.map { "<programme channel=\"\($0)\"/>" }.joined() + "</tv>"
            XCTAssertThrowsError(
                try LiveTVXMLTVParser().parseXML(data: Data(xml.utf8), channels: [], now: now)
            ) { XCTAssertEqual($0 as? LiveTVSourceImportError, .guideTooLarge) }
        }
    }

    func testProgrammeReferencesAndLaterDeclarationsShareAnExactIdentity() throws {
        let xml = Data("""
        <tv><programme channel="g"/>
          <channel id="g"><display-name>First</display-name></channel>
          <channel id="g"><display-name>Additional name</display-name></channel>
        </tv>
        """.utf8)
        let result = try LiveTVXMLTVParser().parseXML(data: xml, channels: [], now: now)
        XCTAssertEqual(result.guideChannels["g"], ["First", "Additional name"])
        XCTAssertEqual(result.guideChannelCount, 1)
    }

    func testUnusableChannelDeclarationsDoNotDiscardUsableListingsOrInventIdentities() throws {
        let data = Data("""
        <tv>
          <channel id="g"><display-name>Guide</display-name></channel>
          <channel><display-name>Private missing ID</display-name></channel>
          <channel id=""><display-name>Private empty ID</display-name></channel>
          <channel id="  "><display-name>Private blank ID</display-name></channel>
          <channel id=" g "><display-name>Separate exact ID</display-name></channel>
          <programme channel="g" start="20260101000000" stop="20260101010000"><title>Usable</title></programme>
        </tv>
        """.utf8)
        let channels = [
            makeChannel(id: "app", name: "Guide", guideID: "g"),
            makeChannel(id: "unconfirmed", name: "Private missing ID", guideID: nil)
        ]
        let parser = LiveTVXMLTVParser()
        let plain = try parser.parseXML(data: data, channels: channels, now: now)
        let compressed = try parser.parse(gzipData: gzip(data), channels: channels, now: now)
        for result in [plain, compressed] {
            XCTAssertEqual(result.guideChannels, ["g": ["Guide"], " g ": ["Separate exact ID"]])
            XCTAssertEqual(result.programs.map(\.title), ["Usable"])
            XCTAssertEqual(result.programs.map(\.channelID), ["app"])
            XCTAssertNil(result.matches["unconfirmed"])
        }
        for input in [data, try gzip(data)] {
            var programs: [LiveTVPrototypeProgram] = []
            let result = try parser.parseIndexed(data: input, channels: channels, now: now) {
                programs.append($0)
            }
            XCTAssertEqual(result.guideChannels, plain.guideChannels)
            XCTAssertEqual(programs, plain.programs)
        }
    }

    func testSkippedChannelsStillRespectDeclarationTextAndIdentifierLimits() {
        let inputs = [
            "<tv>" + String(repeating: "<channel/>", count: LiveTVXMLTVParser.maximumGuideChannels + 1) + "</tv>",
            "<tv><channel><display-name>"
                + String(repeating: "x", count: LiveTVXMLTVParser.maximumTextLength + 1)
                + "</display-name></channel></tv>",
            "<tv><channel id=\"" + String(repeating: " ", count: 4_097) + "\"/></tv>"
        ]
        for xml in inputs {
            XCTAssertThrowsError(try LiveTVXMLTVParser().parseXML(data: Data(xml.utf8), channels: [], now: now)) {
                XCTAssertEqual($0 as? LiveTVSourceImportError, .guideTooLarge)
            }
        }
    }

    func testSkippingAChannelNeverHidesBrokenXMLOrEntities() throws {
        for xml in [
            "<tv><channel><display-name>Broken</channel></tv>",
            "<tv><channel><display-name>&unknown;</display-name></channel></tv>",
            "<tv><channel><tv/></channel></tv>",
            "<!DOCTYPE tv [<!ENTITY hidden 'text'>]><tv><channel/></tv>"
        ] {
            let data = Data(xml.utf8)
            XCTAssertThrowsError(try LiveTVXMLTVParser().parseXML(data: data, channels: [], now: now)) {
                XCTAssertEqual($0 as? LiveTVSourceImportError, .invalidGuide)
            }
            XCTAssertThrowsError(try LiveTVXMLTVParser().parseIndexed(
                data: gzip(data), channels: [], now: now, sink: { _ in XCTFail("No listings expected") }
            )) {
                XCTAssertEqual($0 as? LiveTVSourceImportError, .invalidGuide)
            }
        }
    }

    func testSkippedChannelDiagnosticsContainCountsWithoutFeedContent() throws {
        let since = Date()
        let result = try LiveTVXMLTVParser().parseXML(
            data: Data("<tv><channel><display-name>private-secret.invalid</display-name></channel></tv>".utf8),
            channels: [], now: now
        )
        XCTAssertEqual(result.guideChannelCount, 0)
        let entries = PlozzLog.recentEntries(limit: 50).filter {
            $0.date >= since && $0.message.hasPrefix("XMLTV_PARSE ")
        }
        XCTAssertEqual(entries.count, 1)
        let message = try XCTUnwrap(entries.first?.message)
        XCTAssertTrue(message.contains("pass=metadata outcome=succeeded skippedChannels=1 reason=channelID"))
        XCTAssertFalse(message.contains("private"))
        XCTAssertFalse(message.contains("secret.invalid"))
    }

    func testProgrammeTextPrefersRequestedLanguageRegardlessOfVariantOrder() throws {
        let variants = [
            "<title>Default</title><sub-title>Default episode</sub-title><desc>Default synopsis</desc>",
            "<title lang=\"eng\">News</title><sub-title lang=\"en-US\">Episode</sub-title><desc lang=\"EN_us\">Synopsis</desc>",
            "<title lang=\"fr\">Journal</title><sub-title lang=\"fr\">French episode</sub-title><desc lang=\"fr\">French synopsis</desc>"
        ]
        for order in [variants, Array(variants.reversed())] {
            let xml = """
            <tv><programme channel="g" start="20260101000000" stop="20260101010000">
              \(order.joined())
              <title lang="en"/><sub-title lang="en"> </sub-title><desc lang="en"/>
            </programme></tv>
            """
            for programs in try programsAcrossParserPaths(xml, preferredLanguage: " en_GB ") {
                let program = try XCTUnwrap(programs.first)
                XCTAssertEqual(programs.count, 1)
                XCTAssertEqual(program.title, "News")
                XCTAssertEqual(program.subtitle, "Episode")
                XCTAssertEqual(program.details?.description, "Synopsis")
            }
        }
    }

    func testProgrammeTextFallsBackPerFieldWithoutEmptyVariantsErasingText() throws {
        let xml = """
        <tv><programme channel="g" start="20260101000000" stop="20260101010000">
          <title lang="fr">First title</title><title lang="de">Later title</title><title lang="en"/>
          <sub-title lang="fr">French episode</sub-title><sub-title lang=" ">Default episode</sub-title><sub-title lang="en"/>
          <desc lang="fr">French synopsis</desc><desc>Default synopsis</desc><desc lang="de">German synopsis</desc><desc/>
        </programme></tv>
        """
        let languages: [String?] = ["en", nil]
        for language in languages {
            for programs in try programsAcrossParserPaths(xml, preferredLanguage: language) {
                let program = try XCTUnwrap(programs.first)
                XCTAssertEqual(program.title, "First title")
                XCTAssertEqual(program.subtitle, "Default episode")
                XCTAssertEqual(program.details?.description, "Default synopsis")
            }
        }
    }

    func testLanguagePriorityResetsForEachProgrammeIncludingInferredStops() throws {
        let xml = """
        <tv>
          <programme channel="g" start="20260101000000">
            <title lang="fra">First title</title><title lang="fr-FR">Later same-language title</title>
            <desc lang="fr">First synopsis</desc><desc lang="eng">Other synopsis</desc>
          </programme>
          <programme channel="g" start="20260101010000" stop="20260101020000">
            <title lang="eng">Next title</title><desc>Next synopsis</desc>
          </programme>
        </tv>
        """
        for programs in try programsAcrossParserPaths(xml, preferredLanguage: "fr_CA") {
            XCTAssertEqual(programs.map(\.title), ["First title", "Next title"])
            XCTAssertEqual(programs.map { $0.details?.description }, ["First synopsis", "Next synopsis"])
            XCTAssertEqual(programs.first?.details?.endWasInferred, true)
        }
    }

    func testUnselectedLanguageVariantsStillEnforceTextLimits() throws {
        let xml = """
        <tv><programme channel="g" start="20260101000000" stop="20260101010000">
          <title lang="en">Usable</title><title lang="fr">\(String(repeating: "x", count: LiveTVXMLTVParser.maximumTextLength + 1))</title>
        </programme></tv>
        """
        let parser = LiveTVXMLTVParser(preferredLanguage: "en")
        let channels = [makeChannel(id: "app", name: "Guide", guideID: "g")]
        let data = Data(xml.utf8)
        XCTAssertThrowsError(try parser.parseXML(data: data, channels: channels, now: now)) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .guideTooLarge)
        }
        XCTAssertThrowsError(try parser.parseIndexed(
            data: gzip(data), channels: channels, now: now, sink: { _ in XCTFail("No listing may be emitted") }
        )) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .guideTooLarge)
        }
    }

    func testMissingEndUsesOnlyBoundedSameChannelSuccessorAndRetainsProvenance() throws {
        let xml = """
        <tv><channel id="g"><display-name>Station</display-name></channel>
        <programme channel="g" start="20260101000000 +0000"><title>Inferred</title><desc>Details</desc><category>Science</category><language>en</language><rating><value>PG</value></rating></programme>
        <programme channel="other" start="20260101001500 +0000" stop="20260101003000 +0000"><title>Other channel</title></programme>
        <programme channel="g" start="20260101010000 +0000" stop="20260101020000 +0000"><title>Next</title></programme>
        <programme channel="g" start="20260101030000 +0000"><title>Unbounded final</title></programme>
        </tv>
        """
        let result = try LiveTVXMLTVParser().parseXML(
            data: Data(xml.utf8), channels: [makeChannel(id: "app", name: "Station", guideID: "g")], now: now
        )
        XCTAssertEqual(result.programs.map(\.title), ["Inferred", "Next"])
        XCTAssertEqual(result.programs[0].end, result.programs[1].start)
        XCTAssertEqual(result.programs[0].details?.endWasInferred, true)
        XCTAssertEqual(result.programs[0].details?.description, "Details")
        XCTAssertEqual(result.programs[0].details?.rating, "PG")
        XCTAssertEqual(result.programs[0].details?.categories, ["Science"])
        XCTAssertEqual(result.programs[0].details?.languages, ["en"])
    }

    func testMissingManualGuideStationNeverFallsBackToAnExactOrNameMatch() throws {
        let xml = Data("<tv><channel id=\"g\"><display-name>Station</display-name></channel></tv>".utf8)
        let result = try LiveTVXMLTVParser().parseXML(
            data: xml, channels: [makeChannel(id: "app", name: "Station", guideID: "g")], now: now,
            overrides: ["app": "removed-station"]
        )
        XCTAssertTrue(result.matches.isEmpty)
    }


    func testParsesChunksEntitiesOffsetsAndMapsToApplicationChannelID() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="guide.one"><display-name>News HD</display-name></channel>
          <programme channel="guide.one" start="20251231210000 -0500" stop="20251231223000 -0500">
            <title>Tom &amp; Jerry</title>
            <sub-title>Part <![CDATA[One]]></sub-title>
          </programme>
        </tv>
        """
        let channel = makeChannel(id: "app-channel", name: "News HD", guideID: "guide.one")
        let result = try LiveTVXMLTVParser().parseXML(
            data: Data(xml.utf8),
            channels: [channel],
            now: now
        )

        XCTAssertEqual(result.guideChannelCount, 1)
        XCTAssertEqual(result.matchedChannelCount, 1)
        XCTAssertEqual(result.programCount, 1)
        XCTAssertEqual(result.programs[0].channelID, "app-channel")
        XCTAssertEqual(result.programs[0].title, "Tom & Jerry")
        XCTAssertEqual(result.programs[0].subtitle, "Part One")
        XCTAssertEqual(result.programs[0].start, date("20260101020000 +0000"))
        XCTAssertEqual(result.programs[0].end, date("20260101033000 +0000"))
        XCTAssertEqual(result.coverageStart, result.programs[0].start)
        XCTAssertEqual(result.coverageEnd, result.programs[0].end)
    }

    func testPreservesGuideGapsAndDoesNotFabricateMissingStops() throws {
        let xml = """
        <tv>
          <channel id="gap"><display-name>Gap TV</display-name></channel>
          <programme channel="gap" start="20251231230000 +0000" stop="20260101000000 +0000"><title>First</title></programme>
          <programme channel="gap" start="20260101010000 +0000" stop="20260101020000 +0000"><title>Second</title></programme>
          <programme channel="gap" start="20260101020000 +0000"><title>No Stop</title></programme>
          <programme channel="gap" start="20260101030000 +0000" stop="20260101020000 +0000"><title>Backwards</title></programme>
        </tv>
        """
        let result = try LiveTVXMLTVParser().parseXML(
            data: Data(xml.utf8),
            channels: [makeChannel(id: "gap-app", name: "Gap TV", guideID: "gap")],
            now: now
        )
        XCTAssertEqual(result.programs.map(\.title), ["First", "Second"])
        XCTAssertEqual(
            result.programs[1].start.timeIntervalSince(result.programs[0].end),
            3_600
        )
    }

    func testNoMatchingOrCurrentProgramsReportsFeedCoverageHonestly() throws {
        let xml = """
        <tv>
          <channel id="old"><display-name>Old TV</display-name></channel>
          <programme channel="old" start="20200101000000 +0000" stop="20200101010000 +0000"><title>Old</title></programme>
        </tv>
        """
        let result = try LiveTVXMLTVParser().parseXML(
            data: Data(xml.utf8),
            channels: [makeChannel(id: "different", name: "Different", guideID: nil)],
            now: now
        )
        XCTAssertTrue(result.programs.isEmpty)
        XCTAssertEqual(result.matchedChannelCount, 0)
        XCTAssertEqual(result.guideChannelCount, 1)
        XCTAssertEqual(result.programCount, 0)
        XCTAssertEqual(result.coverageStart, date("20200101000000 +0000"))
        XCTAssertEqual(result.coverageEnd, date("20200101010000 +0000"))
    }

    func testMatchedChannelIsReportedEvenWhenItsProgramsAreOutsideTheWindow() throws {
        let xml = """
        <tv>
          <channel id="old"><display-name>Old TV</display-name></channel>
          <programme channel="old" start="20200101000000 +0000" stop="20200101010000 +0000"><title>Old</title></programme>
        </tv>
        """
        let result = try LiveTVXMLTVParser().parseXML(
            data: Data(xml.utf8),
            channels: [makeChannel(id: "old-app", name: "Old TV", guideID: "old")],
            now: now
        )
        XCTAssertEqual(result.matchedChannelCount, 1)
        XCTAssertEqual(result.programCount, 0)
    }

    func testExactIdentitySharesProgramsAcrossStreamVariants() throws {
        let xml = """
        <tv>
          <channel id="station"><display-name>Station</display-name></channel>
          <programme channel="station" start="20260101000000 +0000" stop="20260101010000 +0000"><title>Listing</title></programme>
        </tv>
        """
        let result = try LiveTVXMLTVParser().parseXML(
            data: Data(xml.utf8),
            channels: [
                makeChannel(id: "sd", name: "Station SD", guideID: "station"),
                makeChannel(id: "hd", name: "Station HD", guideID: "station")
            ],
            now: now
        )
        XCTAssertEqual(result.matchedChannelCount, 2)
        XCTAssertEqual(Set(result.programs.map(\.channelID)), ["sd", "hd"])
        XCTAssertEqual(Set(result.programs.map(\.id)).count, 2)
    }

    func testProviderIsForwardedToGuideMatcher() throws {
        let xml = """
        <tv>
          <channel id="station"><display-name>Station</display-name></channel>
          <programme channel="station" start="20260101000000 +0000" stop="20260101010000 +0000"><title>Listing</title></programme>
        </tv>
        """
        let samsungChannel = makeChannel(
            id: "samsung",
            name: "Station",
            guideID: "station",
            streamURL: URL(string: "https://samsung-us.amagi.tv/playlist.m3u8")
        )
        let matching = try LiveTVXMLTVParser(provider: .samsung).parseXML(
            data: Data(xml.utf8),
            channels: [samsungChannel],
            now: now
        )
        let mismatching = try LiveTVXMLTVParser(provider: .plex).parseXML(
            data: Data(xml.utf8),
            channels: [samsungChannel],
            now: now
        )
        XCTAssertEqual(matching.programs.map(\.channelID), ["samsung"])
        XCTAssertEqual(matching.matches["samsung"]?.guideChannelID, "station")
        XCTAssertTrue(mismatching.programs.isEmpty)
        XCTAssertTrue(mismatching.matches.isEmpty)
    }

    func testInterleavedChannelsAndProgramsMatchAcrossWholeDocument() throws {
        let xml = """
        <tv>
          <programme channel="late" start="20260101000000 +0000" stop="20260101010000 +0000"><title>Before Metadata</title></programme>
          <channel id="late"><display-name>Station</display-name></channel>
          <programme channel="late" start="20260101010000 +0000" stop="20260101020000 +0000"><title>After Metadata</title></programme>
        </tv>
        """
        let result = try LiveTVXMLTVParser().parseXML(
            data: Data(xml.utf8),
            channels: [makeChannel(id: "station-app", name: "Station", guideID: "late")],
            now: now
        )
        XCTAssertEqual(result.programs.map(\.title), ["Before Metadata", "After Metadata"])
        XCTAssertEqual(
            result.matches["station-app"],
            LiveTVGuideMatch(guideChannelID: "late", method: .exactID)
        )
    }

    func testStandardExternalDOCTYPEParsesAsPlainAndGzipWithoutLoadingDTD() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE tv SYSTEM "xmltv.dtd">
        <tv>
          <channel id="guide"><display-name>Guide</display-name></channel>
          <programme channel="guide" start="20260101000000 +0000" stop="20260101010000 +0000"><title>Listing</title></programme>
        </tv>
        """
        let channel = makeChannel(id: "app", name: "Guide", guideID: "guide")
        let plain = try LiveTVXMLTVParser().parseXML(
            data: Data(xml.utf8),
            channels: [channel],
            now: now
        )
        let compressed = try LiveTVXMLTVParser().parse(
            gzipData: gzip(Data(xml.utf8)),
            channels: [channel],
            now: now
        )
        XCTAssertEqual(plain.programs.map(\.id), compressed.programs.map(\.id))
        XCTAssertEqual(plain.programs.map(\.title), ["Listing"])
        XCTAssertEqual(plain.matches["app"]?.guideChannelID, "guide")
    }

    func testExternalDTDResourceIsNeverRequired() throws {
        let xml = """
        <?xml version="1.0"?>
        <!DOCTYPE tv SYSTEM "https://example.invalid/unavailable.dtd">
        <tv><channel id="guide"><display-name>Guide</display-name></channel></tv>
        """
        let result = try LiveTVXMLTVParser().parseXML(
            data: Data(xml.utf8),
            channels: [],
            now: now
        )
        XCTAssertEqual(result.guideChannelCount, 1)
    }

    func testRejectsEntityDeclarationsInUTF8AndUTF16() {
        let utf8 = """
        <?xml version="1.0"?>
        <!DOCTYPE tv [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
        <tv><channel id="x"><display-name>&xxe;</display-name></channel></tv>
        """
        XCTAssertThrowsError(
            try LiveTVXMLTVParser().parseXML(
                data: Data(utf8.utf8),
                channels: [],
                now: now
            )
        ) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .invalidGuide)
        }
        let utf16 = """
        <?xml version="1.0" encoding="UTF-16"?>
        <!DOCTYPE tv [<!ENTITY payload "expanded">]>
        <tv><channel id="x"><display-name>&payload;</display-name></channel></tv>
        """
        var utf16Data = Data([0xff, 0xfe])
        utf16Data.append(utf16.data(using: .utf16LittleEndian)!)
        XCTAssertThrowsError(
            try LiveTVXMLTVParser().parseXML(
                data: utf16Data,
                channels: [],
                now: now
            )
        ) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .invalidGuide)
        }
    }

    func testRejectsUnusedAndChunkSplitEntityDeclarationsAcrossEncodings() throws {
        let body = """
        <!DOCTYPE tv [<!ENTITY unused SYSTEM "https://example.invalid/entity">]>
        <tv><channel id="x"><display-name>Station</display-name></channel></tv>
        """
        for padding in [0] + Array(4_040...4_055) + Array(65_480...65_495) {
            let xml = "<?xml version=\"1.0\"?><!----><!--\(String(repeating: "x", count: padding))-->\(body)"
            let data = Data(xml.utf8)
            XCTAssertThrowsError(try LiveTVXMLTVParser().parseXML(data: data, channels: [], now: now))
            XCTAssertThrowsError(try LiveTVXMLTVParser().parse(gzipData: gzip(data), channels: [], now: now))
        }
        for encoding in [String.Encoding.utf16BigEndian, .utf32LittleEndian, .utf32BigEndian] {
            let label = encoding == .utf16BigEndian ? "UTF-16BE" :
                (encoding == .utf32LittleEndian ? "UTF-32LE" : "UTF-32BE")
            let data = try XCTUnwrap(("<?xml version=\"1.0\" encoding=\"\(label)\"?>\(body)").data(using: encoding))
            XCTAssertThrowsError(try LiveTVXMLTVParser().parseXML(data: data, channels: [], now: now))
        }
    }

    func testEntityDeclarationCannotBeIntroducedAfterRootStarts() {
        let xml = "<tv><!--\(String(repeating: "x", count: 65_536))-->"
            + "<!ENTITY late \"expanded\"><channel id=\"x\"><display-name>&late;</display-name></channel></tv>"
        XCTAssertThrowsError(try LiveTVXMLTVParser().parseXML(data: Data(xml.utf8), channels: [], now: now)) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .invalidGuide)
        }
    }

    func testRepeatedChannelDeclarationsMergeNamesWithoutMergingDifferentIDs() throws {
        let identical = """
        <tv>
          <channel id="same"><display-name>Same</display-name></channel>
          <channel id="same"><display-name>Same</display-name></channel>
        </tv>
        """
        let result = try LiveTVXMLTVParser().parseXML(
            data: Data(identical.utf8),
            channels: [],
            now: now
        )
        XCTAssertEqual(result.guideChannelCount, 1)

        let repeated = """
        <tv>
          <channel id="same"><display-name>First</display-name></channel>
          <channel id="same"><display-name>Second</display-name><display-name>First</display-name></channel>
          <channel id="SAME"><display-name>Second</display-name></channel>
          <programme channel="same" start="20260101000000 +0000" stop="20260101010000 +0000"><title>Listing</title></programme>
        </tv>
        """
        let data = Data(repeated.utf8)
        let channels = [
            makeChannel(id: "app", name: "First", guideID: "same"),
            makeChannel(id: "unconfirmed", name: "Second", guideID: nil)
        ]
        let plain = try LiveTVXMLTVParser().parseXML(data: data, channels: channels, now: now)
        let compressed = try LiveTVXMLTVParser().parse(gzipData: gzip(data), channels: channels, now: now)
        var indexedPrograms: [LiveTVPrototypeProgram] = []
        let indexed = try LiveTVXMLTVParser().parseIndexed(data: data, channels: channels, now: now) {
            indexedPrograms.append($0)
        }
        XCTAssertEqual(plain.guideChannels["same"], ["First", "Second"])
        XCTAssertEqual(plain.guideChannels["SAME"], ["Second"])
        XCTAssertEqual(plain.guideChannelCount, 2)
        XCTAssertEqual(plain.programs.map(\.channelID), ["app"])
        XCTAssertNil(plain.matches["unconfirmed"])
        XCTAssertEqual(plain.programs.map(\.id), compressed.programs.map(\.id))
        XCTAssertEqual(plain.programs.map(\.id), indexedPrograms.map(\.id))
        XCTAssertEqual(plain.guideChannels, indexed.guideChannels)
    }

    func testRepeatedDeclarationsStillRespectChannelAndTextBudgets() {
        let repeated = "<channel id=\"same\"><display-name>Same</display-name></channel>"
        let tooMany = "<tv>" + String(repeating: repeated, count: LiveTVXMLTVParser.maximumGuideChannels + 1) + "</tv>"
        XCTAssertThrowsError(try LiveTVXMLTVParser().parseXML(data: Data(tooMany.utf8), channels: [], now: now)) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .guideTooLarge)
        }
        let names = (0..<2_049).map {
            let prefix = String($0)
            return "<channel id=\"same\"><display-name>" + prefix
                + String(repeating: "x", count: LiveTVXMLTVParser.maximumTextLength - prefix.count)
                + "</display-name></channel>"
        }.joined()
        XCTAssertThrowsError(try LiveTVXMLTVParser().parseXML(data: Data(("<tv>" + names + "</tv>").utf8), channels: [], now: now)) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .guideTooLarge)
        }
    }

    func testNestedRootRemainsInvalid() {
        XCTAssertThrowsError(
            try LiveTVXMLTVParser().parseXML(
                data: Data("<tv><tv/></tv>".utf8),
                channels: [],
                now: now
            )
        ) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .invalidGuide)
        }
    }

    func testRejectsMalformedXML() {
        XCTAssertThrowsError(
            try LiveTVXMLTVParser().parseXML(
                data: Data("<tv><channel>".utf8),
                channels: [],
                now: now
            )
        )
    }

    func testConcatenatedGzipMembersValidateEveryTrailerAndRejectTrailingGarbage() throws {
        let first = try gzip(Data("<tv>".utf8))
        let last = try gzip(Data("</tv>".utf8))
        let parsed = try LiveTVXMLTVParser().parse(gzipData: first + last, channels: [], now: now)
        XCTAssertEqual(parsed.programCount, 0)
        let complete = try gzip(Data("<tv/>".utf8))
        var damaged = complete
        damaged[damaged.count - 8] ^= 0xff
        for data in [damaged, Data(complete.dropLast()), complete + Data("garbage".utf8),
                     complete + damaged, complete + Data(last.dropLast())] {
            XCTAssertThrowsError(try LiveTVXMLTVParser().parse(gzipData: data, channels: [], now: now)) {
                XCTAssertEqual($0 as? LiveTVSourceImportError, .invalidGuide)
            }
        }
        XCTAssertThrowsError(
            try LiveTVXMLTVParser(maximumExpandedBytes: 6).parse(
                gzipData: first + last, channels: [], now: now
            )
        ) { XCTAssertEqual($0 as? LiveTVSourceImportError, .guideTooLarge) }
    }

    func testGzipCorruptionAndExpansionLimitAreRejected() throws {
        XCTAssertThrowsError(
            try LiveTVXMLTVParser().parse(
                gzipData: Data(count: LiveTVXMLTVParser.maximumCompressedBytes + 1), channels: [], now: now
            )
        ) { XCTAssertEqual($0 as? LiveTVSourceImportError, .guideTooLarge) }
        XCTAssertThrowsError(
            try LiveTVXMLTVParser().parse(gzipData: Data([0x1f, 0x8b, 0x00, 0x01]), channels: [], now: now)
        ) { XCTAssertEqual($0 as? LiveTVSourceImportError, .invalidGuide) }
        let oversizedXML = "<tv><!--" + String(repeating: "x", count: 1_024) + "--></tv>"
        let compressed = try gzip(Data(oversizedXML.utf8))
        XCTAssertThrowsError(
            try LiveTVXMLTVParser(maximumExpandedBytes: 128).parse(
                gzipData: compressed,
                channels: [],
                now: now
            )
        ) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .guideTooLarge)
        }
    }

    func testOversizedOptionalDescriptionsStayBoundedWithoutDiscardingTheSchedule() throws {
        let description = String(repeating: "é", count: LiveTVXMLTVParser.maximumTextLength)
        let data = Data("""
        <tv>
        <programme channel="guide" start="20260101000000 +0000" stop="20260101010000 +0000">
        <title>Listing</title><desc>\(description)</desc></programme>
        <programme channel="other" start="20260101000000 +0000" stop="20260101010000 +0000">
        <title>Other</title><desc><![CDATA[\(description)]]></desc></programme>
        </tv>
        """.utf8)
        let channels = [makeChannel(id: "app", name: "Guide", guideID: "guide")]
        for result in [
            try LiveTVXMLTVParser().parseXML(data: data, channels: channels, now: now),
            try LiveTVXMLTVParser().parse(gzipData: gzip(data), channels: channels, now: now)
        ] {
            let program = try XCTUnwrap(result.programs.first)
            XCTAssertEqual(result.programs.count, 1)
            XCTAssertEqual(program.title, "Listing")
            XCTAssertEqual(program.details?.description?.utf8.count, LiveTVXMLTVParser.maximumTextLength)
            XCTAssertEqual(program.details?.description, String(description.prefix(LiveTVXMLTVParser.maximumTextLength / 2)))
        }
    }

    func testTextLimitIsEnforcedForMatchedAndUnmatchedListings() {
        let title = String(
            repeating: "x",
            count: LiveTVXMLTVParser.maximumTextLength + 1
        )
        let xml = """
        <tv>
          <channel id="guide"><display-name>Guide</display-name></channel>
          <programme channel="guide" start="20260101000000 +0000" stop="20260101010000 +0000"><title>\(title)</title></programme>
        </tv>
        """
        XCTAssertThrowsError(
            try LiveTVXMLTVParser().parseXML(
                data: Data(xml.utf8),
                channels: [makeChannel(id: "app", name: "Guide", guideID: "guide")],
                now: now
            )
        ) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .guideTooLarge)
        }
        XCTAssertThrowsError(
            try LiveTVXMLTVParser().parseXML(
                data: Data(xml.utf8),
                channels: [],
                now: now
            )
        ) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .guideTooLarge)
        }
    }

    func testCancellationPropagates() async {
        let xml = "<tv>" + (0..<20_000).map {
            #"<channel id="\#($0)"><display-name>Channel \#($0)</display-name></channel>"#
        }.joined() + "</tv>"
        let task = Task {
            try LiveTVXMLTVParser().parseXML(
                data: Data(xml.utf8),
                channels: [],
                now: now
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? LiveTVSourceImportError, .cancelled)
        }
    }

    func testDateParserRejectsInvalidFieldsAndPreservesOffsets() {
        XCTAssertNil(XMLTVDateParser.date(from: "20261301000000 +0000"))
        XCTAssertNil(XMLTVDateParser.date(from: "20260101000000 +2460"))
        XCTAssertNil(XMLTVDateParser.date(from: String(repeating: "\u{06F1}", count: 14) + " +0000"))
        XCTAssertEqual(
            XMLTVDateParser.date(from: "20260101010000 +0100"),
            XMLTVDateParser.date(from: "20260101000000 +0000")
        )
    }

    func testMinutePrecisionAndUnambiguousZeroOffsets() throws {
        for offset in ["", " Z", " UTC", " GMT", " +0000", " +00:00"] {
            XCTAssertEqual(XMLTVDateParser.date(from: "202601010130\(offset)"), date("20260101013000 +0000"))
            XCTAssertEqual(XMLTVDateParser.date(from: "20260101013000\(offset)"), date("20260101013000 +0000"))
        }
        XCTAssertEqual(XMLTVDateParser.date(from: "202601010130 -05:30"), date("20260101070000 +0000"))
        XCTAssertEqual(XMLTVDateParser.date(from: "202601010130+0130"), now)
        for invalid in ["202601", "20260101", "2026010101", "2026010101300", "202601010130000",
                        "202602300130", "202601012430", "202601010160", "202601010130 CST",
                        "202601010130 GMT+01", "202601010130 UTC trailing", "202601010130 +2460",
                        "202601010130 +010", "202601010130 +0x00", "20260101013٠"] {
            XCTAssertNil(XMLTVDateParser.date(from: invalid), invalid)
        }
        let xml = Data("""
        <tv><programme channel="g" start="202601010000 UTC" stop="202601010100 GMT"><title>Minute precision</title></programme></tv>
        """.utf8)
        let channels = [makeChannel(id: "app", name: "Guide", guideID: "g")]
        for result in [
            try LiveTVXMLTVParser().parseXML(data: xml, channels: channels, now: now),
            try LiveTVXMLTVParser().parse(gzipData: gzip(xml), channels: channels, now: now)
        ] {
            XCTAssertEqual(result.programs.count, 1)
            XCTAssertEqual(result.programs.first?.start, now)
            XCTAssertEqual(result.programs.first?.end, now.addingTimeInterval(3_600))
        }
    }

    func testEntityLikeTextInCommentsInstructionsAndCDATAIsNotADeclaration() throws {
        let xml = """
        <?xml version="1.0"?>
        <!-- Example: <!ENTITY not-a-declaration "literal"> -->
        <?guide example="<!ENTITY also-literal 'text'>"?>
        <!DOCTYPE tv [
          <!-- <!ENTITY still-a-comment "text"> -->
        ]>
        <tv><channel id="g"><display-name>Guide</display-name></channel>
          <programme channel="g" start="20260101000000" stop="20260101010000"><title><![CDATA[<!ENTITY literal>]]></title></programme>
        </tv>
        """
        let channel = makeChannel(id: "app", name: "Guide", guideID: "g")
        for result in [
            try LiveTVXMLTVParser().parseXML(data: Data(xml.utf8), channels: [channel], now: now),
            try LiveTVXMLTVParser().parse(gzipData: gzip(Data(xml.utf8)), channels: [channel], now: now)
        ] {
            XCTAssertEqual(result.programs.map(\.title), ["<!ENTITY literal>"])
        }
    }

    func testEntityGuardResumesAfterChunkSplitCommentsAndInstructionsAcrossSupportedEncodings() throws {
        for padding in [0, 4_037, 4_045, 65_477, 65_485] {
            for literal in [
                "<!--\(String(repeating: "x", count: padding)) <!ENTITY example 'literal'> -->",
                "<?guide \(String(repeating: "x", count: padding)) <!ENTITY example 'literal'> ?>"
            ] {
                for (label, encoding) in [
                    ("UTF-8", String.Encoding.utf8), ("UTF-16LE", .utf16LittleEndian),
                    ("UTF-16BE", .utf16BigEndian), ("UTF-32BE", .utf32BigEndian)
                ] {
                    let prefix = "<?xml version=\"1.0\" encoding=\"\(label)\"?>\(literal)"
                    let harmless = try XCTUnwrap((prefix + "<tv/>").data(using: encoding))
                    XCTAssertNoThrow(
                        try LiveTVXMLTVParser().parseXML(data: harmless, channels: [], now: now),
                        "\(label) padding=\(padding)"
                    )
                    let declaration = "<!DOCTYPE tv [<!ENTITY private SYSTEM 'https://private.invalid/token'>]>"
                    let forbidden = try XCTUnwrap((prefix + declaration + "<tv/>").data(using: encoding))
                    XCTAssertThrowsError(try LiveTVXMLTVParser().parseXML(data: forbidden, channels: [], now: now)) {
                        XCTAssertEqual($0 as? LiveTVSourceImportError, .invalidGuide)
                    }
                    XCTAssertThrowsError(try LiveTVXMLTVParser().parse(gzipData: gzip(forbidden), channels: [], now: now))
                }
            }
        }
    }

    func testParseDiagnosticsIdentifyFailuresWithoutIncludingFeedContent() throws {
        let privateText = "private-channel-https://secret.invalid/password"
        for (xml, reason) in [
            ("<tv>\n<channel id=\"\(privateText)\"><display-name>Private</channel></tv>", "syntax"),
            ("<html><title>\(privateText)</title></html>", "root"),
            ("<!DOCTYPE tv [<!ENTITY private SYSTEM 'https://secret.invalid/password'>]><tv/>", "entity"),
            ("<tv><tv>\(privateText)</tv></tv>", "structure")
        ] {
            let since = Date()
            XCTAssertThrowsError(try LiveTVXMLTVParser().parseXML(data: Data(xml.utf8), channels: [], now: now))
            let messages = PlozzLog.recentEntries(limit: 50).filter {
                $0.date >= since && $0.message.hasPrefix("XMLTV_PARSE ")
            }.map(\.message)
            XCTAssertEqual(messages.count, 1, reason)
            let message = try XCTUnwrap(messages.first)
            XCTAssertTrue(message.contains("pass=metadata outcome=failed reason=\(reason)"), message)
            for field in ["code=", "line=", "column=", "channels=", "programmes="] {
                XCTAssertTrue(message.contains(field), field)
            }
            if reason == "syntax" {
                XCTAssertFalse(message.contains("code=unknown"))
                XCTAssertTrue(message.contains("line=2 "))
            }
            for secret in ["private-channel", "secret.invalid", "password", "Private", "unknown;"] {
                XCTAssertFalse(message.contains(secret), message)
            }
        }
    }
    private func programsAcrossParserPaths(
        _ xml: String, preferredLanguage: String?
    ) throws -> [[LiveTVPrototypeProgram]] {
        let parser = LiveTVXMLTVParser(preferredLanguage: preferredLanguage)
        let channels = [makeChannel(id: "app", name: "Guide", guideID: "g")]
        let data = Data(xml.utf8)
        let compressed = try gzip(data)
        var results = [
            try parser.parseXML(data: data, channels: channels, now: now).programs,
            try parser.parse(gzipData: compressed, channels: channels, now: now).programs
        ]
        for input in [data, compressed] {
            var programs: [LiveTVPrototypeProgram] = []
            let result = try parser.parseIndexed(data: input, channels: channels, now: now) {
                programs.append($0)
            }
            XCTAssertEqual(result.programCount, programs.count)
            results.append(programs)
        }
        for programs in results.dropFirst() {
            XCTAssertEqual(programs, results[0])
        }
        return results
    }

    private func makeChannel(
        id: String,
        name: String,
        guideID: String?,
        streamURL: URL? = URL(string: "https://example.com/live.m3u8")
    ) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id,
            number: 1,
            name: name,
            category: "Test",
            symbol: "tv.fill",
            accent: 0,
            source: .iptv,
            tagline: "Test",
            streamURL: streamURL,
            guideID: guideID
        )
    }

    private func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        return formatter.date(from: value)!
    }

    private func gzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(
            &stream,
            Z_BEST_SPEED,
            Z_DEFLATED,
            15 + 16,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            throw LiveTVSourceImportError.invalidGuide
        }
        defer { deflateEnd(&stream) }

        var result = Data()
        var input = [UInt8](data)
        let status = input.withUnsafeMutableBytes { bytes -> Int32 in
            stream.next_in = bytes.baseAddress!.assumingMemoryBound(to: Bytef.self)
            stream.avail_in = uInt(bytes.count)
            repeat {
                var output = [UInt8](repeating: 0, count: 64 * 1_024)
                let code = output.withUnsafeMutableBytes { outputBytes -> Int32 in
                    stream.next_out = outputBytes.baseAddress!
                        .assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(outputBytes.count)
                    return deflate(&stream, Z_FINISH)
                }
                let produced = output.count - Int(stream.avail_out)
                result.append(contentsOf: output.prefix(produced))
                if code == Z_STREAM_END { return code }
                if code != Z_OK { return code }
            } while true
        }
        guard status == Z_STREAM_END else {
            throw LiveTVSourceImportError.invalidGuide
        }
        return result
    }
}
#endif
