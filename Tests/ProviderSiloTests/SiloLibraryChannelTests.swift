import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderSilo

extension SiloProviderTests {
    private func channelResponses() -> [String: String] {
        var result = Dictionary(uniqueKeysWithValues: playbackResponses().map {
            ($0.key.replacingOccurrences(of: "movie:1", with: "movie-tmdb-1"),
             $0.value.replacingOccurrences(of: "movie:1", with: "movie-tmdb-1"))
        })
        result["/api/v2/user/libraries"] = #"{"items":[{"id":"1","name":"Movies","type":"movie"}]}"#
        result["/api/v2/catalog"] = """
        {"items":[{"content_id":"movie-tmdb-1","type":"movie","title":"Test movie","runtime":999}],
         "total":1,"total_exact":true,"window_cursor":"window"}
        """
        result["POST /api/v2/watched/movie-tmdb-1"] = ""
        return result
    }

    private func channelProvider(_ http: any HTTPClient) throws -> SiloProvider {
        let raw = try credential(profileToken: "profile-proof").encoded()
        return try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
    }

    private func scheduledItem(_ provider: SiloProvider) async throws -> LibraryChannelItem {
        let page = try await provider.libraryChannelItems(in: "1", kind: .movie, page: .init(limit: 250))
        return try LibraryChannelItem(
            item: XCTUnwrap(page.items.first),
            library: .init(accountID: provider.accountID, libraryID: "1"),
            serverID: provider.session.server.id, userID: provider.session.userID)
    }

    func testChannelCatalogUsesConcreteFileSecondsNotMetadataMinutesOrResume() async throws {
        let http = SiloHTTPStub(channelResponses())
        let provider = try channelProvider(http)
        let page = try await provider.libraryChannelItems(in: "1", kind: .movie, page: .init(limit: 250))
        let media = try XCTUnwrap(page.items.first)
        XCTAssertEqual(media.runtime, 600)
        XCTAssertEqual(media.selectedVersionID, "42")
        XCTAssertEqual(media.versions.map(\.id), ["42"])
        XCTAssertEqual(media.versions.first?.sizeBytes, 100)
        XCTAssertEqual(media.sourceAccountID, "account1")
        XCTAssertEqual(media.libraryID, "1")
        XCTAssertNil(media.resumePosition)
        let scheduled = try LibraryChannelItem(
            item: media, library: .init(accountID: "silo|server1|user1:profile1", libraryID: "1"),
            serverID: "server1", userID: provider.session.userID)
        let snapshot = try LibraryChannelSnapshot(items: [scheduled], createdAt: Date())
        XCTAssertEqual(try JSONDecoder().decode(LibraryChannelSnapshot.self,
                                               from: JSONEncoder().encode(snapshot)), snapshot)
        let requests = await http.requests
        let catalog = try XCTUnwrap(requests.first { $0.path == "/api/v2/catalog" })
        XCTAssertTrue(catalog.queryItems.contains(.init(name: "limit", value: "200")))
        XCTAssertTrue(catalog.queryItems.contains(.init(name: "seek", value: "0")))
        let detail = try XCTUnwrap(requests.first { $0.path.hasPrefix("/api/v2/catalog/items/") })
        XCTAssertTrue(detail.queryItems.contains(.init(name: "library_id", value: "1")))
        XCTAssertEqual(detail.headers["X-Profile-Id"], "profile1")
        XCTAssertEqual(detail.headers["X-Profile-Token"], "profile-proof")
        XCTAssertFalse(requests.contains { $0.method != .get })
    }

