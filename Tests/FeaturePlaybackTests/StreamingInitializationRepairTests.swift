import AVFoundation
import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import FeaturePlayback

final class StreamingInitializationRepairTests: XCTestCase {
    private let media = URL(string: "https://server.test/video/main.m3u8?parent=secret")!
    private let playlist = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-TARGETDURATION:3
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXT-X-MAP:URI="init.mp4?session=a%2Bb"
    #EXTINF:3,
    segment.mp4?session=a%2Bb&value=1&value=2
    #EXT-X-ENDLIST
    """

    func testRepairsInitializationAndPreservesExactSegmentQueries() async throws {
        let client = RepairHTTPClient(playlist: playlist)
        let result = try await prepare(client)
        let repair = try XCTUnwrap(result)
        XCTAssertEqual(repair.initialization, MP4InitializationFixture.make(dependencies: nil))
        let text = String(decoding: repair.playlist, as: UTF8.self)
        XCTAssertTrue(text.contains("https://server.test/video/segment.mp4?session=a%2Bb&value=1&value=2"))
        XCTAssertTrue(text.contains("#EXT-X-MAP:URI=\"\(repair.initializationURL.absoluteString)\""))
        XCTAssertFalse(text.contains("parent="))
        let calls = await client.calls
        XCTAssertEqual(calls.map(\.1), [media, URL(string: "https://server.test/video/init.mp4?session=a%2Bb")!])
        XCTAssertTrue(calls.allSatisfy { $0.0.redirectPolicy == .sameOrigin && $0.0.path.isEmpty })
        let nextResult = try await prepare(RepairHTTPClient(playlist: playlist))
        let next = try XCTUnwrap(nextResult)
        XCTAssertNotEqual(repair.playlistURL, next.playlistURL, "Each item must own its initialization resources.")
    }

    func testSupportsLargeVODManifestsButRejectsOversizedOnes() async throws {
        let large = playlist.replacingOccurrences(of: "#EXTINF:3,\nsegment.mp4?session=a%2Bb&value=1&value=2",
            with: String(repeating: "#EXTINF:3,\nsegment.mp4?session=a%2Bb\n", count: 3_000))
        XCTAssertGreaterThan(large.utf8.count, 65_536)
        let accepted = try await prepare(RepairHTTPClient(playlist: large))
        XCTAssertNotNil(accepted)
        let client = RepairHTTPClient(playlist: playlist + "\n#" + String(repeating: "a", count: 1_048_576))
        let rejected = try await prepare(client)
        XCTAssertNil(rejected)
        let calls = await client.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testRejectsUnsupportedManifestShapesBeforeFetchingInitialization() async throws {
        let extras = [
            "#EXT-X-KEY:METHOD=AES-128,URI=\"key\"",
            "#EXT-X-SESSION-KEY:METHOD=AES-128,URI=\"key\"",
            "#EXT-X-DEFINE:NAME=\"token\",VALUE=\"x\"",
            "#EXT-X-STREAM-INF:BANDWIDTH=500000",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\"",
            "#EXT-X-BYTERANGE:10@0",
            "#EXT-X-PART:DURATION=1,URI=\"part.mp4\"",
            "#EXT-X-MAP:URI=\"second.mp4\""
        ]
        let cases = extras.map { playlist.replacingOccurrences(of: "#EXT-X-VERSION:7", with: $0) } + [
            playlist.replacingOccurrences(of: "#EXT-X-ENDLIST", with: ""),
            playlist.replacingOccurrences(of: "#EXT-X-PLAYLIST-TYPE:VOD", with: "#EXT-X-PLAYLIST-TYPE:EVENT"),
            playlist.replacingOccurrences(of: "URI=\"init.mp4?session=a%2Bb\"", with: "URI=\"init.mp4\",BYTERANGE=\"20@0\""),
            playlist.replacingOccurrences(of: "#EXTINF:3,", with: "#EXTINF:NaN,"),
            playlist.replacingOccurrences(of: "#EXTINF:3,", with: "#EXTINF:0,"),
            playlist.replacingOccurrences(of: "#EXTINF:3,", with: "#EXTINF:3,\n#EXTINF:3,"),
            playlist + "\nsegment.mp4"
        ]
        for text in cases {
            let client = RepairHTTPClient(playlist: text)
            let repair = try await prepare(client)
            XCTAssertNil(repair, text)
            let calls = await client.calls
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testRejectsUnsafeMapAndSegmentReferences() async throws {
        let references = [
            "https://foreign.test/file.mp4", "//foreign.test/file.mp4", "file:///tmp/file.mp4",
            "http://server.test/file.mp4", "https://server.test:444/file.mp4",
            "https://user:password@server.test/file.mp4", "file.mp4#fragment",
            "file-{$token}.mp4", #"https:\foreign.test\file.mp4"#
        ]
        for reference in references {
            for original in ["init.mp4?session=a%2Bb", "segment.mp4?session=a%2Bb&value=1&value=2"] {
                let client = RepairHTTPClient(playlist: playlist.replacingOccurrences(of: original, with: reference))
                let repair = try await prepare(client)
                XCTAssertNil(repair)
                let calls = await client.calls
                XCTAssertEqual(calls.count, 1)
            }
        }
    }

    func testRejectsUnsupportedInputWithoutSendingRequest() async throws {
        for url in ["file:///tmp/main.m3u8", "https://server.test/movie.mp4",
                    "https://user:password@server.test/main.m3u8", "https://server.test/main.m3u8#fragment"] {
            let client = RepairHTTPClient(playlist: playlist)
            let result = try await StreamingInitializationRepair.prepare(mediaURL: URL(string: url)!, using: client)
            XCTAssertNil(result)
            let calls = await client.calls
            XCTAssertTrue(calls.isEmpty)
        }
    }

    func testUsesFinalSameOriginPathAndRejectsForeignRedirects() async throws {
        let redirected = RepairHTTPClient(playlist: playlist,
            playlistResponseURL: URL(string: "https://server.test/redirect/main.m3u8")!)
        let repair = try await prepare(redirected)
        XCTAssertNotNil(repair)
        let calls = await redirected.calls
        XCTAssertEqual(calls.last?.1.path, "/redirect/init.mp4")
        for initialization in [false, true] {
            let foreign = URL(string: "https://foreign.test/file")!
            let client = RepairHTTPClient(playlist: playlist,
                playlistResponseURL: initialization ? nil : foreign,
                initializationResponseURL: initialization ? foreign : nil)
            let rejected = try await prepare(client)
            XCTAssertNil(rejected)
        }
    }

    func testHealthyInitializationKeepsProviderPlayback() async throws {
        let result = try await prepare(RepairHTTPClient(
            playlist: playlist, initialization: MP4InitializationFixture.make(dependencies: nil)
        ))
        XCTAssertNil(result)
    }

    @MainActor
    func testStopAndNewLoadCannotBeOverwrittenByLateInitialization() async {
        for newerLoad in [false, true] {
            let client = RepairHTTPClient(playlist: playlist, suspendInitialization: true)
            let engine = NativeVideoEngine(streamingPlaylistClient: client)
            let request = request()
            let oldLoad = Task { await engine.load(request: request, startPosition: 0) }
            await client.waitForInitialization()
            let newer = PlaybackRequest(item: request.item, streamURL: URL(fileURLWithPath: "/dev/null"))
            if newerLoad { await engine.load(request: newer, startPosition: 0) }
            else { engine.stop() }
            await client.resume()
            await oldLoad.value
            if newerLoad {
                XCTAssertEqual((engine.underlyingPlayer?.currentItem?.asset as? AVURLAsset)?.url, newer.streamURL)
            } else {
                XCTAssertNil(engine.underlyingPlayer)
                XCTAssertEqual(engine.status, .idle)
            }
            engine.stop()
        }
    }

    @MainActor
    func testCancelledInitializationCannotCreatePlayer() async {
        let client = RepairHTTPClient(playlist: playlist, suspendInitialization: true)
        let engine = NativeVideoEngine(streamingPlaylistClient: client)
        defer { engine.stop() }
        let load = Task { await engine.load(request: request(), startPosition: 0) }
        await client.waitForInitialization()
        load.cancel()
        await client.resume()
        await load.value
        XCTAssertNil(engine.underlyingPlayer)
    }

    @MainActor
    func testNativeHEVCUsesRepairButH264LeavesInitializationAlone() async {
        for codec in [DirectPlayVideoCodec.hevc, .h264] {
            let client = RepairHTTPClient(playlist: playlist)
            let engine = NativeVideoEngine(streamingPlaylistClient: client)
            var request = request()
            request.negotiatedStreamingVideoCodec = codec
            await engine.load(request: request, startPosition: 0)
            let asset = engine.underlyingPlayer?.currentItem?.asset as? AVURLAsset
            XCTAssertEqual(asset?.url.scheme, codec == .hevc ? "plozz-stream" : "https")
            let calls = await client.calls
            XCTAssertEqual(calls.filter { $0.1.pathExtension == "mp4" }.count, codec == .hevc ? 1 : 0)
            engine.stop()
        }
    }

    private func prepare(_ client: RepairHTTPClient) async throws -> StreamingInitializationRepair? {
        try await StreamingInitializationRepair.prepare(mediaURL: media, using: client)
    }

    private func request() -> PlaybackRequest {
        var request = PlaybackRequest(
            item: .init(id: "item", title: "Fixture", kind: .movie), streamURL: media,
            playSessionID: "fixture", isTranscoding: true, sourceProvider: .emby
        )
        request.streamingOptions = .init(quality: .low)
        request.negotiatedStreamingVideoCodec = .hevc
        return request
    }
}

private actor RepairHTTPClient: HTTPClient {
    let playlist: String
    let initialization: Data
    let playlistResponseURL: URL?
    let initializationResponseURL: URL?
    let suspendInitialization: Bool
    var calls: [(Endpoint, URL)] = []
    var release: CheckedContinuation<Void, Never>?
    var requested: CheckedContinuation<Void, Never>?

    init(
        playlist: String, initialization: Data = MP4InitializationFixture.make(),
        playlistResponseURL: URL? = nil, initializationResponseURL: URL? = nil,
        suspendInitialization: Bool = false
    ) {
        self.playlist = playlist
        self.initialization = initialization
        self.playlistResponseURL = playlistResponseURL
        self.initializationResponseURL = initializationResponseURL
        self.suspendInitialization = suspendInitialization
    }

    func waitForInitialization() async {
        guard release == nil else { return }
        await withCheckedContinuation { requested = $0 }
    }

    func resume() { release?.resume(); release = nil }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        calls.append((endpoint, baseURL))
        let isInitialization = baseURL.pathExtension == "mp4"
        if isInitialization, suspendInitialization {
            await withCheckedContinuation { continuation in
                release = continuation
                requested?.resume()
                requested = nil
            }
        }
        let url = (isInitialization ? initializationResponseURL : playlistResponseURL) ?? baseURL
        return (isInitialization ? initialization : Data(playlist.utf8),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
