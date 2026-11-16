#if DEBUG
import Foundation
import XCTest
@testable import FeatureLiveTVCore

final class LiveTVGuideMatcherTests: XCTestCase {
    func testMatchesOnlyUniqueDisplayNamesAndTechnicalResolutionSuffixes() {
        let channels = [
            channel(id: "one", name: "ACC Network (720p)", guideID: "ACCNetwork.us@SD"),
            channel(id: "two", name: "Movies! (480p)", guideID: "Movies.us@SD"),
        ]
        let result = LiveTVGuideMatcher().match(
            channels: channels,
            guideChannels: [
                "ACC.Network.us2": ["ACC Network"],
                "Movies!.us2": ["Movies!"],
            ]
        )
        XCTAssertEqual(result["ACC.Network.us2"]?.map(\.id), ["one"])
        XCTAssertEqual(result["Movies!.us2"]?.map(\.id), ["two"])
    }

    func testRejectsAmbiguousNamesDifferentRegionsAffiliatesAndTimeShifts() {
        let channels = [
            channel(id: "a", name: "Comet", guideID: "Comet.us@SD"),
            channel(id: "b", name: "Comet", guideID: "Comet.us@West"),
            channel(id: "c", name: "KABC 7", guideID: "KABC.us"),
            channel(id: "d", name: "HBO", guideID: "HBO.us@East"),
            channel(id: "e", name: "News +1", guideID: "News.us@+1"),
            channel(id: "f", name: "Haunt TV", guideID: "HauntTV.ca@SD"),
        ]
        let result = LiveTVGuideMatcher().match(
            channels: channels,
            guideChannels: [
                "Comet.us2": ["Comet"],
                "WABC.New.York.us2": ["KABC 7"],
                "HBO.us2": ["HBO"],
                "News.us2": ["News +1"],
                "Haunt.TV.us2": ["Haunt TV"],
            ]
        )
        XCTAssertTrue(result.isEmpty)
    }
    func testVerifiedProviderAliasesRemainExactAndConservative() {
        let channels = [
            channel(
                id: "english",
                name: "3ABN English",
                guideID: "3ABNEnglish.us@SD"
            ),
            channel(
                id: "proclaim",
                name: "3ABN Proclaim! Network",
                guideID: "3ABNProclaimNetwork.us@SD"
            ),
        ]
        let result = LiveTVGuideMatcher(aliasSet: .iptvOrgToEPGShareUS2Version1).match(
            channels: channels,
            guideChannels: [
                "3ABN.us2": ["3ABN"],
                "3ABN.Proclaim.Network.us2": ["3ABN Proclaim Network"],
                "3ABN.Radio.Network.us2": ["3ABN Radio Network"],
            ]
        )
        XCTAssertEqual(result["3ABN.us2"]?.map(\.id), ["english"])
        XCTAssertEqual(result["3ABN.Proclaim.Network.us2"]?.map(\.id), ["proclaim"])
        XCTAssertNil(result["3ABN.Radio.Network.us2"])
    }

    func testStreamVariantsWithOneExactIDShareTheGuide() {
        let channels = [
            channel(id: "one", name: "Station SD", guideID: "station"),
            channel(id: "two", name: "Station HD", guideID: "station")
        ]
        let matches = LiveTVGuideMatcher().match(channels: channels, guideChannels: ["station": ["Station"]])
        XCTAssertEqual(Set(matches["station"]?.map(\.id) ?? []), ["one", "two"])
    }

    func testGuideAliasesCannotArbitrarilyChooseBetweenDifferentStations() {
        let channels = [
            channel(id: "one", name: "News", guideID: "a"),
            channel(id: "two", name: "Noticias", guideID: "b")
        ]
        XCTAssertTrue(LiveTVGuideMatcher().match(
            channels: channels, guideChannels: ["station": ["News", "Noticias"]]
        ).isEmpty)
    }

    func testPlutoNativeIDBeatsNamesAndDoesNotGuessWhenIDIsMissing() {
        let id = "62ba60f059624e000781c436"
        let channels = [
            channel(id: "exact", name: "Renamed stream", guideID: "Replay.us@SD",
                    streamURL: "https://jmp2.uk/plu-\(id).m3u8"),
            channel(id: "different-region", name: "Replay", guideID: "Replay.us@HD",
                    streamURL: "https://jmp2.uk/plu-000000000000000000000000.m3u8"),
            channel(id: "lookalike-host", name: "Replay", guideID: "Replay.us@FHD",
                    streamURL: "https://jmp2.uk.example.com/plu-\(id).m3u8")
        ]
        let result = LiveTVGuideMatcher(provider: .pluto).matching(
            channels: channels, guideChannels: [id: ["Replay"]]
        )
        XCTAssertEqual(result.channelsByGuideID[id]?.map(\.id), ["exact"])
        XCTAssertEqual(result.assignments["exact"]?.method, .nativeID)
        XCTAssertEqual(result.assignments.count, 1)
    }

    func testProviderNamesDoNotCrossProvidersOrGuessUnknownStreamOrigins() {
        let channels = [
            channel(id: "plex", name: "Movies (720p) [Not 24/7]", guideID: "Movies.us@SD",
                    streamURL: "https://example-movies-plex.amagi.tv/playlist.m3u8"),
            channel(id: "samsung", name: "Movies", guideID: "Movies.us@HD",
                    streamURL: "https://example-movies-samsungus.amagi.tv/playlist.m3u8"),
            channel(id: "unknown", name: "Movies", guideID: "Movies.us@FHD")
        ]
        let guide = ["station": ["Movies"]]
        let result = LiveTVGuideMatcher(provider: .plex).matching(channels: channels, guideChannels: guide)
        XCTAssertTrue(result.assignments.isEmpty)
        XCTAssertTrue(LiveTVGuideMatcher(provider: .samsung).match(channels: channels, guideChannels: guide).isEmpty)
        XCTAssertTrue(LiveTVGuideMatcher().match(channels: channels, guideChannels: guide).isEmpty)
    }