    func testChannelPlaybackSeparatesTransportFromOrdinaryHistoryAndReleasesGrant() async throws {
        let http = SiloHTTPStub(channelResponses())
        let provider = try channelProvider(http)
        let item = try await scheduledItem(provider)
        let request = try await provider.libraryChannelPlayback(for: item)
        XCTAssertTrue(request.suppressOrdinaryWatchReporting)
        XCTAssertEqual(request.startPosition, 0)
        XCTAssertNil(request.item.resumePosition)
        XCTAssertEqual(request.item.runtime, 600)
        XCTAssertNil(request.originalFileSource)
        let progress = PlaybackProgress(
            itemID: item.itemID, playSessionID: request.playSessionID, positionSeconds: 590, isPaused: true)
        do {
            try await provider.reportPlayback(progress, event: .stop)
            XCTFail("An isolated session must reject the ordinary reporter")
        } catch { XCTAssertEqual(error as? AppError, .unauthorized) }
        try await provider.reportLibraryChannelPlayback(progress)
        try await provider.releaseLibraryChannelPlayback(request)
        try await provider.releaseLibraryChannelPlayback(request)
        guard case .authenticatedHTTP(let locator) = request.playbackSource else {
            return XCTFail("Missing authenticated source")
        }
        do {
            _ = try await provider.resolveHTTPResource(locator)
            XCTFail("Released grant still resolves")
        } catch { XCTAssertEqual(error as? AppError, .notFound) }
        let requests = await http.requests
        let start = try XCTUnwrap(requests.first { $0.path == "/api/v2/playback/start" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(start.body)) as? [String: Any])
        XCTAssertEqual(body["progress_persistence"] as? String, "client")
        XCTAssertEqual(body["start_position"] as? Double, 0)
        XCTAssertEqual(body["profile_id"] as? String, "profile1")
        XCTAssertEqual(body["allow_alternate_versions"] as? Bool, false)
        let stops = requests.filter { $0.method == .delete }
        XCTAssertEqual(stops.count, 1)
        let stop = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(stops.first?.body)) as? [String: Any])
        XCTAssertNil(stop["position"])
        XCTAssertNil(stop["sequence"])
        XCTAssertNotNil(stop["stop_id"])
        XCTAssertFalse(requests.contains { $0.path.contains("/watched/") || $0.path.contains("/sync/") || $0.path.contains("/downloads") })
    }

    func testChannelReporterCannotTouchOrdinarySiloSession() async throws {
        let http = SiloHTTPStub(channelResponses())
        let provider = try channelProvider(http)
        let request = try await provider.playbackInfo(for: "movie-tmdb-1")
        do {
            try await provider.reportLibraryChannelPlayback(.init(
                itemID: request.item.id, playSessionID: request.playSessionID, positionSeconds: 590, isPaused: false))
            XCTFail("An ordinary session cannot be adopted by Channels")
        } catch { XCTAssertEqual(error as? AppError, .unauthorized) }
        try await provider.releaseLibraryChannelPlayback(request)
        let requests = await http.requests
        XCTAssertFalse(requests.contains { $0.method == .delete || $0.path.hasSuffix("/progress") })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(requests.first { $0.path.hasSuffix("/start") }?.body)) as? [String: Any])
        XCTAssertNil(body["progress_persistence"], "Ordinary playback retains its existing server policy")
    }

    func testChannelCompletionIsAnExplicitWatchedWriteWithProfileProof() async throws {
        let http = SiloHTTPStub(channelResponses())
        let provider = try channelProvider(http)
        try await provider.recordLibraryChannelCompletion(itemID: "movie-tmdb-1")
        let requests = await http.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.path, "/api/v2/watched/movie-tmdb-1")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.headers["X-Profile-Id"], "profile1")
        XCTAssertEqual(request.headers["X-Profile-Token"], "profile-proof")
    }

    func testUnavailableChannelCapabilityDoesNotScanOrOpenAPlaybackSession() async throws {
        var responses = channelResponses()
        responses["/api/v2/playback/capabilities"] = """
        {"installation_id":"server1","protocol_versions":[2],"features":[],
         "deliveries":["original_http"],"state":"available","allowed":true}
        """
        let http = SiloHTTPStub(responses)
        let provider = try channelProvider(http)
        do {
            try await provider.prepareLibraryChannels()
            XCTFail("Unsupported protocol must be distinct from unknown durations")
        } catch { XCTAssertEqual(error as? LibraryChannelError, .sourceUnsupported) }
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), ["/api/v2/playback/capabilities"])
    }

    func testChannelCatalogRefusesInexactTotalsAndOutOfScopeLibraries() async throws {
        var responses = channelResponses()
        responses["/api/v2/catalog"] = responses["/api/v2/catalog"]?
            .replacingOccurrences(of: "\"total_exact\":true", with: "\"total_exact\":false")
        let http = SiloHTTPStub(responses)
        let provider = try channelProvider(http)
        do {
            _ = try await provider.libraryChannelItems(in: "1", kind: .movie, page: .init())
            XCTFail("Estimated totals cannot define an immutable schedule")
        } catch { XCTAssertEqual(error as? LibraryChannelError, .catalogChanged) }
        do {
            _ = try await provider.libraryChannelItems(in: "hidden", kind: .movie, page: .init())
            XCTFail("A revoked library must not be scanned")
        } catch { XCTAssertEqual(error as? LibraryChannelError, .authorizationChanged) }
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.path == "/api/v2/catalog" }.count, 1)
    }

    func testUnknownDurationAndMultipartFilesNeverBorrowMetadataRuntime() async throws {
        for replacement in [
            "\"duration\":0", "\"duration\":600,\"presentation_part_total\":2",
            "\"duration\":600,\"multi_episode_start\":1,\"multi_episode_end\":2"
        ] {
            var responses = channelResponses()
            responses["/api/v2/catalog/items/movie-tmdb-1"] = responses["/api/v2/catalog/items/movie-tmdb-1"]?
                .replacingOccurrences(of: "\"duration\":600", with: replacement)
            let provider = try channelProvider(SiloHTTPStub(responses))
            let page = try await provider.libraryChannelItems(in: "1", kind: .movie, page: .init())
            XCTAssertNil(page.items.first?.runtime)
            XCTAssertTrue(page.items.first?.versions.isEmpty == true)
        }
    }

    func testChangedScheduledFileIsRefusedBeforeNegotiation() async throws {
        let initial = try channelProvider(SiloHTTPStub(channelResponses()))
        let item = try await scheduledItem(initial)
        for (from, to) in [("\"file_size\":100", "\"file_size\":101"), ("\"duration\":600", "\"duration\":601")] {
            var responses = channelResponses()
            responses["/api/v2/catalog/items/movie-tmdb-1"] = responses["/api/v2/catalog/items/movie-tmdb-1"]?
                .replacingOccurrences(of: from, with: to)
            let http = SiloHTTPStub(responses)
            let provider = try channelProvider(http)
            do {
                _ = try await provider.libraryChannelPlayback(for: item)
                XCTFail("Changed bytes or timeline must not change the schedule")
            } catch { XCTAssertEqual(error as? LibraryChannelError, .mediaChanged) }
            let requests = await http.requests
            XCTAssertFalse(requests.contains { $0.path.hasSuffix("/start") })
        }
    }

    func testChannelRefusesAndReleasesServerConversion() async throws {
        var responses = channelResponses()
        responses["/api/v2/playback/start"] = responses["/api/v2/playback/start"]?
            .replacingOccurrences(of: "\"delivery\":\"original_http\"", with: "\"delivery\":\"server_remux_hls\"")
        let http = SiloHTTPStub(responses)
        let provider = try channelProvider(http)
        let item = try await scheduledItem(provider)
        do {
            _ = try await provider.libraryChannelPlayback(for: item)
            XCTFail("Generated channels currently require a seekable original file")
        } catch { XCTAssertEqual(error as? LibraryChannelError, .incompatiblePlaybackMode) }
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.method == .delete }.count, 1)
    }

    func testRecursiveEpisodeWindowRetainsNativeParentAndFileIdentity() async throws {
        var responses = channelResponses()
        responses["/api/v2/catalog"] = responses["/api/v2/catalog"]?
            .replacingOccurrences(of: "movie-tmdb-1", with: "episode-tmdb-1-1-2")
            .replacingOccurrences(of: "\"type\":\"movie\"", with: "\"type\":\"episode\"")
            .replacingOccurrences(of: "\"total\":1", with: "\"total\":201")
        responses["/api/v2/catalog/items/episode-tmdb-1-1-2"] = responses["/api/v2/catalog/items/movie-tmdb-1"]?
            .replacingOccurrences(of: "movie-tmdb-1", with: "episode-tmdb-1-1-2")
            .replacingOccurrences(of: "\"type\":\"movie\"", with: "\"type\":\"episode\"")
        let http = SiloHTTPStub(responses)
        let provider = try channelProvider(http)
        let page = try await provider.libraryChannelItems(
            in: "1", kind: .episode, page: .init(startIndex: 200, limit: 250))
        XCTAssertEqual(page.startIndex, 200)
        XCTAssertEqual(page.totalCount, 201)
        XCTAssertEqual(page.items.first?.kind, .episode)
        XCTAssertEqual(page.items.first?.seriesID, "series-tmdb-1")
        XCTAssertEqual(page.items.first?.episodeNumber, 2)
        XCTAssertEqual(page.items.first?.selectedVersionID, "42")
        XCTAssertEqual(page.items.first?.runtime, 600)
        let requests = await http.requests
        let query = try XCTUnwrap(requests.first { $0.path == "/api/v2/catalog" }?.queryItems)
        XCTAssertTrue(query.contains(.init(name: "seek", value: "200")))
        XCTAssertTrue(query.contains(.init(name: "type", value: "episode")))
    }

    func testScheduledPlaybackCannotCrossAccountsOrServerProfiles() async throws {
        let http = SiloHTTPStub(channelResponses())
        let provider = try channelProvider(http)
        let media = MediaItem(id: "movie-tmdb-1", title: "Movie", kind: .movie, runtime: 600)
        for (account, user) in [("other", "user1:profile1"), ("account1", "user1:other")] {
            let item = try LibraryChannelItem(
                item: media, library: .init(accountID: account, libraryID: "1"),
                serverID: "server1", userID: user)
            do {
                _ = try await provider.libraryChannelPlayback(for: item)
                XCTFail("Scheduled metadata cannot authorize another account or server profile")
            } catch { XCTAssertEqual(error as? LibraryChannelError, .authorizationChanged) }
        }
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testLostChannelStartResponseReplaysTheSameAttemptInsteadOfLeakingIt() async throws {
        let http = SiloChannelTransportHTTP(responses: channelResponses(), lostStarts: 1)
        let provider = try channelProvider(http)
        let item = try await scheduledItem(provider)
        let request = try await provider.libraryChannelPlayback(for: item)
        try await provider.releaseLibraryChannelPlayback(request)
        let requests = await http.requests
        let starts = requests.filter { $0.path == "/api/v2/playback/start" }
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts.first?.body, starts.last?.body)
        XCTAssertEqual(requests.filter { $0.method == .delete }.count, 1)
    }

    func testTwoLostStartRepliesRetainTheAttemptUntilItCanBeRecoveredAndRetired() async throws {
        let http = SiloChannelTransportHTTP(responses: channelResponses(), lostStarts: 2)
        let provider = try channelProvider(http)
        let item = try await scheduledItem(provider)
        do {
            _ = try await provider.libraryChannelPlayback(for: item)
            XCTFail("Two lost responses must not look like playback success")
        } catch { XCTAssertEqual(error as? AppError, .serverUnreachable) }
        let request = try await provider.libraryChannelPlayback(for: item)
        try await provider.releaseLibraryChannelPlayback(request)
        let requests = await http.requests
        let operations = requests.filter { $0.path.hasSuffix("/start") || $0.method == .delete }
        XCTAssertEqual(operations.map(\.method), [.post, .post, .post, .delete, .post, .delete])
        XCTAssertEqual(operations[0].body, operations[1].body)
        XCTAssertEqual(operations[1].body, operations[2].body)
        XCTAssertNotEqual(operations[2].body, operations[4].body)
    }

    func testRejectedPlanRetainsCleanupOwnershipAfterAnUnconfirmedStop() async throws {
        var responses = channelResponses()
        responses["/api/v2/playback/start"] = responses["/api/v2/playback/start"]?
            .replacingOccurrences(of: "\"delivery\":\"original_http\"", with: "\"delivery\":\"server_remux_hls\"")
        let http = SiloChannelTransportHTTP(responses: responses, failedStops: 2)
        let provider = try channelProvider(http)
        let item = try await scheduledItem(provider)
        for _ in 0..<2 {
            do {
                _ = try await provider.libraryChannelPlayback(for: item)
                XCTFail("An incompatible plan must not start")
            } catch { XCTAssertEqual(error as? LibraryChannelError, .incompatiblePlaybackMode) }
        }
        let requests = await http.requests
        let operations = requests.filter { $0.path.hasSuffix("/start") || $0.method == .delete }
        XCTAssertEqual(operations.map(\.method), [.post, .delete, .delete, .delete, .post, .delete])
        XCTAssertEqual(operations[1].body, operations[2].body)
        XCTAssertEqual(operations[2].body, operations[3].body)
    }

    func testUnconfirmedStopMustFinishBeforeANewChannelSessionCanOpen() async throws {
        let http = SiloChannelTransportHTTP(responses: channelResponses(), failedStops: 2)
        let provider = try channelProvider(http)
        let item = try await scheduledItem(provider)
        let first = try await provider.libraryChannelPlayback(for: item)
        do {
            try await provider.releaseLibraryChannelPlayback(first)
            XCTFail("A stop transport failure must remain a failure")
        } catch { XCTAssertEqual(error as? AppError, .serverUnreachable) }
        let second = try await provider.libraryChannelPlayback(for: item)
        try await provider.releaseLibraryChannelPlayback(second)
        let requests = await http.requests
        let operations = requests.filter { $0.path.hasSuffix("/start") || $0.method == .delete }
        XCTAssertEqual(operations.map(\.method), [.post, .delete, .delete, .delete, .post, .delete])
        XCTAssertEqual(operations[1].body, operations[2].body)
        XCTAssertEqual(operations[2].body, operations[3].body)
    }
}

private actor SiloChannelTransportHTTP: HTTPClient {
    private let base: SiloHTTPStub
    private var lostStarts: Int
    private var failedStops: Int
    private(set) var requests: [Endpoint] = []

    init(responses: [String: String], lostStarts: Int = 0, failedStops: Int = 0) {
        base = SiloHTTPStub(responses)
        self.lostStarts = lostStarts
        self.failedStops = failedStops
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(endpoint)
        if endpoint.path.hasSuffix("/playback/start"), lostStarts > 0 {
            lostStarts -= 1
            throw AppError.serverUnreachable
        }
        if endpoint.method == .delete, failedStops > 0 {
            failedStops -= 1
            throw AppError.serverUnreachable
        }
        return try await base.send(endpoint, baseURL: baseURL)
    }
}
