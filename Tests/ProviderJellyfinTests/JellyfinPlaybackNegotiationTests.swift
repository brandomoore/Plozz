import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderJellyfin

final class JellyfinPlaybackNegotiationTests: XCTestCase {
    func testEmbyMaximumDirectPlaysWithNonNullableServerBitrateSemantics() async throws {
        for bitrate in [1_166_625, 200_000_000] {
            for hybrid in [false, true] {
                for streaming in [nil, StreamingPlaybackOptions(quality: .original)] {
                    let http = EmbyBitrateNegotiationHTTP(sourceBitrate: bitrate)
                    let provider = provider(.emby, http: http, hybrid: hybrid)
                    let request: PlaybackRequest
                    if let streaming {
                        request = try await provider.playbackInfo(
                            for: "movie", mediaSourceID: "version", forceTranscode: false, streaming: streaming
                        )
                    } else {
                        request = try await provider.playbackInfo(
                            for: "movie", mediaSourceID: "version", forceTranscode: false
                        )
                    }
                    XCTAssertFalse(request.isTranscoding)
                    XCTAssertEqual(request.serverDecision?.supportsDirectPlay, true)
                    XCTAssertEqual(request.deliveryMode, .directPlay)
                    XCTAssertNil(request.serverDecision?.clientMaxBitrate, "Maximum has no selected quality cap")
                    guard case .authenticatedHTTP(let locator) = request.playbackSource else {
                        return XCTFail("Expected the selected original file")
                    }
                    XCTAssertEqual(locator.mediaSourceID, "version")
                    XCTAssertEqual(locator.deliveryMode, .directFile)
                }
            }
        }
    }

    func testEmbyLowerQualityStillHonorsTheSelectedBitrate() async throws {
        let http = EmbyBitrateNegotiationHTTP(sourceBitrate: 1_166_625)
        let quality = try StreamingQuality.custom(maximumHeight: 1080, bitrateKbps: 500)
        let request = try await provider(.emby, http: http, hybrid: true).playbackInfo(
            for: "movie", mediaSourceID: "version", forceTranscode: false,
            streaming: .init(quality: quality)
        )
        XCTAssertTrue(request.isTranscoding)
        XCTAssertEqual(request.serverDecision?.supportsDirectPlay, false)
        XCTAssertEqual(request.serverDecision?.clientMaxBitrate, 500_000)
        XCTAssertEqual(request.serverDecision?.transcodeReasons, ["ContainerBitrateExceedsLimit"])
        XCTAssertNil(request.originalFileSource)
    }

    func testOriginalConversionBoundsOnlyEmbysSaturatedEncoderTarget() async throws {
        for kind in [ProviderKind.emby, .jellyfin] {
            for managed in [false, true] {
                for forceTranscode in [false, true] {
                    let http = fixtureHTTP(decisions: [decision(
                        session: "conversion",
                        url: "/Videos/movie/master.m3u8?VideoCodec=h264&VideoBitrate=2147483647&MaxStreamingBitrate=35128000&TranscodeReasons=DirectPlayError"
                    )])
                    let provider = provider(kind, http: http, hybrid: true)
                    let request: PlaybackRequest
                    if managed {
                        request = try await provider.playbackInfo(
                            for: "movie", mediaSourceID: "version", forceTranscode: forceTranscode,
                            streaming: .init(quality: .original, codec: .preferH264)
                        )
                    } else {
                        request = try await provider.playbackInfo(
                            for: "movie", mediaSourceID: "version", forceTranscode: forceTranscode
                        )
                    }
                    XCTAssertTrue(request.isTranscoding)
                    guard case .authenticatedHTTP(let locator) = request.playbackSource else {
                        return XCTFail("Expected the server's conversion")
                    }
                    XCTAssertEqual(
                        locator.resource.queryItems.first { $0.name == "VideoBitrate" }?.value,
                        kind == .emby ? "30000000" : "2147483647"
                    )
                    XCTAssertEqual(
                        locator.resource.queryItems.first { $0.name == "MaxStreamingBitrate" }?.value,
                        "35128000"
                    )
                    XCTAssertEqual(locator.mediaSourceID, "version")
                    XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/PlaybackInfo") }.count, 1)
                }
            }
        }
    }

