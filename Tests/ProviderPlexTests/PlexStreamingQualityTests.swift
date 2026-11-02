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
                XCTAssertEqual(items.first { $0.name == "audioChannelCount" }?.value, "2")
                XCTAssertNil(items.first { $0.name == "audioChannels" })
                XCTAssertEqual(items.first { $0.name == "videoResolution" }?.value, "1920x1080")
                XCTAssertEqual(items.first { $0.name == "directPlay" }?.value, "0")
                XCTAssertEqual(items.first { $0.name == "directStream" }?.value, "0")
                let profile = try XCTUnwrap(items.first { $0.name == "X-Plex-Client-Profile-Extra" }?.value)
                XCTAssertTrue(profile.contains("type=upperBound&name=video.width&value=1920&"))
                XCTAssertTrue(profile.contains("type=upperBound&name=video.height&value=1080&"))
                XCTAssertTrue(profile.contains("type=upperBound&name=video.bitrate&value=1872&"))
                XCTAssertTrue(profile.contains("scope=videoAudioCodec&scopeName=*&type=upperBound&name=audio.bitrate&value=128&"))
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
        decision: String? = nil, status: Int = 200, http: StubHTTPClient = StubHTTPClient(),
        container: String = "mp4", videoCodec: String = "h264", audioCodec: String = "aac",
        streams: String = #"{"id":2,"streamType":2,"codec":"aac","languageCode":"eng","default":true}"#,
        partID: Int? = 8,
        transport: (any HTTPClient)? = nil
    ) -> PlexProvider {
        http.stub(pathSuffix: "/video/:/transcode/universal/decision", json: decision ?? """
        {"MediaContainer":{"generalDecisionCode":1001,"transcodeDecisionCode":1001,
          "Metadata":[{"Media":[{"container":"mp4","videoCodec":"h264","width":426,"height":240}]}]}}
        """, status: status)
        http.stub(pathSuffix: "/video/:/transcode/universal/stop", json: "{}")
        http.stub(pathSuffix: "/library/parts/8", json: "", status: 204)
        http.stub(pathSuffix: "/library/metadata/movie", json: """
        {"MediaContainer":{"Metadata":[{"ratingKey":"movie","title":"Movie","type":"movie","Media":[
          {"id":7,"container":"\(container)","videoCodec":"\(videoCodec)","audioCodec":"\(audioCodec)",
           "bitrate":\(bitrate.map(String.init) ?? "null"),"width":\(width),"height":\(height),
           "Part":[{"id":\(partID.map(String.init) ?? "null"),"key":"/library/parts/8/file.mp4","Stream":[\(streams)]}]}]}]}}
        """)
        return PlexProvider(session: .init(
            server: .init(id: "plex", name: "Plex", baseURL: URL(string: "https://plex.example.test")!, provider: .plex),
            userID: "user", userName: "User", deviceID: "device", accessToken: "fixture"
        ), http: transport ?? http)
    }

    private func locator(_ request: PlaybackRequest) throws -> AuthenticatedHTTPPlaybackLocator {
        guard case let .authenticatedHTTP(locator) = request.playbackSource else {
            XCTFail("Expected credential-free HTTP playback")
            throw AppError.invalidResponse
        }
        return locator
    }

    func testAudioSwitchPersistsTheServerStreamBeforeEachTranscodeDecision() async throws {
        let http = StubHTTPClient()
        let provider = fixture(http: http, streams: """
        {"id":101,"index":1,"streamType":2,"codec":"aac","languageTag":"rus","selected":true},
        {"id":202,"index":2,"streamType":2,"codec":"aac","languageTag":"eng"}
        """)
        var sessions = Set<String>()
        for (index, language, streamID) in [(1, "rus", 101), (2, "eng", 202), (1, "rus", 101)] {
            var options = StreamingPlaybackOptions(quality: .hd720, codec: .preferH264)
            options.audioTrack = .init(id: index, kind: .audio, displayTitle: language, language: language)
            let request = try await provider.playbackInfo(
                for: "movie", mediaSourceID: "7", forceTranscode: false, streaming: options
            )
            XCTAssertEqual(Array(http.sentPaths.suffix(3)), [
                "/library/metadata/movie", "/library/parts/8", "/video/:/transcode/universal/decision"
            ])
            XCTAssertEqual(http.method(forPathSuffix: "/library/parts/8"), .put)
            let selection = try XCTUnwrap(http.queryItems(forPathSuffix: "/library/parts/8"))
            XCTAssertEqual(selection.first { $0.name == "audioStreamID" }?.value, String(streamID))
            XCTAssertEqual(selection.first { $0.name == "allParts" }?.value, "1")
            XCTAssertFalse(selection.contains { $0.name == "subtitleStreamID" })
            let selectionIndex = try XCTUnwrap(http.sentPaths.lastIndex(of: "/library/parts/8"))
            XCTAssertEqual(http.sentHeaders[selectionIndex]["X-Plex-Token"], "fixture")
            XCTAssertEqual(http.sentHeaders[selectionIndex]["X-Plex-Client-Identifier"], "device")
            let decision = try XCTUnwrap(http.queryItems(forPathSuffix: "/decision"))
            XCTAssertEqual(decision.first { $0.name == "audioStreamID" }?.value, String(streamID))
            XCTAssertEqual(try locator(request).resource.queryItems.first { $0.name == "audioStreamID" }?.value,
                           String(streamID))
            XCTAssertEqual(request.streamingOptions?.audioTrack?.id, index)
            XCTAssertEqual(request.streamingOptions?.quality, .hd720)
            XCTAssertTrue(sessions.insert(try XCTUnwrap(request.streamingSessionID)).inserted)
        }
    }

    func testAudioSelectionUsesTheChosenVersionsPartAndDatabaseStreamID() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/metadata/movie", json: """
        {"MediaContainer":{"Metadata":[{"ratingKey":"movie","title":"Movie","type":"movie","Media":[
          {"id":7,"container":"mp4","videoCodec":"h264","audioCodec":"aac","bitrate":30000,
           "Part":[{"id":8,"key":"/library/parts/8/file.mp4","Stream":[
             {"id":101,"index":1,"streamType":2,"codec":"aac","languageCode":"eng"}]}]},
          {"id":9,"container":"mp4","videoCodec":"h264","audioCodec":"aac","bitrate":30000,
           "Part":[{"id":10,"key":"/library/parts/10/file.mp4","Stream":[
             {"id":303,"index":1,"streamType":2,"codec":"aac","languageCode":"eng"}]}]}
        ]}]}}
        """)
        http.stub(pathSuffix: "/library/parts/10", json: "")
        let request = try await fixture(http: http).playbackInfo(
            for: "movie", mediaSourceID: "9", forceTranscode: false,
            streaming: .init(quality: .hd720)
        )
        XCTAssertFalse(http.sentPaths.contains("/library/parts/8"))
        XCTAssertEqual(http.queryItems(forPathSuffix: "/library/parts/10")?.first { $0.name == "audioStreamID" }?.value,
                       "303")
        XCTAssertEqual(http.queryItems(forPathSuffix: "/decision")?.first { $0.name == "mediaIndex" }?.value, "1")
        XCTAssertEqual(try locator(request).mediaSourceID, "9")
        XCTAssertEqual(request.streamingOptions?.audioTrack?.id, 1)
    }

    func testInitialTranscodePersistsTheResolvedAudioSelection() async throws {
        let http = StubHTTPClient()
        let provider = fixture(http: http, streams: """
        {"id":101,"index":1,"streamType":2,"codec":"aac","languageTag":"rus","default":true},
        {"id":202,"index":2,"streamType":2,"codec":"aac","languageTag":"eng"}
        """)
        let request = try await provider.playbackInfo(
            for: "movie", mediaSourceID: "7", forceTranscode: false,
            streaming: .init(quality: .hd720)
        )
        XCTAssertEqual(http.queryItems(forPathSuffix: "/library/parts/8")?.first { $0.name == "audioStreamID" }?.value,
                       "101")
        XCTAssertEqual(request.streamingOptions?.audioTrack?.id, 1)
    }

    func testDirectPlaybackDoesNotWriteServerAudioSelection() async throws {
        let http = StubHTTPClient()
        var options = StreamingPlaybackOptions(quality: .original)
        options.audioTrack = .init(id: 2, kind: .audio, displayTitle: "English", language: "eng")
        let request = try await fixture(http: http, streams: """
        {"id":101,"index":1,"streamType":2,"codec":"aac","languageTag":"rus","default":true},
        {"id":202,"index":2,"streamType":2,"codec":"aac","languageTag":"eng"}
        """).playbackInfo(for: "movie", mediaSourceID: "7", forceTranscode: false, streaming: options)
        XCTAssertFalse(request.isTranscoding)
        XCTAssertEqual(request.streamingOptions?.audioTrack?.id, 2)
        XCTAssertEqual(http.sentPaths, ["/library/metadata/movie"])
    }

    func testFailedAudioSelectionDoesNotNegotiateOrPublishTheWrongTrack() async {
        for (status, error) in [(401, AppError.unauthorized), (404, .notFound), (500, .invalidResponse)] {
            let http = StubHTTPClient()
            http.stub(pathSuffix: "/library/parts/8", json: "", status: status)
            do {
                _ = try await fixture(http: http).playbackInfo(
                    for: "movie", mediaSourceID: "7", forceTranscode: false,
                    streaming: .init(quality: .hd720)
                )
                XCTFail("An audio selection failure must not publish the default soundtrack")
            } catch let actual as AppError {
                XCTAssertEqual(actual, error)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(http.sentPaths.contains { $0.hasSuffix("/decision") || $0.hasSuffix("/stop") })
        }
    }

    func testTranscodeAudioSelectionRejectsMissingNativeIdentifiers() async {
        for (partID, streamID) in [(nil, 101), (0, 101), (8, nil), (8, 0)] as [(Int?, Int?)] {
            let http = StubHTTPClient()
            do {
                _ = try await fixture(http: http, streams: """
                {"id":\(streamID.map(String.init) ?? "null"),"index":1,"streamType":2,"codec":"aac","default":true}
                """, partID: partID).playbackInfo(
                    for: "movie", mediaSourceID: "7", forceTranscode: false,
                    streaming: .init(quality: .hd720)
                )
                XCTFail("A container index must never replace a missing Plex database identifier")
            } catch {
                XCTAssertEqual(error as? StreamingQualityError, .sourceUnavailable)
            }
            XCTAssertEqual(http.sentPaths, ["/library/metadata/movie"])
        }
    }

    func testCancellationAfterAudioSelectionDoesNotStartANewRendition() async {
        let http = StubHTTPClient()
        let provider = fixture(
            http: http, transport: CancellationCheckingHTTPClient(stub: http, cancelAfterAudioSelection: true)
        )
        let attempt = Task {
            try await provider.playbackInfo(
                for: "movie", mediaSourceID: "7", forceTranscode: false,
                streaming: .init(quality: .hd720)
            )
        }
        do {
            _ = try await attempt.value
            XCTFail("Cancellation must not publish a rendition")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(http.sentPaths, ["/library/metadata/movie", "/library/parts/8"])
    }

    func testCompatibilityDeliveryAllowsCopyWithoutRelaxingQualityOrChangingTheSession() async throws {
        for quality in [StreamingQuality.original, .hd720] {
            for audioDecision in ["copy", "transcode"] {
                let http = StubHTTPClient()
                let decision = """
                {"MediaContainer":{"transcodeDecisionCode":1001,"Metadata":[{"Media":[{
                  "container":"mp4","videoCodec":"h264","audioCodec":"aac",
                  "Part":[{"Stream":[
                    {"streamType":1,"codec":"h264","decision":"copy"},
                    {"streamType":2,"codec":"aac","decision":"\(audioDecision)"}
                  ]}]
                }]}]}}
                """
                let request = try await fixture(
                    bitrate: 1_500, width: 1280, height: 720, decision: decision, http: http,
                    container: "avi", audioCodec: audioDecision == "copy" ? "aac" : "dts",
                    streams: #"{"id":2,"streamType":2,"codec":"\#(audioDecision == "copy" ? "aac" : "dts")","default":true}"#
                ).playbackInfo(
                    for: "movie", mediaSourceID: "7", forceTranscode: false,
                    streaming: .init(quality: quality, codec: .preferHEVC)
                )
                let source = try locator(request)
                let query = source.resource.queryItems
                let negotiated = try XCTUnwrap(http.queryItems(forPathSuffix: "/decision"))
                XCTAssertEqual(query.first { $0.name == "directStream" }?.value, "1")
                XCTAssertEqual(query.first { $0.name == "directStreamAudio" }?.value, audioDecision == "copy" ? "1" : "0")
                let profile = try XCTUnwrap(query.first { $0.name == "X-Plex-Client-Profile-Extra" }?.value)
                if audioDecision == "copy" {
                    XCTAssertNil(query.first { $0.name == "audioChannelCount" },
                                 "An already-under-limit copy must not be downmixed")
                    XCTAssertFalse(profile.contains("name=audio.bitrate"))
                } else if quality != .original {
                    XCTAssertEqual(query.first { $0.name == "audioChannelCount" }?.value, "2")
                    XCTAssertTrue(profile.contains("name=audio.bitrate&value=128&"))
                }
                for name in ["directStream", "directStreamAudio", "maxVideoBitrate", "videoResolution"] {
                    XCTAssertEqual(query.first { $0.name == name }?.value,
                                   negotiated.first { $0.name == name }?.value)
                }
                XCTAssertEqual(source.playSessionID, negotiated.first { $0.name == "session" }?.value)
                XCTAssertEqual(source.playSessionID, request.streamingSessionID)
                XCTAssertEqual(request.playSessionID, source.playSessionID)
                XCTAssertEqual(request.deliveryMode, audioDecision == "copy" ? .remux : .transcode)
                XCTAssertEqual(source.deliveryMode, audioDecision == "copy" ? .serverRemux : .serverTranscode)
                XCTAssertEqual(request.negotiatedStreamingVideoCodec, .h264,
                               "Transcoding codec preference must not reject compatible copied video")
                XCTAssertEqual(request.streamingOptions?.quality, quality)
                XCTAssertTrue(request.isTranscoding, "Server HLS still uses the native engine")
                XCTAssertNil(request.originalFileSource, "Do not introduce an uncapped playback fallback")
                XCTAssertNotNil(request.streamingSessionID)
            }
        }
    }

    func testForcedOrOversizedCompatibilityDeliveryStillDisablesStreamCopy() async throws {
        for (quality, forced, bitrate) in [
            (StreamingQuality.original, true, 1_500),
            (.hd720, false, 30_000)
        ] {
            let request = try await fixture(
                bitrate: bitrate, width: 1280, height: 720, container: "avi"
            ).playbackInfo(
                for: "movie", mediaSourceID: "7", forceTranscode: forced,
                streaming: .init(quality: quality)
            )
            let query = try locator(request).resource.queryItems
            XCTAssertEqual(query.first { $0.name == "directStream" }?.value, "0")
            XCTAssertEqual(query.first { $0.name == "directStreamAudio" }?.value, "0")
        }
    }

    func testBitmapBurnInReservesBoundedAudioInsteadOfCopyingBeyondTheTotalBudget() async throws {
        for quality in [StreamingQuality.original, .hd720] {
            let http = StubHTTPClient()
            let bounded = quality != .original
            let decision = """
            {"MediaContainer":{"transcodeDecisionCode":1001,"Metadata":[{"Media":[{
              "container":"mp4","videoCodec":"h264","audioCodec":"\(bounded ? "aac" : "eac3")",
              "Part":[{"Stream":[
                {"streamType":1,"codec":"h264","decision":"transcode"},
                {"streamType":2,"codec":"\(bounded ? "aac" : "eac3")","decision":"\(bounded ? "transcode" : "copy")"}
              ]}]
            }]}]}}
            """
            let request = try await fixture(
                bitrate: 1_500, width: 1280, height: 720, decision: decision, http: http,
                container: "avi", audioCodec: "eac3", streams: """
                {"id":101,"index":1,"streamType":2,"codec":"eac3","bitrate":640,"channels":6,"default":true},
                {"id":103,"index":3,"streamType":3,"codec":"pgs","default":true}
                """
            ).playbackInfo(
                for: "movie", mediaSourceID: "7", forceTranscode: false,
                streaming: .init(quality: quality, codec: .preferH264)
            )
            let playback = try locator(request).resource.queryItems.map {
                URLQueryItem(name: $0.name, value: $0.value)
            }
            let decisionQuery = try XCTUnwrap(http.queryItems(forPathSuffix: "/decision"))
            for query in [playback, decisionQuery] {
                XCTAssertEqual(query.first { $0.name == "directStream" }?.value, "0")
                XCTAssertEqual(query.first { $0.name == "directStreamAudio" }?.value, bounded ? "0" : "1")
                XCTAssertEqual(query.first { $0.name == "audioChannelCount" }?.value, bounded ? "2" : nil)
                XCTAssertEqual(query.first { $0.name == "subtitles" }?.value, "burn")
                let profile = try XCTUnwrap(query.first { $0.name == "X-Plex-Client-Profile-Extra" }?.value)
                XCTAssertEqual(profile.contains("name=audio.bitrate&value=128&"), bounded)
            }
            XCTAssertEqual(request.streamingOptions?.quality, quality)
            XCTAssertEqual(request.streamingOptions?.subtitleTrack?.id, 3)
            XCTAssertEqual(request.deliveryMode, .transcode)
        }
    }

    func testCopiedDecisionCannotEscapeALimitOrSendUnsupportedNativeAudio() throws {
        for audioCodec in ["aac", "dts", "truehd"] {
            let response = """
            {"MediaContainer":{"transcodeDecisionCode":1001,"Metadata":[{"Media":[{
              "container":"mp4","videoCodec":"h264","Part":[{"Stream":[
                {"streamType":1,"decision":"copy"},
                {"streamType":2,"codec":"\(audioCodec)","decision":"copy"}
              ]}]
            }]}]}}
            """
            let decision = try JSONDecoder().decode(PlexStreamingDecisionResponse.self, from: Data(response.utf8)).MediaContainer
            XCTAssertThrowsError(try decision.validate(options: .init(quality: .hd720), supportsHEVC: true))
            XCTAssertThrowsError(try decision.validate(
                options: .init(quality: .hd720), supportsHEVC: true, allowsStreamCopy: true
            ), "Copied audio must not evade the requested audio conversion")
            if audioCodec == "aac" {
                XCTAssertEqual(try decision.validate(
                    options: .init(quality: .original), supportsHEVC: true,
                    allowsStreamCopy: true, allowsAudioStreamCopy: true
                ), .h264)
            } else {
                XCTAssertThrowsError(try decision.validate(
                    options: .init(quality: .original), supportsHEVC: true,
                    allowsStreamCopy: true, allowsAudioStreamCopy: true
                ))
            }
        }
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
        XCTAssertTrue(query.first { $0.name == "X-Plex-Client-Profile-Extra" }?.value?.contains("container=mp4&") == true)
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

    func testCanceledDecisionReleasesItsOwnedSessionBeforeReturning() async {
        let http = StubHTTPClient()
        let provider = fixture(
            http: http,
            transport: CancellationCheckingHTTPClient(stub: http, cancelAfterDecision: true)
        )
        let attempt = Task {
            try await provider.playbackInfo(
                for: "movie", mediaSourceID: "7", forceTranscode: false,
                streaming: .init(quality: .hd720)
            )
        }
        do {
            _ = try await attempt.value
            XCTFail("Cancellation must not publish a rendition")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let decisionID = http.queryItems(forPathSuffix: "/decision")?.first { $0.name == "session" }?.value
        XCTAssertNotNil(decisionID)
        XCTAssertEqual(http.queryItems(forPathSuffix: "/stop")?.first { $0.name == "session" }?.value, decisionID)
        XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/stop") }.count, 1)
    }

    func testMaintenancePingsEachExactRenditionWithAuthenticatedClientIdentity() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/video/:/transcode/universal/ping", json: "{}")
        let provider = fixture(http: http)
        let first = try await provider.playbackInfo(
            for: "movie", mediaSourceID: "7", forceTranscode: false,
            streaming: .init(quality: .hd720)
        )
        let second = try await provider.playbackInfo(
            for: "movie", mediaSourceID: "7", forceTranscode: false,
            streaming: .init(quality: .hd720)
        )
        XCTAssertNotEqual(first.streamingSessionID, second.streamingSessionID)
        for request in [first, second] {
            try await provider.maintainStreamingSession(request)
            let session = try XCTUnwrap(request.streamingSessionID)
            XCTAssertEqual(http.queryItems(forPathSuffix: "/ping"), [.init(name: "session", value: session)])
            XCTAssertEqual(http.method(forPathSuffix: "/ping"), .get)
            XCTAssertEqual(http.sentHeaders.last?["X-Plex-Session-Identifier"], session)
            XCTAssertEqual(http.sentHeaders.last?["X-Plex-Token"], "fixture")
            XCTAssertEqual(http.sentHeaders.last?["X-Plex-Client-Identifier"], "device")
            XCTAssertEqual(http.sentHeaders.last?["Cache-Control"], "no-store")
            XCTAssertEqual(http.baseURL(forPathSuffix: "/ping"), URL(string: "https://plex.example.test"))
        }
    }

    func testTimelineReportsRetainEachRenditionIdentityAcrossReplacementAndStop() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/:/timeline", json: "{}")
        let provider = fixture(http: http)
        var requests: [PlaybackRequest] = []
        // Two identical requests still own different sessions; changing quality
        // also creates a new rendition without retargeting older reports.
        for quality in [StreamingQuality.sd480, .sd480, .hd720] {
            let request = try await provider.playbackInfo(
                for: "movie", mediaSourceID: "7", forceTranscode: false,
                streaming: .init(quality: quality)
            )
            let sessionID = try XCTUnwrap(request.playSessionID)
            let decision = try XCTUnwrap(http.queryItems(forPathSuffix: "/decision"))
            XCTAssertEqual(decision.first { $0.name == "session" }?.value, sessionID)
            XCTAssertEqual(decision.first { $0.name == "X-Plex-Session-Identifier" }?.value, sessionID)
            XCTAssertEqual(try locator(request).playSessionID, sessionID)
            XCTAssertEqual(request.streamingSessionID, sessionID)
            XCTAssertEqual(request.item.id, "movie")
            XCTAssertNotEqual(sessionID, request.item.id)
            requests.append(request)
        }
        XCTAssertEqual(Set(requests.compactMap(\.playSessionID)).count, requests.count)

        let events: [(Int, PlaybackEvent, String)] = [
            (0, .start, "playing"), (1, .start, "playing"),
            (2, .start, "playing"), (0, .pause, "paused"),
            (1, .progress, "playing"), (0, .stop, "stopped"),
            (2, .unpause, "playing"), (1, .stop, "stopped"),
            (2, .progress, "playing"), (2, .stop, "stopped")
        ]
        for (index, event, state) in events {
            let request = requests[index]
            try await provider.reportPlayback(.init(
                itemID: request.item.id, playSessionID: request.playSessionID,
                positionSeconds: 1_224, isPaused: event == .pause
            ), event: event)
            let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/:/timeline"))
            XCTAssertEqual(query.first { $0.name == "ratingKey" }?.value, "movie")
            XCTAssertEqual(query.first { $0.name == "key" }?.value, "/library/metadata/movie")
            XCTAssertEqual(query.first { $0.name == "state" }?.value, state)
            XCTAssertEqual(query.first { $0.name == "time" }?.value, "1224000")
            XCTAssertEqual(http.sentHeaders.last?["X-Plex-Session-Identifier"], request.playSessionID)
            XCTAssertEqual(http.sentHeaders.last?["X-Plex-Client-Identifier"], "device")
            XCTAssertEqual(http.sentHeaders.last?["X-Plex-Token"], "fixture")
            if event == .stop {
                await provider.releaseStreamingSession(request)
                XCTAssertEqual(
                    http.queryItems(forPathSuffix: "/stop")?.first { $0.name == "session" }?.value,
                    request.playSessionID
                )
            }
        }
        XCTAssertEqual(http.sentPaths.filter { $0 == "/:/timeline" }.count, events.count)
        XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/stop") }.count, requests.count)
    }

    func testOrdinaryConversionAndForcedFallbackOwnSessionsWithoutQualityOptions() async throws {
        for (container, forceTranscode) in [("avi", false), ("mp4", true)] {
            let http = StubHTTPClient()
            http.stub(pathSuffix: "/video/:/transcode/universal/ping", json: "{}")
            http.stub(pathSuffix: "/:/timeline", json: "{}")
            let provider = fixture(http: http, container: container)
            let request = try await provider.playbackInfo(
                for: "movie", mediaSourceID: "7", forceTranscode: forceTranscode
            )
            XCTAssertNil(request.streamingOptions)
            XCTAssertTrue(request.isTranscoding)
            let session = try XCTUnwrap(request.streamingSessionID)
            let source = try locator(request)
            XCTAssertEqual(request.playSessionID, session)
            XCTAssertEqual(source.playSessionID, session)
            XCTAssertEqual(source.deliveryMode, .serverTranscode)
            XCTAssertEqual(source.resource.pathBase, .configuredBaseURL)
            XCTAssertEqual(source.resource.path, "video/:/transcode/universal/start.m3u8")

            try await provider.maintainStreamingSession(request)
            XCTAssertEqual(http.queryItems(forPathSuffix: "/ping"), [.init(name: "session", value: session)])
            XCTAssertEqual(http.sentHeaders.last?["X-Plex-Session-Identifier"], session)
            try await provider.reportPlayback(.init(
                itemID: request.item.id, playSessionID: request.playSessionID,
                positionSeconds: 30, isPaused: false
            ), event: .stop)
            XCTAssertEqual(http.sentHeaders.last?["X-Plex-Session-Identifier"], session)
            await provider.releaseStreamingSession(request)
            XCTAssertEqual(http.queryItems(forPathSuffix: "/stop"), [.init(name: "session", value: session)])
            XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/ping") }.count, 1)
            XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/stop") }.count, 1)
        }
    }

    func testOriginalFileWithoutQualityOptionsHasNoSessionToMaintainOrRelease() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/:/timeline", json: "{}")
        let provider = fixture(bitrate: 1_000, width: 640, height: 360, http: http)
        let request = try await provider.playbackInfo(
            for: "movie", mediaSourceID: "7", forceTranscode: false
        )
        XCTAssertNil(request.streamingOptions)
        XCTAssertNil(request.streamingSessionID)
        XCTAssertFalse(request.isTranscoding)
        XCTAssertEqual(try locator(request).deliveryMode, .directFile)
        XCTAssertNil(try locator(request).playSessionID, "A direct file is not a transcoder session")
        let sessionID = try XCTUnwrap(request.playSessionID)
        XCTAssertNotEqual(sessionID, request.item.id)
        let replacement = try await provider.playbackInfo(
            for: "movie", mediaSourceID: "7", forceTranscode: false
        )
        XCTAssertNotNil(replacement.playSessionID)
        XCTAssertNotEqual(replacement.playSessionID, sessionID)
        for direct in [request, replacement] {
            try await provider.reportPlayback(.init(
                itemID: direct.item.id, playSessionID: direct.playSessionID,
                positionSeconds: 30, isPaused: false
            ), event: .stop)
            XCTAssertEqual(http.sentHeaders.last?["X-Plex-Session-Identifier"], direct.playSessionID)
            XCTAssertEqual(
                http.queryItems(forPathSuffix: "/:/timeline")?.first { $0.name == "ratingKey" }?.value,
                "movie"
            )
            try await provider.maintainStreamingSession(direct)
            await provider.releaseStreamingSession(direct)
        }
        XCTAssertFalse(http.sentPaths.contains { $0.hasSuffix("/ping") || $0.hasSuffix("/stop") })
    }

    func testMaintenanceDoesNotPingOriginalFilesOrMissingSessions() async throws {
        let http = StubHTTPClient()
        let provider = fixture(bitrate: 1_000, width: 640, height: 360, http: http)
        var request = try await provider.playbackInfo(
            for: "movie", mediaSourceID: "7", forceTranscode: false,
            streaming: .init(quality: .original)
        )
        XCTAssertFalse(request.isTranscoding)
        try await provider.maintainStreamingSession(request)
        request.streamingSessionID = "stale-session"
        try await provider.maintainStreamingSession(request)
        request.isTranscoding = true
        let missingIDs: [String?] = [nil, ""]
        for id in missingIDs {
            request.streamingSessionID = id
            try await provider.maintainStreamingSession(request)
        }
        XCTAssertFalse(http.sentPaths.contains { $0.hasSuffix("/ping") })
    }

    func testMaintenanceHonorsCancellationBeforeAndAfterItsRequest() async throws {
        for cancelBeforeSend in [true, false] {
            let http = StubHTTPClient()
            http.stub(pathSuffix: "/video/:/transcode/universal/ping", json: "{}")
            let provider = fixture(
                http: http,
                transport: CancellationCheckingHTTPClient(stub: http, cancelAfterPing: !cancelBeforeSend)
            )
            let request = try await provider.playbackInfo(
                for: "movie", mediaSourceID: "7", forceTranscode: false,
                streaming: .init(quality: .hd720)
            )
            let maintenance = Task {
                if cancelBeforeSend { withUnsafeCurrentTask { $0?.cancel() } }
                try await provider.maintainStreamingSession(request)
            }
            do {
                try await maintenance.value
                XCTFail("Session maintenance must not survive cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/ping") }.count, cancelBeforeSend ? 0 : 1)
            XCTAssertFalse(http.sentPaths.contains { $0.hasSuffix("/stop") })
        }
    }

    func testMaintenancePropagatesFailureWithoutStoppingOrReplacingTheRendition() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/video/:/transcode/universal/ping", json: "", status: 500)
        let provider = fixture(http: http)
        let request = try await provider.playbackInfo(
            for: "movie", mediaSourceID: "7", forceTranscode: false,
            streaming: .init(quality: .hd720)
        )
        do {
            try await provider.maintainStreamingSession(request)
            XCTFail("A failed ping must be reported to the session owner")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
        XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/decision") }.count, 1)
        XCTAssertFalse(http.sentPaths.contains { $0.hasSuffix("/stop") })
    }

    func testAlreadyCanceledReleaseStillAwaitsItsOwnedSessionStop() async throws {
        let http = StubHTTPClient()
        let provider = fixture(http: http, transport: CancellationCheckingHTTPClient(stub: http))
        let request = try await provider.playbackInfo(
            for: "movie", mediaSourceID: "7", forceTranscode: false,
            streaming: .init(quality: .hd720)
        )
        let release = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await provider.releaseStreamingSession(request)
        }
        await release.value
        XCTAssertEqual(http.queryItems(forPathSuffix: "/stop")?.first { $0.name == "session" }?.value,
                       request.streamingSessionID)
        XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/stop") }.count, 1)
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
                XCTAssertTrue(profile.contains("protocol=hls&container=mp4&"))
                XCTAssertTrue(profile.contains("audioCodec=aac&subtitleCodec=webvtt&replace=true)"))
                XCTAssertTrue(profile.contains("add-transcode-target(type=subtitleProfile&context=streaming&protocol=hls&container=webvtt&subtitleCodec=webvtt&replace=true)"))
                XCTAssertFalse(profile.contains("mpegts"))
                XCTAssertEqual(query.first { $0.name == "maxVideoBitrate" }?.value, "1872")
                XCTAssertEqual(query.first { $0.name == "videoResolution" }?.value, "1280x720")
                XCTAssertEqual(query.first { $0.name == "path" }?.value, "/library/metadata/movie")
                XCTAssertEqual(query.first { $0.name == "session" }?.value, "fixture")
            }
        }
    }

        func testFallbackWithoutQualityOptionsAlsoAdvertisesMP4AndWebVTT() throws {
            let client = PlexClient(
                baseURL: URL(string: "https://fixture.test")!,
                deviceProfile: .init(clientIdentifier: "fixture"), token: "fixture",
                http: StubHTTPClient(), capabilities: .init(supportsHEVC: false)
            )
            let url = try XCTUnwrap(client.transcodeURL(ratingKey: "movie", sessionID: "fallback"))
            let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(url.path, "/video/:/transcode/universal/start.m3u8")
            XCTAssertEqual(query.first { $0.name == "protocol" }?.value, "hls")
            XCTAssertEqual(query.first { $0.name == "directStream" }?.value, "1")
            XCTAssertEqual(query.first { $0.name == "X-Plex-Client-Profile-Name" }?.value, "Generic")
            XCTAssertEqual(query.first { $0.name == "X-Plex-Client-Profile-Extra" }?.value,
                           "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mp4&videoCodec=h264&audioCodec=aac&subtitleCodec=webvtt&replace=true)"
                           + "+add-transcode-target(type=subtitleProfile&context=streaming&protocol=hls&container=webvtt&subtitleCodec=webvtt&replace=true)")
            XCTAssertFalse(query.contains { $0.name == "maxVideoBitrate" || $0.name == "videoResolution" })
        }

        func testTextSubtitlesNegotiateWebVTTUsingServerIDsWithoutChangingPlayerIndexes() async throws {
            for codec in ["srt", "ass", "webvtt"] {
                for external in [false, true] {
                    let http = StubHTTPClient()
                    let key = external ? #","key":"/library/streams/104/subtitle.\#(codec)""# : ""
                    let provider = fixture(http: http, streams: """
                    {"id":101,"index":1,"streamType":2,"codec":"aac","languageTag":"eng","default":true},
                    {"id":102,"index":2,"streamType":2,"codec":"aac","languageTag":"jpn"},
                    {"id":103,"index":3,"streamType":3,"codec":"pgs","languageTag":"eng","default":true},
                    {"id":104,"index":4,"streamType":3,"codec":"\(codec)","languageTag":"eng"\(key)}
                    """)
                    var options = StreamingPlaybackOptions(quality: .hd720, codec: .preferH264)
                    options.audioTrack = .init(id: 2, kind: .audio, displayTitle: "Japanese", language: "jpn")
                    options.subtitleTrack = .init(id: 4, kind: .subtitle, displayTitle: "English", language: "eng")
                    let request = try await provider.playbackInfo(
                        for: "movie", mediaSourceID: "7", forceTranscode: false, streaming: options
                    )
                    let playback = try locator(request).resource.queryItems.map {
                        URLQueryItem(name: $0.name, value: $0.value)
                    }
                    let decision = try XCTUnwrap(http.queryItems(forPathSuffix: "/decision"))
                    let playbackNames = Set(playback.map(\.name))
                    XCTAssertEqual(decision.filter { playbackNames.contains($0.name) }, playback,
                                   "The decision must validate the exact credential-free playback parameters")
                    XCTAssertEqual(decision.first { $0.name == "session" }?.value, request.streamingSessionID)
                    XCTAssertEqual(playback.first { $0.name == "audioStreamID" }?.value, "102")
                    XCTAssertEqual(playback.first { $0.name == "subtitleStreamID" }?.value, "104")
                    XCTAssertEqual(playback.first { $0.name == "subtitles" }?.value, "auto")
                    XCTAssertEqual(playback.first { $0.name == "maxVideoBitrate" }?.value, "1872")
                    XCTAssertEqual(playback.first { $0.name == "videoResolution" }?.value, "1280x720")
                    let profile = try XCTUnwrap(playback.first { $0.name == "X-Plex-Client-Profile-Extra" }?.value)
                    XCTAssertTrue(profile.contains("container=mp4&videoCodec=h264&audioCodec=aac&subtitleCodec=webvtt&replace=true)"))
                    XCTAssertTrue(profile.contains("type=subtitleProfile&context=streaming&protocol=hls&container=webvtt&subtitleCodec=webvtt&replace=true)"))
                    XCTAssertEqual(request.streamingOptions?.audioTrack?.id, 2)
                    XCTAssertEqual(request.streamingOptions?.subtitleTrack?.id, 4)
                    let subtitle = try XCTUnwrap(request.subtitleTracks.first { $0.id == 4 })
                    XCTAssertEqual(subtitle.codec, codec, "Original track facts must not claim a negotiated codec")
                    XCTAssertFalse(subtitle.isBitmapSubtitle)
                    if external {
                        guard case .authenticatedHTTP(let source)? = subtitle.deliverySource else {
                            return XCTFail("Text sidecars must remain available to the styled overlay")
                        }
                        XCTAssertEqual(source.formatHint.container, codec)
                        XCTAssertEqual(source.resource.path, "library/streams/104/subtitle.\(codec)")
                    } else {
                        XCTAssertNil(subtitle.deliverySource, "Embedded text is delivered by the HLS rendition")
                    }
                }
            }
        }

        func testBitmapAndOffKeepExplicitDeliveryWhileUsingMP4() async throws {
            for off in [false, true] {
                let http = StubHTTPClient()
                let provider = fixture(http: http, streams: """
                {"id":101,"index":1,"streamType":2,"codec":"aac","default":true},
                {"id":103,"index":3,"streamType":3,"codec":"pgs","languageCode":"eng","default":true}
                """)
                var options = StreamingPlaybackOptions(quality: .hd720, codec: .preferH264)
                options.subtitlesOff = off
                let request = try await provider.playbackInfo(
                    for: "movie", mediaSourceID: "7", forceTranscode: false, streaming: options
                )
                let query = try locator(request).resource.queryItems
                XCTAssertEqual(query.first { $0.name == "subtitleStreamID" }?.value, off ? "-1" : "103")
                XCTAssertEqual(query.first { $0.name == "subtitles" }?.value, off ? "none" : "burn")
                XCTAssertEqual(request.streamingOptions?.subtitleTrack?.id, off ? nil : 3)
                XCTAssertEqual(request.subtitleTracks.first?.isBitmapSubtitle, true)
                let profile = try XCTUnwrap(query.first { $0.name == "X-Plex-Client-Profile-Extra" }?.value)
                XCTAssertTrue(profile.contains("container=mp4&"))
            }
        }

        func testEveryCodecPreferenceRejectsMPEGTSAndReleasesItsSession() async {
            for codec in StreamingCodecPreference.allCases {
                let http = StubHTTPClient()
                let outputCodec = codec == .preferHEVC && MediaCapabilities.detected().allowedDirectPlayVideoCodecs.contains(.hevc)
                    ? "hevc" : "h264"
                let provider = fixture(decision: """
                {"MediaContainer":{"transcodeDecisionCode":1001,"Metadata":[{"Media":[
                  {"container":"mpegts","videoCodec":"\(outputCodec)"}
                ]}]}}
                """, http: http)
                do {
                    _ = try await provider.playbackInfo(
                        for: "movie", mediaSourceID: "7", forceTranscode: false,
                        streaming: .init(quality: .hd720, codec: codec)
                    )
                    XCTFail("The returned container must match the negotiated MP4 target")
                } catch {
                    XCTAssertEqual(error as? StreamingQualityError, .noCompatibleStream)
                }
                let session = http.queryItems(forPathSuffix: "/decision")?.first { $0.name == "session" }?.value
                XCTAssertNotNil(session)
                XCTAssertEqual(http.queryItems(forPathSuffix: "/stop")?.first { $0.name == "session" }?.value, session)
            }
        }
}

private struct CancellationCheckingHTTPClient: HTTPClient {
    let stub: StubHTTPClient
    var cancelAfterDecision = false
    var cancelAfterPing = false
    var cancelAfterAudioSelection = false

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let result = try await stub.send(endpoint, baseURL: baseURL)
        if cancelAfterPing, endpoint.path.hasSuffix("/ping") {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        if cancelAfterAudioSelection, endpoint.method == .put, endpoint.path.hasPrefix("/library/parts/") {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return result
    }

    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let result = try await stub.sendRaw(endpoint, baseURL: baseURL)
        if cancelAfterDecision, endpoint.path.hasSuffix("/decision") {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return result
    }
}
