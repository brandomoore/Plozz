import CoreModels
import CoreNetworking
import Foundation
import XCTest
#if canImport(AVFoundation)
import AVFoundation
#endif
@testable import FeaturePlayback

final class StreamingMediaPlaylistTests: XCTestCase {
    private let master = URL(string: "https://server.test/emby/videos/item/master.m3u8?api_key=private&VideoBitrate=372000")!
    private let attributes = #"BANDWIDTH=513184,AVERAGE-BANDWIDTH=496776,RESOLUTION=426x230,CODECS="hvc1.1.6.L60.90,mp4a.40.2""#

    private func playlist(_ uri: String, extra: String = "") -> String {
        "#EXTM3U\n#EXT-X-VERSION:7\n\(extra)#EXT-X-STREAM-INF:\(attributes)\n\(uri)\n"
    }

    func testExactSingleRenditionFromReproducedHDRMaster() throws {
        let url = try XCTUnwrap(StreamingMediaPlaylist.singleMediaURL(
            in: playlist("main.m3u8?api_key=child&PlaySessionId=one&VideoBitrate=372000&AudioBitrate=128000"),
            masterURL: master
        ))
        XCTAssertEqual(url.absoluteString,
                       "https://server.test/emby/videos/item/main.m3u8?api_key=child&PlaySessionId=one&VideoBitrate=372000&AudioBitrate=128000")
        XCTAssertFalse(url.absoluteString.contains("private"), "Do not copy parent query credentials or invent child parameters.")
    }

    func testRelativeRootRelativeAndSameOriginAbsoluteURIs() {
        for uri in ["main.m3u8", "/emby/videos/item/main.m3u8",
                    "https://server.test:443/emby/videos/item/main.m3u8"] {
            XCTAssertNotNil(StreamingMediaPlaylist.singleMediaURL(in: playlist(uri), masterURL: master))
        }
    }

    func testEncodedChildQueryIsNotDecodedOrMergedWithParentQuery() {
        let uri = "main.m3u8?api_key=a%2Bb%26c&path=x%2Fy&value=1&value=2"
        XCTAssertEqual(
            StreamingMediaPlaylist.singleMediaURL(in: playlist(uri), masterURL: master)?.absoluteString,
            "https://server.test/emby/videos/item/" + uri
        )
    }

    func testDoesNotSelectAnAdaptiveVariantOrDropExternalTracks() {
        let cases = [
            playlist("low.m3u8") + "#EXT-X-STREAM-INF:BANDWIDTH=900000\nhigh.m3u8\n",
            playlist("main.m3u8", extra: "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",URI=\"audio.m3u8\"\n"),
            playlist("main.m3u8", extra: "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"s\",URI=\"subs.m3u8\"\n"),
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=500000,AUDIO=\"missing\"\nmain.m3u8\n",
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=500000,VIDEO=\"missing\"\nmain.m3u8\n"
        ]
        for text in cases {
            XCTAssertNil(StreamingMediaPlaylist.singleMediaURL(in: text, masterURL: master))
        }
    }

