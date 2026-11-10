import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderSilo

extension SiloProviderTests {
    func testExternalSiloOriginalOwnsCleanupAndLeavesProgressToTheCallback() async throws {
        for options in [nil, StreamingPlaybackOptions(quality: .original)] {
            let raw = try credential().encoded()
            let http = SiloHTTPStub(playbackResponses())
            let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
            let request = try await provider.externalPlaybackInfo(
                for: "movie:1", mediaSourceID: "42", player: .infuse, streaming: options
            )
            XCTAssertEqual(request.streamingSessionID, "session1")
            XCTAssertEqual(request.playSessionID, "session1")
            XCTAssertEqual(request.item.selectedVersionID, "42")
            XCTAssertFalse(request.suppressOrdinaryWatchReporting, "Library videos are not scheduled channels")
            guard case .authenticatedHTTP(let locator) = request.playbackSource else {
                return XCTFail("Missing native playback grant")
            }
            let url = try await provider.resolveHTTPResource(locator)
            XCTAssertTrue(ExternalPlayerURL.isSupportedMediaURL(url))
            let requests = await http.requests
            let start = try XCTUnwrap(requests.first { $0.path == "/api/v2/playback/start" })
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(start.body)) as? [String: Any])
            XCTAssertEqual(body["progress_persistence"] as? String, "client")
            XCTAssertEqual(body["start_position"] as? Double, 0)
            XCTAssertEqual(body["file_id"] as? String, "42")
            XCTAssertFalse(requests.contains { $0.method == .delete || $0.path.hasSuffix("/progress") })
            await provider.releaseStreamingSession(request)
            let ended = await http.requests
            XCTAssertEqual(ended.filter { $0.method == .delete }.map(\.path), ["/api/v2/playback/session1"])
        }
    }

    func testExternalSiloConversionPreservesQualityButDoesNotDoubleApplyResume() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub(streamingResponses())
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        var options = StreamingPlaybackOptions(quality: try .custom(maximumHeight: 1080, bitrateKbps: 2_000))
        options.startPosition = 125
        let request = try await provider.externalPlaybackInfo(
            for: "movie:1", mediaSourceID: "42", player: .vlc, streaming: options
        )
        XCTAssertEqual(request.streamingOptions?.quality, options.quality)
        XCTAssertEqual(request.streamingOptions?.startPosition, 0)
        XCTAssertEqual(request.streamingSessionID, "session1")
        XCTAssertEqual(request.deliveryMode, .transcode)
        let requests = await http.requests
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(
            requests.first { $0.path == "/api/v2/playback/start" }?.body
        )) as? [String: Any])
        XCTAssertEqual(body["progress_persistence"] as? String, "client")
        XCTAssertEqual(body["start_position"] as? Double, 0)
        XCTAssertEqual(body["bandwidth_cap_kbps"] as? Int, 1_808)
        XCTAssertEqual(body["quality_preference"] as? String, "1080p-high")
    }

    func testExternalSiloStillRejectsUnusableGrantsAndCleansUp() async throws {
        for (old, new) in [
            (#""effective_media_file_id":"42""#, #""effective_media_file_id":"another-file""#),
            (#""headers":{}"#, #""headers":{"Authorization":"synthetic"}"#),
            (#""timeline_offset_seconds":0"#, #""timeline_offset_seconds":125"#),
            (#""can_seek_anywhere":true"#, #""can_seek_anywhere":false"#)
        ] {
            let raw = try credential().encoded()
            var responses = playbackResponses()
            responses["/api/v2/playback/start"] = responses["/api/v2/playback/start"]?
                .replacingOccurrences(of: old, with: new)
            let http = SiloHTTPStub(responses)
            let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
            do {
                _ = try await provider.externalPlaybackInfo(for: "movie:1", mediaSourceID: "42")
                XCTFail("External handoff must retain native plan validation")
            } catch {
                guard case .serverRefusal = error as? StreamingQualityError else { return XCTFail("\(error)") }
            }
            let requests = await http.requests
            XCTAssertEqual(requests.filter { $0.method == .delete }.map(\.path), ["/api/v2/playback/session1"])
        }
    }

    func testExternalSiloRejectsInvalidQualityBeforeNegotiation() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub(playbackResponses())
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        for quality in [StreamingQuality.invalid(.bitrateTooLow), .low] {
            do {
                _ = try await provider.externalPlaybackInfo(
                    for: "movie:1", mediaSourceID: "42", player: .infuse, streaming: .init(quality: quality)
                )
                XCTFail("Invalid or unsupported limits must not be bypassed")
            } catch { XCTAssertTrue(error is StreamingQualityError) }
        }
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testRestoredExternalSiloCleanupDoesNotNeedOrCreateAPlaybackGrant() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub(playbackResponses())
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        await provider.releaseStreamingSession(id: "session1")
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), ["/api/v2/playback/capabilities", "/api/v2/playback/session1"])
        let stop = try XCTUnwrap(requests.last)
        XCTAssertEqual(stop.method, .delete)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(stop.body)) as? [String: Any])
        XCTAssertEqual(body["installation_id"] as? String, "server1")
        XCTAssertNotNil(body["stop_id"])
        XCTAssertNil(body["position"])
    }

    func testExternalSiloRequiresTokenLifetimeForTheWholeVideoAndStartup() async throws {
        for (remaining, eligible) in [(899.0, false), (950.0, true)] {
            var login = try credential()
            login.expiresAt = Date().addingTimeInterval(remaining)
            let raw = try login.encoded()
            let http = SiloHTTPStub(playbackResponses())
            let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
            do {
                _ = try await provider.externalPlaybackInfo(for: "movie:1", mediaSourceID: "42")
                XCTAssertTrue(eligible)
            } catch {
                XCTAssertFalse(eligible)
                XCTAssertEqual(error as? ExternalPlayerError, .unsupportedSource)
            }
            let requests = await http.requests
            XCTAssertEqual(requests.filter { $0.method == .delete }.count, eligible ? 0 : 1)
        }
    }

    func testExternalSiloRejectsShortSignedGrantEvenWithLongAccountLifetime() async throws {
        let raw = try credential().encoded()
        var responses = playbackResponses()
        let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(850))
        responses["/api/v2/playback/start"] = responses["/api/v2/playback/start"]?
            .replacingOccurrences(of: #""delivery":"original_http""#, with: #""expires_at":"\#(expiry)","delivery":"original_http""#)
        let http = SiloHTTPStub(responses)
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        do {
            _ = try await provider.externalPlaybackInfo(for: "movie:1", mediaSourceID: "42")
            XCTFail("An expiring signed grant must stay internal")
        } catch { XCTAssertEqual(error as? ExternalPlayerError, .unsupportedSource) }
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.method == .delete }.count, 1)
    }

    private func streamingResponses(
        height: Int = 1080, bitrate: Int = 1_808, channels: Int = 2
    ) -> [String: String] {
        var responses = playbackResponses()
        responses["/api/v2/playback/capabilities"] = """
        {"installation_id":"server1","protocol_versions":[3],"features":["fixed_media_file_v1"],
         "deliveries":["original_http","server_transcode_hls"],"state":"available","allowed":true}
        """
        responses["/api/v2/playback/start"] = """
        {"protocol_version":3,"outcome":"playable","session_id":"session1",
         "playback_plan":{"protocol_version":3,"delivery":"server_transcode_hls","effective_media_file_id":"42",
         "stream":{"url":"https://silo.test/base/api/v2/playback/transcode/session1/master.m3u8?st=stream-secret","headers":{},"header_refresh":"none"},
         "timeline":{"source_start_seconds":42,"player_start_seconds":42,"timeline_offset_seconds":0,"can_seek_anywhere":true},
         "effective_recipe":{"video_codec":"h264","audio_codec":"aac","width":1920,"height":\(height),"bitrate_kbps":\(bitrate),"audio_channels":\(channels)},
         "subtitle":{"mode":"off","inventory":[]}}}
        """
        return responses
    }

    func testCustomSiloLimitCarriesIndependentHeightBudgetResumeAndOwnedCleanup() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub(streamingResponses())
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        var options = StreamingPlaybackOptions(
            quality: try .custom(maximumHeight: 1080, bitrateKbps: 2_000), codec: .preferH264
        )
        options.startPosition = 42
        let request = try await provider.playbackInfo(
            for: "movie:1", mediaSourceID: "42", forceTranscode: false, streaming: options
        )
        XCTAssertTrue(request.isTranscoding)
        XCTAssertEqual(request.streamingOptions, options)
        XCTAssertEqual(request.startPosition, 42)
        XCTAssertEqual(request.negotiatedStreamingVideoCodec, .h264)
        XCTAssertEqual(request.streamingSessionID, "session1")
        let starts = await http.requests
        let start = try XCTUnwrap(starts.first { $0.path == "/api/v2/playback/start" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(start.body)) as? [String: Any])
        XCTAssertEqual(body["quality_preference"] as? String, "1080p-high")
        XCTAssertEqual(body["bandwidth_cap_kbps"] as? Int, 1_808, "Reserve Silo's stereo AAC budget inside the total.")
        XCTAssertEqual(body["start_position"] as? Double, 42)
        XCTAssertEqual(body["file_id"] as? String, "42")
        XCTAssertEqual(body["allow_alternate_versions"] as? Bool, false)
        let client = try XCTUnwrap(body["client_playback_context"] as? [String: Any])
        let deliveries = try XCTUnwrap(client["deliveries"] as? [String: [String: Any]])
        XCTAssertEqual(deliveries["original_http"]?["enabled"] as? Bool, false)
        XCTAssertEqual(deliveries["hls"]?["max_channels"] as? Int, 2)
        await provider.releaseStreamingSession(request)
        await provider.releaseStreamingSession(request)
        let requests = await http.requests
        let stops = requests.filter { $0.method == .delete }
        XCTAssertEqual(stops.count, 1)
        let stop = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(stops.first?.body)) as? [String: Any])
        XCTAssertNil(stop["position"], "Encoding cleanup must not overwrite resume with a fabricated sample.")
        XCTAssertNotNil(stop["stop_id"])
    }

    func testSiloRejectsBoundsViolationsAndReleasesOnlyTheReturnedSession() async throws {
        for response in [
            streamingResponses(height: 2160),
            streamingResponses(bitrate: 2_000),
            streamingResponses(channels: 6)
        ] {
            let raw = try credential().encoded()
            let http = SiloHTTPStub(response)
            let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
            do {
                _ = try await provider.playbackInfo(
                    for: "movie:1", mediaSourceID: "42", forceTranscode: false,
                    streaming: .init(quality: try .custom(maximumHeight: 1080, bitrateKbps: 2_000))
                )
                XCTFail("A response outside the selected limits must not be played.")
            } catch {
                guard case .serverRefusal = error as? StreamingQualityError else { return XCTFail("\(error)") }
            }
            let requests = await http.requests
            XCTAssertEqual(requests.filter { $0.method == .delete }.map(\.path), ["/api/v2/playback/session1"])
        }
    }

    func testUnsupportedSiloLimitsFailBeforeNetworkAndMaximumRetainsOriginalRoute() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub(playbackResponses())
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        for quality in [StreamingQuality.low, try .custom(maximumHeight: 1440, bitrateKbps: 2_000)] {
            do {
                _ = try await provider.playbackInfo(
                    for: "movie:1", mediaSourceID: "42", forceTranscode: false,
                    streaming: .init(quality: quality)
                )
                XCTFail("Unsupported native resolutions must remain explicit.")
            } catch {
                guard case .serverRefusal = error as? StreamingQualityError else { return XCTFail("\(error)") }
            }
        }
        let before = await http.requests
        XCTAssertTrue(before.isEmpty)
        let request = try await provider.playbackInfo(
            for: "movie:1", mediaSourceID: "42", forceTranscode: false,
            streaming: .init(quality: .original, codec: .preferHEVC)
        )
        XCTAssertFalse(request.isTranscoding)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 3, "Maximum retains the existing metadata/capabilities/start path.")
        let start = try XCTUnwrap(requests.first { $0.path == "/api/v2/playback/start" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(start.body)) as? [String: Any])
        XCTAssertEqual(body["quality_preference"] as? String, "original")
        XCTAssertNil(body["bandwidth_cap_kbps"])
    }

    func testSiloHEVCPreferenceDeclinesBeforeOpeningAnEncodingSession() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub(streamingResponses())
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        do {
            _ = try await provider.playbackInfo(
                for: "movie:1", mediaSourceID: "42", forceTranscode: false,
                streaming: .init(quality: .hd720, codec: .preferHEVC)
            )
            XCTFail("The shared codec policy must choose the H.264 retry explicitly.")
        } catch { XCTAssertEqual(error as? StreamingQualityError, .codecUnavailable(.hevc)) }
        let requests = await http.requests
        XCTAssertFalse(requests.contains { $0.path == "/api/v2/playback/start" })
    }

    func testOriginalQualityKeepsClientHDRAndAudioHandlingOutOfServerHLSClaims() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub(playbackResponses())
        let provider = try SiloProvider(
            context: context(raw), credentials: SiloCredentialStub(raw), http: http,
            capabilities: .init(supportsHDR10: false, supportsHLG: false, supportsDolbyVision: false)
        )
        let request = try await provider.playbackInfo(
            for: "movie:1", mediaSourceID: "42", forceTranscode: false,
            streaming: .init(quality: .original)
        )
        XCTAssertEqual(request.deliveryMode, .directPlay)
        let requests = await http.requests
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(requests.first { $0.path == "/api/v2/playback/start" }?.body)
        ) as? [String: Any])
        XCTAssertEqual(body["quality_preference"] as? String, "original")
        XCTAssertNil(body["bandwidth_cap_kbps"])
        let client = try XCTUnwrap(body["client_playback_context"] as? [String: Any])
        let output = try XCTUnwrap(client["output"] as? [String: Any])
        let hdr = try XCTUnwrap(output["hdr_details"] as? [String: Any])
        XCTAssertEqual(hdr["hdr10"] as? Bool, false)
        XCTAssertEqual(hdr["hdr10_plus"] as? Bool, false)
        XCTAssertEqual(hdr["dolby_vision_profiles"] as? [Int], [])
        let deliveries = try XCTUnwrap(client["deliveries"] as? [String: [String: Any]])
        XCTAssertEqual(deliveries["original_http"]?["enabled"] as? Bool, true)
        XCTAssertEqual(deliveries["original_http"]?["validated_claims"] as? [String], [
            "client_managed_dynamic_range_v1", "client_selected_audio_track_v1"
        ])
        XCTAssertEqual(deliveries["hls"]?["validated_claims"] as? [String], [])
        XCTAssertTrue(
            (deliveries["hls"]?["containers"] as? [String])?.contains("hls") == true,
            "Silo checks the plan's stream container, not just its segment format."
        )
    }

    func testUnknownSiloRefusalDoesNotAssertThatTranscodingWasRequested() {
        let error = SiloStreamingSelection.refusal("adaptation_unavailable")
        XCTAssertEqual(error, .serverRefusal(
            "Silo did not return a playable stream. No recognized reason was supplied.", reason: .unspecified
        ))
        XCTAssertEqual(SiloStreamingSelection.refusal("transcoding_disabled"), .serverRefusal(
            "Silo reported that transcoding is disabled.", reason: .transcodingDisabled
        ))
    }

    func testKnownSiloReasonsSurviveWithoutSpeculativeRemedies() {
        let hdr = SiloStreamingSelection.refusal("hdr_transcode_unsupported")
        XCTAssertEqual(hdr.diagnosticCode, "hdr_transcode_unsupported")
        XCTAssertFalse(String(localized: hdr.userMessage).contains("tone"))
        XCTAssertEqual(SiloStreamingSelection.refusal("session_expired"),
                       .playback(.init(kind: .unavailable, provider: .silo, providerReason: .sessionExpired)))
    }

    func testSiloWillNotSilentlyReturnOriginalOrNormalizeAnUnsupportedQuality() async throws {
        var original = streamingResponses()
        original["/api/v2/playback/start"] = playbackResponses()["/api/v2/playback/start"]
        var normalized = streamingResponses()
        normalized["/api/v2/playback/start"] = normalized["/api/v2/playback/start"]?
            .replacingOccurrences(
                of: #""effective_recipe":{"#,
                with: #""degradation_warnings":[{"code":"quality_preference_normalized"}],"effective_recipe":{"#
            )
        for responses in [original, normalized] {
            let raw = try credential().encoded()
            let http = SiloHTTPStub(responses)
            let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
            do {
                _ = try await provider.playbackInfo(
                    for: "movie:1", mediaSourceID: "42", forceTranscode: false,
                    streaming: .init(quality: try .custom(maximumHeight: 1080, bitrateKbps: 2_000))
                )
                XCTFail("Server substitution must not remove the user's limits.")
            } catch {
                guard case .serverRefusal = error as? StreamingQualityError else { return XCTFail("\(error)") }
            }
            let requests = await http.requests
            XCTAssertEqual(requests.filter { $0.method == .delete }.count, 1)
        }
    }

    func testSiloKeepsAnOriginalThatFitsAndReservesItsOwnAudioBudgetWhenForced() async throws {
        var responses = playbackResponses()
        responses["/api/v2/catalog/items/movie:1"] = responses["/api/v2/catalog/items/movie:1"]?
            .replacingOccurrences(of: #""bitrate":12000"#, with: #""bitrate":1500"#)
            .replacingOccurrences(of: #""width":3840,"height":2160"#, with: #""width":1280,"height":720"#)
        let raw = try credential().encoded()
        let http = SiloHTTPStub(responses)
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let result = try await provider.playbackInfo(
            for: "movie:1", mediaSourceID: "42", forceTranscode: false, streaming: .init(quality: .hd720)
        )
        XCTAssertFalse(result.isTranscoding)
        let requests = await http.requests
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(requests.first { $0.path == "/api/v2/playback/start" }?.body)
        ) as? [String: Any])
        XCTAssertEqual(body["quality_preference"] as? String, "original")
        XCTAssertNil(body["bandwidth_cap_kbps"])

        let dto = try JSONDecoder().decode(SiloItem.self, from: Data(
            try XCTUnwrap(responses["/api/v2/catalog/items/movie:1"]).utf8
        ))
        let file = try XCTUnwrap(dto.versions?.first)
        let forced = try SiloStreamingSelection(
            options: .init(quality: .original, forceTranscoding: true), source: file, forceTranscode: false
        )
        XCTAssertTrue(forced.requiresEncoding)
        XCTAssertEqual(forced.qualityPreference, "720p-high")
        XCTAssertEqual(forced.videoBudgetKbps, 1_308)
    }

    func testSiloStartKeepsAudioAndSubtitleSelectionAndZeroResume() throws {
        let source = try JSONDecoder().decode(SiloFileVersion.self, from: Data(#"""
        {"file_id":"42","resolution":"1080p","codec_video":"h264","codec_audio":"aac",
         "container":"mp4","file_size":100,"duration":600,"bitrate":10000,
         "video_tracks":[{"width":1920,"height":1080}],
         "audio_tracks":[{"language":"eng","default":true},{"language":"fra","default":false}],
         "subtitle_tracks":[{"language":"eng","codec":"srt","forced":false,"default":true,"external":true}]}
        """#.utf8))
        var options = StreamingPlaybackOptions(quality: .hd720)
        options.startPosition = 0
        options.audioTrack = source.playbackAudioTracks[1]
        options.subtitlesOff = true
        let selection = try SiloStreamingSelection(options: options, source: source, forceTranscode: false)
        let start = SiloPlaybackStart(
            installation_id: "server", file_id: "42", profile_id: "profile",
            capabilities: .default, forceTranscode: false, streaming: selection
        )
        XCTAssertEqual(start.audio_track_index, 1)
        XCTAssertNil(start.subtitle_track_index)
        XCTAssertEqual(start.start_position, 0)
        XCTAssertEqual(start.bandwidth_cap_kbps, 1_808)
    }
}
