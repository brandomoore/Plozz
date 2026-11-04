import AppRuntime
import CoreModels
import CoreNetworking
import FeatureAuthCore
import Foundation
@testable import ProviderPlex
import XCTest

final class PlexExtraResumeTests: XCTestCase {
    private func context(
        profile: String = "profile", account: String = "account", user: String = "viewer"
    ) -> LocalMediaContext {
        .init(accountID: account, profileID: profile, profileNamespace: nil, serverUserID: user)
    }

    private func session(server: String = "server", token: String = "test-token") -> UserSession {
        .init(
            server: .init(id: server, name: "Test", baseURL: URL(string: "https://plex.invalid")!, provider: .plex),
            userID: "owner", userName: "Owner", deviceID: "test-device", accessToken: token
        )
    }

    private func extra(_ kind: MediaExtraKind = .trailer) -> MediaItem {
        MediaExtra(
            item: MediaItem(id: "extra", title: "Extra", kind: .movie, runtime: 45),
            kind: kind
        ).playbackItem
    }

    func testShortExtrasSurviveRecreationAndTokenRefresh() async throws {
        for kind in [MediaExtraKind.trailer, .featurette] {
            let backend = InMemorySecureStore()
            let item = extra(kind)
            let state = PlexExtraWatchState(
                context: context(), session: session(), durableStore: try DurableLocalStateStore(secureStore: backend)
            )
            for position in [2.0, 15, 30] {
                try await state.setResume(position, itemID: item.id, capturedAt: Date()) { item }
                let rebuilt = PlexExtraWatchState(
                    context: context(), session: session(token: "refreshed"),
                    durableStore: try DurableLocalStateStore(secureStore: backend)
                )
                let restored = await rebuilt.stamp(item)
                XCTAssertEqual(restored.resumePosition, position)
                XCTAssertEqual(restored.playedPercentage ?? 0, position / 45, accuracy: 0.001)
            }
        }
    }

    func testEveryIdentityBoundaryIsIsolated() async throws {
        let durable = try DurableLocalStateStore(secureStore: InMemorySecureStore())
        let item = extra()
        let state = PlexExtraWatchState(context: context(), session: session(), durableStore: durable)
        try await state.setResume(15, itemID: item.id, capturedAt: Date()) { item }
        for (context, session) in [
            (context(profile: "other-profile"), session()),
            (context(account: "other-account"), session()),
            (context(user: "other-viewer"), session()),
            (context(), session(server: "other-server"))
        ] {
            let other = PlexExtraWatchState(context: context, session: session, durableStore: durable)
            let unread = await other.stamp(item)
            XCTAssertNil(unread.resumePosition)
            try await other.setResume(20, itemID: item.id, capturedAt: Date()) { item }
        }
        let original = await state.stamp(item)
        XCTAssertEqual(original.resumePosition, 15)
    }

    func testMoviesAndEpisodesNeverAcquireFallback() async throws {
        let state = PlexExtraWatchState(context: context(), session: session(), durableStore: nil)
        for kind in [MediaItemKind.movie, .episode] {
            let item = MediaItem(id: kind.rawValue, title: "Library item", kind: kind, runtime: 45)
            try await state.setResume(15, itemID: item.id, capturedAt: Date()) { item }
            let restored = await state.stamp(item)
            XCTAssertNil(restored.resumePosition)
        }
    }

    func testOlderProviderCannotResurrectCompletedOrClearedProgress() async throws {
        let durable = try DurableLocalStateStore(secureStore: InMemorySecureStore())
        let old = PlexExtraWatchState(context: context(), session: session(), durableStore: durable)
        let current = PlexExtraWatchState(context: context(), session: session(), durableStore: durable)
        let item = extra(.featurette)
        let date = Date()
        try await old.setResume(15, itemID: item.id, capturedAt: date) { item }
        try await current.setPlayed(true, itemID: item.id, capturedAt: date.addingTimeInterval(10)) { item }
        try await old.setResume(20, itemID: item.id, capturedAt: date.addingTimeInterval(5)) { item }
        let completed = await old.stamp(item)
        XCTAssertTrue(completed.isPlayed)
        XCTAssertNil(completed.resumePosition)
        try await current.setResume(5, itemID: item.id, capturedAt: date.addingTimeInterval(20)) { item }
        try await old.setResume(0, itemID: item.id, capturedAt: date.addingTimeInterval(30)) { item }
        try await current.setResume(10, itemID: item.id, capturedAt: date.addingTimeInterval(25)) { item }
        let cleared = await current.stamp(item)
        XCTAssertFalse(cleared.isPlayed)
        XCTAssertNil(cleared.resumePosition)
    }

    func testGenuinelyNewerServerProgressWinsButDiscardedOffsetDoesNot() async throws {
        let state = PlexExtraWatchState(context: context(), session: session(), durableStore: nil)
        let item = extra()
        let date = Date()
        try await state.setResume(15, itemID: item.id, capturedAt: date) { item }
        var server = item
        server.lastPlayedAt = date.addingTimeInterval(10)
        let dropped = await state.stamp(server)
        XCTAssertEqual(dropped.resumePosition, 15)
        server.resumePosition = 20
        let newer = await state.stamp(server)
        XCTAssertEqual(newer.resumePosition, 20)
    }

