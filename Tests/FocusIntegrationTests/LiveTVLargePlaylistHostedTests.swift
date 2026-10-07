import FeatureLiveTVCore
import Foundation
import XCTest

@MainActor
final class LiveTVLargePlaylistHostedTests: XCTestCase {
    func testLargeImportedCatalogPublicationStaysBelowOneSecond() async throws {
        let channels = await Task.detached {
            (0..<100_000).map { index in
                LiveTVPrototypeChannel(
                    id: "large-\(index)", number: index + 1,
                    name: "Channel \(100_000 - index)", category: "Group \(index % 80)",
                    symbol: "tv", accent: 0, source: .iptv, tagline: "",
                    language: "English", country: "US"
                )
            }
        }.value
        for count in [10_000, 100_000] {
            for sort in [LiveTVPrototypeSort.channelNumber, .name] {
                let model = LiveTVPrototypeModel(channels: [])
                model.sort = sort
                let input = Array(channels.prefix(count))
                let start = ContinuousClock.now
                try model.replaceCatalog(channels: input, programs: [])
                let elapsed = start.duration(to: .now)
                let attachment = XCTAttachment(string: "channels=\(count) sort=\(sort) mainThread=\(elapsed)")
                attachment.name = "live-tv-publication-\(count)-\(sort)"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertLessThan(elapsed, .seconds(1), "Catalogue publication must leave headroom below the hang threshold.")
                XCTAssertEqual(model.channels.count, count)
                XCTAssertEqual(model.visibleChannels.count, count)
                XCTAssertEqual(model.guideChannels.count, count)
            }
        }
    }
}
