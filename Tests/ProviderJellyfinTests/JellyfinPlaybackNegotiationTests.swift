import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderJellyfin

final class JellyfinPlaybackNegotiationTests: XCTestCase {
    func testDecoderBackedPlaybackDoesNotOverrideDirectPlayWithALegacyServerRemux() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            for container in ["mp4", "mkv"] {
                let original = """
                {"PlaySessionId":"original","MediaSources":[{
                  "Id":"version","Container":"\(container)","SupportsDirectPlay":true,
                  "MediaStreams":[
                    {"Index":0,"Type":"Video","Codec":"hevc","CodecTag":"hev1","VideoRangeType":"DOVIWithHDR10"},
                    {"Index":1,"Type":"Audio","Codec":"eac3","IsDefault":true}
                  ]
                }]}
                """
                let http = fixtureHTTP(decisions: [original, decision(session: "unnecessary-remux")])
                let request = try await provider(kind, http: http, hybrid: true).playbackInfo(
                    for: "movie", mediaSourceID: "version", forceTranscode: false
                )
                XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/PlaybackInfo") }.count, 1)
                XCTAssertFalse(request.isTranscoding)
                XCTAssertEqual(request.deliveryMode, .directPlay)
                XCTAssertEqual(request.playSessionID, "original")
                XCTAssertEqual(request.sourceMetadata?.container, container)
                XCTAssertTrue(releasedSessions(http).isEmpty)
                guard case .authenticatedHTTP(let locator) = request.playbackSource else {
                    return XCTFail("Keep the selected original source")
                }
                XCTAssertEqual(locator.mediaSourceID, "version")
                XCTAssertEqual(locator.deliveryMode, .directFile)
            }
        }
    }

    func testDecoderBackedPlaybackStillHonorsServerConversionAndUserQuality() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            for bounded in [false, true] {
                let http = fixtureHTTP(decisions: [decision(session: "required-conversion")])
                let request = try await request(provider(kind, http: http, hybrid: true), streaming: bounded)
                XCTAssertTrue(request.isTranscoding)
                XCTAssertEqual(request.playSessionID, "required-conversion")
                XCTAssertEqual(request.streamingOptions?.quality, bounded ? .hd720 : nil)
                XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/PlaybackInfo") }.count, 1)
            }
        }
    }

    func testUnavailablePlaceholderNeverBecomesAPlaybackLocatorAndReleasesSession() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let http = fixtureHTTP(decisions: ["""
            {"PlaySessionId":"refused","MediaSources":[
            {"Id":"movie","IsRemote":true,"Name":"No streams · Unavailable",
             "Container":"mkv","SupportsDirectPlay":true,"SupportsTranscoding":false}]}
            """])
            do {
                _ = try await provider(kind, http: http).playbackInfo(for: "movie")
                XCTFail("Do not manufacture a stream URL from a negative lookup.")
            } catch {
                XCTAssertEqual(error as? StreamingQualityError, .sourceUnavailable)
            }
            XCTAssertEqual(releasedSessions(http), ["refused"])
        }
    }

    func testOnlyForcedConversionDisablesBothCopyPermissionsInBodyAndQuery() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            for streaming in [nil, StreamingPlaybackOptions(quality: .hd720)] {
                for mode in [JellyfinClient.PlaybackStreamMode.auto, .remux, .transcode] {
                    let http = StubHTTPClient()
                    http.stub(pathSuffix: "/PlaybackInfo", json: #"{"MediaSources":[]}"#)
                    let client = JellyfinClient(
                        baseURL: URL(string: "https://fixture.test")!,
                        deviceProfile: .init(deviceID: "device"), providerKind: kind, http: http
                    )
                    _ = try await client.playbackInfo(
                        userID: "user", itemID: "movie", mode: mode, streaming: streaming
                    )
                    let data = try XCTUnwrap(http.sentBodies["/Items/movie/PlaybackInfo"])
                    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/PlaybackInfo"))
                    for name in ["AllowVideoStreamCopy", "AllowAudioStreamCopy"] {
                        if case .transcode = mode {
                            XCTAssertEqual(body[name] as? Bool, false)
                            XCTAssertEqual(query.filter { $0.name == name }, [.init(name: name, value: "false")])
                        } else {
                            XCTAssertNil(body[name], "Keep the server's compatibility-copy decision")
                            XCTAssertFalse(query.contains { $0.name == name })
                        }
                    }
                }
            }
        }
    }

    func testAutomaticUsesTheFirstSupportedServerCodecWhenEncodingIsRequired() throws {
        for (offered, expected) in [
            ("hevc,h264", "hevc"),
            ("h264,hevc", "h264"),
            ("AV1, HEVC,H264", "hevc"),
            ("vp9,h264", "h264")
        ] {
            let source = try mediaSource(url: "/master.m3u8?VideoCodec=\(offered)")
            for options in [
                StreamingPlaybackOptions(quality: .hd720),
                .init(quality: .original, forceTranscoding: true)
            ] {
                let query = try XCTUnwrap(URLComponents(string: source.boundedTranscodingURL(
                    options, supportsHEVC: true
                ))?.queryItems)
                XCTAssertEqual(query.first { $0.name == "VideoCodec" }?.value, expected)
                XCTAssertEqual(query.first { $0.name == "AllowVideoStreamCopy" }?.value, "false")
            }
        }
    }

    func testAutomaticDoesNotInventAnEncoderWhenNoSupportedCodecWasOffered() throws {
        for offered in ["av1,vp9", "copy", ""] {
            let source = try mediaSource(url: "/master.m3u8?VideoCodec=\(offered)")
            XCTAssertThrowsError(try source.boundedTranscodingURL(
                .init(quality: .hd720), supportsHEVC: true
            )) {
                XCTAssertEqual($0 as? StreamingQualityError, .noCompatibleStream)
            }
        }
    }

    func testOrdinaryForcedFallbackCannotReturnTheOriginalFile() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let http = fixtureHTTP(decisions: [decision(session: "refused", url: nil)])
            let provider = provider(kind, http: http)
            do {
                _ = try await provider.playbackInfo(
                    for: "movie", mediaSourceID: "version", forceTranscode: true
                )
                XCTFail("A full-transcode fallback cannot repeat the failed original")
            } catch {
                XCTAssertEqual(error as? StreamingQualityError, .unavailable)
            }
            XCTAssertEqual(releasedSessions(http), ["refused"])
            XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/PlaybackInfo") }.count, 1)
        }
    }

    func testOrdinaryForcedFallbackKeepsTheRequestedSourceAndServerRefusal() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            for (json, expected) in [
                (decision(session: "refused", source: "other"), StreamingQualityError.sourceUnavailable),
                (#"{"PlaySessionId":"refused","ErrorCode":"NoCompatibleStream"}"#, .noCompatibleStream)
            ] {
                let http = fixtureHTTP(decisions: [json])
                do {
                    _ = try await provider(kind, http: http).playbackInfo(
                        for: "movie", mediaSourceID: "version", forceTranscode: true
                    )
                    XCTFail("A rejected rendition must not become direct playback")
                } catch {
                    XCTAssertEqual(error as? StreamingQualityError, expected)
                }
                XCTAssertEqual(releasedSessions(http), ["refused"])
            }
        }
    }

    func testDetailFailureReleasesTheConcurrentlyNegotiatedSession() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            for streaming in [false, true] {
                let http = NegotiationHTTP(detailError: .invalidResponse)
                let provider = provider(kind, http: http)
                let task = Task { try await self.request(provider, streaming: streaming) }
                await fulfillment(of: [http.decisionRequested, http.detailRequested], timeout: 2)
                await http.detailGate.release()
                do {
                    _ = try await task.value
                    XCTFail("The missing detail cannot become playback")
                } catch {
                    XCTAssertEqual(error as? AppError, .invalidResponse)
                }
                let released = await http.releasedSessions
                XCTAssertEqual(released, ["owned"])
            }
        }
    }

    func testCancellationReleasesTheDecisionWithANoncancelledCleanupRequest() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            for streaming in [false, true] {
                let http = NegotiationHTTP()
                let provider = provider(kind, http: http)
                let task = Task { try await self.request(provider, streaming: streaming) }
                await fulfillment(of: [http.decisionRequested, http.detailRequested], timeout: 2)
                task.cancel()
                // Model a transport/cache that still delivers its completed response.
                await http.detailGate.release()
                do {
                    _ = try await task.value
                    XCTFail("A cancelled negotiation must not transfer playback ownership")
                } catch {
                    XCTAssertTrue(error is CancellationError)
                }
                let released = await http.releasedSessions
                XCTAssertEqual(released, ["owned"])
            }
        }
    }

    func testInvalidFinalLocatorReleasesBothOrdinaryAndBoundedDecisions() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            for streaming in [false, true] {
                let http = fixtureHTTP(decisions: [decision(session: "invalid", url: "?VideoCodec=hevc")])
                do {
                    _ = try await request(provider(kind, http: http), streaming: streaming)
                    XCTFail("A query with no resource path cannot become playback")
                } catch {
                    XCTAssertEqual(error as? AppError, .invalidResponse)
                }
                XCTAssertEqual(releasedSessions(http), ["invalid"])
            }
        }
    }

    func testFailedRetryReleasesEachKnownSessionExactlyOnce() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            for receivesDecision in [false, true] {
                var decisions = [decision(session: "initial", url: nil)]
                if receivesDecision {
                    decisions.append(decision(session: "retry", source: "wrong-source"))
                }
                let http = fixtureHTTP(decisions: decisions)
                do {
                    _ = try await request(provider(kind, http: http), streaming: true)
                    XCTFail("A failed retry must not become playback")
                } catch {
                    if receivesDecision {
                        XCTAssertEqual(error as? StreamingQualityError, .unavailable)
                    } else {
                        XCTAssertEqual(error as? AppError, .notFound)
                    }
                }
                XCTAssertEqual(releasedSessions(http), receivesDecision ? ["initial", "retry"] : ["initial"])
                XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/PlaybackInfo") }.count, 2)
            }
        }
    }

    func testBestEffortRemuxPinsItsSourceAndReleasesOnlyAbandonedSessions() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            for outcome in ["accepted", "unavailable", "wrong-source", "rejected"] {
                let remux: String
                switch outcome {
                case "unavailable": remux = decision(session: "remux", url: nil)
                case "wrong-source": remux = decision(session: "remux", source: "other")
                case "rejected": remux = #"{"PlaySessionId":"remux","ErrorCode":"NoCompatibleStream"}"#
                default: remux = decision(session: "remux")
                }
                let http = fixtureHTTP(decisions: [
                    decision(session: "original", url: nil, codecTag: "hev1"), remux
                ])
                let request = try await provider(kind, http: http).playbackInfo(for: "movie")
                XCTAssertEqual(request.playSessionID, outcome == "accepted" ? "remux" : "original")
                XCTAssertEqual(request.isTranscoding, outcome == "accepted")
                XCTAssertEqual(releasedSessions(http), [outcome == "accepted" ? "original" : "remux"])
                XCTAssertEqual(
                    http.queryItems(forPathSuffix: "/PlaybackInfo")?.first { $0.name == "MediaSourceId" }?.value,
                    "version"
                )
                guard case .authenticatedHTTP(let locator) = request.playbackSource else {
                    return XCTFail("Expected the original or remuxed source")
                }
                XCTAssertEqual(locator.mediaSourceID, "version")
            }
        }
    }

    func testSuccessfulDecisionTransfersOwnershipWithoutPrematureCleanup() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let http = fixtureHTTP(decisions: [decision(session: "active")])
            let provider = provider(kind, http: http)
            let request = try await request(provider, streaming: true)
            XCTAssertTrue(releasedSessions(http).isEmpty)
            XCTAssertEqual(request.streamingSessionID, "active")
            await provider.releaseStreamingSession(request)
            XCTAssertEqual(releasedSessions(http), ["active"])
        }
    }

    private func request(_ provider: JellyfinProvider, streaming: Bool) async throws -> PlaybackRequest {
        if streaming {
            return try await provider.playbackInfo(
                for: "movie", mediaSourceID: "version", forceTranscode: false,
                streaming: .init(quality: .hd720)
            )
        }
        return try await provider.playbackInfo(for: "movie", mediaSourceID: "version", forceTranscode: false)
    }

    private func provider(_ kind: ProviderKind, http: any HTTPClient, hybrid: Bool = false) -> JellyfinProvider {
        JellyfinProvider(session: .init(
            server: .init(id: "server", name: "Server", baseURL: URL(string: "https://fixture.test")!, provider: kind),
            userID: "user", userName: "User", deviceID: "device", accessToken: "fixture"
        ), http: http, hybridEngineEnabled: hybrid, playbackRequests: .init())
    }

    private func fixtureHTTP(decisions: [String]) -> StubHTTPClient {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/Users/user/Items/movie", json: #"{"Id":"movie","Name":"Movie","Type":"Movie"}"#)
        http.stub(pathSuffix: "/Videos/ActiveEncodings", json: "{}")
        http.stubSequence(pathSuffix: "/Items/movie/PlaybackInfo", jsons: decisions)
        return http
    }

    private func releasedSessions(_ http: StubHTTPClient) -> [String] {
        http.sentPaths.enumerated().compactMap { index, path in
            guard path.hasSuffix("/Videos/ActiveEncodings") else { return nil }
            XCTAssertEqual(http.sentMethods[index], .delete)
            XCTAssertEqual(http.sentQueryItems[index].first { $0.name == "deviceId" }?.value, "device")
            return http.sentQueryItems[index].first { $0.name == "playSessionId" }?.value
        }
    }

    private func decision(
        session: String, source: String = "version",
        url: String? = "/Videos/movie/master.m3u8?VideoCodec=hevc,h264", codecTag: String = "hvc1"
    ) -> String {
        let rendition = url.map { #""TranscodingUrl":"\#($0)","# } ?? ""
        return """
        {"PlaySessionId":"\(session)","MediaSources":[{
          "Id":"\(source)","Container":"mp4","SupportsDirectPlay":\(url == nil),"Bitrate":30000000,
          \(rendition)
          "MediaStreams":[{"Index":0,"Type":"Video","Codec":"hevc","CodecTag":"\(codecTag)","BitDepth":10}]
        }]}
        """
    }

    private func mediaSource(url: String) throws -> MediaSourceInfo {
        try JSONDecoder().decode(MediaSourceInfo.self, from: JSONSerialization.data(withJSONObject: [
            "TranscodingUrl": url, "Bitrate": 30_000_000
        ]))
    }
}