    func testAllowsExplicitInBandAudioGroup() {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Stereo",DEFAULT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=500000,AUDIO="a"
        main.m3u8
        """
        XCTAssertNotNil(StreamingMediaPlaylist.singleMediaURL(in: text, masterURL: master))
    }

    func testRefusesCredentialForwardingAndNonPlaylistResources() {
        for uri in ["https://foreign.test/main.m3u8", "//foreign.test/main.m3u8",
                    "http://server.test/main.m3u8", "https://server.test:444/main.m3u8",
                    "https://user:password@server.test/main.m3u8",
                    "file:///tmp/main.m3u8", "original.mp4", "main.m3u8#fragment",
                    #"https:\foreign.test\main.m3u8"#, "main-{$name}.m3u8",
                    master.absoluteString] {
            XCTAssertNil(StreamingMediaPlaylist.singleMediaURL(in: playlist(uri), masterURL: master))
        }
    }

    func testLeavesMediaMalformedOversizedAndDependentManifestsAlone() {
        let cases = [
            "#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXTINF:3,\nsegment.mp4\n",
            playlist("main.m3u8", extra: "#EXT-X-SESSION-KEY:METHOD=AES-128,URI=\"key\"\n"),
            playlist("main.m3u8", extra: "#EXT-X-DEFINE:NAME=\"name\",VALUE=\"x\"\n"),
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=500000\n",
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=500000,BANDWIDTH=600000\nmain.m3u8\n",
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=500000,CODECS=\"unfinished\nmain.m3u8\n",
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=0\nmain.m3u8\n",
            playlist("main.m3u8") + "unexpected.m3u8\n",
            playlist("main.m3u8") + "#" + String(repeating: "x", count: 65536),
            "<html>Server error</html>"
        ]
        for text in cases {
            XCTAssertNil(StreamingMediaPlaylist.singleMediaURL(in: text, masterURL: master))
        }
    }

    func testCRLFWhitespaceAndCommentsAreAccepted() {
        let text = playlist("  main.m3u8  ").replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertNotNil(StreamingMediaPlaylist.singleMediaURL(in: text, masterURL: master))
        XCTAssertNotNil(StreamingMediaPlaylist.singleMediaURL(
            in: playlist("# comment\nmain.m3u8"), masterURL: master
        ))
    }

    func testFetchUsesSameOriginRedirectsAndKeepsTheExactAuthenticatedURL() async throws {
        let client = PlaylistHTTPClient(text: playlist("main.m3u8"))
        let result = try await StreamingMediaPlaylist.resolve(master, using: client)
        XCTAssertEqual(result?.path, "/emby/videos/item/main.m3u8")
        let call = await client.call
        XCTAssertEqual(call?.0.redirectPolicy, .sameOrigin)
        XCTAssertEqual(call?.0.path, "")
        XCTAssertEqual(call?.1, master)
    }

    func testRedirectedResponseResolvesRelativeToItsFinalSameOriginPath() async throws {
        let client = PlaylistHTTPClient(text: playlist("main.m3u8"),
                                        responseURL: URL(string: "https://server.test/other/master.m3u8")!)
        let result = try await StreamingMediaPlaylist.resolve(master, using: client)
        XCTAssertEqual(result?.path, "/other/main.m3u8")
    }

    func testRejectsForeignResponseEvenIfTransportFailsToEnforceRedirectPolicy() async throws {
        let client = PlaylistHTTPClient(text: playlist("main.m3u8"),
                                        responseURL: URL(string: "https://foreign.test/master.m3u8")!)
        let result = try await StreamingMediaPlaylist.resolve(master, using: client)
        XCTAssertNil(result)
    }

    #if canImport(AVFoundation)
    @MainActor
    func testNativeLoadUsesExactChildWithoutChangingSessionOrQuality() async {
        let client = PlaylistHTTPClient(text: playlist("main.m3u8?VideoBitrate=372000&PlaySessionId=one"))
        let engine = NativeVideoEngine(streamingPlaylistClient: client)
        defer { engine.stop() }
        let request = managedRequest()
        await engine.load(request: request, startPosition: 0)
        let asset = engine.underlyingPlayer?.currentItem?.asset as? AVURLAsset
        XCTAssertEqual(asset?.url.absoluteString,
                       "https://server.test/emby/videos/item/main.m3u8?VideoBitrate=372000&PlaySessionId=one")
        XCTAssertEqual(request.streamingSessionID, "one")
        XCTAssertEqual(request.streamingOptions?.quality, .low)
    }

    @MainActor
    func testOrdinaryPlaybackDoesNotInspectPlaylist() async {
        let client = PlaylistHTTPClient(text: playlist("main.m3u8"))
        let engine = NativeVideoEngine(streamingPlaylistClient: client)
        defer { engine.stop() }
        var request = managedRequest()
        request.streamingOptions = nil
        await engine.load(request: request, startPosition: 0)
        let call = await client.call
        XCTAssertNil(call)
        XCTAssertEqual((engine.underlyingPlayer?.currentItem?.asset as? AVURLAsset)?.url, master)
    }

    @MainActor
    func testStopDuringPlaylistFetchCannotResurrectPlayer() async {
        let client = PlaylistHTTPClient(text: playlist("main.m3u8"), suspended: true)
        let engine = NativeVideoEngine(streamingPlaylistClient: client)
        let request = managedRequest()
        let load = Task { await engine.load(request: request, startPosition: 0) }
        await client.waitForRequest()
        engine.stop()
        await client.resume()
        await load.value
        XCTAssertNil(engine.underlyingPlayer)
        XCTAssertEqual(engine.status, .idle)
    }

    @MainActor
    func testNewLoadWinsOverLatePlaylistResponse() async {
        let client = PlaylistHTTPClient(text: playlist("stale.m3u8"), suspended: true)
        let engine = NativeVideoEngine(streamingPlaylistClient: client)
        defer { engine.stop() }
        let request = managedRequest()
        let first = Task { await engine.load(request: request, startPosition: 0) }
        await client.waitForRequest()
        let newer = PlaybackRequest(item: request.item, streamURL: URL(fileURLWithPath: "/dev/null"))
        await engine.load(request: newer, startPosition: 0)
        await client.resume()
        await first.value
        XCTAssertEqual((engine.underlyingPlayer?.currentItem?.asset as? AVURLAsset)?.url, newer.streamURL)
    }

    private func managedRequest() -> PlaybackRequest {
        var request = PlaybackRequest(
            item: .init(id: "item", title: "Fixture", kind: .movie), streamURL: master,
            playSessionID: "one", isTranscoding: true, sourceProvider: .emby
        )
        request.streamingOptions = .init(quality: .low)
        request.streamingSessionID = "one"
        return request
    }
    #endif
}

private actor PlaylistHTTPClient: HTTPClient {
    let text: String
    let responseURL: URL?
    var call: (Endpoint, URL)?
    var suspended: Bool
    var release: CheckedContinuation<Void, Never>?
    var requested: CheckedContinuation<Void, Never>?

    init(text: String, responseURL: URL? = nil, suspended: Bool = false) {
        self.text = text
        self.responseURL = responseURL
        self.suspended = suspended
    }

    func waitForRequest() async {
        guard call == nil else { return }
        await withCheckedContinuation { requested = $0 }
    }

    func resume() {
        suspended = false
        release?.resume()
        release = nil
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        call = (endpoint, baseURL)
        requested?.resume()
        requested = nil
        if suspended { await withCheckedContinuation { release = $0 } }
        return (Data(text.utf8), HTTPURLResponse(url: responseURL ?? baseURL,
                                                statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