    func testEmbySaturatedEncoderTargetUsesVideoRateWithoutRaisingSmallerServerTargets() throws {
        for (requested, expected) in [(35_000_000, 35_000_000), (Int(Int32.max), 998_075), (Int(Int64.max), 998_075)] {
            var source = try JSONDecoder().decode(MediaSourceInfo.self, from: Data("""
            {"Bitrate":1166625,
             "TranscodingUrl":"/master.m3u8?VideoBitrate=\(requested)&AudioBitrate=161133&AllowVideoStreamCopy=false",
             "MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264","BitRate":998075}]}
            """.utf8))
            try source.boundEmbyOriginalTranscodingBitrate()
            let query = try XCTUnwrap(URLComponents(string: XCTUnwrap(source.TranscodingUrl))?.queryItems)
            XCTAssertEqual(query.first { $0.name == "VideoBitrate" }?.value, String(expected))
            XCTAssertEqual(query.first { $0.name == "AudioBitrate" }?.value, "161133")
            XCTAssertEqual(query.first { $0.name == "AllowVideoStreamCopy" }?.value, "false")
        }
    }

    func testEmbyUnboundedConversionWithoutSourceBitrateFailsAndReleasesItsSession() async throws {
        let http = fixtureHTTP(decisions: ["""
        {"PlaySessionId":"unbounded","MediaSources":[{
          "Id":"version","Container":"mp4","SupportsDirectPlay":false,"SupportsTranscoding":true,
          "TranscodingUrl":"/Videos/movie/master.m3u8?VideoCodec=h264&VideoBitrate=2147483647"
        }]}
        """])
        do {
            _ = try await provider(.emby, http: http, hybrid: true).playbackInfo(for: "movie")
            XCTFail("Do not start a saturated encode without a source bitrate")
        } catch {
            XCTAssertEqual(error as? StreamingQualityError, .unavailable)
        }
        XCTAssertEqual(releasedSessions(http), ["unbounded"])
    }

