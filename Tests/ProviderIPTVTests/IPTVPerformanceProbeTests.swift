import CoreModels
import CoreNetworking
import CryptoKit
import Darwin
@testable import FeatureLiveTVCore
import Foundation
@testable import ProviderIPTV
@testable import TestSupportPerformance
import XCTest

@MainActor
final class IPTVPerformanceProbeTests: XCTestCase {
    private final class GuidePerformanceSecureStore: SecureStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        func string(for key: String) -> String? { lock.withLock { values[key] } }
        func readString(for key: String) throws -> String? { string(for: key) }
        func setString(_ value: String, for key: String) throws { lock.withLock { values[key] = value } }
        func removeValue(for key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
    }

    func testPerformanceLargeGuideBatches() async throws {
        try PerformanceProbe.requireEnabled()
        let channelCount = 6_000
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        let times = (0...8).map { formatter.string(from: now.addingTimeInterval(Double($0) * 3_600)) }
        let description = String(repeating: "Generated guide description. ", count: 12)
        var body = Data("<tv>".utf8)
        for channel in 0..<channelCount {
            body.append(Data("<channel id=\"c\(channel)\"><display-name>Channel \(channel)</display-name></channel>".utf8))
        }
        for channel in 0..<channelCount {
            for hour in 0..<8 {
                body.append(Data("""
                <programme channel="c\(channel)" start="\(times[hour])" stop="\(times[hour + 1])">\
                <title>Programme \(channel)-\(hour)</title><desc>\(description)</desc></programme>
                """.utf8))
            }
        }
        body.append(Data("</tv>".utf8))
        let payload = body
        XCTAssertGreaterThan(payload.count, 16 * 1_024 * 1_024)
        let batches = (0..<2).map { batch in
            (batch * 2_000..<(batch + 1) * 2_000).map { channel in
                LiveTVPrototypeChannel(
                    id: "channel-\(channel)", number: channel, name: "Channel \(channel)",
                    category: "Live TV", symbol: "tv", accent: 0, source: .iptv, tagline: "",
                    guideID: "c\(channel)"
                )
            }
        }
        let catalog = (0..<channelCount).map { channel in
            LiveTVPrototypeChannel(
                id: "channel-\(channel)", number: channel, name: "Channel \(channel)",
                category: "Live TV", symbol: "tv", accent: 0, source: .iptv, tagline: "",
                guideID: "c\(channel)"
            )
        }
        try await PerformanceProbe.measure(self, scenario: "guide-large-batches") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                do { try FileManager.default.removeItem(at: root) }
                catch { XCTFail("Could not remove the owned guide fixture.") }
            }
            let server = try IPTVTestHTTPServer { _ in
                .init(data: payload, headers: ["Cache-Control": "max-age=60"])
            }
            let base: URL
            do { base = try await server.start() }
            catch { await server.stop(); throw error }
            let client: IPTVClient
            do {
                client = try IPTVClient(
                    credential: IPTVCredential(mode: .playlist, address: base.appendingPathComponent("playlist.m3u")),
                    directory: root
                )
            } catch { await server.stop(); throw error }
            do {
                let cache = LiveTVIndexedCache(
                    url: root.appendingPathComponent("guide.sqlite"), namespace: "performance",
                    authorizationScope: "fixture", secureStore: GuidePerformanceSecureStore()
                )
                let index = LiveTVGuideIndex(cache: cache)
                let guideURL = base.appendingPathComponent("guide.xml")
                var rows = 0
                var generations = Set<UUID>()
                var batchNanoseconds: [Int] = []
                for channels in batches {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let programs = try await index.programs(
                        from: guideURL, catalog: catalog, channels: channels,
                        range: DateInterval(start: now, duration: 8 * 3_600),
                        download: { try await client.guideDocument(from: guideURL) }
                    )
                    batchNanoseconds.append(Int(DispatchTime.now().uptimeNanoseconds - start))
                    XCTAssertEqual(programs.count, 16_000)
                    XCTAssertEqual(Set(programs.map(\.channelID)), Set(channels.map(\.id)))
                    let state = try await cache.guideIndexState(
                        sourceID: LiveTVGuideIndex.sourceID(guideURL), sourceURL: guideURL
                    )
                    generations.insert(try XCTUnwrap(state).generation)
                    rows += programs.count
                }
                let requests = await server.requestCount
                XCTAssertEqual(generations.count, 1)
                XCTAssertEqual(requests, 1)
                await index.cancel()
                await client.cancel()
                await server.stop()
                return [
                    "guideBytes": payload.count, "httpRequests": requests,
                    "downloadedBytes": requests * payload.count, "parseInvocations": generations.count,
                    "retainedRows": rows, "requestedChannels": batches.reduce(0) { $0 + $1.count },
                    "coldBatchNanoseconds": batchNanoseconds[0], "warmBatchNanoseconds": batchNanoseconds[1],
                    "indexedChannels": catalog.count
                ]
            } catch {
                await client.cancel()
                await server.stop()
                throw error
            }

        }
    }

    func testPerformanceCachedPlaylistRefresh() async throws {
        try PerformanceProbe.requireEnabled()
        let count = 1_000
        func playlist(_ prefix: String) -> Data {
            Data(("#EXTM3U\n" + (0..<count).map {
                "#EXTINF:-1,\(prefix) \($0)\nhttps://fixture.invalid/\(prefix)/\($0).ts\n"
            }.joined()).utf8)
        }
        let savedBody = playlist("Saved")
        let updatedBody = playlist("Updated")
        let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/iptv-performance-fixtures")
        try await PerformanceProbe.measure(self, scenario: "catalog-cached-refresh") {
            let root = fixtureRoot.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                do { try FileManager.default.removeItem(at: root) }
                catch { XCTFail("Could not remove the owned cached-refresh fixture.") }
            }
            let started = self.expectation(description: "Expired playlist response is held")
            let readable = self.expectation(description: "Cached reads complete before releasing the response")
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let requests = RefreshRequestCounter()
            let server = try IPTVTestHTTPServer { _ in
                let request = requests.next()
                if request == 1 {
                    return .init(data: savedBody, headerDelay: .milliseconds(100))
                }
                if request == 2 {
                    started.fulfill()
                    guard release.wait(timeout: .now() + 5) == .success else {
                        return .init(status: 500)
                    }
                }
                return .init(data: updatedBody)
            }
            let base: URL
            do { base = try await server.start() }
            catch { await server.stop(); throw error }
            let credential: IPTVCredential
            let client: IPTVClient
            do {
                credential = try IPTVCredential(
                    mode: .playlist, address: base.appendingPathComponent("playlist.m3u"),
                    discoversPlaylistGuides: false
                )
                client = try IPTVClient(credential: credential, directory: root)
            } catch {
                await server.stop()
                throw error
            }
            do {
                let coldStart = DispatchTime.now().uptimeNanoseconds
                let cold = try await client.liveChannels()
                let coldNanoseconds = DispatchTime.now().uptimeNanoseconds - coldStart
                XCTAssertEqual(cold.count, count)
                XCTAssertTrue(cold.allSatisfy { $0.name.hasPrefix("Saved ") })
                do {
                    let catalog = try IPTVCatalog(
                        url: root.appendingPathComponent(credential.identity.uuidString + ".sqlite"),
                        key: credential.catalogKey
                    )
                    try catalog.setState(
                        "playlist-v5", String(Date().addingTimeInterval(-3_600).timeIntervalSince1970)
                    )
                }
                let foreground = Task { @MainActor in
                    let start = DispatchTime.now().uptimeNanoseconds
                    for _ in 0..<3 {
                        let channels = try await client.liveChannels()
                        XCTAssertEqual(channels.count, count)
                        XCTAssertTrue(channels.allSatisfy { $0.name.hasPrefix("Saved ") })
                    }
                    let elapsed = DispatchTime.now().uptimeNanoseconds - start
                    readable.fulfill()
                    return elapsed
                }
                await self.fulfillment(of: [started, readable], timeout: 3)
                release.signal()
                let cachedNanoseconds = try await foreground.value
                let deadline = ContinuousClock.now + .seconds(5)
                var replacement: [ServerLiveTVChannel] = []
                repeat {
                    replacement = try await client.liveChannels()
                    if replacement.count == count,
                       replacement.allSatisfy({ $0.name.hasPrefix("Updated ") }) { break }
                    try await Task.sleep(for: .milliseconds(10))
                } while ContinuousClock.now < deadline
                XCTAssertEqual(replacement.count, count)
                XCTAssertTrue(replacement.allSatisfy { $0.name.hasPrefix("Updated ") })
                XCTAssertNotEqual(replacement.map(\.id), cold.map(\.id))
                let requestCount = await server.requestCount
                XCTAssertEqual(requestCount, 2, "One cold import and exactly one shared background refresh.")
                await client.cancel()
                await server.stop()
                return [
                    "channels": count, "cachedReads": 3, "replacementChannels": replacement.count,
                    "httpRequests": requestCount, "refreshRequests": requestCount - 1,
                    "coldForegroundNanoseconds": Int(coldNanoseconds),
                    "cachedForegroundNanoseconds": Int(cachedNanoseconds)
                ]
            } catch {
                release.signal()
                await client.cancel()
                await server.stop()
                throw error
            }
        }
    }

    private final class RefreshRequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func next() -> Int {
            lock.withLock { count += 1; return count }
        }
    }

    func testPerformanceCatalogImport() async throws {
        try PerformanceProbe.requireEnabled()
        let records = (0..<10_000).map { index in
            IPTVRecord(
                item: MediaItem(id: "movie:\(index)", title: "Movie \(index)", kind: .movie, libraryID: "movies"),
                streamURL: URL(string: "https://fixture.invalid/movie/\(index)")
            )
        }
        try await PerformanceProbe.measure(self, scenario: "catalog-import") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {
                do { try FileManager.default.removeItem(at: root) }
                catch { XCTFail("Could not remove the owned performance catalogue: \(error)") }
            }
            let catalog = try IPTVCatalog(url: root.appendingPathComponent("catalog.sqlite"), key: Data(repeating: 7, count: 32))
            try catalog.beginImport()
            defer { catalog.discardImport() }
            for record in records { try catalog.insert(record, into: .incoming) }
            try catalog.commitImport(library: nil, scope: "playlist")
            let count = try catalog.count(where: "1 = 1")
            XCTAssertEqual(count, records.count)
            XCTAssertEqual(try catalog.record("movie:9999").item.title, "Movie 9999")
            return ["records": count]
        }
    }

    func testOptInXtreamImportAndLibraryDiscovery() async throws {
        let control = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/iptv-xtream-performance-source.json")
        guard FileManager.default.fileExists(atPath: control.path) else {
            throw XCTSkip("Opt-in local Xtream relay required; ordinary tests never contact a trial provider.")
        }
        let sources = try JSONDecoder().decode([XtreamSource].self, from: Data(contentsOf: control))
        XCTAssertFalse(sources.isEmpty)
        for source in sources {
            let url = try XCTUnwrap(URL(string: source.url))
            guard url.host == "127.0.0.1" else {
                XCTFail("Only an explicitly owned local relay is permitted.")
                continue
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {
                do { try FileManager.default.removeItem(at: root) }
                catch { XCTFail("Could not remove the owned Xtream probe catalogue.") }
            }
            let credential = try IPTVCredential(
                mode: .xtream, address: url, username: "fixture", password: "fixture"
            )
            let diagnostics = IPTVSetupDiagnostics()
            let counts = ProbeCounts()
            diagnostics.start { value in
                counts.diagnostic(value)
                print("IPTV_XTREAM_STAGE source=\(source.source) stage=\(value.stage.rawValue) outcome=\(value.outcome.rawValue) entries=\(value.entries ?? 0) elapsed_ms=\(value.elapsedMilliseconds) requests=\(value.requestCount)")
            }
            defer { diagnostics.stop() }
            let attempt = try XCTUnwrap(diagnostics.begin(source: .xtream, authentication: .xtream, entry: .addAccount))
            let started = Date()
            do {
                let session = try await IPTVSetupDiagnostics.$current.withValue(attempt) {
                    try await IPTVProvider.signIn(
                        credential: credential, name: "Xtream probe", deviceID: "probe", cacheDirectory: root
                    )
                }
                attempt.finish()
                XCTAssertEqual(counts.requests, 7, "Authentication and each catalogue/category list are fetched once.")
                let imported = Date()
                let provider = try IPTVProvider(
                    context: .init(
                        session: session, accountID: "probe", credentialRevision: .init(),
                        localMediaContext: .init(accountID: "probe", profileID: "probe", profileNamespace: nil)
                    ),
                    cacheDirectory: root
                )
                do {
                    let libraries = try await provider.libraries()
                    let discoverySeconds = Date().timeIntervalSince(imported)
                    XCTAssertLessThan(discoverySeconds, 2, "Discovery must reuse the imported catalogue.")
                    XCTAssertEqual(
                        Set(libraries.map(\.id)),
                        Set(source.counts.filter { $0.key != "live" && $0.value > 0 }.keys)
                    )
                    for library in libraries {
                        let page = try await provider.items(in: library.id, kind: library.kind, page: .init(limit: 1))
                        if let expected = source.counts[library.id] { XCTAssertEqual(page.totalCount, expected) }
                        print("IPTV_XTREAM_LIBRARY source=\(source.source) kind=\(library.id) count=\(page.totalCount)")
                    }
                    let channels = try await provider.liveTVChannels()
                    if let expected = source.counts["live"] { XCTAssertEqual(channels.count, expected) }
                    var usage = rusage()
                    XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
                    print("IPTV_XTREAM_PROBE source=\(source.source) import_seconds=\(imported.timeIntervalSince(started)) library_seconds=\(discoverySeconds) live=\(channels.count) peak_bytes=\(usage.ru_maxrss)")
                } catch {
                    await provider.teardown()
                    throw error
                }
                await provider.teardown()
                let catalog = try IPTVCatalog(
                    url: root.appendingPathComponent(credential.identity.uuidString + ".sqlite"),
                    key: credential.catalogKey
                )
                var lastID = ""
                var restored = 0
                while true {
                    let page = try catalog.records(where: "id > ?", values: [lastID], order: "id", limit: 2_000)
                    guard let last = page.last else { break }
                    for record in page {
                        XCTAssertFalse(record.item.title.isEmpty)
                        XCTAssertNotNil(record.streamID)
                    }
                    restored += page.count
                    lastID = last.item.id
                }
                XCTAssertEqual(restored, source.counts.values.reduce(0, +))
                print("IPTV_XTREAM_REOPEN source=\(source.source) records=\(restored)")
            } catch {
                let failure = (error as? IPTVError)?.setupFailure ?? .sanitized(error)
                attempt.finish(failure)
                XCTFail("Xtream source \(source.source) failed: \(failure.reason.rawValue)")
            }
        }
    }

    private struct XtreamSource: Decodable, Sendable {
        let source: Int
        let url: String
        let counts: [String: Int]
    }

    func testOptInCatalogWritePerformance() throws {
        let marker = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/iptv-catalog-benchmark.enabled")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw XCTSkip("An explicitly enabled local catalogue benchmark is required.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Could not remove the owned benchmark catalogue.") }
        }
        let url = root.appendingPathComponent("catalog.sqlite")
        let catalog = try IPTVCatalog(url: url, key: Data(repeating: 7, count: 32))
        try catalog.beginImport()
        defer { catalog.discardImport() }
        let started = Date()
        for index in 0..<100_000 {
            let series = "Series \(index / 40)"
            let record = IPTVRecord(
                item: MediaItem(
                    id: "episode:\(index)", title: "\(series) S01 E\(index % 40 + 1)", kind: .episode,
                    parentTitle: series, seasonNumber: 1, episodeNumber: index % 40 + 1,
                    seriesID: "series:\(index / 40)", seasonID: "season:\(index / 40):1",
                    seriesPosterURL: URL(string: "https://provider.test/artwork/\(index / 40).jpg"),
                    libraryID: "series"
                ),
                parentID: "season:\(index / 40):1",
                streamURL: URL(string: "https://provider.test/series/fixture/\(index)")
            )
            try catalog.insert(record, into: .incoming)
        }
        let staged = Date()
        try catalog.commitImport(library: nil, scope: "playlist")
        let committed = Date()
        XCTAssertEqual(try catalog.count(where: "1 = 1"), 100_000)
        XCTAssertEqual(try catalog.record("episode:99999").item.title, "Series 2499 S01 E40")
        let bytes = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.fileSizeKey]
        ).reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        print("IPTV_CATALOG_BENCHMARK records=100000 staging_seconds=\(staged.timeIntervalSince(started)) commit_seconds=\(committed.timeIntervalSince(staged)) files_bytes=\(bytes)")
    }

    func testOptInPlaylistImportAndLibraryDiscovery() async throws {
        let control = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/iptv-performance-source.json")
        guard FileManager.default.fileExists(atPath: control.path) else {
            throw XCTSkip("Opt-in local relay required; ordinary tests never contact a trial provider.")
        }
        let source = try JSONDecoder().decode(Source.self, from: Data(contentsOf: control))
        let url = try XCTUnwrap(URL(string: source.url))
        XCTAssertEqual(url.host, "127.0.0.1", "Only an explicitly owned local relay is permitted.")
        guard url.host == "127.0.0.1" else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Could not remove the owned probe catalogue.") }
        }
        let credential = try IPTVCredential(mode: .playlist, address: url, discoversPlaylistGuides: false)
        let started = Date()
        let counts = ProbeCounts()
        let diagnostics = IPTVSetupDiagnostics()
        diagnostics.start { counts.diagnostic($0) }
        let attempt = try XCTUnwrap(diagnostics.begin(source: .playlistURL, authentication: .none, entry: .addAccount))
        let session = try await IPTVSetupDiagnostics.$current.withValue(attempt) {
            try await IPTVProvider.signIn(
                credential: credential, name: "Performance probe", deviceID: "probe", cacheDirectory: root,
                progress: { counts.record($0) }
            )
        }
        attempt.finish()
        let imported = Date()
        counts.finished()
        let downloaded = try JSONDecoder().decode(Source.self, from: Data(contentsOf: control))
        XCTAssertEqual(counts.entries + counts.skipped, downloaded.entries)
        XCTAssertEqual(counts.requests, 1, "The full import must use one playlist response.")
        let readingSeconds = try XCTUnwrap(counts.readingSeconds)
        let commitSeconds = try XCTUnwrap(counts.commitSeconds)
        XCTAssertGreaterThan(readingSeconds, 0)
        XCTAssertGreaterThan(commitSeconds, 0)
        let provider = try IPTVProvider(
            context: .init(session: session, accountID: "probe", credentialRevision: .init(),
                           localMediaContext: .init(accountID: "probe", profileID: "probe", profileNamespace: nil)),
            cacheDirectory: root
        )
        do {
            let libraries = try await provider.libraries()
            let discovered = Date()
            XCTAssertLessThan(discovered.timeIntervalSince(imported), 2, "Library discovery must read the imported catalogue.")
            var totalTitles = 0
            for library in libraries {
                totalTitles += try await provider.items(in: library.id, kind: library.kind, page: .init(limit: 1)).totalCount
            }
            let channels = try await provider.liveTVChannels()
            var configuration = LiveTVSourcesConfiguration()
            configuration.servers = [.init(id: "probe", name: "Probe", accountID: "probe")]
            let imports = LiveTVPrototypeImportModel(configuration: configuration, serverProviderResolver: { _ in
                .init(accountID: "probe", authorizationID: "probe", kind: .iptv, provider: provider)
            })
            let model = LiveTVPrototypeModel(channels: [])
            await imports.reload(into: model, forceServerRefresh: false)
            XCTAssertEqual(model.channels.count, channels.count)
            XCTAssertNil(imports.serverSources.first?.failure)
            var usage = rusage()
            XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
            print("IPTV_PROBE entries=\(counts.entries) import_seconds=\(imported.timeIntervalSince(started)) reading_seconds=\(readingSeconds) commit_seconds=\(commitSeconds) library_seconds=\(discovered.timeIntervalSince(imported)) libraries=\(libraries.count) titles=\(totalTitles) live=\(channels.count) peak_bytes=\(usage.ru_maxrss)")
        } catch {
            await provider.teardown()
            throw error
        }
        await provider.teardown()
        if source.verifyRecords == true || source.expectedRecordDigest != nil {
            let catalog = try IPTVCatalog(
                url: root.appendingPathComponent(credential.identity.uuidString + ".sqlite"),
                key: credential.catalogKey
            )
            var hash = SHA256()
            var lastID = ""
            var records = 0
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            while true {
                let page = try catalog.records(where: "id > ?", values: [lastID], order: "id", limit: 2_000)
                guard let last = page.last else { break }
                for record in page { hash.update(data: try encoder.encode(record)) }
                records += page.count
                lastID = last.item.id
            }
            XCTAssertEqual(records, try catalog.count(where: "1 = 1"))
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            if let expected = source.expectedRecordDigest { XCTAssertEqual(digest, expected) }
            print("IPTV_PROBE_RECORDS count=\(records) sha256=\(digest)")
        }
    }

    private struct Source: Decodable {
        let url: String
        let entries: Int
        let verifyRecords: Bool?
        let expectedRecordDigest: String?
    }

    private final class ProbeCounts: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var lastDiagnostic: IPTVSetupDiagnostic?
        private var readingStarted: TimeInterval?
        private var commitStarted: TimeInterval?
        private var completedAt: TimeInterval?
        var entries: Int { lock.withLock { count } }
        var skipped: Int { lock.withLock { lastDiagnostic?.skippedEntries ?? 0 } }
        var requests: Int { lock.withLock { lastDiagnostic?.requestCount ?? 0 } }
        var readingSeconds: TimeInterval? {
            lock.withLock {
                guard let commitStarted, let readingStarted else { return nil }
                return commitStarted - readingStarted
            }
        }
        var commitSeconds: TimeInterval? {
            lock.withLock {
                guard let completedAt, let commitStarted else { return nil }
                return completedAt - commitStarted
            }
        }
        func diagnostic(_ value: IPTVSetupDiagnostic) { lock.withLock { lastDiagnostic = value } }
        func finished() { lock.withLock { completedAt = ProcessInfo.processInfo.systemUptime } }
        func record(_ progress: IPTVImportProgress) {
            lock.withLock {
                let now = ProcessInfo.processInfo.systemUptime
                if progress.stage == .playlist {
                    if readingStarted == nil { readingStarted = now }
                    count = progress.entries
                } else if progress.stage == .catalogCommit {
                    if commitStarted == nil { commitStarted = now }
                }
            }
        }
    }
}
