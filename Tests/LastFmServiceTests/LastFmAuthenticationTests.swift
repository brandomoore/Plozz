import CoreModels
import XCTest
@testable import LastFmService
@testable import TestSupportNetworking

final class LastFmAuthenticationTests: XCTestCase {
    @MainActor
    func testMusicUsesPersistedProfileActivationAndSameSessionReconnectStartsEnabled() async throws {
        let profile = TrackerPauseFixture()
        let http = RecordingHTTPClient()
        let config = LastFmConfig(apiKey: "fixture", sharedSecret: "fixture")
        let store = InMemoryLastFmTokenStore()
        let legacy = try JSONDecoder().decode(LastFmTokens.self, from: Data(#"{"sessionKey":"session","username":"viewer"}"#.utf8))
        store.setNamespace(profile.namespace)
        try store.save(legacy)
        let settings = LastFmService(config: config, http: http, tokenStore: store, namespace: profile.namespace)
        await settings.refreshStatus()
        let music = settings.scrobbler
        let song = MusicTrack(id: "1", title: "Song", artistName: "Artist")
        XCTAssertTrue(settings.trackerEnabled)
        try settings.setTrackerEnabled(false)
        let restored = LastFmService(config: config, http: http, tokenStore: store, namespace: profile.namespace)
        await restored.refreshStatus()
        XCTAssertFalse(restored.trackerEnabled)
        XCTAssertEqual(restored.phase, .connected(username: "viewer"))
        XCTAssertEqual(store.load(), legacy)
        await music.handle(track: song, event: .start, position: 0, duration: 100)
        await music.handle(track: song, event: .stop, position: 96, duration: 100)
        XCTAssertTrue(http.sent.isEmpty)

        http.stub(pathSuffix: "/2.0/", json: #"{"token":"token"}"#)
        http.stub(pathSuffix: "/2.0/", json: #"{"session":{"key":"session","name":"viewer"}}"#)
        http.stubEmpty(pathSuffix: "/2.0/", status: 200)
        restored.connect()
        await restored.connectTask?.value
        XCTAssertTrue(restored.trackerEnabled)
        XCTAssertEqual(store.load()?.sessionKey, legacy.sessionKey)
        await music.handle(track: song, event: .start, position: 0, duration: 100)
        await music.handle(track: song, event: .stop, position: 96, duration: 100)
        let forms = http.sent.compactMap(\.body).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(forms.count, 2)
        XCTAssertTrue(forms.first?.contains("method=track.updateNowPlaying") == true)
        XCTAssertTrue(forms.last?.contains("method=track.scrobble") == true)
    }

    func testChallengeCreationAndConsumptionRequireIndependentTransfers() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/2.0/", json: #"{"token":"fixture-token"}"#)
        http.stub(pathSuffix: "/2.0/", json: """
        {"session":{"key":"fixture-session","name":"fixture-user"}}
        """)
        let client = LastFmClient(
            config: LastFmConfig(apiKey: "fixture", sharedSecret: "fixture"),
            http: http
        )

        let token = try await client.getToken()
        let session = try await client.getSession(token: token)

        XCTAssertEqual(session.sessionKey, "fixture-session")
        XCTAssertEqual(http.sent.map { request in
            request.queryItems.first { $0.name == "method" }?.value
        }, ["auth.getToken", "auth.getSession"])
        XCTAssertEqual(http.sent.map(\.allowsRequestCoalescing), [false, false])
    }
}
