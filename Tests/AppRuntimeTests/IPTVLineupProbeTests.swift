#if DEBUG
@testable import AppRuntime
import CoreModels
import CoreNetworking
import CryptoKit
@testable import FeatureLiveTVCore
import Foundation
import ProviderIPTV
import SQLite3
import Synchronization
@testable import TestSupportNetworking
@testable import TestSupportPerformance
import XCTest

@MainActor
final class IPTVLineupProbeTests: XCTestCase {
    func testWarmSavedWindowsBuildLineupAndProjectionOnce() async throws {
        try await withFixture { fixture in
            let result = try await fixture.readWindows()
            print("IPTV_LINEUP_BASELINE \(result.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
            XCTAssertEqual(result["fullClientMaps"], 1, "Build the committed lookup only once for all eight windows.")
            XCTAssertEqual(result["providerIDMaps"], 1, "Do not rebuild an ID map for each request.")
            XCTAssertEqual(result["adapterMaps"], 1, "Map the full lineup only on the projection miss.")
            XCTAssertEqual(result["projectionBuilds"], 1, "Share the matching projection across sources and windows.")
        }
    }

    func testWarmSingleStationDoesNotReadTheSavedDocumentAgain() async throws {
        try await withFixture(extraGuideStations: 20_000) { fixture in
            let window = fixture.windows[0]
            let first = try XCTUnwrap(window.expected.first { $0.channelID == window.ids[0] })
            let station = Window(ids: [window.ids[0]], start: window.start, end: window.end, expected: [first])
            let endpointsBefore = await fixture.endpointCounts()
            try await fixture.withReader(observingCache: { provider, cache in
                let primed = try await station.read(provider)
                XCTAssertEqual(primed, station.expected)
                let before = await cache.guideSQLWorkForTesting
                let decodesBefore = await cache.guideDocumentDecodesForTesting
                XCTAssertEqual(before.documentSelects, 1)
                XCTAssertGreaterThan(before.documentBytesCopied, 500_000)
                XCTAssertEqual(before.programmeSelects, 1)
                XCTAssertEqual(decodesBefore, 1)
                for _ in 0..<5 {
                    let rows = try await station.read(provider)
                    XCTAssertEqual(rows, station.expected)
                }
                let after = await cache.guideSQLWorkForTesting
                let decodes = await cache.guideDocumentDecodesForTesting - decodesBefore
                let selects = after.documentSelects - before.documentSelects
                let bytes = after.documentBytesCopied - before.documentBytesCopied
                let queries = after.programmeSelects - before.programmeSelects
                let endpointsAfter = await fixture.endpointCounts()
                let http = zip(endpointsBefore, endpointsAfter).reduce(0) { $0 + $1.1 - $1.0 }
                print("Guide provider probe: B=\(before.documentBytesCopied) warmReads=5 payloadSELECTs=\(selects) "
                      + "copiedBytes=\(bytes) decodes=\(decodes) programmeQueries=\(queries) fixtureHTTP=\(http)")
                XCTAssertEqual(selects, 0)
                XCTAssertEqual(bytes, 0)
                XCTAssertEqual(decodes, 0)
                XCTAssertEqual(queries, 5)
                XCTAssertEqual(endpointsAfter, endpointsBefore)
            })
        }
    }

    func testTwoOverlappingColdRequestsShareOneBuild() async throws {
        try await withFixture { fixture in
            let work = WorkCounts()
            let before = await fixture.endpointCounts()
            try await fixture.withReader { provider in
                let (first, second) = try await IPTVLineupProbe.$record.withValue(work.record) {
                    async let first = fixture.windows[0].read(provider)
                    async let second = fixture.windows[1].read(provider)
                    return try await (first, second)
                }
                XCTAssertEqual(first, fixture.windows[0].expected)
                XCTAssertEqual(second, fixture.windows[1].expected)
            }
            let after = await fixture.endpointCounts()
            XCTAssertEqual(after, before)
            print("IPTV_LINEUP_CONCURRENT client=\(work[.fullClientMaps]) id=\(work[.providerIDMaps]) adapter=\(work[.adapterMaps]) projection=\(work[.projectionBuilds]) queries=\(work[.nonemptySourceQueries])")
            XCTAssertEqual(work[.nonemptySourceQueries], 4)
            XCTAssertEqual(work[.guideDownloads], 0)
            XCTAssertEqual(work[.guideImports], 0)
            XCTAssertEqual(work[.fullClientMaps], 1)
            XCTAssertEqual(work[.providerIDMaps], 1)
            XCTAssertEqual(work[.adapterMaps], 1)
            XCTAssertEqual(work[.projectionBuilds], 1)
        }
    }

    func testUnknownChannelDoesNotBecomeAnEmptyGuide() async throws {
        try await withFixture { fixture in
            let before = await fixture.endpointCounts()
            try await fixture.withReader { provider in
                let window = fixture.windows[0]
                do {
                    _ = try await provider.liveTVGuide(
                        channelIDs: [window.ids[0], "unknown-channel"], from: window.start, to: window.end
                    )
                    XCTFail("A missing committed ID must fail the request.")
                } catch AppError.notFound {
                    // Not an empty guide or a partial source failure.
                }
                let actual = try await window.read(provider)
                XCTAssertEqual(actual, window.expected)
            }
            let after = await fixture.endpointCounts()
            XCTAssertEqual(after, before)
        }
    }

    func testSameCountMatchingReplacementAndNonmatchingEdit() async throws {
        let reached = expectation(description: "Replacement playlist request is in flight")
        let (release, open) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let edits = PlaylistEdits()
        try await withFixture(playlistEdits: edits) { fixture in
            let window = fixture.windows[0]
            let initialProjections = try await fixture.savedProjections()
            try await fixture.withReader { provider in
                let initial = try await window.read(provider)
                XCTAssertEqual(initial, window.expected)
                await edits.install(old: "tvg-id=\"station-0\",Station 0", new: "tvg-id=\"station-0\",Renamed 0") {
                    reached.fulfill()
                    for await _ in release { break }
                }
                // Separate writer connection: a forced sign-in has not yet committed its replacement.
                let replacement = Task { try await fixture.replacePlaylist() }
                await fulfillment(of: [reached], timeout: 5)
                do {
                    let during = try await window.read(provider)
                    XCTAssertEqual(during, window.expected)
                } catch {
                    open.finish()
                    _ = await replacement.result
                    throw error
                }
                open.finish()
                try await replacement.value

                let lineup = try await provider.liveTVChannels()
                XCTAssertEqual(lineup.count, Fixture.channelCount)
                let oldID = window.ids[0]
                let newID = try XCTUnwrap(lineup.first { $0.name == "Renamed 0" }?.id)
                XCTAssertNotEqual(newID, oldID)
                let firstSource = window.expected.prefix(128).filter { $0.channelID != oldID }
                    + [Fixture.programme(channel: 0, id: newID, window: 0)]
                let updated = Window(ids: [newID] + Array(window.ids.dropFirst()), start: window.start, end: window.end,
                                     expected: firstSource.sorted { $0.id < $1.id } + Array(window.expected.suffix(128)))
                let replacementWork = WorkCounts()
                let replaced = try await IPTVLineupProbe.$record.withValue(replacementWork.record) {
                    try await updated.read(provider)
                }
                XCTAssertEqual(replaced, updated.expected)
                XCTAssertEqual(replacementWork[.guideDownloads], 2)
                XCTAssertEqual(replacementWork[.guideImports], 2)
                let changedProjections = try await fixture.savedProjections()
                XCTAssertNotEqual(changedProjections, initialProjections)

                // Change only display artwork. Keep the same writer's matching edit in the next body.
                await edits.install(old: "tvg-id=\"station-0\",Renamed 0",
                                    new: "tvg-id=\"station-0\" tvg-logo=\"https://fixture.invalid/logo.png\",Renamed 0")
                try await fixture.replacePlaylist()
                let edited = try await provider.liveTVChannels()
                XCTAssertEqual(edited.count, Fixture.channelCount)
                XCTAssertEqual(edited.first { $0.id == newID }?.imageURL?.absoluteString, "https://fixture.invalid/logo.png")
                let afterEdit = try await updated.read(provider)
                XCTAssertEqual(afterEdit, updated.expected)
                let unchangedProjections = try await fixture.savedProjections()
                XCTAssertEqual(unchangedProjections, changedProjections)

                let endpoints = await fixture.endpointCounts()
                XCTAssertEqual(endpoints, [3, 2, 2, 0], "Artwork-only replacement must preserve both saved projections.")
                print("IPTV_LINEUP_REPLACEMENT projection=\(replacementWork[.projectionBuilds]) imports=\(replacementWork[.guideImports])")
                XCTAssertEqual(replacementWork[.projectionBuilds], 1, "Rebuild the projection once for the new matching fields.")
            }
        }
    }

    func testSuspendedExplicitGuideRejectsSupersededRowsAndFreshReadUsesReplacement() async throws {
        for secondFeedFails in [false, true] {
            let reached = expectation(description: "Second guide response pending (fails: \(secondFeedFails))")
            let (release, open) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let pauseNext = Mutex(false)
            let edits = PlaylistEdits()
            try await withFixture(playlistEdits: edits, respondToSecondGuide: { body in
                let pause = pauseNext.withLock { armed in
                    defer { armed = false }
                    return armed
                }
                if pause {
                    reached.fulfill()
                    for await _ in release { break }
                    if secondFeedFails { return .init(status: 404) }
                }
                return .init(headers: ["Cache-Control": "max-age=3600"], body: body)
            }) { fixture in
                let window = fixture.windows[0]
                let originalIDs = Array(window.ids.prefix(2))
                try await fixture.withReader(observingCache: { provider, cache in
                    // Keep the first feed warm. Only the second feed needs to reach transport.
                    let credential = try IPTVCredential.decode(fixture.context.session.accessToken)
                    let second = try XCTUnwrap(credential.explicitGuideURLs.dropFirst().first)
                    try await cache.removeDownloadedGuide(sourceID: LiveTVGuideIndex.sourceID(second), sourceURL: second)
                    pauseNext.withLock { $0 = true }
                    let pending = Task {
                        try await provider.liveTVGuide(channelIDs: originalIDs, from: window.start, to: window.end)
                    }
                    await fulfillment(of: [reached], timeout: 5)
                    do {
                        // Swap matching IDs without changing the count or leaving duplicate guide IDs.
                        await edits.install(old: "tvg-id=\"station-0\",Station 0", new: "tvg-id=\"station-2\",Station 0")
                        await edits.install(old: "tvg-id=\"station-2\",Station 2", new: "tvg-id=\"station-0\",Station 2")
                        try await fixture.replacePlaylist()
                    } catch {
                        open.finish()
                        pending.cancel()
                        _ = await pending.result
                        throw error
                    }
                    open.finish()
                    switch await pending.result {
                    case .success(let rows):
                        XCTFail("Superseded request returned \(rows.map(\.title)).")
                    case .failure(let partial as ServerLiveTVPartialGuideError):
                        XCTFail("Superseded request returned partial rows \(partial.programmes.map(\.title)).")
                    case .failure(let error):
                        XCTAssertTrue(error is CancellationError, "Expected cancellation, not \(error).")
                    }

                    let lineup = try await provider.liveTVChannels()
                    XCTAssertEqual(lineup.count, Fixture.channelCount)
                    let replacementID = try XCTUnwrap(lineup.first { $0.name == "Station 0" }?.id)
                    XCTAssertNotEqual(replacementID, originalIDs[0])
                    let fresh = try await provider.liveTVGuide(
                        channelIDs: [replacementID, originalIDs[1]], from: window.start, to: window.end
                    )
                    XCTAssertEqual(fresh.map(\.channelID), [replacementID, originalIDs[1]])
                    XCTAssertEqual(fresh.map(\.title), ["Programme 2-0", "Programme 1-0"])
                })
            }
        }
    }

    func testSuspendedExplicitGuidePublishesAfterUnrelatedExternalCommit() async throws {
        try await assertSuspendedExplicitGuidePublishes { fixture in
            let catalogs = try IPTVCatalogStorage.catalogs(in: fixture.root)
            XCTAssertEqual(catalogs.count, 1)
            let url = try XCTUnwrap(catalogs.first)
            var db: OpaquePointer?
            let status = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
            defer { XCTAssertEqual(sqlite3_close(db), SQLITE_OK) }
            XCTAssertEqual(status, SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(db, "INSERT INTO state(key,value) VALUES('unrelated','1')",
                                        nil, nil, nil), SQLITE_OK)
        }
    }

    func testSuspendedExplicitGuidePublishesAfterIdenticalReimport() async throws {
        try await assertSuspendedExplicitGuidePublishes { fixture in
            try await fixture.replacePlaylist()
        }
    }

    private func assertSuspendedExplicitGuidePublishes(_ commit: (Fixture) async throws -> Void) async throws {
        let reached = expectation(description: "Second guide response pending")
        let (release, open) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let pauseNext = Mutex(false)
        try await withFixture(respondToSecondGuide: { body in
            let pause = pauseNext.withLock { armed in
                defer { armed = false }
                return armed
            }
            if pause {
                reached.fulfill()
                for await _ in release { break }
            }
            return .init(headers: ["Cache-Control": "max-age=3600"], body: body)
        }) { fixture in
            let window = fixture.windows[0]
            let originalIDs = Array(window.ids.prefix(2))
            let expectedTitles = ["Programme 0-0", "Programme 1-0"]
            try await fixture.withReader(observingCache: { provider, cache in
                let credential = try IPTVCredential.decode(fixture.context.session.accessToken)
                let second = try XCTUnwrap(credential.explicitGuideURLs.dropFirst().first)
                try await cache.removeDownloadedGuide(sourceID: LiveTVGuideIndex.sourceID(second), sourceURL: second)
                pauseNext.withLock { $0 = true }
                let pending = Task {
                    try await provider.liveTVGuide(channelIDs: originalIDs, from: window.start, to: window.end)
                }
                await fulfillment(of: [reached], timeout: 5)
                do {
                    try await commit(fixture)
                } catch {
                    open.finish()
                    pending.cancel()
                    _ = await pending.result
                    throw error
                }
                open.finish()
                switch await pending.result {
                case .success(let rows):
                    XCTAssertEqual(rows.map(\.channelID), originalIDs)
                    XCTAssertEqual(rows.map(\.title), expectedTitles)
                case .failure(let partial as ServerLiveTVPartialGuideError):
                    XCTFail("Unchanged lineup returned partial rows \(partial.programmes.map(\.title)).")
                case .failure(let error):
                    XCTFail("Unchanged lineup did not publish: \(error).")
                }

                let fresh = try await provider.liveTVGuide(channelIDs: originalIDs, from: window.start, to: window.end)
                XCTAssertEqual(fresh.map(\.channelID), originalIDs)
                XCTAssertEqual(fresh.map(\.title), expectedTitles)
            })
        }
    }

    func testCommittedUnguidedPlaylistIDIsKnownAndDoesNotTriggerRequests() async throws {
        try await withFixture { fixture in
            let before = await fixture.endpointCounts()
            try await fixture.withReader { provider in
                let lineup = try await provider.liveTVChannels()
                let unguided = try XCTUnwrap(lineup.first { $0.name == "Station \(Fixture.channelCount - 1)" })
                let window = fixture.windows[0]
                let rows = try await provider.liveTVGuide(
                    channelIDs: window.ids + [unguided.id], from: window.start, to: window.end
                )
                XCTAssertEqual(rows, window.expected)
            }
            let after = await fixture.endpointCounts()
            XCTAssertEqual(after, before)
        }
    }

    func testPerformanceWarmSavedLineup() async throws {
        try PerformanceProbe.requireEnabled()
        try await withFixture { fixture in
            try await PerformanceProbe.measure(self, scenario: "guide-warm-saved-lineup") {
                try await fixture.readWindows()
            }
        }
    }

    private func withFixture(
        playlistEdits: PlaylistEdits? = nil, extraGuideStations: Int = 0,
        respondToSecondGuide: (@Sendable (Data) async -> LoopbackHTTPServer.Response)? = nil,
        _ run: (Fixture) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Could not remove the owned lineup fixture.") }
        }
        let bodies = Fixture.bodies(extraGuideStations: extraGuideStations)
        let server = try LoopbackHTTPServer { request in
            guard var body = bodies[request.target] else { return .init(status: 404) }
            if request.target == Fixture.paths[0], let playlistEdits { body = await playlistEdits.apply(to: body) }
            if request.target == Fixture.paths[2], let respondToSecondGuide { return await respondToSecondGuide(body) }
            return .init(headers: ["Cache-Control": "max-age=3600"], body: body)
        }
        do {
            let fixture = try await Fixture.seed(root: root, server: server)
            try await run(fixture)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    private struct Window: Sendable {
        let ids: [String]
        let start: Date
        let end: Date
        let expected: [ServerLiveTVProgramme]

        func read(_ provider: IPTVProvider) async throws -> [ServerLiveTVProgramme] {
            try await provider.liveTVGuide(channelIDs: ids, from: start, to: end)
        }
    }

    private struct Fixture: Sendable {
        static let channelCount = 6_000
        static let windowCount = 8
        static let width = 256
        static let origin = Date(timeIntervalSince1970: 1_800_000_000)
        static let paths = ["/lineup.m3u", "/first.xml", "/second.xml"]

        let root: URL
        let server: LoopbackHTTPServer
        let context: ProviderResolutionContext
        let secureStore: FixtureSecrets
        let windows: [Window]

        static func bodies(extraGuideStations: Int) -> [String: Data] {
            let playlist = "#EXTM3U\n" + (0..<channelCount).map { channel in
                // One unguided station outside the requested set; the lineup is not guided-only.
                let guide = channel == channelCount - 1 ? "" : " tvg-id=\"station-\(channel)\""
                return "#EXTINF:-1\(guide),Station \(channel)\nhttps://fixture.invalid/live/\(channel).ts\n"
            }.joined()
            let dates = DateFormatter()
            dates.locale = Locale(identifier: "en_US_POSIX")
            dates.timeZone = TimeZone(secondsFromGMT: 0)
            dates.dateFormat = "yyyyMMddHHmmss Z"
            let times = (0...windowCount).map { dates.string(from: time($0)) }
            var result = [paths[0]: Data(playlist.utf8)]
            for source in 0..<2 {
                var xml = "<tv>"
                if source == 0 {
                    for station in 0..<extraGuideStations {
                        xml += "<channel id=\"extra-\(station)\"><display-name>Extra Station \(station)</display-name></channel>"
                    }
                }
                for channel in stride(from: source, to: channelCount - 1, by: 2) {
                    xml += "<channel id=\"station-\(channel)\"><display-name>Station \(channel)</display-name></channel>"
                }
                for window in 0..<windowCount {
                    for channel in batch(window) where channel % 2 == source {
                        xml += """
                        <programme channel="station-\(channel)" start="\(times[window])" stop="\(times[window + 1])">\
                        <title>Programme \(channel)-\(window)</title><sub-title>Episode \(window)</sub-title>\
                        <desc>Synopsis \(channel)</desc><category>Fixture</category></programme>
                        """
                    }
                }
                result[paths[source + 1]] = Data((xml + "</tv>").utf8)
            }
            return result
        }

        static func seed(root: URL, server: LoopbackHTTPServer) async throws -> Self {
            let base = try await server.start()
            let credential = try IPTVCredential(
                mode: .playlist, address: base.appendingPathComponent("lineup.m3u"),
                guideURL: base.appendingPathComponent("first.xml"),
                additionalGuideURLs: [base.appendingPathComponent("second.xml")]
            )
            let session = try await IPTVProvider.signIn(
                credential: credential, name: "Lineup fixture", deviceID: "fixture", cacheDirectory: root,
                configuration: .ephemeral
            )
            let context = ProviderResolutionContext(
                session: session, accountID: "lineup-fixture", credentialRevision: .init(),
                localMediaContext: .init(accountID: "lineup-fixture", profileID: "fixture", profileNamespace: nil)
            )
            let seed = Self(root: root, server: server, context: context, secureStore: FixtureSecrets(), windows: [])
            let windows = try await seed.withReader { provider in
                let channels = try await provider.liveTVChannels()
                XCTAssertEqual(channels.count, channelCount)
                let byName = Dictionary(uniqueKeysWithValues: channels.map { ($0.name, $0.id) })
                let windows = try (0..<windowCount).map { window in
                    let ids = try batch(window).map { try XCTUnwrap(byName["Station \($0)"]) }
                    XCTAssertEqual(Set(ids).count, width)
                    let expectedBySource = (0..<2).map { source in
                        zip(batch(window), ids).filter { $0.0 % 2 == source }.map { channel, id in
                            programme(channel: channel, id: id, window: window)
                        }.sorted { $0.id < $1.id }
                    }
                    XCTAssertEqual(expectedBySource.map(\.count), [128, 128])
                    return Window(ids: ids, start: time(window), end: time(window + 1),
                                  expected: expectedBySource.flatMap { $0 })
                }
                let seeded = try await windows[0].read(provider)
                XCTAssertEqual(seeded, windows[0].expected)
                return windows
            }
            let endpoints = await seed.endpointCounts()
            XCTAssertEqual(endpoints, [1, 1, 1, 0], "One playlist and one document per ordered guide URL.")
            return Self(root: root, server: server, context: context, secureStore: seed.secureStore, windows: windows)
        }

        private static func batch(_ window: Int) -> Range<Int> { (window * 64)..<(window * 64 + width) }
        private static func time(_ window: Int) -> Date { origin.addingTimeInterval(Double(window) * 3_600) }

        static func programme(channel: Int, id: String, window: Int) -> ServerLiveTVProgramme {
            let title = "Programme \(channel)-\(window)", subtitle = "Episode \(window)"
            let start = time(window), end = time(window + 1)
            let parts = [id, "station-\(channel)", title, subtitle,
                         String(Int64(start.timeIntervalSince1970)), String(Int64(end.timeIntervalSince1970))]
            let hash = SHA256.hash(data: Data(parts.joined(separator: "\u{1f}").utf8))
            let airingID = "xmltv-" + hash.map { String(format: "%02x", $0) }.joined()
            return .init(id: airingID, channelID: id, title: title, subtitle: subtitle,
                         overview: "Synopsis \(channel)", startDate: start, endDate: end, categories: ["Fixture"])
        }

        func replacePlaylist() async throws {
            let credential = try IPTVCredential.decode(context.session.accessToken)
            _ = try await IPTVProvider.signIn(
                credential: credential, name: "Lineup fixture", deviceID: "fixture", cacheDirectory: root,
                configuration: .ephemeral
            )
        }

        func endpointCounts() async -> [Int] {
            let targets = await server.requests.map(\.target)
            return Self.paths.map { path in targets.count { $0 == path } }
                + [targets.count { !Self.paths.contains($0) }]
        }

        private func makeCache(lifecycle: ApplicationStorageLifecycle = .shared) -> LiveTVIndexedCache {
            LiveTVIndexedCache(url: root.appendingPathComponent("guide.sqlite"), namespace: "fixture",
                               authorizationScope: "fixture", secureStore: secureStore, storageLifecycle: lifecycle)
        }

        func savedProjections() async throws -> [String] {
            let credential = try IPTVCredential.decode(context.session.accessToken)
            let cache = makeCache()
            var projections: [String] = []
            for url in credential.explicitGuideURLs {
                let state = try await cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
                projections.append(try XCTUnwrap(state).projection)
            }
            XCTAssertEqual(projections.count, 2)
            return projections
        }

        func withReader<T>(_ run: (IPTVProvider) async throws -> T) async throws -> T {
            try await withReader(observingCache: { provider, _ in try await run(provider) })
        }

        func withReader<T>(observingCache run: (IPTVProvider, LiveTVIndexedCache) async throws -> T) async throws -> T {
            // Same authorized files and key, but new client, index actor and open SQLite connection.
            let lifecycle = ApplicationStorageLifecycle()
            let cache = makeCache(lifecycle: lifecycle)
            let adapter = IPTVAccountGuideIndex(index: LiveTVGuideIndex(cache: cache, preferredLanguage: nil),
                                                settings: .init(namespace: nil))
            let provider = try IPTVProvider(context: context, cacheDirectory: root, configuration: .ephemeral,
                                            guideIndex: adapter)
            do {
                let result = try await run(provider, cache)
                await provider.teardown()
                await lifecycle.setApplicationActive(false, revision: 1)
                return result
            } catch {
                await provider.teardown()
                await lifecycle.setApplicationActive(false, revision: 1)
                throw error
            }
        }

        func readWindows() async throws -> [String: Int] {
            let before = await endpointCounts()
            let work = WorkCounts()
            var durations: [Int] = []
            var rows = 0
            try await withReader { provider in
                try await IPTVLineupProbe.$record.withValue(work.record) {
                    for window in windows {
                        let start = DispatchTime.now().uptimeNanoseconds
                        let answer = try await window.read(provider)
                        durations.append(Int(DispatchTime.now().uptimeNanoseconds - start))
                        XCTAssertEqual(answer, window.expected)
                        rows += answer.count
                    }
                }
            }
            let after = await endpointCounts()
            XCTAssertEqual(after, before, "Measured windows may neither refresh the playlist nor download a guide.")
            XCTAssertEqual(rows, 2_048)
            XCTAssertEqual(work[.nonemptySourceQueries], 16)
            XCTAssertEqual(work[.guideDownloads], 0)
            XCTAssertEqual(work[.guideImports], 0)
            return work.report.merging([
                "rows": rows, "httpRequests": zip(before, after).reduce(0) { $0 + $1.1 - $1.0 },
                "firstWindowNanoseconds": durations[0], "warmWindowsNanoseconds": durations.dropFirst().reduce(0, +)
            ], uniquingKeysWith: { first, _ in first })
        }
    }

    private actor PlaylistEdits {
        private var replacements: [(String, String)] = []
        private var pause: (@Sendable () async -> Void)?

        func install(old: String, new: String, pause: (@Sendable () async -> Void)? = nil) {
            replacements.append((old, new))
            self.pause = pause
        }

        func apply(to body: Data) async -> Data {
            let edited = replacements.reduce(String(decoding: body, as: UTF8.self)) {
                $0.replacingOccurrences(of: $1.0, with: $1.1)
            }
            let pause = self.pause
            self.pause = nil
            await pause?()
            return Data(edited.utf8)
        }
    }

    private final class WorkCounts: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [IPTVLineupProbe.Event: Int] = [:]
        func record(_ event: IPTVLineupProbe.Event) { lock.withLock { values[event, default: 0] += 1 } }
        subscript(_ event: IPTVLineupProbe.Event) -> Int { lock.withLock { values[event, default: 0] } }
        var report: [String: Int] {
            Dictionary(uniqueKeysWithValues: IPTVLineupProbe.Event.allCases.map { ($0.rawValue, self[$0]) })
        }
    }

    private final class FixtureSecrets: SecureStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        func string(for key: String) -> String? { lock.withLock { values[key] } }
        func readString(for key: String) throws -> String? { string(for: key) }
        func setString(_ value: String, for key: String) throws { lock.withLock { values[key] = value } }
        func removeValue(for key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
    }
}
#endif
