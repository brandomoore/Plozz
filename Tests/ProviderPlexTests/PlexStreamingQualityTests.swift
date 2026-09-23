import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderPlex

final class PlexStreamingQualityTests: XCTestCase {
    func testCustom1080pAt2000KbpsKeepsDecisionAndPlaybackLimitsIdentical() async throws {
        let quality = try StreamingQuality.custom(maximumHeight: 1080, bitrateKbps: 2_000)
        let supportsHEVC = MediaCapabilities.detected().allowedDirectPlayVideoCodecs.contains(.hevc)
        for codec in StreamingCodecPreference.allCases {
            let http = StubHTTPClient()
            let decision = """
            {"MediaContainer":{"transcodeDecisionCode":1001,"Metadata":[{"Media":[{
              "container":"mp4","videoCodec":"\(codec == .preferHEVC && supportsHEVC ? "hevc" : "h264")"
            }]}]}}
            """
            let provider = fixture(decision: decision, http: http)
            let request = try await provider.playbackInfo(
                for: "movie", mediaSourceID: "7", forceTranscode: false,
                streaming: .init(quality: quality, codec: codec)
            )
            let source = try locator(request)
            let query = source.resource.queryItems.map { URLQueryItem(name: $0.name, value: $0.value) }
            let decisionQuery = try XCTUnwrap(http.queryItems(forPathSuffix: "/decision"))
            for items in [query, decisionQuery] {
                XCTAssertEqual(items.first { $0.name == "maxVideoBitrate" }?.value, "1872")
                XCTAssertEqual(items.first { $0.name == "audioBitrate" }?.value, "128")
                XCTAssertEqual(items.first { $0.name == "videoResolution" }?.value, "1920x1080")
                XCTAssertEqual(items.first { $0.name == "directPlay" }?.value, "0")
                XCTAssertEqual(items.first { $0.name == "directStream" }?.value, "0")
                let profile = try XCTUnwrap(items.first { $0.name == "X-Plex-Client-Profile-Extra" }?.value)
                XCTAssertTrue(profile.contains("type=upperBound&name=video.width&value=1920&"))
                XCTAssertTrue(profile.contains("type=upperBound&name=video.height&value=1080&"))
                XCTAssertTrue(profile.contains("type=upperBound&name=video.bitrate&value=1872&"))
                let codecs = codec.codecs(supportsHEVC: supportsHEVC).joined(separator: "%2C")
                XCTAssertTrue(profile.contains("videoCodec=\(codecs)&"))
            }
            XCTAssertEqual(request.streamingOptions?.quality, quality)
            XCTAssertEqual(request.streamingOptions?.codec, codec)
            XCTAssertEqual(source.mediaSourceID, "7")
            XCTAssertNil(request.localRemuxSource)
            XCTAssertNil(request.originalFileSource)
            XCTAssertTrue(request.isTranscoding)
        }
    }

    func testCustomCeilingRetainsSmallerPlexOriginalWithoutNegotiationOrUpscaling() async throws {
        let quality = try StreamingQuality.custom(maximumHeight: 1080, bitrateKbps: 2_000)
        let http = StubHTTPClient()
        let request = try await fixture(bitrate: 1_500, width: 1280, height: 720, http: http).playbackInfo(
            for: "movie", mediaSourceID: "7", forceTranscode: false,
            streaming: .init(quality: quality, codec: .preferHEVC)
        )
        XCTAssertFalse(request.isTranscoding)
        XCTAssertEqual(try locator(request).deliveryMode, .directFile)
        XCTAssertFalse(http.sentPaths.contains { $0.hasSuffix("/decision") })
        XCTAssertEqual(request.streamingOptions?.quality, quality)
    }

    func testInvalidSavedCustomLimitStopsPlexBeforeNetworkIO() async {
        let http = StubHTTPClient()
        do {
            _ = try await fixture(http: http).playbackInfo(
                for: "movie", mediaSourceID: "7", forceTranscode: false,
                streaming: .init(quality: .invalid(.bitrateTooHigh))
            )
            XCTFail("An invalid custom limit must not turn into unrestricted playback")
        } catch {
            XCTAssertEqual(error as? StreamingQualityError, .invalidQuality(.bitrateTooHigh))
        }
        XCTAssertTrue(http.sentPaths.isEmpty)
    }

