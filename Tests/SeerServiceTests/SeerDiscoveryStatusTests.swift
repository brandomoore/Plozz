import CoreModels
import XCTest
@testable import SeerService

@MainActor
final class SeerDiscoveryStatusTests: XCTestCase {
    private func service(_ http: SeerRecordingHTTPClient) -> SeerService {
        SeerService(
            connectionStore: InMemorySeerConnectionStore(connection: .init(
                baseURL: URL(string: "https://requests.example.test")!, apiKey: "fixture"
            )),
            http: http
        )
    }

    func testRequestIdentityRequiresSupportedKindAndPositiveTMDBID() {
        let service = service(SeerRecordingHTTPClient())
        XCTAssertTrue(service.hasRequestIdentity(for: MediaItem(
            id: "tmdb", title: "Movie", kind: .movie, providerIDs: ["Tmdb": "42"]
        )))
        XCTAssertFalse(service.hasRequestIdentity(for: MediaItem(
            id: "anilist", title: "Anime", kind: .series, providerIDs: ["AniList": "42"]
        )))
        XCTAssertFalse(service.hasRequestIdentity(for: MediaItem(
            id: "bad", title: "Bad", kind: .movie, providerIDs: ["Tmdb": "-1"]
        )))
        XCTAssertFalse(service.hasRequestIdentity(for: MediaItem(
            id: "episode", title: "Episode", kind: .episode, providerIDs: ["Tmdb": "42"]
        )))
    }

    func testStatusUsesDisplayedIDsAndSkipsUnrequestableTitles() async {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/movie/42", json: #"{"mediaInfo":{"status":2}}"#)
        let items = [
            MediaItem(
                id: "outside-trending", title: "Movie", kind: .movie,
                providerIDs: ["Tmdb": "42"], discoverySources: [.simkl],
                availability: .unknown, locallyValidatedPlayableSource: false
            ),
            MediaItem(
                id: "anime", title: "Anime", kind: .series,
                providerIDs: ["AniList": "9"], discoverySources: [.anilist],
                availability: .unknown, locallyValidatedPlayableSource: false
            )
        ]
        let updates = await service(http).availabilityUpdates(for: items)
        XCTAssertEqual(updates.map(\.id), ["outside-trending"])
        XCTAssertEqual(updates.first?.availability, .pending)
        XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/movie/42") }.count, 1)
        XCTAssertFalse(http.sentPaths.contains { $0.contains("/discover/") })
    }
}