    func testUSGuideRejectsExplicitForeignSamsungFeedsEvenWithUSPlaylistIDs() {
        let hosts = [
            "station-samsungau.amagi.tv", "station-samsunguk.amagi.tv",
            "station-1-nl.samsung.wurl.tv", "station-samsung-ca.amagi.tv",
            "station-samsungmx.amagi.tv"
        ]
        let channels = hosts.enumerated().map { index, host in
            channel(id: "\(index)", name: "Station", guideID: "Station.us",
                    streamURL: "https://\(host)/playlist.m3u8")
        }
        XCTAssertTrue(LiveTVGuideMatcher(provider: .samsung).match(
            channels: channels, guideChannels: ["Station.us": ["Station"]]
        ).isEmpty)
    }

    func testAccountGuideGivesEveryChannelCarryingAnIDItsListingsWhateverElseIsRequested() {
        let copies = [
            channel(id: "hd", name: "UK: Sky Cinema Premiere HD", guideID: "premiere.uk"),
            channel(id: "4k", name: "UK: Sky Cinema Premiere 4K", guideID: "premiere.uk"),
            channel(id: "backup", name: "VIP | Premiere (backup)", guideID: "premiere.uk"),
            channel(id: "other", name: "Other", guideID: "missing.uk")
        ]
        let guide = ["premiere.uk": ["Sky Cinema Premiere"]]
        let matcher = LiveTVGuideMatcher()
        XCTAssertTrue(
            matcher.match(channels: copies, guideChannels: guide).isEmpty,
            "A playlist paired with another guide keeps the stricter rule"
        )
        let together = matcher.match(channels: copies, guideChannels: guide, trustsGuideIDs: true)
        XCTAssertEqual(together["premiere.uk"]?.map(\.id), ["hd", "4k", "backup"])
        XCTAssertNil(together["missing.uk"])

        let cased = [channel(id: "a", name: "A", guideID: " Premiere.UK "), channel(id: "b", name: "B", guideID: "DAVE.uk")]
        let folded = matcher.match(
            channels: cased, guideChannels: ["premiere.uk": [], "Dave.uk": [], "dave.UK": []], trustsGuideIDs: true
        )
        XCTAssertEqual(folded["premiere.uk"]?.map(\.id), ["a"], "Case and stray spaces do not hide listings")
        // Declared under several spellings: the channel's own comes first, then the rest.
        XCTAssertEqual(folded["Dave.uk"]?.map(\.id), ["b"])
        XCTAssertEqual(folded["dave.UK"]?.map(\.id), ["b"])
        let own = matcher.matching(
            channels: [channel(id: "c", name: "C", guideID: "Dave.uk")],
            guideChannels: ["Dave.uk": [], "dave.UK": []], trustsGuideIDs: true
        )
        XCTAssertEqual(own.assignments["c"]?.guideChannelID, "Dave.uk")
        // The answer for a channel does not depend on what is on screen with it.
        for copy in copies.prefix(3) {
            let alone = matcher.match(channels: [copy], guideChannels: guide, trustsGuideIDs: true)
            XCTAssertEqual(alone["premiere.uk"]?.map(\.id), [copy.id])
        }
    }

    func testExplicitGuideIDCanIdentifyAStreamWithUnknownDistributor() {
        let channels = [channel(id: "one", name: "Different name", guideID: "provider-native")]
        let result = LiveTVGuideMatcher(provider: .plex).matching(
            channels: channels, guideChannels: ["provider-native": ["Guide name"]]
        )
        XCTAssertEqual(result.assignments["one"]?.method, .exactID)
    }

    func testSameNamedChannelWithoutGuideIDBlocksPlaylistNameMatch() {
        let guided = channel(id: "guided", name: "ACC Network", guideID: "ACCNetwork.us@SD")
        let unguided = LiveTVPrototypeChannel(
            id: "unguided", number: 2, name: "ACC Network", category: "Test", symbol: "tv",
            accent: 0, source: .iptv, tagline: "", guideID: nil
        )
        let matcher = LiveTVGuideMatcher()
        let stations = ["ACC.Network.us2": ["ACC Network"]]
        XCTAssertFalse(matcher.match(channels: [guided], guideChannels: stations).isEmpty)
        XCTAssertTrue(matcher.match(channels: [guided, unguided], guideChannels: stations).isEmpty)
    }

    func testNameMemoDoesNotWipeDuringMaximumLineupAndStaysBounded() {
        let memo = LiveTVGuideMatcher.NormalizedNames()
        var computed = 0
        func make(_ input: String) -> String { computed += 1; return input.lowercased() }
        for i in 0..<100_000 { _ = memo.value(for: "Channel \(i)", make: make) }
        for i in 0..<100_000 { _ = memo.value(for: "Channel \(i)", make: make) }
        XCTAssertEqual(computed, 100_000)
        for i in 100_000..<200_001 { _ = memo.value(for: "Channel \(i)", make: make) }
        _ = memo.value(for: "Channel 0", make: make)
        XCTAssertEqual(computed, 200_001, "The full memo never discards earlier entries")
        _ = memo.value(for: "Channel 200000", make: make)
        XCTAssertEqual(computed, 200_002, "New entries are not retained beyond the bound")
    }

    private func channel(
        id: String,
        name: String,
        guideID: String,
        streamURL: String? = nil
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
            streamURL: URL(string: streamURL ?? "https://example.com/\(id).m3u8"),
            guideID: guideID
        )
    }
}
#endif
