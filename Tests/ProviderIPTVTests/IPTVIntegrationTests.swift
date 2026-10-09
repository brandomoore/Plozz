import CoreModels
import CoreNetworking
import Foundation
@testable import ProviderIPTV
import XCTest

final class IPTVIntegrationTests: XCTestCase {
    override func tearDown() {
        IPTVFixture.state.reset()
        super.tearDown()
    }

    func testXtreamMoviesSeriesLiveGuideAndOpaquePlayback() async throws {
        IPTVFixture.state.handler = Self.xtream
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credential = try IPTVCredential(
            mode: .xtream, address: XCTUnwrap(URL(string: "https://provider.test/prefix")),
            username: "fixture-user", password: "fixture-password"
        )
        let session = try await IPTVProvider.signIn(
            credential: credential, name: "Fixture", deviceID: "device",
            cacheDirectory: root, configuration: configuration()
        )
        XCTAssertEqual(session.server.baseURL.absoluteString, "https://provider.test")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(Account(id: "account", from: session)), as: UTF8.self)
            .contains("fixture-password"))
        let context = ProviderResolutionContext(
            session: session, accountID: "account", credentialRevision: .init(),
            localMediaContext: .init(accountID: "account", profileID: "profile", profileNamespace: nil)
        )
        let provider = try IPTVProvider(context: context, cacheDirectory: root, configuration: configuration())
        do {
            async let movies = provider.items(in: "movies", kind: .movie, page: .init(limit: 20))
            async let channels = provider.liveTVChannels()
            let page = try await movies
            let lineup = try await channels
            XCTAssertEqual(page.items.map(\.id), ["movie:20"])
            XCTAssertEqual(lineup.map(\.id), ["live:10"])
            XCTAssertEqual(lineup.first?.groups, ["News"])
            let seasons = try await provider.children(of: "series:30")
            XCTAssertEqual(seasons.map(\.seasonNumber), [1])
            let episodes = try await provider.children(of: XCTUnwrap(seasons.first).id)
            XCTAssertEqual(episodes.map(\.id), ["episode:30:31"])
            let request = try await provider.playbackInfo(for: "episode:30:31")
            guard case .authenticatedHTTP(let locator) = request.playbackSource else {
                return XCTFail("IPTV must use an opaque authenticated locator")
            }
            XCTAssertFalse(locator.resource.path.contains("fixture-password"))
            let playbackURL = try await provider.resolveHTTPResource(locator)
            XCTAssertEqual(playbackURL.host, "127.0.0.1")
            XCTAssertFalse(playbackURL.absoluteString.contains("fixture-password"))
            let programs = try await provider.liveTVGuide(
                channelIDs: ["live:10"], from: Date(timeIntervalSince1970: 100),
                to: Date(timeIntervalSince1970: 500)
            )
            XCTAssertEqual(programs.map(\.title), ["News"])
            try await provider.setResumePosition(120, itemID: "episode:30:31", capturedAt: Date())
            try await provider.reportPlayback(
                .init(itemID: "episode:30:31", playSessionID: request.playSessionID,
                      positionSeconds: 0, isPaused: true), event: .stop
            )
            let resumed = try await provider.continueWatching(limit: 20)
            XCTAssertEqual(resumed.map(\.id), ["episode:30:31"])
            XCTAssertEqual(resumed.first?.resumePosition, 120)
            try await provider.removeFromContinueWatching(itemID: "episode:30:31")
            let dismissed = try await provider.continueWatching(limit: 20)
            XCTAssertTrue(dismissed.isEmpty)
        } catch { await provider.teardown(); throw error }
        await provider.teardown()
        XCTAssertTrue(IPTVFixture.state.requests.allSatisfy { $0.url?.path.hasPrefix("/prefix/") == true })
    }

    func testFailedPlaylistRefreshKeepsPriorCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        IPTVFixture.state.handler = { _ in
            (200, [:], Data("#EXTM3U\n#EXTINF:-1,Movie\nhttps://provider.test/movie/one.mp4\n".utf8))
        }

        let credential = try IPTVCredential(mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.test/list")))
        let client = try IPTVClient(credential: credential, directory: root, configuration: configuration())
        try await client.ensureCatalog("movies")
        let before = try await client.page(library: "movies", kind: .movie, page: .init(limit: 20))
        IPTVFixture.state.handler = { _ in (200, [:], Data("<html>Sign in</html>".utf8)) }
        do {
            try await client.ensureCatalog("movies", force: true)
            XCTFail("A login page is not a playlist")
        } catch {
            XCTAssertEqual(error as? LiveTVSourceImportError, .invalidPlaylist)
        }
        let after = try await client.page(library: "movies", kind: .movie, page: .init(limit: 20))
        XCTAssertEqual(after.items.map(\.id), before.items.map(\.id))
        XCTAssertEqual(after.totalCount, 1)
    }

    func testPlaylistOutputHintAppliesOnlyToExtensionlessLiveChannels() async throws {
        IPTVFixture.state.handler = { _ in
            (200, [:], Data("""
            #EXTM3U
            #EXTINF:-1,Channel
            https://provider.test/channel
            #EXTINF:-1,Explicit HLS
            https://provider.test/channel.m3u8
            #EXTINF:-1,Movie
            https://provider.test/movie/one

            """.utf8))
        }
        for (query, expected) in [
            ("output=ts", "ts"), ("output=m3u8", "m3u8"), ("OUTPUT=TS", "ts"),
            ("output=unknown", ""), ("output=ts&output=m3u8", ""), ("", "")
        ] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let credential = try IPTVCredential(
                mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.test/get.php?" + query))
            )
            let client = try IPTVClient(credential: credential, directory: root, configuration: configuration())
            let channels = try await client.liveChannels()
            let channel = try XCTUnwrap(channels.first { $0.name == "Channel" })
            let delivery = try await client.delivery(channel.id)
            XCTAssertEqual(delivery.formatHint.container ?? "", expected)
            XCTAssertEqual(delivery.url.path, "/channel")
            let explicit = try XCTUnwrap(channels.first { $0.name == "Explicit HLS" })
            let hls = try await client.delivery(explicit.id)
            XCTAssertNil(hls.formatHint.container, "An explicit stream suffix takes precedence over the playlist default")
            let movies = try await client.page(library: "movies", kind: .movie, page: .init(limit: 20))
            let movie = try XCTUnwrap(movies.items.first)
            let onDemand = try await client.delivery(movie.id)
            XCTAssertNil(onDemand.formatHint.container, "A live-output preference must not alter on-demand playback")
        }
    }

    func testConcurrentCatalogRequestsAreSerializedAcrossLibraries() async throws {
        IPTVFixture.state.handler = Self.xtream
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credential = try IPTVCredential(
            mode: .xtream, address: XCTUnwrap(URL(string: "https://provider.test")),
            username: "fixture-user", password: "fixture-password"
        )
        let client = try IPTVClient(credential: credential, directory: root, configuration: configuration())
        async let movies = client.page(library: "movies", kind: .movie, page: .init(limit: 20))
        async let series = client.page(library: "series", kind: .series, page: .init(limit: 20))
        async let live = client.liveChannels()
        let results = try await (movies, series, live)
        XCTAssertEqual(results.0.totalCount, 1)
        XCTAssertEqual(results.1.totalCount, 1)
        XCTAssertEqual(results.2.count, 1)
    }

    func testFreshLegacyPlaylistCacheIsReclassifiedOnceWithoutResettingItsAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credential = try IPTVCredential(mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.test/list")))
        let catalogURL = root.appendingPathComponent(credential.identity.uuidString + ".sqlite")
        do {
            let old = try IPTVCatalog(url: catalogURL, key: credential.catalogKey)
            try old.insert(IPTVRecord(
                item: MediaItem(id: "movie:old-misclassification", title: "Channel", kind: .movie, libraryID: "movies"),
                streamURL: XCTUnwrap(URL(string: "https://provider.test/channel.mp4"))
            ))
            try old.setState("playlist", String(Date().timeIntervalSince1970))
        }
        IPTVFixture.state.handler = { _ in
            (200, [:], Data("#EXTM3U\n#EXTINF:-1,Channel\nhttps://provider.test/channel.mp4\n".utf8))
        }
        let client = try IPTVClient(credential: credential, directory: root, configuration: configuration())
        let movies = try await client.page(library: "movies", kind: .movie, page: .init(limit: 20))
        let channels = try await client.liveChannels()
        XCTAssertTrue(movies.items.isEmpty)
        XCTAssertEqual(channels.map(\.name), ["Channel"])
        XCTAssertEqual(IPTVFixture.state.requests.count, 1)
        let reopened = try IPTVClient(credential: credential, directory: root, configuration: configuration())
        let restored = try await reopened.liveChannels()
        XCTAssertEqual(restored.map(\.id), channels.map(\.id))
        XCTAssertEqual(IPTVFixture.state.requests.count, 1, "Current mapping must reuse the refreshed catalogue")
    }

    func testCancellingOneImporterDoesNotCancelAnotherWaitingCaller() async throws {
        let entered = expectation(description: "Playlist download started")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        IPTVFixture.state.handler = { _ in
            entered.fulfill()
            guard gate.wait(timeout: .now() + 10) == .success else { throw URLError(.timedOut) }
            return (200, [:], Data("#EXTM3U\n#EXTINF:-1,News\nhttps://provider.test/live/1.ts\n".utf8))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credential = try IPTVCredential(mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.test/list")))
        let client = try IPTVClient(credential: credential, directory: root, configuration: configuration())
        let first = Task { try await client.ensureCatalog("live") }
        await fulfillment(of: [entered], timeout: 3)
        let second = Task { try await client.ensureCatalog("live") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await client.pendingCatalogRequestCount < 2, ContinuousClock.now < deadline { await Task.yield() }
        let pending = await client.pendingCatalogRequestCount
        XCTAssertEqual(pending, 2)
        first.cancel()
        do { try await first.value; XCTFail("The cancelled caller must finish with cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        gate.signal()
        try await second.value
        XCTAssertEqual(IPTVFixture.state.requests.count, 1)
        let channels = try await client.liveChannels()
        XCTAssertEqual(channels.count, 1)
    }

    func testLibraryDiscoveryReadsCommittedCatalogWhileRefreshWaitsForProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credential = try IPTVCredential(
            mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.test/list"))
        )
        let body = Data("#EXTM3U\n#EXTINF:120,Movie\nhttps://provider.test/movie/1.mp4\n".utf8)
        IPTVFixture.state.handler = { _ in (200, [:], body) }
        let client = try IPTVClient(credential: credential, directory: root, configuration: configuration())
        try await client.ensureCatalog("movies")
        let entered = expectation(description: "Refresh waiting on response")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        IPTVFixture.state.handler = { _ in
            entered.fulfill()
            guard gate.wait(timeout: .now() + 10) == .success else { throw URLError(.timedOut) }
            return (200, [:], body)
        }
        let refresh = Task { try await client.ensureCatalog("movies", force: true) }
        await fulfillment(of: [entered], timeout: 3)
        let discovered = expectation(description: "Fresh library remains immediately readable")
        let discovery = Task {
            let hasMovies = try await client.hasItems(in: "movies", kind: .movie)
            XCTAssertTrue(hasMovies)
            discovered.fulfill()
        }
        await fulfillment(of: [discovered], timeout: 2)
        gate.signal()
        try await refresh.value
        try await discovery.value
        XCTAssertEqual(IPTVFixture.state.requests.count, 2)
    }

    func testPreviousURLCatalogRefreshesToRemovePlaceholderChannels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credential = try IPTVCredential(mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.test/list")))
        do {
            let old = try IPTVCatalog(
                url: root.appendingPathComponent(credential.identity.uuidString + ".sqlite"), key: credential.catalogKey
            )
            try old.insert(IPTVRecord(
                item: MediaItem(id: "live:placeholder", title: "Unavailable", kind: .video, libraryID: "live"),
                streamURL: XCTUnwrap(URL(string: "https://provider.test/%5BNO%20PUBLIC%20STREAM%5D")), isLive: true
            ))
            try old.setState("playlist-v2", String(Date().timeIntervalSince1970))
        }
        IPTVFixture.state.handler = { _ in
            (200, [:], Data("""
            #EXTM3U
            #EXTINF:-1,Unavailable
            [NO PUBLIC STREAM]
            #EXTINF:-1,News
            https://provider.test/live/news.m3u8

            """.utf8))
        }
        let client = try IPTVClient(credential: credential, directory: root, configuration: configuration())
        let channels = try await client.liveChannels()
        XCTAssertEqual(channels.map(\.name), ["News"])
        XCTAssertEqual(IPTVFixture.state.requests.count, 1)
    }

    func testGuideHeadersAreOriginScopedAndSmallResponsesAreReused() async throws {
        IPTVFixture.state.handler = { _ in (200, ["Cache-Control": "max-age=300"], Data("<tv/>".utf8)) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let guide = try XCTUnwrap(URL(string: "https://cdn.test/guide"))
        let credential = try IPTVCredential(
            mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.test/list")),
            headers: ["X-Playlist-Key": "playlist-fixture"], guideURL: guide,
            guideHeaders: ["X-Guide-Key": "guide-fixture"]
        )
        let client = try IPTVClient(credential: credential, directory: root, configuration: configuration())
        let first = try await client.guideData(from: guide)
        let second = try await client.guideData(from: guide)
        XCTAssertEqual(first, second)
        XCTAssertEqual(IPTVFixture.state.requests.count, 1)
        XCTAssertEqual(IPTVFixture.state.requests.first?.value(forHTTPHeaderField: "X-Guide-Key"), "guide-fixture")
        XCTAssertNil(IPTVFixture.state.requests.first?.value(forHTTPHeaderField: "X-Playlist-Key"))
    }

    func testPlaylistGuideMetadataSurvivesTheStoredAccountCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        IPTVFixture.state.handler = { request in
            let body = request.url?.path == "/list" ? """
            #EXTM3U x-tvg-url="https://provider.test/guide.xml"
            #EXTINF:-1 tvg-id="NEWS.us" tvg-name="News" tvg-country="US",101 - News Live
            https://provider.test/live/news
            """ : "<tv/>"
            return (200, [:], Data(body.utf8))
        }
        let credential = try IPTVCredential(mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.test/list")))
        let session = try await IPTVProvider.signIn(
            credential: credential, name: "Guide", deviceID: "fixture",
            cacheDirectory: root, configuration: configuration()
        )
        let provider = try IPTVProvider(
            context: .init(session: session, accountID: "guide", credentialRevision: .init(),
                           localMediaContext: .init(accountID: "guide", profileID: "viewer", profileNamespace: nil)),
            cacheDirectory: root, configuration: configuration()
        ) { _, _, channels, _, _ in
            XCTAssertEqual(channels.map(\.name), ["101 - News Live"])
            XCTAssertEqual(channels.map(\.guideID), ["NEWS.us"])
            XCTAssertEqual(channels.map(\.guideName), ["News"])
            XCTAssertEqual(channels.map(\.country), ["US"])
            return []
        }
        do {
            let channels = try await provider.liveTVChannels()
            _ = try await provider.liveTVGuide(
                channelIDs: channels.map(\.id), from: Date(timeIntervalSince1970: 100),
                to: Date(timeIntervalSince1970: 500)
            )
            XCTAssertEqual(IPTVFixture.state.requests.filter { $0.url?.path == "/list" }.count, 1)
            XCTAssertEqual(IPTVFixture.state.requests.filter { $0.url?.path == "/guide.xml" }.count, 1)
        } catch { await provider.teardown(); throw error }
        await provider.teardown()
    }

    func testPlainPlaylistAccountIDsSurviveReordering() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credential = try IPTVCredential(mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.test/list")))
        let client = try IPTVClient(credential: credential, directory: root, configuration: configuration())
        IPTVFixture.state.handler = { _ in
            (200, [:], Data("https://provider.test/one\nhttps://provider.test/two\n".utf8))
        }
        let first = try await client.liveChannels()
        IPTVFixture.state.handler = { _ in
            (200, [:], Data("https://provider.test/two\nhttps://provider.test/one\n".utf8))
        }
        try await client.ensureCatalog("live", force: true)
        let second = try await client.liveChannels()
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(Set(first.map(\.id)), Set(second.map(\.id)))
        XCTAssertEqual(first.first?.id, second.last?.id)
    }

    func testXtreamFallsBackToXMLTVForEmptyOrUnavailableGuideAPI() async throws {
        for (status, body) in [
            (200, #"{"epg_listings":[]}"#), (200, "{}"), (200, "[]"), (200, "invalid JSON"),
            (404, ""), (405, ""), (501, "")
        ] {
            IPTVFixture.state.reset()
            IPTVFixture.state.handler = { request in
                if request.url?.path == "/prefix/xmltv.php" { return (200, [:], Data("<tv/>".utf8)) }
                if request.url?.query?.contains("action=get_simple_data_table") == true {
                    return (status, [:], Data(body.utf8))
                }
                return try Self.xtream(request)
            }
            let provider = try await makeXtreamGuideProvider { data, url, channels, from, to in
                XCTAssertEqual(data, Data("<tv/>".utf8))
                XCTAssertEqual(url.path, "/prefix/xmltv.php")
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first { $0.name == "username" }?.value, "fixture-user")
                XCTAssertEqual(query?.first { $0.name == "password" }?.value, "fixture-password")
                XCTAssertEqual(channels.map(\.id), ["live:10"])
                XCTAssertEqual(channels.map(\.guideID), ["news"])
                return [.init(id: "xmltv", channelID: "live:10", title: "XMLTV", startDate: from, endDate: to)]
            }
            let programmes = try await provider.liveTVGuide(
                channelIDs: ["live:10"], from: Date(timeIntervalSince1970: 100), to: Date(timeIntervalSince1970: 500)
            )
            XCTAssertEqual(programmes.map(\.title), ["XMLTV"], "HTTP \(status): \(body)")
            XCTAssertEqual(IPTVFixture.state.requests.filter { $0.url?.path == "/prefix/xmltv.php" }.count, 1)
            await provider.teardown()
        }
    }

    func testXtreamFallbackPreservesNativeListingsAndOnlyLoadsMissingChannels() async throws {
        IPTVFixture.state.handler = { request in
            let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems
            if request.url?.path == "/prefix/xmltv.php" { return (200, [:], Data("<tv/>".utf8)) }
            if query?.first(where: { $0.name == "action" })?.value == "get_live_streams" {
                return (200, [:], Data(#"[{"stream_id":10,"name":"News","epg_channel_id":"news"},{"stream_id":11,"name":"Sports","epg_channel_id":"sports"}]"#.utf8))
            }
            if query?.first(where: { $0.name == "action" })?.value == "get_simple_data_table",
               query?.first(where: { $0.name == "stream_id" })?.value == "11" {
                return (200, [:], Data(#"{"epg_listings":[]}"#.utf8))
            }
            return try Self.xtream(request)
        }
        let provider = try await makeXtreamGuideProvider { _, _, channels, from, to in
            XCTAssertEqual(channels.map(\.id), ["live:11"])
            return [.init(id: "sports", channelID: "live:11", title: "Sports", startDate: from, endDate: to)]
        }
        let programmes = try await provider.liveTVGuide(
            channelIDs: ["live:10", "live:11"], from: Date(timeIntervalSince1970: 100), to: Date(timeIntervalSince1970: 500)
        )
        XCTAssertEqual(programmes.map(\.title), ["News", "Sports"])
        XCTAssertEqual(IPTVFixture.state.requests.filter { $0.url?.path == "/prefix/xmltv.php" }.count, 1)
    }

    func testUnavailableXtreamGuideEndpointIsNotRetriedForEveryChannel() async throws {
        for status in [404, 405, 501] {
            IPTVFixture.state.reset()
            IPTVFixture.state.handler = { request in
                if request.url?.path == "/prefix/xmltv.php" { return (200, [:], Data("<tv/>".utf8)) }
                if request.url?.query?.contains("action=get_live_streams") == true {
                    return (200, [:], Data(#"[{"stream_id":10,"name":"News"},{"stream_id":11,"name":"Sports"}]"#.utf8))
                }
                if request.url?.query?.contains("action=get_simple_data_table") == true {
                    return (status, [:], Data())
                }
                return try Self.xtream(request)
            }
            let provider = try await makeXtreamGuideProvider { _, _, channels, from, to in
                XCTAssertEqual(channels.map(\.id), ["live:10", "live:11"])
                return channels.map {
                    .init(id: $0.id, channelID: $0.id, title: $0.name, startDate: from, endDate: to)
                }
            }
            let programmes = try await provider.liveTVGuide(
                channelIDs: ["live:10", "live:11"], from: Date(timeIntervalSince1970: 100),
                to: Date(timeIntervalSince1970: 500)
            )
            XCTAssertEqual(programmes.count, 2)
            XCTAssertEqual(IPTVFixture.state.requests.filter {
                $0.url?.query?.contains("action=get_simple_data_table") == true
            }.count, 1)
            XCTAssertEqual(IPTVFixture.state.requests.filter { $0.url?.path == "/prefix/xmltv.php" }.count, 1)
            await provider.teardown()
        }
    }

    func testXtreamGuideDoesNotHideAuthenticationRateLimitOrTransportFailures() async throws {
        for (status, body) in [
            (401, ""), (403, ""), (429, ""), (500, ""), (0, ""),
            (200, #"{"user_info":{"auth":0}}"#), (200, #"{"auth":0}"#)
        ] {
            IPTVFixture.state.reset()
            IPTVFixture.state.handler = { request in
                if request.url?.query?.contains("action=get_simple_data_table") == true {
                    if status == 0 { throw URLError(.timedOut) }
                    return (status, [:], Data(body.utf8))
                }
                return try Self.xtream(request)
            }
            let provider = try await makeXtreamGuideProvider { _, _, _, _, _ in
                XCTFail("Authentication and transient failures must not trigger XMLTV")
                return []
            }
            do {
                _ = try await provider.liveTVGuide(
                    channelIDs: ["live:10"], from: Date(timeIntervalSince1970: 100), to: Date(timeIntervalSince1970: 500)
                )
                XCTFail("The original error must remain visible")
            } catch {
                if status == 401 || status == 403 || status == 200 {
                    XCTAssertEqual(error as? IPTVError, .authentication)
                } else if status == 0 {
                    XCTAssertEqual((error as? URLError)?.code, .timedOut)
                } else if status == 429 {
                    guard case AppError.rateLimited = error else { return XCTFail("Expected rate limit, got \(error)") }
                } else {
                    guard case AppError.invalidResponse = error else { return XCTFail("Expected server failure, got \(error)") }
                }
            }
            XCTAssertFalse(IPTVFixture.state.requests.contains { $0.url?.path == "/prefix/xmltv.php" })
            await provider.teardown()
        }
    }

    func testExplicitXtreamGuideBypassesNativeAPIAndFailedFallbackRemainsAnError() async throws {
        let guideURL = try XCTUnwrap(URL(string: "https://cdn.test/guide.xml"))
        IPTVFixture.state.handler = { request in
            if request.url == guideURL { return (200, [:], Data("<tv/>".utf8)) }
            return try Self.xtream(request)
        }
        let configured = try await makeXtreamGuideProvider(guideURL: guideURL) { _, url, _, _, _ in
            XCTAssertEqual(url, guideURL)
            return []
        }
        _ = try await configured.liveTVGuide(
            channelIDs: ["live:10"], from: Date(timeIntervalSince1970: 100), to: Date(timeIntervalSince1970: 500)
        )
        XCTAssertFalse(IPTVFixture.state.requests.contains { $0.url?.query?.contains("get_simple_data_table") == true })
        await configured.teardown()
        IPTVFixture.state.reset()
        IPTVFixture.state.handler = { request in
            if request.url?.path == "/prefix/xmltv.php" { return (403, [:], Data()) }
            if request.url?.query?.contains("action=get_simple_data_table") == true {
                return (200, [:], Data(#"{"epg_listings":[]}"#.utf8))
            }
            return try Self.xtream(request)
        }
        let fallback = try await makeXtreamGuideProvider { _, _, _, _, _ in
            XCTFail("Rejected XMLTV must not reach the parser")
            return []
        }
        do {
            _ = try await fallback.liveTVGuide(
                channelIDs: ["live:10"], from: Date(timeIntervalSince1970: 100), to: Date(timeIntervalSince1970: 500)
            )
            XCTFail("A failed fallback must not look like an empty successful guide")
        } catch { XCTAssertEqual(error as? IPTVError, .authentication) }
    }

    private func makeXtreamGuideProvider(
        guideURL: URL? = nil, guideLoader: @escaping IPTVProvider.IPTVGuideLoader
    ) async throws -> IPTVProvider {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
        let credential = try IPTVCredential(
            mode: .xtream, address: XCTUnwrap(URL(string: "https://provider.test/prefix")),
            username: "fixture-user", password: "fixture-password", guideURL: guideURL
        )
        let session = try await IPTVProvider.signIn(
            credential: credential, name: "Guide", deviceID: "fixture",
            cacheDirectory: root, configuration: configuration()
        )
        let provider = try IPTVProvider(
            context: .init(session: session, accountID: "guide", credentialRevision: .init(),
                           localMediaContext: .init(accountID: "guide", profileID: "viewer", profileNamespace: nil)),
            cacheDirectory: root, configuration: configuration(), guideLoader: guideLoader
        )
        addTeardownBlock { await provider.teardown() }
        return provider
    }

    func testArtworkContainingAnAccountSecretNeverEscapesThePrivateCatalog() async throws {
        IPTVFixture.state.handler = { _ in
            (200, [:], Data("""
            #EXTM3U
            #EXTINF:120 tvg-logo="https://provider.test/poster/fixture-private-key/image.jpg",Movie
            https://provider.test/movie/one.mp4

            """.utf8))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credential = try IPTVCredential(
            mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.test/list")),
            headers: ["X-Provider-Key": "fixture-private-key"]
        )
        let client = try IPTVClient(credential: credential, directory: root, configuration: configuration())
        let page = try await client.page(library: "movies", kind: .movie, page: .init(limit: 10))
        XCTAssertEqual(page.totalCount, 1)
        XCTAssertNil(page.items.first?.posterURL)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(page.items), as: UTF8.self).contains("fixture-private-key"))
    }

    func testHTTPImportIndexesAndPagesBeyondLegacyEntryLimit() async throws {
        let total = 100_005
        var document = Data("#EXTM3U\n".utf8)
        for index in 0..<total {
            document.append(Data("#EXTINF:120,Movie \(index)\nhttps://provider.test/movie/\(index).mp4\n".utf8))
        }
        let payload = document
        IPTVFixture.state.handler = { _ in (200, [:], payload) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credential = try IPTVCredential(mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.test/list")))
        let client = try IPTVClient(credential: credential, directory: root, configuration: configuration())
        let end = try await client.page(library: "movies", kind: .movie, page: .init(startIndex: total - 5, limit: 20))
        XCTAssertEqual(end.totalCount, total)
        XCTAssertEqual(end.items.count, 5)
        XCTAssertEqual(Set(end.items.map(\.id)).count, 5)
        XCTAssertFalse(end.hasMore)
        XCTAssertEqual(IPTVFixture.state.requests.count, 1)
        let file = root.appendingPathComponent("large.m3u")
        try payload.write(to: file)
        let fileCredential = try IPTVCredential(
            mode: .file, address: XCTUnwrap(URL(string: "https://imported-playlist.invalid"))
        )
        let imported = try IPTVClient(credential: fileCredential, directory: root, configuration: configuration())
        try await imported.importFile(file)
        let fileEnd = try await imported.page(
            library: "movies", kind: .movie, page: .init(startIndex: total - 5, limit: 20)
        )
        XCTAssertEqual(fileEnd.totalCount, total)
        XCTAssertEqual(fileEnd.items.map(\.id), end.items.map(\.id))
        try await imported.ensureCatalog("movies", force: true)
        XCTAssertEqual(IPTVFixture.state.requests.count, 1, "Imported files must never trigger a synthetic network request")
    }

    func testLiveOnlyPlaylistDoesNotAdvertiseEmptyMovieAndSeriesLibraries() async throws {
        IPTVFixture.state.handler = { _ in
            (200, [:], Data("#EXTM3U\n#EXTINF:-1,News\nhttps://provider.test/live/one.ts\n".utf8))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credential = try IPTVCredential(mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.test/list")))
        let session = try await IPTVProvider.signIn(
            credential: credential, name: "Live", deviceID: "device",
            cacheDirectory: root, configuration: configuration()
        )
        let provider = try IPTVProvider(
            context: .init(session: session, accountID: "live-account", credentialRevision: .init(),
                           localMediaContext: .init(accountID: "live-account", profileID: "viewer", profileNamespace: nil)),
            cacheDirectory: root, configuration: configuration()
        )
        do {
            let libraries = try await provider.libraries()
            XCTAssertTrue(libraries.isEmpty)
            let channels = try await provider.liveTVChannels()
            XCTAssertEqual(channels.count, 1)
        } catch { await provider.teardown(); throw error }
        await provider.teardown()
    }

    func testProxyRewritesHLSAndScopesHeadersToOriginalOrigin() async throws {
        IPTVFixture.state.handler = { request in
            if request.url?.path == "/master.m3u8" {
                return (200, ["Content-Type": "application/vnd.apple.mpegurl"], Data("""
                \u{FEFF}#EXTM3U
                #EXT-X-TARGETDURATION:6
                #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
                #EXTINF:6,
                https://cdn.test/segment.ts
                #EXT-X-ENDLIST
                """.utf8))
            }
            return (200, ["Content-Type": "video/mp2t"], Data("segment".utf8))
        }
        let proxy = try IPTVPlaybackProxy(
            origin: XCTUnwrap(URL(string: "https://provider.test/master.m3u8")),
            headers: ["Authorization": "Bearer fixture"], configuration: configuration()
        )
        do {
            let url = try await proxy.start()
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let (manifest, _) = try await session.data(from: url)
            let text = String(decoding: manifest, as: UTF8.self)
            XCTAssertFalse(text.contains("cdn.test"))
            let segmentURL = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("http") }.flatMap { URL(string: String($0)) })
            let (segment, response) = try await session.data(from: segmentURL)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(String(decoding: segment, as: UTF8.self), "segment")
            let requests = IPTVFixture.state.requests
            XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            XCTAssertNil(requests.last?.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(requests.last?.url?.host, "cdn.test")
        } catch { await proxy.stop(); throw error }
        await proxy.stop()
    }

    func testProxyPreservesHeadAndByteRanges() async throws {
        IPTVFixture.state.handler = { request in
            (206, ["Content-Type": "video/mp4", "Content-Range": "bytes 10-12/100", "Content-Length": "3"],
             request.httpMethod == "HEAD" ? Data() : Data("abc".utf8))
        }
        let proxy = try IPTVPlaybackProxy(
            origin: XCTUnwrap(URL(string: "https://provider.test/movie.mp4")),
            headers: ["Cookie": "session=fixture"], configuration: configuration()
        )
        do {
            let url = try await proxy.start()
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            for method in ["HEAD", "GET"] {
                var request = URLRequest(url: url)
                request.httpMethod = method
                request.setValue("bytes=10-12", forHTTPHeaderField: "Range")
                let (data, response) = try await session.data(for: request)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
                XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), "bytes 10-12/100")
                XCTAssertEqual(data.count, method == "HEAD" ? 0 : 3)
            }
            XCTAssertEqual(IPTVFixture.state.requests.map(\.httpMethod), ["HEAD", "GET"])
            XCTAssertTrue(IPTVFixture.state.requests.allSatisfy { $0.value(forHTTPHeaderField: "Range") == "bytes=10-12" })
        } catch { await proxy.stop(); throw error }
        await proxy.stop()
    }

    private func configuration() -> URLSessionConfiguration {
        IPTVFixture.configuration()
    }

    private static func xtream(_ request: URLRequest) throws -> IPTVFixture.Response {
        let components = try XCTUnwrap(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        guard components.queryItems?.first(where: { $0.name == "username" })?.value == "fixture-user",
              components.queryItems?.first(where: { $0.name == "password" })?.value == "fixture-password" else {
            return (401, [:], Data())
        }
        let action = components.queryItems?.first { $0.name == "action" }?.value
        let payload: String
        switch action {
        case nil: payload = #"{"user_info":{"auth":1,"status":"Active","allowed_output_formats":["m3u8","ts"]}}"#
        case "get_live_categories", "get_vod_categories", "get_series_categories":
            payload = #"[{"category_id":"1","category_name":"News"}]"#
        case "get_live_streams": payload = #"[{"stream_id":10,"name":"News","epg_channel_id":"news","category_id":"1"}]"#
        case "get_vod_streams": payload = #"[{"stream_id":"20","name":"Movie","container_extension":"mkv","tmdb":"123"}]"#
        case "get_series": payload = #"[{"series_id":30,"name":"Series"}]"#
        case "get_vod_info": payload = #"{"info":{"plot":"Movie plot"},"movie_data":{"container_extension":"mkv"}}"#
        case "get_series_info":
            payload = #"{"info":{"plot":"Series plot"},"episodes":{"1":[{"id":31,"episode_num":1,"title":"Pilot","container_extension":"mp4","info":{"duration_secs":1800}}]}}"#
        case "get_simple_data_table":
            payload = #"{"epg_listings":[{"id":"p1","title":"TmV3cw==","start_timestamp":"100","stop_timestamp":"400"}]}"#
        default: throw URLError(.unsupportedURL)
        }
        return (200, ["Content-Type": "application/json"], Data(payload.utf8))
    }
}

final class IPTVFixture: URLProtocol, @unchecked Sendable {
    typealias Response = (Int, [String: String], Data)
    static let state = State()

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IPTVFixture.self]
        return configuration
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (@Sendable (URLRequest) throws -> Response)?
        private var received: [URLRequest] = []
        var handler: (@Sendable (URLRequest) throws -> Response)? {
            get { lock.withLock { action } }
            set { lock.withLock { action = newValue } }
        }
        var requests: [URLRequest] { lock.withLock { received } }
        func reset() { lock.withLock { received = []; action = nil } }
        func respond(_ request: URLRequest) throws -> Response {
            let callback = lock.withLock { received.append(request); return action }
            guard let callback else { throw URLError(.unsupportedURL) }
            return try callback(request)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        ["provider.test", "cdn.test"].contains(request.url?.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.state.respond(request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: XCTUnwrap(request.url), statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