    func testCustomMinimumAndMaximumProviderBudgetsAreNotRoundedOrSilentlyCapped() throws {
        let client = PlexClient(
            baseURL: URL(string: "https://fixture.test")!,
            deviceProfile: .init(clientIdentifier: "fixture"), token: "fixture",
            http: StubHTTPClient()
        )
        for bitrate in [129, CustomStreamingQuality.maximumBitrateKbps] {
            let quality = try StreamingQuality.custom(maximumHeight: 2160, bitrateKbps: bitrate)
            let url = try XCTUnwrap(client.transcodeURL(
                ratingKey: "movie", sessionID: "fixture", streaming: .init(quality: quality)
            ))
            let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(query.first { $0.name == "maxVideoBitrate" }?.value, String(bitrate - 128))
            XCTAssertEqual(query.first { $0.name == "audioBitrate" }?.value, "128")
            XCTAssertEqual(query.first { $0.name == "videoResolution" }?.value, "3840x2160")
        }
    }

    func testHEVCOnlyDecisionRejectsAnUnchangedH264Output() throws {
        let decision = try JSONDecoder().decode(PlexStreamingDecisionResponse.self, from: Data(
            #"{"MediaContainer":{"transcodeDecisionCode":1001,"Metadata":[{"Media":[{"container":"mp4","videoCodec":"h264"}]}]}}"#.utf8
        )).MediaContainer
        XCTAssertThrowsError(try decision.validate(
            options: .init(quality: .hd720, codec: .preferHEVC), supportsHEVC: true
        )) { XCTAssertEqual($0 as? StreamingQualityError, .codecUnavailable(.hevc)) }
        XCTAssertEqual(try decision.validate(options: .init(quality: .hd720), supportsHEVC: true), .h264)
        let hevc = try JSONDecoder().decode(PlexStreamingDecisionResponse.self, from: Data(
            #"{"MediaContainer":{"transcodeDecisionCode":1001,"Metadata":[{"Media":[{"container":"mp4","videoCodec":"hevc"}]}]}}"#.utf8
        )).MediaContainer
        XCTAssertEqual(try hevc.validate(
            options: .init(quality: .hd720, codec: .preferHEVC), supportsHEVC: true
        ), .hevc)
    }

    func testDecisionDoesNotDecodeUnrelatedLibraryMetadata() async throws {
        let decision = """
        {"MediaContainer":{
          "generalDecisionCode":1001,"transcodeDecisionCode":1001,
          "Metadata":[{
            "ratingKey":"movie","librarySectionID":"1","year":"1997",
            "Media":[{
              "id":"7","container":"mp4","videoCodec":"h264",
              "Part":[{"id":"8","duration":"7654000","size":"24200000000",
                       "Stream":[{"streamType":"1","selected":1}]}]
            }]
          }]
        }}
        """
        let request = try await fixture(decision: decision).playbackInfo(
            for: "movie", mediaSourceID: "7", forceTranscode: false,
            streaming: .init(quality: .low)
        )
        XCTAssertTrue(request.isTranscoding)
        XCTAssertEqual(try locator(request).mediaSourceID, "7")
        XCTAssertEqual(request.streamingOptions?.quality, .low)
    }

    private func fixture(
        bitrate: Int? = 30_000, width: Int = 3840, height: Int = 2160,
        decision: String? = nil, status: Int = 200, http: StubHTTPClient = StubHTTPClient()
    ) -> PlexProvider {
        http.stub(pathSuffix: "/video/:/transcode/universal/decision", json: decision ?? """
        {"MediaContainer":{"generalDecisionCode":1001,"transcodeDecisionCode":1001,
          "Metadata":[{"Media":[{"container":"mp4","videoCodec":"h264","width":426,"height":240}]}]}}
        """, status: status)
        http.stub(pathSuffix: "/video/:/transcode/universal/stop", json: "{}")
        http.stub(pathSuffix: "/library/metadata/movie", json: """
        {"MediaContainer":{"Metadata":[{"ratingKey":"movie","title":"Movie","type":"movie","Media":[
          {"id":7,"container":"mp4","videoCodec":"h264","audioCodec":"aac",
           "bitrate":\(bitrate.map(String.init) ?? "null"),"width":\(width),"height":\(height),
           "Part":[{"id":8,"key":"/library/parts/8/file.mp4","Stream":[
             {"id":2,"streamType":2,"codec":"aac","languageCode":"eng","default":true}]}]}]}]}}
        """)
        return PlexProvider(session: .init(
            server: .init(id: "plex", name: "Plex", baseURL: URL(string: "https://plex.example.test")!, provider: .plex),
            userID: "user", userName: "User", deviceID: "device", accessToken: "fixture"
        ), http: http)
    }

    private func locator(_ request: PlaybackRequest) throws -> AuthenticatedHTTPPlaybackLocator {
        guard case let .authenticatedHTTP(locator) = request.playbackSource else {
            XCTFail("Expected credential-free HTTP playback")
            throw AppError.invalidResponse
        }
        return locator
    }

