import CoreModels
import CoreNetworking
import CryptoKit
import Foundation
import Synchronization
import XCTest
@testable import FeatureLiveTVCore

final class LiveTVGuideIndexTests: XCTestCase {
    func testForegroundWaiterReceivesExistingFlightProgressAndParserStageTotals() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let url = url
        let range = range
        let download = HeldDownload(response(document()))
        let first = Task {
            try await index.programs(from: url, catalog: channels, channels: channels, range: range) {
                ServerLiveTVGuideProgress.report?(.init(stage: .downloading, completed: 50, total: 100))
                return try await download.get()
            }
        }
        await download.waitUntilStarted()
        let events = Mutex<[ServerLiveTVGuideProgress]>([])
        let second = Task {
            try await ServerLiveTVGuideProgress.$report.withValue({ value in events.withLock { $0.append(value) } }) {
                try await index.programs(from: url, catalog: channels, channels: channels, range: range) {
                    XCTFail("Joining a guide must not download again.")
                    return try await download.get()
                }
            }
        }
        await index.waitForWaitersForTesting(2)
        XCTAssertEqual(events.withLock { $0.first }, .init(stage: .downloading, completed: 50, total: 100))
        await download.release()
        _ = try await first.value
        _ = try await second.value
        let progress = events.withLock { $0 }
        XCTAssertTrue(progress.contains(.init(stage: .readingGuide, completed: 2)))
        XCTAssertTrue(progress.contains(.init(stage: .preparingListings, completed: 2, total: 2)))
        XCTAssertEqual(progress.last?.stage, .saving)
        let count = await download.count
        XCTAssertEqual(count, 1)
    }

    private let url = URL(string: "https://fixture.test/guide.xml")!
    private let now = Date(timeIntervalSince1970: 100)
    private var range: DateInterval { DateInterval(start: now, duration: 400) }

    private func channel(_ id: String, guideID: String = "news", name: String = "News") -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id, number: 0, name: name, category: "Live TV", symbol: "tv",
            accent: 0, source: .iptv, tagline: "", guideID: guideID
        )
    }

    private func document(title: String = "Bulletin") -> Data {
        Data("""
        <tv><channel id="news"><display-name>News</display-name></channel>
        <programme channel="news" start="19700101000140 +0000" stop="19700101000820 +0000">
        <title>\(title)</title><desc>Synopsis</desc></programme>
        <channel id="sport"><display-name>Sport</display-name></channel>
        <programme channel="sport" start="19700101000140 +0000" stop="19700101000820 +0000">
        <title>Match</title></programme></tv>
        """.utf8)
    }

    private func response(_ data: Data, expires: Date = .distantFuture, persists: Bool = true) -> XMLTVDownloadedDocument {
        .init(data: data, expiresAt: expires, permitsPersistence: persists)
    }

    private func httpMetadata(
        headers: [String: String] = ["ETag": "\"v1\""], status: Int = 200,
        previous: XMLTVGuideCacheMetadata? = nil, at time: Date? = nil
    ) throws -> XMLTVGuideCacheMetadata {
        try XMLTVGuideCacheMetadata(
            response: XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)),
            previous: previous, now: time ?? now
        )
    }

    private func httpDocument(_ metadata: XMLTVGuideCacheMetadata, title: String = "Bulletin") -> XMLTVDownloadedDocument {
        .init(data: document(title: title), expiresAt: metadata.expiresAt,
              permitsPersistence: metadata.permitsPersistence, cacheMetadata: metadata)
    }

    func testTemporarilyEmptyFeedRetriesOnDemandAcrossRestorationAndRevalidation() async throws {
        for status in [200, 304] {
            for lifetime: TimeInterval in [30, 60] {
                try await verifyEmptyFeedRecovery(status: status, lifetime: lifetime)
            }
        }
    }

    private func verifyEmptyFeedRecovery(status: Int, lifetime: TimeInterval) async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let clock = Mutex(now)
        let channels = [channel("a")]
        let headers = lifetime == 30 ? ["ETag": "\"v1\"", "Cache-Control": "max-age=30"] : ["ETag": "\"v1\""]
        let original = try httpMetadata(headers: headers)
        let empty = XMLTVDownloadedDocument(
            data: Data("<tv/>".utf8), expiresAt: original.expiresAt, permitsPersistence: true, cacheMetadata: original
        )
        let index = LiveTVGuideIndex(cache: fixture.cache, clock: { clock.withLock { $0 } })
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { empty }
        let restored = LiveTVGuideIndex(cache: fixture.reopen(), clock: { clock.withLock { $0 } })
        clock.withLock { $0 = original.checkedAt.addingTimeInterval(lifetime - 1) }
        _ = try await restored.programs(from: url, catalog: channels, channels: channels, range: range) { _ in
            XCTFail("Empty recovery is bounded, not a download on every navigation")
            throw URLError(.badServerResponse)
        }
        let checked = original.checkedAt.addingTimeInterval(lifetime)
        clock.withLock { $0 = checked }
        let unchanged = try httpMetadata(headers: headers, status: status, previous: original, at: checked)
        let before = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        let attempts = Mutex(0)
        _ = try await restored.programs(from: url, catalog: channels, channels: channels, range: range) { previous in
            XCTAssertEqual(previous, original)
            attempts.withLock { $0 += 1 }
            return status == 304 ? .notModified(unchanged) : .document(.init(
                data: empty.data, expiresAt: unchanged.expiresAt, permitsPersistence: true, cacheMetadata: unchanged
            ))
        }
        XCTAssertEqual(attempts.withLock { $0 }, 1)
        let after = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        XCTAssertEqual(before?.generation, after?.generation)
        clock.withLock { $0 = checked.addingTimeInterval(lifetime) }
        let updated = httpDocument(try httpMetadata(at: checked.addingTimeInterval(lifetime)))
        let rows = try await restored.programs(from: url, catalog: channels, channels: channels, range: range) { previous in
            XCTAssertEqual(previous, unchanged)
            return .document(updated)
        }
        XCTAssertEqual(rows.map(\.title), ["Bulletin"])
    }

    func testPopulatedFeedDoesNotRefetchEarlyForUnmatchedChannelsOrUnpopulatedWindows() async throws {
        let cases = [
            ([channel("missing", guideID: "missing", name: "Unmatched")], range),
            ([channel("a")], DateInterval(start: now.addingTimeInterval(2 * 86_400), duration: 400))
        ]
        for (channels, requestedRange) in cases {
            let fixture = try CacheFixture()
            defer { fixture.removeOwnedFiles() }
            let clock = Mutex(now)
            let index = LiveTVGuideIndex(cache: fixture.cache, clock: { clock.withLock { $0 } })
            let metadata = try httpMetadata()
            let populated = httpDocument(metadata)
            let first = try await index.programs(from: url, catalog: channels, channels: channels, range: requestedRange) {
                populated
            }
            XCTAssertTrue(first.isEmpty)
            clock.withLock { $0 = metadata.checkedAt.addingTimeInterval(60) }
            let second = try await index.programs(from: url, catalog: channels, channels: channels, range: requestedRange) { _ in
                XCTFail("A populated feed is not due simply because this query has no matches")
                throw URLError(.badServerResponse)
            }
            XCTAssertTrue(second.isEmpty)
        }
    }

    func testRestoredIndexRevalidatesAtTwelveHoursWithoutRebuildingOrDownloadingWhileFresh() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let clock = Mutex(now)
        let index = LiveTVGuideIndex(cache: fixture.cache, clock: { clock.withLock { $0 } })
        let channels = [channel("a")]
        let metadata = try httpMetadata()
        let initial = httpDocument(metadata)
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { initial }
        let before = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        let restored = LiveTVGuideIndex(cache: fixture.reopen(), clock: { clock.withLock { $0 } })
        clock.withLock { $0 = metadata.checkedAt.addingTimeInterval(43_199) }
        let fresh = try await restored.programs(from: url, catalog: channels, channels: channels, range: range) { _ in
            XCTFail("Navigation and restored instances must reuse fresh parsed rows")
            throw URLError(.badServerResponse)
        }
        XCTAssertEqual(fresh.map(\.title), ["Bulletin"])
        let checked = metadata.checkedAt.addingTimeInterval(43_200)
        clock.withLock { $0 = checked }
        let updated = try httpMetadata(headers: ["ETag": "\"v2\""], status: 304, previous: metadata, at: checked)
        let rows = try await restored.programs(from: url, catalog: channels, channels: channels, range: range) { prior in
            XCTAssertEqual(prior, metadata)
            return .notModified(updated)
        }
        let after = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        XCTAssertEqual(rows, fresh)
        XCTAssertEqual(before?.generation, after?.generation)
        XCTAssertEqual(after?.cacheMetadata, updated)
        XCTAssertEqual(after?.expiresAt, updated.expiresAt)
    }

    func testManualRefreshCanRevalidateFreshIndexAnd200ReplacesItsListingsAndValidators() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let time = now
        let index = LiveTVGuideIndex(cache: fixture.cache, clock: { time })
        let channels = [channel("a")]
        let metadata = try httpMetadata()
        let initial = httpDocument(metadata)
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { initial }
        await index.invalidate()
        let updated = httpDocument(try httpMetadata(headers: ["ETag": "\"v2\""]), title: "New bulletin")
        let rows = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { previous in
            XCTAssertEqual(previous, metadata)
            return .document(updated)
        }
        XCTAssertEqual(rows.map(\.title), ["New bulletin"])
        let state = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        XCTAssertEqual(state?.cacheMetadata?.etag, "\"v2\"")
    }

    func testIncompatibleProjectionOrWindowNeverSendsValidators() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let initial = httpDocument(try httpMetadata())
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { initial }
        let expanded = channels + [channel("b", guideID: "sport", name: "Sport")]
        let rows = try await index.programs(from: url, catalog: expanded, channels: expanded, range: range) { previous in
            XCTAssertNil(previous)
            return .document(initial)
        }
        XCTAssertEqual(Set(rows.map(\.title)), ["Bulletin", "Match"])
        let future = DateInterval(start: now.addingTimeInterval(8 * 86_400), duration: 400)
        _ = try await index.programs(from: url, catalog: expanded, channels: expanded, range: future) { previous in
            XCTAssertNil(previous)
            return .document(initial)
        }
    }

    func test304WithoutEligibleRepresentationFailsInsteadOfPublishingEmptySuccess() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let metadata = try httpMetadata(status: 304)
        do {
            _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { _ in
                .notModified(metadata)
            }
            XCTFail("304 cannot stand in for missing rows")
        } catch { XCTAssertEqual(error as? LiveTVSourceImportError, .invalidResponse) }
        let saved = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        XCTAssertNil(saved)
    }

    func test304NoStoreRevokesIndexBeforeUnconditionalReplacement() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let metadata = try httpMetadata()
        let initial = httpDocument(metadata)
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { initial }
        let noStore = try httpMetadata(headers: ["Cache-Control": "no-store"], status: 304, previous: metadata)
        let calls = Mutex(0)
        let cache = fixture.cache
        let url = url
        let rows = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { previous in
            let count = calls.withLock { $0 += 1; return $0 }
            if count == 1 {
                XCTAssertNotNil(previous)
                return .notModified(noStore)
            }
            XCTAssertNil(previous)
            let saved = try await cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
            XCTAssertNil(saved)
            return .document(initial)
        }
        XCTAssertEqual(rows.map(\.title), ["Bulletin"])
        XCTAssertEqual(calls.withLock { $0 }, 2)
    }

    func testFailedConditionalRequestPreservesSavedMetadataAndListingsButReportsFailure() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let metadata = try httpMetadata()
        let initial = httpDocument(metadata)
        let old = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { initial }
        let sourceID = LiveTVGuideIndex.sourceID(url)
        let saved = try await fixture.cache.guideIndexState(sourceID: sourceID, sourceURL: url)
        let state = try XCTUnwrap(saved)
        do {
            _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { previous in
                XCTAssertEqual(previous, metadata)
                throw URLError(.notConnectedToInternet)
            }
            XCTFail("Stale rows must not mask a failed refresh")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        let after = try await fixture.cache.guideIndexState(sourceID: sourceID, sourceURL: url)
        let retained = try await fixture.cache.indexedAccountPrograms(
            sourceID: sourceID, sourceURL: url, generation: state.generation, channels: channels, range: range
        )
        XCTAssertEqual(after?.cacheMetadata, metadata)
        XCTAssertEqual(after?.expiresAt, state.expiresAt)
        XCTAssertEqual(retained, old)
    }

    func testCancelled304NoStoreStillRevokesPersistence() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let metadata = try httpMetadata()
        let initial = httpDocument(metadata)
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { initial }
        let noStore = try httpMetadata(headers: ["Cache-Control": "no-store"], status: 304, previous: metadata)
        do {
            _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return .notModified(noStore)
            }
            XCTFail("Cancellation must not return stale success")
        } catch { XCTAssertTrue(error is CancellationError) }
        let state = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        XCTAssertNil(state)
    }

    func testDifferentBatchesReuseOneIndexAndRestoreAcrossInstances() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a"), channel("b", guideID: "sport", name: "Sport")]
        let download = DownloadCounter(response(document()))
        let first = try await index.programs(
            from: url, catalog: channels, channels: [channels[0]], range: range, download: { await download.get() }
        )
        let state = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        let reopened = LiveTVGuideIndex(cache: fixture.reopen())
        let second = try await reopened.programs(
            from: url, catalog: channels.reversed(), channels: [channels[1]], range: range,
            download: { await download.get() }
        )
        let current = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        XCTAssertEqual(first.map(\.title), ["Bulletin"])
        XCTAssertEqual(second.map(\.title), ["Match"])
        XCTAssertEqual(state?.generation, current?.generation)
        let count = await download.count
        XCTAssertEqual(count, 1)
    }

    func testMatchingAndAiringIdentityEqualLegacyForDifferentRequestSubsets() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a"), channel("b", name: "Different station"), channel("c", guideID: "sport", name: "Sport")]
        let data = document()
        let response = response(data)
        for requested in [[channels[0]], [channels[1]], Array(channels.prefix(2)), channels] {
            let actual = try await index.programs(
                from: url, catalog: channels, channels: requested, range: range, download: { response }
            )
            let expected = try LiveTVXMLTVParser().parseXML(data: data, channels: requested, now: now)
                .programs.filter { $0.start < range.end && $0.end > range.start }
            XCTAssertEqual(Set(actual.map(\.id)), Set(expected.map(\.id)))
            XCTAssertEqual(Set(actual.map(\.channelID)), Set(expected.map(\.channelID)))
        }
    }

    func testNameMatchingPriorityUsesRequestedSetNotFullCatalog() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("exact", guideID: "news.us"), channel("name", guideID: "NEWS.us")]
        let data = Data("""
        <tv><channel id="news.us"><display-name>News</display-name></channel>
        <programme channel="news.us" start="19700101000140" stop="19700101000820"><title>News</title></programme></tv>
        """.utf8)
        let response = response(data)
        for requested in [[channels[0]], [channels[1]], channels] {
            let actual = try await index.programs(
                from: url, catalog: channels, channels: requested, range: range, download: { response }
            )
            let expected = try LiveTVXMLTVParser().parseXML(data: data, channels: requested, now: now)
            XCTAssertEqual(Set(actual.map(\.id)), Set(expected.programs.map(\.id)))
        }

    }

    func testAccountQueryDoesNotTruncateAtUIWindowLimit() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = (0..<1_000).map { channel("variant-\($0)") }
        let programmes = (0..<25).map {
            "<programme channel=\"news\" start=\"19700101000140\" stop=\"19700101000820\"><title>Show \($0)</title></programme>"
        }.joined()
        let body = response(Data(("<tv>" + programmes + "</tv>").utf8))
        let rows = try await index.programs(
            from: url, catalog: channels, channels: channels, range: range, download: { body }
        )
        XCTAssertEqual(rows.count, 25_000)
        XCTAssertEqual(Set(rows.map(\.channelID)), Set(channels.map(\.id)))
    }

    func testLanguageChangeRebuildsLocalizedIndex() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let channels = [channel("a")]
        let body = response(Data("""
        <tv><programme channel="news" start="19700101000140" stop="19700101000820">
        <title lang="en">English</title><title lang="fr">French</title></programme></tv>
        """.utf8))
        let english = LiveTVGuideIndex(cache: fixture.cache, preferredLanguage: "en")
        let first = try await english.programs(from: url, catalog: channels, channels: channels, range: range, download: { body })
        let french = LiveTVGuideIndex(cache: fixture.reopen(), preferredLanguage: "fr")
        let second = try await french.programs(from: url, catalog: channels, channels: channels, range: range, download: { body })
        XCTAssertEqual(first.map(\.title), ["English"])
        XCTAssertEqual(second.map(\.title), ["French"])
    }

    func testValidEmptyGuideIsReusableWithoutInventingListings() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let download = DownloadCounter(response(Data("<tv/>".utf8)))
        for _ in 0..<2 {
            let rows = try await index.programs(
                from: url, catalog: channels, channels: channels, range: range, download: { await download.get() }
            )
            XCTAssertTrue(rows.isEmpty)
        }
        let count = await download.count
        XCTAssertEqual(count, 1)
    }

    func testPreviousParserEmptyIndexIsRebuiltForShortenedDates() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let channels = [channel("a")]
        let data = Data("""
        <tv><programme channel="news" start="19700101" stop="1970010101"><title>Recovered listing</title></programme></tv>
        """.utf8)
        // Reproduce the pre-versioned projection and an empty, unexpired index
        // left by the old parser after it skipped these valid timestamps.
        var legacy = SHA256()
        legacy.update(data: try JSONEncoder().encode(["account-xmltv-stations-v1", nil] as [String?]))
        for channel in channels {
            legacy.update(data: try JSONEncoder().encode(
                [channel.id, channel.name, channel.guideID, channel.guideName, channel.country]
            ))
        }
        func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
        let oldState = LiveTVGuideIndexState(
            generation: UUID(), projection: hex(legacy.finalize()), digest: hex(SHA256.hash(data: data)),
            lowerBound: .distantPast, upperBound: .distantFuture, expiresAt: .distantFuture
        )
        _ = try await fixture.cache.importGuide(
            data: Data("<tv/>".utf8), sourceID: LiveTVGuideIndex.sourceID(url), channels: channels,
            provider: nil, now: now, sourceURL: url, preferredLanguage: nil, indexState: oldState
        )
        let index = LiveTVGuideIndex(cache: fixture.reopen(), preferredLanguage: nil)
        let download = DownloadCounter(response(data))
        let programs = try await index.programs(
            from: url, catalog: channels, channels: channels, range: range, download: { await download.get() }
        )
        XCTAssertEqual(programs.map(\.title), ["Recovered listing"])
        XCTAssertEqual(programs.first?.start, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(programs.first?.end, Date(timeIntervalSince1970: 3_600))
        let count = await download.count
        XCTAssertEqual(count, 1)
    }

    func testIndexedQueryEnforcesLanguageEpisodeAndRatingTextBudget() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = (0..<1_000).map { channel("variant-\($0)") }
        let text = String(repeating: "x", count: 16_384)
        let data = Data("""
        <tv><programme channel="news" start="19700101000140" stop="19700101000820">
        <title>News</title><language>\(text)</language><episode-num>\(text)</episode-num>
        <rating><value>\(text)</value></rating></programme></tv>
        """.utf8)
        let body = response(data)
        do {
            _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range, download: { body })
            XCTFail("All retained programme text must count toward the output budget.")
        } catch { XCTAssertEqual(error as? LiveTVSourceImportError, .guideTooLarge) }
    }

    func testQueuedDifferentSourceCanCancelWithoutWaitingForCurrentImport() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let url = url
        let otherURL = try XCTUnwrap(URL(string: "https://fixture.test/other.xml"))
        let range = range
        let download = HeldDownload(response(document()))
        let first = Task { try await index.programs(
            from: url, catalog: channels, channels: channels, range: range, download: { try await download.get() }
        ) }
        await download.waitUntilStarted()
        let second = Task { try await index.programs(
            from: otherURL, catalog: channels, channels: channels, range: range, download: { try await download.get() }
        ) }
        await index.waitForAdmissionForTesting()
        second.cancel()
        do { _ = try await second.value; XCTFail("Queued consumer must cancel promptly.") }
        catch { XCTAssertTrue(error is CancellationError) }
        await download.release()
        let rows = try await first.value
        XCTAssertEqual(rows.map(\.title), ["Bulletin"])
        let count = await download.count
        XCTAssertEqual(count, 1)
    }

    func testExpiredUnchangedBodyRevalidatesWithoutReplacingGeneration() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let download = DownloadCounter(response(document(), expires: .distantPast))
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range, download: { await download.get() })
        let first = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range, download: { await download.get() })
        let second = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        let count = await download.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(first?.generation, second?.generation)
    }

    func testFailedReplacementKeepsCommittedRowsAndDoesNotAdvanceFreshness() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let initial = response(document(), expires: .distantPast)
        let old = try await index.programs(from: url, catalog: channels, channels: channels, range: range, download: { initial })
        let sourceID = LiveTVGuideIndex.sourceID(url)
        let saved = try await fixture.cache.guideIndexState(sourceID: sourceID, sourceURL: url)
        let state = try XCTUnwrap(saved)
        let invalid = response(Data("<tv><programme".utf8))
        do {
            _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range, download: { invalid })
            XCTFail("Malformed replacement must fail.")
        } catch { XCTAssertEqual(error as? LiveTVSourceImportError, .invalidGuide) }
        let current = try await fixture.cache.guideIndexState(sourceID: sourceID, sourceURL: url)
        let retained = try await fixture.cache.indexedAccountPrograms(
            sourceID: sourceID, sourceURL: url, generation: state.generation, channels: channels, range: range
        )
        XCTAssertEqual(state.generation, current?.generation)
        XCTAssertEqual(state.expiresAt, current?.expiresAt)
        XCTAssertEqual(retained, old)
    }

    func testNoStoreRevokesPersistedRowsEvenWhenReplacementIsMalformed() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let initial = response(document(), expires: .distantPast)
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range, download: { initial })
        let invalid = response(Data("<tv>".utf8), persists: false)
        do {
            _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range, download: { invalid })
            XCTFail("Invalid no-store body must fail.")
        } catch { XCTAssertEqual(error as? LiveTVSourceImportError, .invalidGuide) }
        let state = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        XCTAssertNil(state)
    }

    func testNoStoreNeverCreatesAnIndexAndUsesRequestedChannelsOnly() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a"), channel("b", name: "Different station")]
        let download = DownloadCounter(response(document(), persists: false))
        for requested in channels {
            let rows = try await index.programs(
                from: url, catalog: channels, channels: [requested], range: range, download: { await download.get() }
            )
            XCTAssertEqual(rows.map(\.channelID), [requested.id])
        }
        let state = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        let count = await download.count
        XCTAssertNil(state)
        XCTAssertEqual(count, 2)
    }

    func testManualInvalidationBypassesFreshnessAndTeardownRejectsAdmission() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let initial = response(document())
        _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range, download: { initial })
        await index.invalidate()
        let updated = response(document(title: "Updated"))
        let rows = try await index.programs(from: url, catalog: channels, channels: channels, range: range, download: { updated })
        XCTAssertEqual(rows.map(\.title), ["Updated"])
        await index.cancel()
        do {
            _ = try await index.programs(from: url, catalog: channels, channels: channels, range: range, download: { initial })
            XCTFail("Closed index must reject work.")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testProjectionAndRetentionChangesRebuildInsteadOfReturningFalseEmptyCoverage() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let firstChannels = [channel("a")]
        let expanded = firstChannels + [channel("b", guideID: "sport", name: "Sport")]
        let download = DownloadCounter(response(document()))
        _ = try await index.programs(from: url, catalog: firstChannels, channels: firstChannels, range: range, download: { await download.get() })
        let before = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        let rows = try await index.programs(from: url, catalog: expanded, channels: [expanded[1]], range: range, download: { await download.get() })
        let changed = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        XCTAssertEqual(rows.map(\.title), ["Match"])
        XCTAssertNotEqual(before?.generation, changed?.generation)
        let future = DateInterval(start: now.addingTimeInterval(8 * 86_400), duration: 400)
        _ = try await index.programs(from: url, catalog: expanded, channels: expanded, range: future, download: { await download.get() })
        let after = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        XCTAssertNotEqual(changed?.generation, after?.generation)
        let count = await download.count
        XCTAssertEqual(count, 3)
    }

    func testCancellingOneWaiterDoesNotCancelAnotherConsumersImport() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let url = url
        let range = range
        let download = HeldDownload(response(document()))
        let first = Task { try await index.programs(
            from: url, catalog: channels, channels: channels, range: range, download: { try await download.get() }
        ) }
        await download.waitUntilStarted()
        let second = Task { try await index.programs(
            from: url, catalog: channels, channels: channels, range: range, download: { try await download.get() }
        ) }
        await index.waitForWaitersForTesting(2)
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled waiter must fail promptly.") }
        catch { XCTAssertTrue(error is CancellationError) }
        await download.release()
        let rows = try await second.value
        XCTAssertEqual(rows.map(\.title), ["Bulletin"])
        let count = await download.count
        XCTAssertEqual(count, 1)
    }

    func testInvalidationCancelsAndDrainsInFlightImport() async throws {
        let fixture = try CacheFixture()
        defer { fixture.removeOwnedFiles() }
        let index = LiveTVGuideIndex(cache: fixture.cache)
        let channels = [channel("a")]
        let url = url
        let range = range
        let started = expectation(description: "Download began")
        let task = Task { try await index.programs(
            from: url, catalog: channels, channels: channels, range: range,
            download: {
                started.fulfill()
                try await Task.sleep(for: .seconds(60))
                throw CancellationError()
            }
        ) }
        await fulfillment(of: [started], timeout: 2)
        await index.invalidate()
        do { _ = try await task.value; XCTFail("Invalidated worker must not publish.") }
        catch { XCTAssertTrue(error is CancellationError) }
        let state = try await fixture.cache.guideIndexState(sourceID: LiveTVGuideIndex.sourceID(url), sourceURL: url)
        XCTAssertNil(state)
    }
}

private actor DownloadCounter {
    var count = 0
    let response: XMLTVDownloadedDocument
    init(_ response: XMLTVDownloadedDocument) { self.response = response }
    func get() -> XMLTVDownloadedDocument { count += 1; return response }
}

private actor HeldDownload {
    var count = 0
    let response: XMLTVDownloadedDocument
    var started: CheckedContinuation<Void, Never>?
    var releaseContinuation: CheckedContinuation<Void, Never>?
    init(_ response: XMLTVDownloadedDocument) { self.response = response }
    func get() async throws -> XMLTVDownloadedDocument {
        count += 1
        started?.resume()
        started = nil
        await withCheckedContinuation { releaseContinuation = $0 }
        try Task.checkCancellation()
        return response
    }
    func waitUntilStarted() async {
        if count == 0 { await withCheckedContinuation { started = $0 } }
    }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }
}
