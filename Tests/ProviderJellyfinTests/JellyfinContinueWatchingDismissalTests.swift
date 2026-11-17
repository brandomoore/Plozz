import CoreModels
import CoreNetworking
import XCTest
@testable import ProviderJellyfin

/// Jellyfin has no "remove from Continue Watching" of its own. Clearing a saved
/// position takes a title off `Items/Resume`, but `Shows/NextUp` then offers the
/// same episode straight back, so Plozz has to remember the dismissal itself.
final class JellyfinContinueWatchingDismissalTests: XCTestCase {
    private let empty = #"{"Items":[],"TotalRecordCount":0}"#

    private func session(kind: ProviderKind = .jellyfin) -> UserSession {
        UserSession(
            server: MediaServer(
                id: "server", name: "Home", baseURL: URL(string: "https://media.test")!, provider: kind
            ),
            userID: "viewer", userName: "Viewer", deviceID: "test-device", accessToken: "TEST_TOKEN"
        )
    }

    private func provider(
        _ http: StubHTTPClient, kind: ProviderKind = .jellyfin,
        profileID: String = "profile", store: DurableLocalStateStore? = nil
    ) -> JellyfinProvider {
        JellyfinProvider(
            session: session(kind: kind),
            accountID: "account",
            localMediaContext: store.map { _ in
                LocalMediaContext(accountID: "account", profileID: profileID, profileNamespace: nil)
            },
            durableStore: store,
            http: http
        )
    }

    private func episode(_ id: String, ticks: Int64 = 0, lastPlayed: String?) -> String {
        let date = lastPlayed.map { #","LastPlayedDate":"\#($0)""# } ?? ""
        return #"{"Id":"\#(id)","Type":"Episode","SeriesId":"series","UserData":{"PlaybackPositionTicks":\#(ticks)\#(date)}}"#
    }

    private func items(_ dtos: String...) -> String {
        #"{"Items":[\#(dtos.joined(separator: ","))],"TotalRecordCount":\#(dtos.count)}"#
    }

    /// An in-progress episode: the position is cleared without stamping a new
    /// last-played date, and the episode stays off the row even though Next Up
    /// now offers it as the next one to watch.
    func testRemovingAnInProgressEpisodeClearsItsPositionAndKeepsNextUpFromOfferingItBack() async throws {
        let http = StubHTTPClient()
        http.stubSequence(pathSuffix: "/Users/viewer/Items", jsons: [
            items(episode("e1", ticks: 6_000_000_000, lastPlayed: "2026-11-01T20:00:00Z")),
            items(episode("e1", lastPlayed: "2026-11-01T20:00:00Z"))
        ])
        http.stub(pathSuffix: "/UserItems/e1/UserData", json: "{}")
        let provider = provider(http)

        try await provider.removeFromContinueWatching(itemID: "e1")

        let body = try XCTUnwrap(http.sentBodies["/UserItems/e1/UserData"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["PlaybackPositionTicks"] as? Int, 0)
        XCTAssertNil(object["LastPlayedDate"], "A dismissal must not move the series to the front of Next Up")
        XCTAssertNil(object["Played"], "Removing is not a claim about having watched it")

        http.stub(pathSuffix: "/Items/Resume", json: empty)
        http.stub(pathSuffix: "/Shows/NextUp", json: items(
            episode("e1", lastPlayed: "2026-11-01T20:00:00Z"),
            episode("other", lastPlayed: "2026-10-01T20:00:00Z")
        ))
        let row = try await provider.continueWatching(limit: 10)
        XCTAssertEqual(row.map(\.id), ["other"])
    }

    /// A Next Up suggestion has no position to clear, so nothing is written to
    /// the server — the dismissal is Plozz's alone.
    func testRemovingANextUpSuggestionWritesNothingAndHidesIt() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/Users/viewer/Items", json: items(episode("e2", lastPlayed: "2026-11-02T20:00:00Z")))
        let provider = provider(http)

        try await provider.removeFromContinueWatching(itemID: "e2")
        XCTAssertFalse(http.sentMethods.contains(.post))

        http.stub(pathSuffix: "/Items/Resume", json: empty)
        http.stub(pathSuffix: "/Shows/NextUp", json: items(episode("e2", lastPlayed: "2026-11-02T20:00:00Z")))
        let row = try await provider.continueWatching(limit: 10)
        XCTAssertTrue(row.isEmpty)
        let nextUpRow = try await provider.homeNextUp(libraryID: "shows", limit: 10)
        XCTAssertTrue(nextUpRow.isEmpty, "A separate Next Up row must not offer it back either")
    }

    /// Playing the title again is the viewer changing their mind: it returns on
    /// its own, judged by the server's clock on both sides of the comparison.
    func testATitlePlayedAfterItsDismissalComesBack() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/Users/viewer/Items", json: items(episode("e3", lastPlayed: "2026-11-03T20:00:00Z")))
        let provider = provider(http)
        try await provider.removeFromContinueWatching(itemID: "e3")

        http.stub(pathSuffix: "/Shows/NextUp", json: empty)
        http.stubSequence(pathSuffix: "/Items/Resume", jsons: [
            items(episode("e3", ticks: 1_200_000_000, lastPlayed: "2026-11-03T20:00:00Z")),
            items(episode("e3", ticks: 1_200_000_000, lastPlayed: "2026-11-04T20:00:00Z")),
            items(episode("e3", ticks: 1_200_000_000, lastPlayed: "2026-11-03T20:00:00Z"))
        ])
        let unchanged = try await provider.continueWatching(limit: 10)
        XCTAssertTrue(unchanged.isEmpty)
        let replayed = try await provider.continueWatching(limit: 10)
        XCTAssertEqual(replayed.map(\.id), ["e3"])
        let afterwards = try await provider.continueWatching(limit: 10)
        XCTAssertEqual(afterwards.map(\.id), ["e3"], "A replay ends the dismissal rather than pausing it")
    }