    func testCellularRequestConstrainsBitrateResolutionAndPreventsOriginalFallback() async throws {
        let http = StubHTTPClient()
        let request = try await fixture(http: http).playbackInfo(
            for: "movie", mediaSourceID: "7", forceTranscode: false,
            streaming: .init(quality: .hd720, codec: .automatic)
        )
        let source = try locator(request)
        let query = Dictionary(source.resource.queryItems.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(source.mediaSourceID, "7")
        XCTAssertEqual(query["maxVideoBitrate"], "1872")
        XCTAssertEqual(query["audioBitrate"], "128")
        XCTAssertEqual(query["videoResolution"], "1280x720")
        XCTAssertEqual(query["directStream"], "0")
        XCTAssertEqual(query["directPlay"], "0")
        XCTAssertEqual(query["autoAdjustQuality"], "0")
        XCTAssertEqual(query["hasMDE"], "1")
        XCTAssertEqual(query["X-Plex-Client-Profile-Name"], "Generic")
        XCTAssertEqual(query["transcodeSessionId"], request.streamingSessionID)
        let profile = source.resource.queryItems.first { $0.name == "X-Plex-Client-Profile-Extra" }?.value
        let decisionQuery = try XCTUnwrap(http.queryItems(forPathSuffix: "/decision"))
        XCTAssertEqual(decisionQuery.first { $0.name == "session" }?.value, request.streamingSessionID)
        XCTAssertEqual(decisionQuery.first { $0.name == "X-Plex-Client-Profile-Extra" }?.value,
                       profile)
        XCTAssertTrue(request.isTranscoding)
        XCTAssertNil(request.localRemuxSource)
        XCTAssertNil(request.originalFileSource)
        XCTAssertNotNil(request.streamingSessionID)
        XCTAssertEqual(request.streamingOptions?.quality, .hd720)
        XCTAssertEqual(request.negotiatedStreamingVideoCodec, .h264,
                       "The response, not the original file or client codec list, identifies the selected codec")
    }

    func testAlreadySmallOriginalDoesNotNeedAConversion() async throws {
        let request = try await fixture(bitrate: 1_500, width: 1280, height: 720).playbackInfo(
            for: "movie", mediaSourceID: "7", forceTranscode: false, streaming: .init(quality: .hd720)
        )
        XCTAssertFalse(request.isTranscoding)
        XCTAssertEqual(try locator(request).deliveryMode, .directFile)
    }

    func testUnknownBitrateCannotBypassTheLimitAndForceConversionAlsoWorksAtMaximum() async throws {
        for options in [StreamingPlaybackOptions(quality: .hd720), .init(quality: .original, forceTranscoding: true)] {
            let request = try await fixture(bitrate: nil, width: 1280, height: 720).playbackInfo(
                for: "movie", mediaSourceID: "7", forceTranscode: false, streaming: options
            )
            XCTAssertTrue(request.isTranscoding)
        }
    }

    func testMissingSelectedVersionFailsInsteadOfPlayingAnotherFile() async {
        do {
            _ = try await fixture().playbackInfo(
                for: "movie", mediaSourceID: "missing", forceTranscode: false, streaming: .init(quality: .hd720)
            )
            XCTFail("Must not replace the explicitly chosen version")
        } catch is StreamingQualityError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCodecAttemptsKeepTheSameBudgetAndUseUniqueSessions() async throws {
        let provider = fixture()
        let first = try await provider.playbackInfo(
            for: "movie", mediaSourceID: "7", forceTranscode: false,
            streaming: .init(quality: .sd480, codec: .automatic)
        )
        let second = try await provider.playbackInfo(
            for: "movie", mediaSourceID: "7", forceTranscode: false,
            streaming: .init(quality: .sd480, codec: .preferH264)
        )
        XCTAssertNotEqual(first.streamingSessionID, second.streamingSessionID)
        let query = try locator(second).resource.queryItems
        XCTAssertEqual(query.first { $0.name == "maxVideoBitrate" }?.value, "872")
        XCTAssertTrue(query.first { $0.name == "X-Plex-Client-Profile-Extra" }?.value?.contains("videoCodec=h264&") == true)
        XCTAssertTrue(query.first { $0.name == "X-Plex-Client-Profile-Extra" }?.value?.contains("container=mpegts&") == true)
    }

    func testRejectedDecisionsNeverPublishAStreamAndReleaseOnlyTheOwnedSession() async {
        for (body, status, expected) in [
            (#"{"MediaContainer":{"transcodeDecisionCode":4005,"transcodeDecisionText":"private server details"}}"#, 200, StreamingQualityError.plexDecision(4005)),
            (#"{"MediaContainer":{"generalDecisionCode":"1001","transcodeDecisionCode":"4005","Metadata":[{"librarySectionID":"1","Media":[{"container":"mp4","videoCodec":"h264","Part":[{"size":"24200000000"}]}]}]}}"#, 200, .plexDecision(4005)),
            (#"{"MediaContainer":{"transcodeDecisionCode":1000}}"#, 200, .noCompatibleStream),
            (#"{"MediaContainer":{"transcodeDecisionCode":1001,"Metadata":[{"Media":[{"container":"mpegts","videoCodec":"hevc"}]}]}}"#, 200, .noCompatibleStream),
            (#"{"MediaContainer":{"transcodeDecisionCode":1001,"Metadata":[{"Media":[{"container":42,"videoCodec":"h264"}]}]}}"#, 200, .malformedResponse),
            (#"{"MediaContainer":{"transcodeDecisionCode":1001,"Metadata":[{"Media":[{"container":"mp4","videoCodec":false}]}]}}"#, 200, .malformedResponse),
            ("not-json", 200, .malformedResponse),
            ("private error", 403, .permissionDenied),
            ("private error", 503, .serverHTTP(503))
        ] {
            let http = StubHTTPClient()
            do {
                _ = try await fixture(decision: body, status: status, http: http).playbackInfo(
                    for: "movie", mediaSourceID: "7", forceTranscode: false,
                    streaming: .init(quality: .low)
                )
                XCTFail("A refused or incompatible decision cannot be handed to the player")
            } catch let error as StreamingQualityError { XCTAssertEqual(error, expected) }
            catch { XCTFail("Unexpected error: \(error)") }
            let decisionID = http.queryItems(forPathSuffix: "/decision")?.first { $0.name == "session" }?.value
            let stoppedID = http.queryItems(forPathSuffix: "/stop")?.first { $0.name == "session" }?.value
            XCTAssertNotNil(decisionID)
            XCTAssertEqual(decisionID, stoppedID)
        }
    }

    func testOriginalPlaybackDoesNotNegotiateATranscode() async throws {
        for preference in StreamingCodecPreference.allCases {
            let http = StubHTTPClient()
            let request = try await fixture(bitrate: 1_000, width: 640, height: 360, http: http).playbackInfo(
                for: "movie", mediaSourceID: "7", forceTranscode: false,
                streaming: .init(quality: .original, codec: preference)
            )
            XCTAssertFalse(request.isTranscoding)
            XCTAssertFalse(http.sentPaths.contains { $0.hasSuffix("/decision") })
        }
    }

    func testCodecListsAreEncodedForBothNestedQueryLayers() throws {
        let client = PlexClient(
            baseURL: URL(string: "https://fixture.test")!,
            deviceProfile: .init(clientIdentifier: "fixture"), token: "fixture",
            http: StubHTTPClient(), capabilities: .init(supportsHEVC: true)
        )
        let url = try XCTUnwrap(client.transcodeURL(
            ratingKey: "movie", sessionID: "fixture", streaming: .init(quality: .low, codec: .automatic)
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let profile = try XCTUnwrap(components.queryItems?.first { $0.name == "X-Plex-Client-Profile-Extra" }?.value)
        XCTAssertTrue(profile.contains("videoCodec=hevc%2Ch264&"))
        XCTAssertTrue(url.absoluteString.contains("hevc%252Ch264"))
        XCTAssertTrue(profile.contains("container=mp4&"))
        XCTAssertTrue(profile.contains("video.bitrate&value=372&"))
    }

    func testHEVCPreferenceRequestsHEVCOnlyWhileAutomaticAllowsBoth() throws {
        for capable in [true, false] {
            let client = PlexClient(
                baseURL: URL(string: "https://fixture.test")!,
                deviceProfile: .init(clientIdentifier: "fixture"), token: "fixture",
                http: StubHTTPClient(), capabilities: .init(supportsHEVC: capable)
            )
            for (preference, capableCodecs) in [
                (StreamingCodecPreference.automatic, "hevc%2Ch264"),
                (.preferHEVC, "hevc"), (.preferH264, "h264")
            ] {
                let url = try XCTUnwrap(client.transcodeURL(
                    ratingKey: "movie", sessionID: "fixture",
                    streaming: .init(quality: .hd720, codec: preference)
                ))
                let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
                let profile = try XCTUnwrap(query.first { $0.name == "X-Plex-Client-Profile-Extra" }?.value)
                XCTAssertTrue(profile.contains("videoCodec=\(capable ? capableCodecs : "h264")&"), profile)
                XCTAssertEqual(query.first { $0.name == "maxVideoBitrate" }?.value, "1872")
                XCTAssertEqual(query.first { $0.name == "videoResolution" }?.value, "1280x720")
                XCTAssertEqual(query.first { $0.name == "path" }?.value, "/library/metadata/movie")
                XCTAssertEqual(query.first { $0.name == "session" }?.value, "fixture")
            }
        }
    }
}