    func testOriginalCodecRecoveryKeepsNoClientCapAndHonorsServerRenditionLimits() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let http = fixtureHTTP(decisions: [
                decision(session: "initial"),
                decision(
                    session: "replacement",
                    url: "/Videos/movie/master.m3u8?VideoCodec=h264&VideoBitrate=35000000&MaxStreamingBitrate=35128000&TranscodeReasons=DirectPlayError"
                )
            ])
            let provider = provider(kind, http: http, hybrid: true)
            let initial = try await provider.playbackInfo(
                for: "movie", mediaSourceID: "version", forceTranscode: false
            )
            XCTAssertTrue(initial.isTranscoding)
            XCTAssertNil(initial.streamingOptions)
            XCTAssertNil(initial.serverDecision?.clientMaxBitrate)
            let replacement = try await provider.playbackInfo(
                for: "movie", mediaSourceID: "version", forceTranscode: true,
                streaming: .init(quality: .original, codec: .preferH264)
            )
            XCTAssertTrue(replacement.isTranscoding)
            XCTAssertEqual(replacement.streamingOptions?.quality, .original)
            XCTAssertEqual(replacement.negotiatedStreamingVideoCodec, .h264)
            XCTAssertNil(replacement.originalFileSource)
            XCTAssertNil(replacement.localRemuxSource)
            let evidence = try XCTUnwrap(replacement.serverDecision)
            XCTAssertNil(evidence.clientMaxBitrate)
            XCTAssertEqual(evidence.transcodeReasons, ["DirectPlayError"])
            guard case .authenticatedHTTP(let locator) = replacement.playbackSource else {
                return XCTFail("Recovery must keep a server-issued authenticated rendition.")
            }
            XCTAssertEqual(locator.mediaSourceID, "version")
            XCTAssertEqual(locator.deliveryMode, .serverTranscode)
            for (name, value) in [
                ("VideoBitrate", "35000000"), ("MaxStreamingBitrate", "35128000"),
                ("AllowVideoStreamCopy", "false"), ("AllowAudioStreamCopy", "false")
            ] {
                XCTAssertEqual(locator.resource.queryItems.first { $0.name == name }?.value, value)
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(
                with: XCTUnwrap(http.sentBodies["/Items/movie/PlaybackInfo"])
            ) as? [String: Any])
            try assertOriginalBitrate(in: body, provider: kind)
            XCTAssertEqual(body["EnableDirectPlay"] as? Bool, false)
            XCTAssertEqual(body["EnableDirectStream"] as? Bool, false)
            XCTAssertEqual(body["EnableTranscoding"] as? Bool, true)
            XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/PlaybackInfo") }.count, 2)
        }
    }

    func testServerRequiredRemuxConversionKeepsDecisionEvidenceAtOriginalQuality() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let http = fixtureHTTP(decisions: ["""
            {"PlaySessionId":"active","MediaSources":[{
              "Id":"version","Container":"mkv","Bitrate":82000000,
              "SupportsDirectPlay":false,"SupportsDirectStream":false,"SupportsTranscoding":true,
              "TranscodeReasons":["SubtitleCodecNotSupported"],
              "TranscodingUrl":"/Videos/movie/master.m3u8?VideoCodec=hevc&SubtitleMethod=Encode&SubtitleStreamIndex=2&TranscodeReasons=SubtitleCodecNotSupported,VideoRangeTypeNotSupported",
              "MediaStreams":[
                {"Index":0,"Type":"Video","Codec":"hevc","VideoRangeType":"DOVIWithHDR10"},
                {"Index":1,"Type":"Audio","Codec":"truehd","IsDefault":true},
                {"Index":2,"Type":"Subtitle","Codec":"pgssub","IsDefault":true,"IsTextSubtitleStream":false}
              ]
            }]}
            """])
            let request = try await provider(kind, http: http, hybrid: true).playbackInfo(
                for: "movie", mediaSourceID: "version", forceTranscode: false
            )
            let evidence = try XCTUnwrap(request.serverDecision)
            XCTAssertEqual(evidence.sourceBitrate, 82_000_000)
            XCTAssertNil(evidence.clientMaxBitrate)
            XCTAssertEqual(evidence.supportsDirectPlay, false)
            XCTAssertEqual(evidence.supportsTranscoding, true)
            XCTAssertTrue(evidence.subtitleBurnIn)
            XCTAssertEqual(evidence.transcodeReasons, ["SubtitleCodecNotSupported", "VideoRangeTypeNotSupported"])
            XCTAssertTrue(request.isTranscoding, "Removing our cap must not override the server's decision")
            XCTAssertEqual(request.burnedInSubtitleTrackID, 2)
            XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/PlaybackInfo") }.count, 1)
        }
    }

    func testDecisionReasonsFromURLsAreAllowlistedWithoutLeakingServerData() throws {
        let source = try JSONDecoder().decode(MediaSourceInfo.self, from: Data("""
        {"Bitrate":77150000,"SupportsDirectPlay":false,
         "TranscodingUrl":"https://private.test/master.m3u8?api_key=private-token&TranscodeReasons=ContainerBitrateExceedsLimit,private-token"}
        """.utf8))
        let evidence = source.playbackServerDecision(clientMaxBitrate: nil)
        XCTAssertEqual(evidence.transcodeReasons, ["ContainerBitrateExceedsLimit", "Other"])
        XCTAssertEqual(evidence.sourceBitrate, 77_150_000)
        let data = try JSONEncoder().encode(evidence)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private"))
        let unknown = try mediaSource(url: "/master.m3u8").playbackServerDecision(clientMaxBitrate: 2_000_000)
        XCTAssertNil(unknown.transcodeReasons, "Missing reasons are unknown, not evidence of no conversion")
        XCTAssertEqual(unknown.clientMaxBitrate, 2_000_000)
    }

    func testOriginalQualityRemovesClientBitrateLimitsWithoutDisablingServerConversion() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            for streaming in [nil, StreamingPlaybackOptions(quality: .original)] {
                let http = StubHTTPClient()
                http.stub(pathSuffix: "/PlaybackInfo", json: #"{"MediaSources":[]}"#)
                let client = JellyfinClient(
                    baseURL: URL(string: "https://fixture.test")!,
                    deviceProfile: .init(deviceID: "device"), providerKind: kind, http: http
                )
                _ = try await client.playbackInfo(
                    userID: "user", itemID: "movie", streaming: streaming
                )
                let data = try XCTUnwrap(http.sentBodies["/Items/movie/PlaybackInfo"])
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                try assertOriginalBitrate(in: body, provider: kind)
                XCTAssertEqual(body["EnableTranscoding"] as? Bool, true)
                XCTAssertNil(body["EnableDirectPlay"])
                XCTAssertNil(body["AllowVideoStreamCopy"])
            }
        }
    }

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

    private func assertOriginalBitrate(
        in body: [String: Any], provider: ProviderKind,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any], file: file, line: line)
        if provider == .emby {
            XCTAssertEqual(body["MaxStreamingBitrate"] as? Int, Int(Int64.max), file: file, line: line)
            XCTAssertEqual(profile["MaxStreamingBitrate"] as? Int, Int(Int64.max), file: file, line: line)
            XCTAssertEqual(profile["MaxStaticBitrate"] as? Int, Int(Int64.max), file: file, line: line)
        } else {
            XCTAssertNil(body["MaxStreamingBitrate"], file: file, line: line)
            XCTAssertTrue(profile["MaxStreamingBitrate"] is NSNull, file: file, line: line)
            XCTAssertTrue(profile["MaxStaticBitrate"] is NSNull, file: file, line: line)
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

/// Replays the bitrate decision observed on Emby 4.10.2.0: null/omitted limits
/// reject even a compatible 1.17 Mbps original. The 200 Mbps case guards the old cap.
private actor EmbyBitrateNegotiationHTTP: HTTPClient {
    private let sourceBitrate: Int

    init(sourceBitrate: Int) {
        self.sourceBitrate = sourceBitrate
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let json: String
        switch endpoint.path {
        case "/Items/movie/PlaybackInfo":
            let body = try XCTUnwrap(JSONSerialization.jsonObject(
                with: XCTUnwrap(endpoint.body)
            ) as? [String: Any])
            let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any])
            let limit = body["MaxStreamingBitrate"] as? Int ?? profile["MaxStreamingBitrate"] as? Int ?? 0
            let direct = sourceBitrate <= limit
            let rendition = direct ? "" : """
            "TranscodingUrl":"/Videos/movie/master.m3u8?VideoCodec=h264&TranscodeReasons=ContainerBitrateExceedsLimit",
            """
            json = """
            {"PlaySessionId":"owned","MediaSources":[{
              "Id":"version","Container":"mp4","Bitrate":\(sourceBitrate),
              "SupportsDirectPlay":\(direct),"SupportsDirectStream":\(direct),"SupportsTranscoding":true,
              \(rendition)
              "MediaStreams":[
                {"Index":0,"Type":"Video","Codec":"h264","Width":720,"Height":400},
                {"Index":1,"Type":"Audio","Codec":"aac","IsDefault":true}
              ]
            }]}
            """
        case "/Users/user/Items/movie":
            json = #"{"Id":"movie","Name":"Movie","Type":"Movie"}"#
        case "/Videos/ActiveEncodings":
            json = "{}"
        default:
            throw AppError.notFound
        }
        return (Data(json.utf8), HTTPURLResponse(
            url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil
        )!)
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