    /// Emby resets omitted fields, so it is sent back the stamp it already had
    /// rather than none at all or a new one.
    func testEmbyIsSentBackItsExistingLastPlayedDate() async throws {
        let http = StubHTTPClient()
        http.stubSequence(pathSuffix: "/Users/viewer/Items", jsons: [
            items(episode("e4", ticks: 6_000_000_000, lastPlayed: "2026-11-01T20:00:00Z")),
            items(episode("e4", lastPlayed: "2026-11-01T20:00:00Z"))
        ])
        http.stub(pathSuffix: "/Users/viewer/Items/e4", json: #"{"UserData":{"Played":false}}"#)
        http.stub(pathSuffix: "/Users/viewer/Items/e4/UserData", json: "{}")
        let provider = provider(http, kind: .emby)

        try await provider.removeFromContinueWatching(itemID: "e4")

        let body = try XCTUnwrap(http.sentBodies["/Users/viewer/Items/e4/UserData"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["PlaybackPositionTicks"] as? Int, 0)
        let sent = try XCTUnwrap(object["LastPlayedDate"] as? String)
        XCTAssertEqual(JellyfinProvider.parseDate(sent), JellyfinProvider.parseDate("2026-11-01T20:00:00Z"))
        XCTAssertEqual(object["Played"] as? Bool, false)
    }

    /// A dismissal survives the provider being rebuilt, and belongs to the Plozz
    /// profile that made it.
    func testDismissalsPersistPerProfile() async throws {
        let store = try DurableLocalStateStore(secureStore: MemorySecureStore())
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/Users/viewer/Items", json: items(episode("e5", lastPlayed: "2026-11-05T20:00:00Z")))
        http.stub(pathSuffix: "/Items/Resume", json: empty)
        http.stub(pathSuffix: "/Shows/NextUp", json: items(episode("e5", lastPlayed: "2026-11-05T20:00:00Z")))

        try await provider(http, store: store).removeFromContinueWatching(itemID: "e5")

        let rebuilt = try await provider(http, store: store).continueWatching(limit: 10)
        XCTAssertTrue(rebuilt.isEmpty)
        let otherProfile = try await provider(http, profileID: "other", store: store).continueWatching(limit: 10)
        XCTAssertEqual(otherProfile.map(\.id), ["e5"])
    }

    /// Ordinary resume writes still stamp recency, so a play floats its title
    /// to the front of Continue Watching.
    func testResumeWritesStillStampLastPlayedDate() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/UserItems/e6/UserData", json: "{}")
        try await provider(http).setResumePosition(0, itemID: "e6", capturedAt: Date(timeIntervalSince1970: 1_800_000_000))

        let body = try XCTUnwrap(http.sentBodies["/UserItems/e6/UserData"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNotNil(object["LastPlayedDate"])
    }
}

private final class MemorySecureStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func setString(_ value: String, for key: String) throws { lock.withLock { values[key] = value } }
    func string(for key: String) -> String? { lock.withLock { values[key] } }
    func readString(for key: String) throws -> String? { lock.withLock { values[key] } }
    func removeValue(for key: String) throws { lock.withLock { values[key] = nil } }
}
