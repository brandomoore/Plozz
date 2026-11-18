import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVChannelNameTests: XCTestCase {
    func testCleanupChangesOnlyPresentationAndNeverCombinesProviderChannels() throws {
        let channels = [
            channel("one", sourceID: "first"),
            channel("two", sourceID: "second")
        ]
        let model = LiveTVPrototypeModel(channels: channels)
        let program = LiveTVPrototypeProgram(
            id: "program", channelID: "one", title: "News", subtitle: "",
            start: model.now.addingTimeInterval(-60), end: model.now.addingTimeInterval(600)
        )
        try model.replacePrograms([program])
        model.toggleFavorite("one")
        model.tune("one")
        XCTAssertTrue(model.recordWatched("one"))
        model.cleanChannelNames = true
        XCTAssertEqual(model.channels.map(\.name), ["UK | BBC One HD", "UK | BBC One HD"])
        XCTAssertEqual(model.channels.map(\.id), channels.map(\.id))
        for (original, displayed) in zip(channels, model.channels) {
            XCTAssertEqual(displayed.streamURL, original.streamURL)
            XCTAssertEqual(displayed.httpHeaders, original.httpHeaders)
            XCTAssertEqual(displayed.guideID, original.guideID)
            XCTAssertEqual(displayed.guideName, original.guideName)
            XCTAssertEqual(displayed.configuredSourceID, original.configuredSourceID)
            XCTAssertEqual(displayed.country, original.country)
            XCTAssertEqual(displayed.number, original.number)
        }
        XCTAssertEqual(model.currentProgram(for: "one"), program)
        XCTAssertEqual(model.playingChannelID, "one")
        XCTAssertEqual(model.favoriteIDs, ["one"])
        XCTAssertEqual(model.recentChannelIDs, ["one"])
        model.cleanChannelNames = false
        XCTAssertEqual(model.channels, channels)
        XCTAssertEqual(model.currentProgram(for: "one"), program)
        XCTAssertEqual(model.playingChannelID, "one")
    }

    func testCustomNamesAndNonIPTVSourcesAreNotRewritten() throws {
        let channels = [channel("iptv")] + [LiveTVPrototypeSource.plex, .jellyfin, .emby, .plozz].map {
            channel($0.rawValue, source: $0)
        }
        let model = LiveTVPrototypeModel(channels: channels)
        model.cleanChannelNames = true
        XCTAssertEqual(model.channels.dropFirst().map(\.name), channels.dropFirst().map(\.name))
        let custom = "## My H D ##"
        XCTAssertTrue(model.setMetadataOverride(.init(name: custom), channelID: "iptv"))
        XCTAssertEqual(model.channel(id: "iptv")?.name, custom)
        model.cleanChannelNames = false
        XCTAssertEqual(model.channel(id: "iptv")?.name, custom)
        model.cleanChannelNames = true
        XCTAssertTrue(model.setMetadataOverride(.init(category: "Personal"), channelID: "iptv"))
        XCTAssertEqual(model.channel(id: "iptv")?.name, "UK | BBC One HD")
        XCTAssertEqual(model.channel(id: "iptv")?.category, "Personal")
        XCTAssertTrue(model.setMetadataOverride(nil, channelID: "iptv"))
        try model.replaceChannels([channel("iptv", name: "## UK|BBC One U H D ##")])
        XCTAssertEqual(model.channel(id: "iptv")?.name, "UK | BBC One UHD")
        model.cleanChannelNames = false
        XCTAssertEqual(model.channel(id: "iptv")?.name, "## UK|BBC One U H D ##")
    }

    func testRecoveryLabelsDoNotPersistCleanedNamesWhenASourceDisappears() throws {
        let original = channel("one")
        let model = LiveTVPrototypeModel(channels: [original])
        model.cleanChannelNames = true
        model.toggleFavorite(original.id)
        XCTAssertTrue(model.hideChannel(try XCTUnwrap(model.channel(id: original.id))))
        try model.replaceChannels([])
        model.cleanChannelNames = false
        XCTAssertEqual(model.unavailableFavorites.first?.name, original.name)
        XCTAssertEqual(model.hiddenChannels.first?.name, original.name)
    }

    func testDisplayedNamesDriveSearchAndSortingWithoutHidingSameNamedChannels() {
        let model = LiveTVPrototypeModel(channels: [
            channel("z", name: "## Zed H D ##"),
            channel("a", name: "** Alpha H D **"),
            channel("other-a", name: "Alpha HD", sourceID: "other")
        ])
        model.cleanChannelNames = true
        model.sort = .name
        XCTAssertEqual(model.visibleChannels.map(\.name), ["Alpha HD", "Alpha HD", "Zed HD"])
        model.query = "Alpha HD"
        XCTAssertEqual(Set(model.visibleChannels.map(\.id)), ["a", "other-a"])
    }

    private func channel(
        _ id: String, name: String = "## UK|BBC One H D ##",
        sourceID: String = "source", source: LiveTVPrototypeSource = .iptv
    ) -> LiveTVPrototypeChannel {
        .init(
            id: id, number: 7, name: name, category: "News", symbol: "tv", accent: 0,
            source: source, tagline: "", streamURL: URL(string: "https://example.test/\(id).m3u8"),
            guideID: "bbc-one-\(sourceID)", guideName: "Original guide name",
            httpHeaders: ["User-Agent": "PlozzFixture"], configuredSourceID: sourceID,
            language: "en", country: "UK", groups: ["News"]
        )
    }
}