    func testProviderTimelineFailureRetainsLocalProgressAndStartOverClearsIt() async throws {
        let durable = try DurableLocalStateStore(secureStore: InMemorySecureStore())
        let http = ExtraHTTP()
        let provider = PlexProvider(
            session: session(), localMediaContext: context(), durableStore: durable, http: http
        )
        _ = try await provider.item(id: "extra")
        await http.setTimelineFailure(true)
        do {
            try await provider.reportPlayback(
                .init(itemID: "extra", playSessionID: nil, positionSeconds: 15, isPaused: true, durationSeconds: 45),
                event: .pause
            )
            XCTFail("Local persistence must not disguise a failed server report.")
        } catch let error as AppError {
            XCTAssertEqual(error, .invalidResponse)
        }
        let rebuilt = PlexProvider(
            session: session(), localMediaContext: context(), durableStore: durable, http: http
        )
        let restored = try await rebuilt.item(id: "extra")
        XCTAssertEqual(restored.resumePosition, 15)
        await http.setTimelineFailure(false)
        try await rebuilt.reportPlayback(
            .init(itemID: "extra", playSessionID: nil, positionSeconds: 0, isPaused: false), event: .start
        )
        let cleared = try await rebuilt.item(id: "extra")
        XCTAssertNil(cleared.resumePosition)
        try await rebuilt.reportPlayback(
            .init(itemID: "extra", playSessionID: nil, positionSeconds: 44, isPaused: false, durationSeconds: 45),
            event: .stop
        )
        let finished = try await rebuilt.item(id: "extra")
        XCTAssertTrue(finished.isPlayed)
        XCTAssertNil(finished.resumePosition)
    }

    func testProviderUsesFallbackInItemExtrasTrailersAndPlaybackRequest() async throws {
        let provider = PlexProvider(
            session: session(), localMediaContext: context(),
            durableStore: try DurableLocalStateStore(secureStore: InMemorySecureStore()), http: ExtraHTTP()
        )
        try await provider.setResumePosition(15, itemID: "extra")
        let item = try await provider.item(id: "extra")
        let extras = try await provider.extras(for: "parent")
        let trailers = try await provider.trailers(for: "parent")
        let playback = try await provider.playbackInfo(for: "extra")
        XCTAssertEqual(item.resumePosition, 15)
        XCTAssertEqual(extras.first?.playbackItem.resumePosition, 15)
        XCTAssertEqual(trailers.first?.resumePosition, 15)
        XCTAssertEqual(playback.startPosition, 15)
        XCTAssertTrue(playback.item.isExtra)
        XCTAssertTrue(playback.item.isTrailer)
    }

    func testUnknownPlaybackReportsNeverRequireExtraMetadata() async throws {
        let http = ExtraHTTP()
        await http.setMetadataFailure(true)
        let provider = PlexProvider(session: session(), localMediaContext: context(), http: http)
        try await provider.reportPlayback(
            .init(itemID: "channel", playSessionID: nil, positionSeconds: 15, isPaused: false), event: .stop
        )
        let timelineCount = await http.timelineCount
        XCTAssertEqual(timelineCount, 1)
    }

    func testStaleOutboxDoesNotRewriteServerAfterNewerLocalCompletion() async throws {
        let http = ExtraHTTP()
        let durable = try DurableLocalStateStore(secureStore: InMemorySecureStore())
        let provider = PlexProvider(session: session(), localMediaContext: context(), durableStore: durable, http: http)
        let staleProvider = PlexProvider(session: session(), localMediaContext: context(), durableStore: durable, http: http)
        let date = Date()
        try await provider.setPlayed(true, itemID: "extra", capturedAt: date)
        try await staleProvider.setResumePosition(15, itemID: "extra", capturedAt: date.addingTimeInterval(-10))
        try await staleProvider.setPlayed(false, itemID: "extra", capturedAt: date.addingTimeInterval(-5))
        let writeCount = await http.stateWriteCount
        XCTAssertEqual(writeCount, 1)
        let item = try await staleProvider.item(id: "extra")
        XCTAssertTrue(item.isPlayed)
        XCTAssertNil(item.resumePosition)
    }
}

private actor ExtraHTTP: HTTPClient {
    private var timelineFailure = false
    private var metadataFailure = false
    private(set) var timelineCount = 0
    private(set) var stateWriteCount = 0
    func setTimelineFailure(_ value: Bool) { timelineFailure = value }
    func setMetadataFailure(_ value: Bool) { metadataFailure = value }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        if endpoint.path.contains("/library/metadata/"), metadataFailure { throw AppError.notFound }
        if endpoint.path.contains("scrobble") || endpoint.path.contains("progress") { stateWriteCount += 1 }
        if endpoint.path.contains("timeline") { timelineCount += 1 }
        if endpoint.path.contains("timeline"), timelineFailure { throw AppError.invalidResponse }
        let body = endpoint.path.contains("/library/metadata/") ? """
        {"MediaContainer":{"Metadata":[{"ratingKey":"extra","type":"clip","title":"Trailer",
        "extraType":1,"duration":45000,
        "Media":[{"id":1,"container":"mp4","videoCodec":"h264","audioCodec":"aac",
          "Part":[{"id":2,"key":"/library/parts/2/file.mp4","file":"/movies/trailer.mp4",
                   "container":"mp4","Stream":[]}]}]}]}}
        """ : "{}"
        return (Data(body.utf8), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
