import XCTest
import CoreModels
import ProviderJellyfin

/// Explicitly configured, passwordless test accounts only. Never writes watch state.
final class JellyfinRecentlyAddedLiveTests: XCTestCase {
    func testLiveEmbyRecentlyAddedContractAndWatchPolicy() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["PLOZZ_TEST_EMBY_URL"],
              let username = environment["PLOZZ_TEST_EMBY_USER"] else {
            throw XCTSkip("Set PLOZZ_TEST_EMBY_URL and PLOZZ_TEST_EMBY_USER for an approved passwordless test account.")
        }
        let url = try XCTUnwrap(URL(string: address))
        let deviceID = "plozz-read-only-home-validation"
        let client = JellyfinClient(
            baseURL: url, deviceProfile: JellyfinDeviceProfile(deviceID: deviceID),
            providerKind: .emby
        )
        let auth = try await client.authenticate(username: username, password: "")
        let server = MediaServer(
            id: try XCTUnwrap(auth.serverID), name: "Test server", baseURL: url, provider: .emby
        )
        let provider = JellyfinProvider(session: UserSession(
            server: server, userID: auth.userID, userName: auth.userName,
            deviceID: deviceID, accessToken: auth.token
        ))
        let response = try await provider.serverHomeLayout()
        let layout = try XCTUnwrap(response)
        let recent = layout.sections.filter { $0.kind == .recentlyAdded }
        XCTAssertFalse(recent.isEmpty, "The live response must identify native Recently Added sections.")
        var nativeCount = 0
        for section in recent.prefix(2) {
            let items = try await provider.serverHomeItems(
                section: section, limit: HomeRecentlyAddedPolicy.candidateLimit, excludingLibraryIDs: []
            )
            nativeCount += items.count
            XCTAssertLessThanOrEqual(items.count, 100)
            XCTAssertTrue(HomeRecentlyAddedPolicy.items(items, hideWatched: true).allSatisfy {
                !HomeRecentlyAddedPolicy.isWatched($0)
            })
        }
        XCTAssertGreaterThan(nativeCount, 0)
        let latest = try await provider.latest(limit: 100)
        XCTAssertFalse(latest.isEmpty)
        let target = try XCTUnwrap(latest.first { $0.kind == .movie })
        var watched = target
        watched.isPlayed = true
        watched.resumePosition = nil
        XCTAssertTrue(HomeRecentlyAddedPolicy.items([watched], hideWatched: true).isEmpty)
        XCTAssertEqual(HomeRecentlyAddedPolicy.items([watched], hideWatched: false).count, 1)
        watched.isPlayed = false
        XCTAssertEqual(HomeRecentlyAddedPolicy.items([watched], hideWatched: true).count, 1)
        print("Live Emby: nativeRecentRows=\(recent.count) nativeItems=\(nativeCount) latest=\(latest.count); read-only mapping and in-memory watch reversal verified")
    }
}
