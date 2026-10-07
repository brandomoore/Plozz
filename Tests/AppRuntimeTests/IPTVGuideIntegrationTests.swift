import CoreModels
import Foundation
import ProviderIPTV
@testable import AppRuntime
import XCTest

final class IPTVGuideIntegrationTests: XCTestCase {
    func testAccountGuideUsesThePlaylistGuideNameWithoutWeakeningIdentityChecks() async throws {
        let data = Data("""
        <tv>
          <channel id="news.us"><display-name>News</display-name></channel>
          <programme channel="news.us" start="19700101000140 +0000" stop="19700101000820 +0000">
            <title>Bulletin</title>
          </programme>
        </tv>
        """.utf8)
        let channels: [IPTVProvider.IPTVGuideChannel] = [
            .init(id: "matched", name: "101 - News Live", guideID: "NEWS.us", guideName: "News", country: "US"),
            .init(id: "wrong-region", name: "News", guideID: "NEWS.ca", guideName: "News", country: "CA"),
            .init(id: "name-only", name: "News", guideID: nil, guideName: "News")
        ]
        for channel in channels {
            let programmes = try await ManagedProviderRegistry.iptvGuideLoader(
                data, XCTUnwrap(URL(string: "https://provider.test/guide.xml")), [channel],
                Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 500)
            )
            XCTAssertEqual(programmes.map(\.channelID), channel.id == "matched" ? ["matched"] : [])
            if channel.id == "matched" { XCTAssertEqual(programmes.map(\.title), ["Bulletin"]) }
        }
    }
}