private actor NegotiationGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor NegotiationHTTP: HTTPClient {
    nonisolated let decisionRequested = XCTestExpectation(description: "Playback decision requested")
    nonisolated let detailRequested = XCTestExpectation(description: "Item detail requested")
    nonisolated let detailGate = NegotiationGate()
    private let detailError: AppError?
    private(set) var releasedSessions: [String] = []

    init(detailError: AppError? = nil) {
        self.detailError = detailError
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let json: String
        switch endpoint.path {
        case "/Items/movie/PlaybackInfo":
            decisionRequested.fulfill()
            json = """
            {"PlaySessionId":"owned","MediaSources":[{
              "Id":"version","Container":"mp4","Bitrate":30000000,
              "TranscodingUrl":"/Videos/movie/master.m3u8?VideoCodec=h264"
            }]}
            """
        case "/Users/user/Items/movie":
            detailRequested.fulfill()
            await detailGate.wait()
            if let detailError { throw detailError }
            json = #"{"Id":"movie","Name":"Movie","Type":"Movie"}"#
        case "/Videos/ActiveEncodings":
            try Task.checkCancellation()
            XCTAssertEqual(endpoint.method, .delete)
            XCTAssertEqual(endpoint.queryItems.first { $0.name == "deviceId" }?.value, "device")
            releasedSessions.append(try XCTUnwrap(
                endpoint.queryItems.first { $0.name == "playSessionId" }?.value
            ))
            json = "{}"
        default:
            throw AppError.notFound
        }
        return (Data(json.utf8), HTTPURLResponse(
            url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil
        )!)
    }
}
