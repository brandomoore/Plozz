import CoreModels
import Darwin
import FeatureLiveTVCore
import Foundation
@testable import ProviderIPTV
import XCTest

@MainActor
final class IPTVPerformanceProbeTests: XCTestCase {
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
        let downloaded = try JSONDecoder().decode(Source.self, from: Data(contentsOf: control))
        XCTAssertEqual(counts.entries + counts.skipped, downloaded.entries)
        XCTAssertEqual(counts.requests, 1, "The full import must use one playlist response.")
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
            print("IPTV_PROBE entries=\(counts.entries) import_seconds=\(imported.timeIntervalSince(started)) library_seconds=\(discovered.timeIntervalSince(imported)) libraries=\(libraries.count) titles=\(totalTitles) live=\(channels.count) peak_bytes=\(usage.ru_maxrss)")
        } catch {
            await provider.teardown()
            throw error
        }
        await provider.teardown()
    }

    private struct Source: Decodable {
        let url: String
        let entries: Int
    }

    private final class ProbeCounts: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var lastDiagnostic: IPTVSetupDiagnostic?
        var entries: Int { lock.withLock { count } }
        var skipped: Int { lock.withLock { lastDiagnostic?.skippedEntries ?? 0 } }
        var requests: Int { lock.withLock { lastDiagnostic?.requestCount ?? 0 } }
        func diagnostic(_ value: IPTVSetupDiagnostic) { lock.withLock { lastDiagnostic = value } }
        func record(_ progress: IPTVImportProgress) {
            guard progress.stage == .playlist else { return }
            lock.withLock { count = progress.entries }
        }
    }
}
