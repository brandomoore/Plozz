import CoreModels
import CoreNetworking
import Darwin
import Foundation
import XCTest
@testable import ProviderIPTV

final class IPTVScaleAndRecoveryTests: XCTestCase {
    func testEightHundredThousandEntryHTTPImportPersistsAndReopensWithoutDownloadingAgain() async throws {
        let total = 800_005
        let live = 2_000
        let clock = ContinuousClock.now
        let report: @Sendable (String) -> Void = { message in
            do {
                try FileHandle.standardOutput.write(contentsOf: Data(
                    "IPTV scale fixture [\(clock.duration(to: .now))]: \(message)\n".utf8
                ))
            } catch {
                XCTFail("Could not record IPTV scale progress: \(error)")
            }
        }
        report("Preparing \(total) playlist entries")
        let root = try temporaryDirectory()
        let playlist = root.appendingPathComponent("large.m3u")
        XCTAssertTrue(FileManager.default.createFile(atPath: playlist.path, contents: nil))
        let file = try FileHandle(forWritingTo: playlist)
        defer { XCTAssertNoThrow(try file.close()) }
        try file.write(contentsOf: Data("#EXTM3U\n".utf8))
        for start in stride(from: 0, to: total, by: 1_000) {
            var data = Data()
            for index in start..<min(total, start + 1_000) {
                let line = index < live
                    ? "#EXTINF:-1 group-title=\"News\",Channel \(index)\nlive/\(index).ts\n"
                    : "#EXTINF:120 group-title=\"Movies\",Movie \(index)\nmovie/\(index).mp4\n"
                data.append(contentsOf: line.utf8)
            }
            try file.write(contentsOf: data)
        }
        try file.synchronize()
        let inputBytes = try XCTUnwrap(playlist.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        report("Prepared \(inputBytes) playlist bytes; starting HTTP import")
        let server = try IPTVTestHTTPServer { _ in
            .init(file: playlist, headers: ["Content-Type": "audio/x-mpegurl"])
        }
        addTeardownBlock { await server.stop() }
        let base = try await server.start()
        let credential = try IPTVCredential(mode: .playlist, address: base.appendingPathComponent("large.m3u"))
        var before = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &before), 0)
        let started = Date()
        let session = try await IPTVProvider.signIn(
            credential: credential, name: "Scale fixture", deviceID: "fixture",
            cacheDirectory: root.appendingPathComponent("catalog"),
            progress: { progress in
                guard progress.entries.isMultiple(of: 10_000) || progress.entries == total else { return }
                switch progress.stage {
                case .playlist:
                    report("Staged \(progress.entries) of \(total) playlist entries")
                case .catalogCommit:
                    report("Copied \(progress.entries) of \(total) entries into the replacement transaction")
                default:
                    XCTFail("Unexpected stage for the playlist scale fixture")
                }
            }
        )
        report("Committed imported catalog; checking channels and pagination")
        let context = ProviderResolutionContext(
            session: try JSONDecoder().decode(UserSession.self, from: JSONEncoder().encode(session)),
            accountID: "scale", credentialRevision: .init(),
            localMediaContext: .init(accountID: "scale", profileID: "fixture", profileNamespace: nil)
        )
        let provider = try IPTVProvider(context: context, cacheDirectory: root.appendingPathComponent("catalog"))
        addTeardownBlock { await provider.teardown() }
        let channels = try await provider.liveTVChannels()
        XCTAssertEqual(channels.count, live)
        let end = try await provider.items(
            in: "movies", kind: .movie, page: .init(startIndex: total - live - 5, limit: 10)
        )
        XCTAssertEqual(end.totalCount, total - live)
        XCTAssertEqual(end.items.count, 5)
        XCTAssertFalse(end.hasMore)
        let count = await server.requestCount
        report("Verified \(channels.count) channels and \(end.totalCount) movies; reopening catalog")
        let reopened = try IPTVProvider(context: context, cacheDirectory: root.appendingPathComponent("catalog"))
        addTeardownBlock { await reopened.teardown() }
        let restored = try await reopened.items(in: "movies", kind: .movie, page: .init(limit: 1))
        XCTAssertEqual(restored.totalCount, total - live)
        let requestsAfterReopening = await server.requestCount
        XCTAssertEqual(requestsAfterReopening, count)
        var after = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &after), 0)
        report("Verified reopened catalog without another download")
        print("IPTV_SCALE entries=\(total) live=\(live) bytes=\(inputBytes) elapsed_seconds=\(Date().timeIntervalSince(started)) process_peak_before_bytes=\(before.ru_maxrss) process_peak_after_bytes=\(after.ru_maxrss)")
    }

    func testInterruptedHTTPPlaylistRollsBackStagedRowsAndRetryCompletes() async throws {
        let initial = Data("#EXTM3U\n#EXTINF:120,Original\nmovie/original.mp4\n".utf8)
        let replies = IPTVFixtureReplies(.init(data: initial))
        let server = try IPTVTestHTTPServer { _ in replies.value }
        addTeardownBlock { await server.stop() }
        let credential = try IPTVCredential(mode: .playlist, address: try await server.start())
        let client = try IPTVClient(credential: credential, directory: temporaryDirectory())
        try await client.ensureCatalog("movies")
        let before = try await client.page(library: "movies", kind: .movie, page: .init(limit: 1))
        let full = Data(("#EXTM3U\n" + (0..<5_000).map {
            "#EXTINF:120,Replacement \($0)\nmovie/\($0).mp4\n"
        }.joined()).utf8)
        replies.value = .init(data: full, cutoff: 160_000, delay: .milliseconds(1))
        do {
            try await client.ensureCatalog("movies", force: true)
            XCTFail("An incomplete HTTP body must not replace the existing catalogue")
        } catch {
            XCTAssertEqual(IPTVSetupDiagnostic.Failure.sanitized(error).reason, .network)
        }
        let retained = try await client.page(library: "movies", kind: .movie, page: .init(limit: 10))
        XCTAssertEqual(retained.items.map(\.id), before.items.map(\.id))
        XCTAssertEqual(retained.totalCount, 1)
        replies.value = .init(data: full, delay: .milliseconds(1))
        try await client.ensureCatalog("movies", force: true)
        let retried = try await client.page(library: "movies", kind: .movie, page: .init(startIndex: 4_999, limit: 10))
        XCTAssertEqual(retried.totalCount, 5_000)
        XCTAssertEqual(retried.items.count, 1)
    }

    func testTruncatedXtreamArrayAfterTwoThousandRowsRollsBackAndRetries() async throws {
        let replies = IPTVFixtureReplies(.init(data: Data(#"[{"stream_id":1,"name":"Original"}]"#.utf8)))
        let server = try IPTVTestHTTPServer { request in
            if request.contains("action=get_live_streams") { return replies.value }
            if request.contains("action=") { return .init(data: Data("[]".utf8)) }
            return .init(data: Data(#"{"user_info":{"auth":1,"status":"Active","allowed_output_formats":["ts"]}}"#.utf8))
        }
        addTeardownBlock { await server.stop() }
        let credential = try IPTVCredential(
            mode: .xtream, address: try await server.start(), username: "fixture", password: "fixture"
        )
        let client = try IPTVClient(credential: credential, directory: temporaryDirectory())
        try await client.ensureCatalog("live")
        let before = try await client.liveChannels()
        let array = "[" + (0..<2_201).map { #"{"stream_id":\#($0 + 10),"name":"Channel \#($0)"}"# }.joined(separator: ",")
        replies.value = .init(data: Data(array.utf8), delay: .milliseconds(1))
        do {
            try await client.ensureCatalog("live", force: true)
            XCTFail("A truncated JSON array must not commit its complete prefix")
        } catch { XCTAssertEqual(error as? IPTVError, .malformed) }
        let retained = try await client.liveChannels()
        XCTAssertEqual(retained.map(\.id), before.map(\.id))
        replies.value = .init(data: Data((array + "]").utf8), delay: .milliseconds(1))
        try await client.ensureCatalog("live", force: true)
        let retried = try await client.liveChannels()
        XCTAssertEqual(retried.count, 2_201)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
}

private final class IPTVFixtureReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var response: IPTVTestHTTPServer.Response
    init(_ response: IPTVTestHTTPServer.Response) { self.response = response }
    var value: IPTVTestHTTPServer.Response {
        get { lock.withLock { response } }
        set { lock.withLock { response = newValue } }
    }
}
