import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderJellyfin

private struct StreamingErrorHTTP: HTTPClient {
    let status: Int
    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        throw AppError.invalidResponse
    }
    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        (Data("private server error text must not enter UI".utf8),
         HTTPURLResponse(url: baseURL, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private struct ResumeMutationApplier: WatchMutationApplying {
    let provider: JellyfinProvider

    func setPlayed(_ played: Bool, on target: WatchMutationTarget) async throws {
        try await provider.setPlayed(played, itemID: target.itemID)
    }

    func setResumePosition(_ seconds: TimeInterval, on target: WatchMutationTarget, capturedAt: Date) async throws {
        try await provider.setResumePosition(seconds, itemID: target.itemID, capturedAt: capturedAt)
    }

    func scrobbleTrakt(_ intent: TraktScrobbleIntent) async throws {}
}

final class JellyfinStreamingQualityTests: XCTestCase {
    func testEmbyResumeWritesUseDocumentedUserScopedEndpointWithoutStoppingPlayback() async throws {
        let (provider, http) = fixture(kind: .emby, rendition: true)
        let path = "/Users/user/Items/movie/UserData"
        http.stub(pathSuffix: path, json: "{}")
        http.stub(pathSuffix: "/Sessions/Playing", json: "{}")
        try await provider.reportPlayback(.init(
            itemID: "movie", playSessionID: "active-session", positionSeconds: 30, isPaused: false
        ), event: .start)
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        for position in [120.0, 0.0] {
            try await provider.setResumePosition(position, itemID: "movie", capturedAt: capturedAt)
            let body = try XCTUnwrap(http.sentBodies.first { $0.key.hasSuffix(path) }?.value)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual((object["PlaybackPositionTicks"] as? NSNumber)?.int64Value, Int64(position * 10_000_000))
            XCTAssertEqual(object["LastPlayedDate"] as? String, JellyfinDate.iso8601(from: capturedAt))
            XCTAssertEqual(Set(object.keys), ["PlaybackPositionTicks", "LastPlayedDate"])
        }
        XCTAssertEqual(http.method(forPathSuffix: path), .post)
        XCTAssertEqual(http.queryItems(forPathSuffix: path), [])
        XCTAssertFalse(http.sentPaths.contains { $0.hasSuffix("/UserItems/movie/UserData") })
        XCTAssertFalse(http.sentPaths.contains { $0.hasSuffix("/Stopped") || $0.hasSuffix("/ActiveEncodings") })
    }

    func testEmbyUserData404IsNotReinterpretedAsSessionlessPlaybackStop() async throws {
        let (provider, http) = fixture(kind: .emby, rendition: true)
        http.stub(pathSuffix: "/Users/user/Items/movie/UserData", json: "{}", status: 404)
        http.stub(pathSuffix: "/Sessions/Playing/Stopped", json: "{}")
        do {
            try await provider.setResumePosition(120, itemID: "movie")
            XCTFail("A failed resume write must remain retryable, not appear successful")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
        XCTAssertFalse(http.sentPaths.contains { $0.hasSuffix("/Stopped") || $0.hasSuffix("/ActiveEncodings") })
    }

    func testEmbyCheckpointFailureRemainsDurableWhileAnotherItemOnServerIsPlaying() async throws {
        let (provider, http) = fixture(kind: .emby, rendition: true)
        http.stub(pathSuffix: "/Sessions/Playing", json: "{}")
        http.stub(pathSuffix: "/Users/user/Items/other/UserData", json: "{}")
        try await provider.reportPlayback(.init(
            itemID: "movie", playSessionID: "active-session", positionSeconds: 30, isPaused: false
        ), event: .start)
        let store = InMemoryWatchMutationStore()
        let reconciler = WatchStateReconciler(store: store, applier: ResumeMutationApplier(provider: provider))
        await reconciler.beginLiveSession(accountID: "server", itemID: "movie")
        let target = WatchMutationTarget(accountID: "server", itemID: "other", providerKind: .emby)
        await reconciler.enqueue(.init(
            capturedAt: Date(), canonicalMediaID: "other-title", resumePosition: 120, targets: [target]
        ))
        http.error = .notFound
        await reconciler.drain()
        XCTAssertEqual(store.load().pending.first?.targets, [target], "404 must preserve the durable write")
        XCTAssertEqual(store.load().pending.first?.resumePosition, 120)
        XCTAssertFalse(http.sentPaths.contains { $0.hasSuffix("/Stopped") || $0.hasSuffix("/ActiveEncodings") })

        http.error = nil
        await reconciler.drain()
        XCTAssertTrue(store.load().pending.isEmpty, "A successful retry must acknowledge the saved write")
        let remainsLive = await reconciler.isLiveSession(accountID: "server", itemID: "movie")
        XCTAssertTrue(remainsLive)
        XCTAssertFalse(http.sentPaths.contains { $0.hasSuffix("/Stopped") || $0.hasSuffix("/ActiveEncodings") })
    }

    func testLifecycleReportsKeepTheExactSessionAndDeviceScope() async throws {
        for kind in [ProviderKind.emby, .jellyfin] {
            let (provider, http) = fixture(kind: kind, rendition: true)
            http.stub(pathSuffix: "/Sessions/Playing", json: "{}")
            http.stub(pathSuffix: "/Sessions/Playing/Stopped", json: "{}")
            let old = PlaybackProgress(
                itemID: "movie", playSessionID: "old-session", positionSeconds: 3, isPaused: true
            )
            let new = PlaybackProgress(
                itemID: "movie", playSessionID: "new-session", positionSeconds: 5, isPaused: false
            )
            try await provider.reportPlayback(new, event: .start)
            try await provider.reportPlayback(old, event: .stop)
            let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/Videos/ActiveEncodings"))
            XCTAssertEqual(query.first { $0.name == "deviceId" }?.value, "device")
            XCTAssertEqual(query.first { $0.name == "playSessionId" }?.value, "old-session")
            let body = try XCTUnwrap(http.sentBodies.first { $0.key.hasSuffix("/Stopped") }?.value)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["PlaySessionId"] as? String, "old-session")
            XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/ActiveEncodings") }.count, 1)
        }
    }

    func testProgressReportsNeverIssueStopAndSessionlessStopDoesNotDeleteEncodings() async throws {
        for kind in [ProviderKind.emby, .jellyfin] {
            let (provider, http) = fixture(kind: kind, rendition: true)
            http.stub(pathSuffix: "/Sessions/Playing", json: "{}")
            http.stub(pathSuffix: "/Sessions/Playing/Progress", json: "{}")
            http.stub(pathSuffix: "/Sessions/Playing/Stopped", json: "{}")
            let progress = PlaybackProgress(
                itemID: "movie", playSessionID: "session", positionSeconds: 3, isPaused: false
            )
            for event in [PlaybackEvent.start, .progress, .pause, .unpause] {
                try await provider.reportPlayback(progress, event: event)
            }
            XCTAssertFalse(http.sentPaths.contains { $0.hasSuffix("/Stopped") || $0.hasSuffix("/ActiveEncodings") })
            try await provider.reportPlayback(.init(
                itemID: "movie", playSessionID: nil, positionSeconds: 3, isPaused: true
            ), event: .stop)
            XCTAssertFalse(http.sentPaths.contains { $0.hasSuffix("/ActiveEncodings") })
            XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/Stopped") }.count, 1)
        }
    }

    func testHEVCConversionRetainsTenBitCapabilityInsteadOfDefaultingToEightBit() throws {
        let profile = JellyfinCapabilityProfile.appleTV(
            capabilities: .init(supportsHEVC: true, supportsHDR10: true)
        )
        let limited = profile.applying(.init(quality: .low, codec: .preferHEVC))
        let hevc = try XCTUnwrap(limited.codecProfiles.first { $0.codec == "hevc" })
        XCTAssertTrue(hevc.conditions.contains {
            $0.property == "VideoBitDepth" && $0.condition == "LessThanEqual" && $0.value == "10"
        })
        let h264 = try XCTUnwrap(limited.codecProfiles.first { $0.codec == "h264" })
        XCTAssertTrue(h264.conditions.contains { $0.property == "VideoBitDepth" && $0.value == "8" })
        XCTAssertEqual(profile, .appleTV(capabilities: .init(supportsHEVC: true, supportsHDR10: true)),
                       "Mobile conversion must not mutate the ordinary playback profile")

        let source = try JSONDecoder().decode(MediaSourceInfo.self, from: Data("""
        {"Id":"version","TranscodingUrl":"/Videos/movie/master.m3u8?VideoCodec=hevc&hevc-profile=main,main10&MaxVideoBitDepth=8",
         "MediaStreams":[{"Index":0,"Type":"Video","Codec":"hevc","BitDepth":10,"ExtendedVideoType":"Hdr10"}]}
        """.utf8))
        let query = try XCTUnwrap(URLComponents(string: source.boundedTranscodingURL(
            .init(quality: .low, codec: .preferHEVC), supportsHEVC: true
        ))?.queryItems)
        XCTAssertEqual(query.first { $0.name == "MaxVideoBitDepth" }?.value, "10")
        XCTAssertEqual(query.first { $0.name == "hevc-videobitdepth" }?.value, "10")
        XCTAssertEqual(query.first { $0.name == "hevc-profile" }?.value, "main10")
        XCTAssertEqual(query.first { $0.name == "VideoBitrate" }?.value, "372000")
        XCTAssertEqual(query.first { $0.name == "AudioBitrate" }?.value, "128000")
        XCTAssertEqual(query.first { $0.name == "MaxHeight" }?.value, "240")

        let fallback = try XCTUnwrap(URLComponents(string: source.boundedTranscodingURL(
            .init(quality: .low, codec: .preferH264), supportsHEVC: true
        ))?.queryItems)
        XCTAssertEqual(fallback.first { $0.name == "VideoCodec" }?.value, "h264")
        XCTAssertEqual(fallback.first { $0.name == "MaxVideoBitDepth" }?.value, "8")
        XCTAssertEqual(fallback.first { $0.name == "h264-videobitdepth" }?.value, "8")
    }

    func testHEVCOnlyRetryCannotSilentlyRestartTheRejectedH264Rendition() throws {
        let source = try JSONDecoder().decode(MediaSourceInfo.self, from: Data(
            #"{"Id":"version","TranscodingUrl":"/Videos/movie/master.m3u8?VideoCodec=h264"}"#.utf8
        ))
        XCTAssertThrowsError(try source.boundedTranscodingURL(
            .init(quality: .hd720, codec: .preferHEVC), supportsHEVC: true
        )) { XCTAssertEqual($0 as? StreamingQualityError, .codecUnavailable(.hevc)) }
        XCTAssertNoThrow(try source.boundedTranscodingURL(
            .init(quality: .hd720), supportsHEVC: true
        ))
        XCTAssertNoThrow(try source.boundedTranscodingURL(
            .init(quality: .hd720, codec: .preferHEVC), supportsHEVC: false
        ))
    }

    func testHEVCAndAutomaticSendDifferentProfilesToJellyfinAndEmby() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            for capable in [true, false] {
                for (preference, capableCodecs) in [
                    (StreamingCodecPreference.automatic, "hevc,h264"),
                    (.preferHEVC, "hevc"), (.preferH264, "h264")
                ] {
                    let http = StubHTTPClient()
                    http.stub(pathSuffix: "/Items/movie/PlaybackInfo", json: #"{"MediaSources":[]}"#)
                    let client = JellyfinClient(
                        baseURL: URL(string: "https://fixture.test")!,
                        deviceProfile: .init(deviceID: "device"), providerKind: kind, http: http,
                        capabilityProfile: .appleTV(capabilities: .init(supportsHEVC: capable))
                    )
                    _ = try await client.playbackInfo(
                        userID: "user", itemID: "movie", mediaSourceID: "version",
                        streaming: .init(quality: .hd720, codec: preference)
                    )
                    let body = try XCTUnwrap(http.sentBodies.first { $0.key.hasSuffix("/PlaybackInfo") }?.value)
                    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                    let profile = try XCTUnwrap(object["DeviceProfile"] as? [String: Any])
                    let targets = try XCTUnwrap(profile["TranscodingProfiles"] as? [[String: Any]])
                    XCTAssertEqual(targets.first?["VideoCodec"] as? String, capable ? capableCodecs : "h264")
                    if capable {
                        let codecProfiles = try XCTUnwrap(profile["CodecProfiles"] as? [[String: Any]])
                        let hevc = try XCTUnwrap(codecProfiles.first { $0["Codec"] as? String == "hevc" })
                        let conditions = try XCTUnwrap(hevc["Conditions"] as? [[String: Any]])
                        XCTAssertTrue(conditions.contains {
                            $0["Property"] as? String == "VideoBitDepth" && $0["Value"] as? String == "10"
                        })
                    }
                    XCTAssertEqual(object["MaxStreamingBitrate"] as? Int, 2_000_000)
                    XCTAssertEqual(object["MediaSourceId"] as? String, "version")
                }
            }
        }
    }

    func testHEVCPreferenceSelectsHEVCFromServerOfferedCodecList() throws {
        let source = try JSONDecoder().decode(MediaSourceInfo.self, from: Data(
            #"{"Id":"version","TranscodingUrl":"/Videos/movie/master.m3u8?VideoCodec=hevc,h264&SegmentContainer=mp4"}"#.utf8
        ))
        let query = try XCTUnwrap(URLComponents(string: source.boundedTranscodingURL(
            .init(quality: .hd720, codec: .preferHEVC), supportsHEVC: true
        ))?.queryItems)
        XCTAssertEqual(query.first { $0.name == "VideoCodec" }?.value, "hevc")
        XCTAssertEqual(query.first { $0.name == "VideoBitrate" }?.value, "1872000")
        XCTAssertEqual(query.first { $0.name == "MaxHeight" }?.value, "720")
    }

    func testEmbyAndJellyfinKeepASSAvailableWithoutBurningItIntoVideo() async throws {
        for kind in [ProviderKind.emby, .jellyfin] {
            let (provider, http) = fixture(kind: kind, rendition: true)
            http.stubSequence(pathSuffix: "/Items/movie/PlaybackInfo", jsons: ["""
            {"PlaySessionId":"session","MediaSources":[{
              "Id":"version","Container":"mkv","SupportsDirectPlay":false,"Bitrate":25000000,
              "TranscodingUrl":"/Videos/movie/master.m3u8?VideoCodec=h264&SubtitleMethod=Encode&SubtitleStreamIndex=2&SubtitleStreamIndexes=2&ManifestSubtitles=vtt",
              "MediaStreams":[
                {"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2076},
                {"Index":1,"Type":"Audio","Codec":"ac3","IsDefault":true},
                {"Index":2,"Type":"Subtitle","Codec":"ass","IsDefault":true,"IsTextSubtitleStream":true}
              ]}]}
            """])
            var options = StreamingPlaybackOptions(quality: .low, codec: .preferH264)
            options.subtitleTrack = .init(id: 2, kind: .subtitle, displayTitle: "ASS", codec: "ass")
            let request = try await provider.playbackInfo(
                for: "movie", mediaSourceID: "version", forceTranscode: false, streaming: options
            )
            guard case .authenticatedHTTP(let locator) = request.playbackSource else {
                return XCTFail("Expected managed stream")
            }
            XCTAssertEqual(locator.resource.queryItems.first { $0.name == "SubtitleStreamIndex" }?.value, "-1")
            XCTAssertEqual(locator.resource.queryItems.first { $0.name == "SubtitleMethod" }?.value, "External")
            XCTAssertEqual(locator.resource.queryItems.first { $0.name == "SubtitleStreamIndexes" }?.value, "-1")
            XCTAssertFalse(locator.resource.queryItems.contains { $0.name == "ManifestSubtitles" })
            XCTAssertNotNil(request.subtitleTracks.first { $0.id == 2 }?.deliverySource)
            XCTAssertEqual(request.streamingOptions?.subtitleTrack?.id, 2)
            XCTAssertEqual(http.queryItems(forPathSuffix: "/PlaybackInfo")?.first { $0.name == "SubtitleStreamIndex" }?.value, "-1")
            XCTAssertEqual(http.queryItems(forPathSuffix: "/PlaybackInfo")?.first { $0.name == "SubtitleMethod" }?.value, "External")
            if kind == .emby {
                XCTAssertEqual(http.queryItems(forPathSuffix: "/PlaybackInfo")?.first { $0.name == "SubtitleStreamIndexes" }?.value, "-1")
            }
        }
    }

    func testTextAndDisabledSubtitlesRemoveServerRequestedBurnIn() throws {
        let source = try JSONDecoder().decode(MediaSourceInfo.self, from: Data(
            #"{"Id":"version","TranscodingUrl":"/Videos/movie/master.m3u8?VideoCodec=h264&SubtitleStreamIndex=2&SubtitleStreamIndexes=2&ManifestSubtitles=vtt&SubtitleMethod=Encode&SegmentContainer=mp4"}"#.utf8
        ))
        for codec in ["ass", "ssa", "srt", "webvtt"] {
            var options = StreamingPlaybackOptions(quality: .low, codec: .preferH264)
            options.subtitleTrack = .init(id: 2, kind: .subtitle, displayTitle: "Subtitle", codec: codec)
            for off in [false, true] {
                options.subtitlesOff = off
                let url = try XCTUnwrap(URLComponents(string: source.boundedTranscodingURL(options, supportsHEVC: true)))
                let query = url.queryItems ?? []
                XCTAssertEqual(query.first { $0.name == "SubtitleStreamIndex" }?.value, "-1")
                XCTAssertEqual(query.first { $0.name == "SubtitleMethod" }?.value, "External")
                XCTAssertEqual(query.first { $0.name == "SubtitleStreamIndexes" }?.value, "-1")
                XCTAssertFalse(query.contains { $0.name == "ManifestSubtitles" })
                XCTAssertEqual(query.first { $0.name == "VideoBitrate" }?.value, "372000")
                XCTAssertEqual(query.first { $0.name == "AudioBitrate" }?.value, "128000")
            }
        }
    }

    func testHTTPRefusalAndServerErrorsKeepTheirStatusInsteadOfBlamingTheCodec() async {
        for (status, expected) in [(403, StreamingQualityError.permissionDenied), (500, .serverHTTP(500)), (503, .serverHTTP(503))] {
            let client = JellyfinClient(
                baseURL: URL(string: "https://fixture.test")!,
                deviceProfile: .init(deviceID: "fixture"),
                providerKind: .emby, http: StreamingErrorHTTP(status: status)
            )
            do {
                _ = try await client.playbackInfo(userID: "user", itemID: "movie", streaming: .init(quality: .hd720))
                XCTFail("Expected rejection")
            } catch let error as StreamingQualityError {
                XCTAssertEqual(error, expected)
                XCTAssertFalse(error.allowsCodecFallback)
            } catch { XCTFail("Unexpected error: \(error)") }
        }
    }
    func testBackendDecisionCodesSurviveWithoutMediaSourcesAndReleaseTheSession() async {
        for kind in [ProviderKind.emby, .jellyfin] {
            for (code, expected) in [
                ("NotAllowed", StreamingQualityError.permissionDenied),
                ("NoCompatibleStream", .noCompatibleStream),
                ("FutureServerCode", .negotiationFailed)
            ] {
                let (provider, http) = fixture(kind: kind, rendition: false)
                http.stubSequence(pathSuffix: "/Items/movie/PlaybackInfo", jsons: [
                    #"{"ErrorCode":"\#(code)","PlaySessionId":"rejected-session"}"#
                ])
                do {
                    _ = try await provider.playbackInfo(
                        for: "movie", mediaSourceID: "version", forceTranscode: false,
                        streaming: .init(quality: .hd720)
                    )
                    XCTFail("Server refusal must not become playable")
                } catch let error as StreamingQualityError {
                    XCTAssertEqual(error, expected)
                } catch { XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/PlaybackInfo") }.count, 1)
                XCTAssertTrue(http.sentPaths.contains { $0.hasSuffix("/Videos/ActiveEncodings") })
            }

        }
    }

    func testMalformedDecisionCannotPretendToBeASourceMissingOrCodecRefusal() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(PlaybackInfoResponse.self, from: Data("{}".utf8)))
        let denied = try JSONDecoder().decode(PlaybackInfoResponse.self, from: Data(#"{"ErrorCode":"NotAllowed"}"#.utf8))
        XCTAssertEqual(denied.streamingError, .permissionDenied)
        XCTAssertFalse(StreamingQualityError.permissionDenied.allowsCodecFallback)
    }

    private func fixture(kind: ProviderKind, rendition: Bool, bitrate: Int = 30_000_000) -> (JellyfinProvider, StubHTTPClient) {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/Users/user/Items/movie", json: #"{"Id":"movie","Name":"Movie","Type":"Movie"}"#)
        http.stub(pathSuffix: "/Videos/ActiveEncodings", json: "{}")
        let url = rendition ? #""TranscodingUrl":"/Videos/movie/master.m3u8?VideoCodec=hevc&VideoBitrate=30000000&AudioBitrate=384000&MaxHeight=2160","# : ""
        http.stub(pathSuffix: "/Items/movie/PlaybackInfo", json: """
        {"PlaySessionId":"session","MediaSources":[{
          "Id":"version","Container":"mp4","SupportsDirectPlay":true,
          \(url)
          "Bitrate":\(bitrate),"MediaStreams":[
            {"Index":0,"Type":"Video","Codec":"h264","Width":1280,"Height":720},
            {"Index":2,"Type":"Audio","Codec":"aac","Language":"eng","IsDefault":true}
          ]}]}
        """)
        let provider = JellyfinProvider(session: .init(
            server: .init(id: "server", name: "Server", baseURL: URL(string: "https://media.example.test")!, provider: kind),
            userID: "user", userName: "User", deviceID: "device", accessToken: "fixture"
        ), http: http)
        return (provider, http)
    }

    func testJellyfinAndEmbyApplySameTotalBudgetAndResolutionWithoutRemuxEscape() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let (provider, http) = fixture(kind: kind, rendition: true)
            let request = try await provider.playbackInfo(
                for: "movie", mediaSourceID: "version", forceTranscode: false,
                streaming: .init(quality: .hd720, codec: .preferHEVC)
            )
            let body = try XCTUnwrap(http.sentBodies.first { $0.key.hasSuffix("/PlaybackInfo") }?.value)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["MaxStreamingBitrate"] as? Int, 2_000_000)
            guard case let .authenticatedHTTP(locator) = request.playbackSource else {
                return XCTFail("Expected managed HTTP")
            }
            let query = Dictionary(locator.resource.queryItems.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
            XCTAssertEqual(query["VideoBitrate"], "1872000")
            XCTAssertEqual(query["AudioBitrate"], "128000")
            XCTAssertEqual(query["MaxWidth"], "1280")
            XCTAssertEqual(query["MaxHeight"], "720")
            XCTAssertEqual(query["AllowVideoStreamCopy"], "false")
            XCTAssertEqual(query["AudioStreamIndex"], "2")
            XCTAssertNil(request.localRemuxSource)
            XCTAssertNil(request.originalFileSource)
            XCTAssertTrue(request.isTranscoding)
            XCTAssertEqual(request.negotiatedStreamingVideoCodec, provider.client.canRequestHEVC ? .hevc : .h264)
            XCTAssertEqual(locator.mediaSourceID, "version")
        }
    }

    func testSmallSourcesRetainDirectPlaybackButRefusedTranscodesFailClosed() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let (small, _) = fixture(kind: kind, rendition: false, bitrate: 1_500_000)
            let direct = try await small.playbackInfo(
                for: "movie", mediaSourceID: "version", forceTranscode: false,
                streaming: .init(quality: .hd720, codec: .preferHEVC)
            )
            XCTAssertFalse(direct.isTranscoding)
            XCTAssertNil(direct.negotiatedStreamingVideoCodec)
            let (large, http) = fixture(kind: kind, rendition: false)
            do {
                _ = try await large.playbackInfo(
                    for: "movie", mediaSourceID: "version", forceTranscode: false, streaming: .init(quality: .hd720)
                )
                XCTFail("No unconstrained direct fallback is allowed")
            } catch is StreamingQualityError {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(http.sentPaths.contains { $0.hasSuffix("/Videos/ActiveEncodings") })
            XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/PlaybackInfo") }.count, 2)
        }
    }

    func testPerRequestProfileCannotChangeOtherPlaybackOrLiveTVDefaults() {
        let original = JellyfinCapabilityProfile.appleTV()
        let limited = original.applying(.init(quality: .hd720, codec: .preferH264))
        XCTAssertEqual(limited.maxStreamingBitrate, 2_000_000)
        XCTAssertEqual(limited.maxStaticBitrate, 2_000_000)
        XCTAssertEqual(limited.transcodingProfiles.first?.videoCodec, "h264")
        XCTAssertEqual(original.maxStreamingBitrate, JellyfinCapabilityProfile.defaultMaxBitrate)
        XCTAssertEqual(original, JellyfinCapabilityProfile.appleTV())
    }

    func testOptionalTranscodeURLDoesNotOverrideAProvenDirectPlayFit() async throws {
        let (provider, _) = fixture(kind: .jellyfin, rendition: true, bitrate: 1_000_000)
        let request = try await provider.playbackInfo(
            for: "movie", mediaSourceID: "version", forceTranscode: false,
            streaming: .init(quality: .hd720)
        )
        XCTAssertFalse(request.isTranscoding)
        guard case let .authenticatedHTTP(locator) = request.playbackSource else {
            return XCTFail("Expected original managed source")
        }
        XCTAssertEqual(locator.deliveryMode, .directFile)
    }

    func testCodecAndBitmapSelectionsAreAppliedToTheBoundedRendition() throws {
        let source = try JSONDecoder().decode(MediaSourceInfo.self, from: Data(
            #"{"Id":"version","TranscodingUrl":"/Videos/movie/master.m3u8?VideoCodec=hevc&VideoBitrate=30000000"}"#.utf8
        ))
        var options = StreamingPlaybackOptions(quality: .sd480, codec: .preferH264)
        options.audioTrack = .init(id: 4, kind: .audio, displayTitle: "Japanese", language: "jpn")
        options.subtitleTrack = .init(id: 6, kind: .subtitle, displayTitle: "English", language: "eng", codec: "pgssub")
        let url = try XCTUnwrap(URLComponents(string: source.boundedTranscodingURL(options, supportsHEVC: true)))
        let query = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(query["VideoCodec"], "h264")
        XCTAssertEqual(query["VideoBitrate"], "872000")
        XCTAssertEqual(query["SubtitleStreamIndex"], "6")
        XCTAssertEqual(query["SubtitleMethod"], "Encode")
        XCTAssertEqual(query["AudioStreamIndex"], "4")
        options.subtitlesOff = true
        let off = try XCTUnwrap(URLComponents(string: source.boundedTranscodingURL(options, supportsHEVC: true)))
        XCTAssertEqual(off.queryItems?.first { $0.name == "SubtitleStreamIndex" }?.value, "-1")
    }

    func testSelectedVersionMustNotSilentlyChange() async {
        let (provider, _) = fixture(kind: .jellyfin, rendition: true)
        do {
            _ = try await provider.playbackInfo(
                for: "movie", mediaSourceID: "missing", forceTranscode: false, streaming: .init(quality: .hd720)
            )
            XCTFail("Wrong source should fail")
        } catch is StreamingQualityError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}
