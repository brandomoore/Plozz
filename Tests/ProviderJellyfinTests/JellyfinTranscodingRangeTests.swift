import CoreModels
import Foundation
import XCTest
@testable import ProviderJellyfin

final class JellyfinTranscodingRangeTests: XCTestCase {
    func testOnlyForcedConversionProfilesConstrainH264ToTheProviderSpecificSDRRange() async throws {
        let original = JellyfinCapabilityProfile.appleTV(
            capabilities: .init(supportsHEVC: true, supportsHDR10: true)
        )
        for provider in [ProviderKind.jellyfin, .emby] {
            for mode in [JellyfinClient.PlaybackStreamMode.auto, .remux, .transcode] {
                let http = StubHTTPClient()
                http.stub(pathSuffix: "/Items/movie/PlaybackInfo", json: #"{"MediaSources":[]}"#)
                let client = JellyfinClient(
                    baseURL: URL(string: "https://media.example.test")!,
                    deviceProfile: .init(deviceID: "device"), providerKind: provider,
                    http: http, capabilityProfile: original
                )
                _ = try await client.playbackInfo(userID: "user", itemID: "movie", mode: mode)
                let data = try XCTUnwrap(http.sentBodies.first { $0.key.hasSuffix("/PlaybackInfo") }?.value)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any])
                let codecs = try XCTUnwrap(profile["CodecProfiles"] as? [[String: Any]])
                let h264Conditions = codecs.filter { $0["Codec"] as? String == "h264" }
                    .flatMap { $0["Conditions"] as? [[String: Any]] ?? [] }
                let ranges = h264Conditions.filter {
                    ["VideoRange", "VideoRangeType"].contains($0["Property"] as? String ?? "")
                }
                if case .transcode = mode {
                    XCTAssertEqual(ranges.count, 1)
                    XCTAssertEqual(ranges.first?["Property"] as? String,
                                   provider == .emby ? "VideoRange" : "VideoRangeType")
                    XCTAssertEqual(ranges.first?["Value"] as? String, "SDR")
                    XCTAssertEqual(ranges.first?["Condition"] as? String, "Equals")
                    XCTAssertEqual(body["EnableDirectPlay"] as? Bool, false)
                    XCTAssertEqual(body["EnableDirectStream"] as? Bool, false)
                } else {
                    XCTAssertTrue(ranges.isEmpty, "Do not narrow direct-play or remux capabilities")
                }
                let hevc = try XCTUnwrap(codecs.first { $0["Codec"] as? String == "hevc" })
                let conditions = try XCTUnwrap(hevc["Conditions"] as? [[String: Any]])
                XCTAssertTrue(conditions.contains {
                    ($0["Value"] as? String)?.contains("HDR10") == true
                }, "The H.264 output constraint must not narrow HEVC")
            }
        }
        XCTAssertEqual(original, .appleTV(capabilities: .init(supportsHEVC: true, supportsHDR10: true)))
    }

    func testSDRRequestPreservesEveryUnrelatedRenditionParameterAndSourceFact() throws {
        for provider in [ProviderKind.jellyfin, .emby] {
            let name = provider == .emby ? "h264-videorange" : "h264-rangetype"
            let otherName = provider == .emby ? "h264-rangetype" : "h264-videorange"
            let issued = "/Videos/movie/master.m3u8?VideoCodec=h264&\(name.uppercased())=HDR&\(name)=HDR10"
                + "&VideoBitrate=1872000&AudioBitrate=128000&MaxHeight=720"
                + "&AudioStreamIndex=4&SubtitleStreamIndex=6&SubtitleMethod=Encode"
                + "&PlaySessionId=owned-session&MediaSourceId=version&api_key=fixture%2Btoken"
                + "&hevc-rangetype=HDR10&hevc-videorange=HDR"
            var source = try mediaSource(url: issued)
            let originalStreams = source.MediaStreams?.map(\.VideoRangeType)
            try source.requestSDRForH264Transcode(provider: provider, forceVideoTranscode: true)
            let before = try XCTUnwrap(URLComponents(string: issued)?.queryItems)
            let after = try XCTUnwrap(URLComponents(string: XCTUnwrap(source.TranscodingUrl))?.queryItems)
            XCTAssertEqual(after.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame },
                           [.init(name: name, value: "SDR")])
            XCTAssertEqual(after.filter { $0.name != name },
                           before.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame })
            XCTAssertFalse(after.contains { $0.name == otherName })
            XCTAssertEqual(source.MediaStreams?.map(\.VideoRangeType), originalStreams)
        }
    }

    func testVideoCopyAndHEVCPathsRemainByteForByteUnchanged() throws {
        let cases: [(String, String?, Bool)] = [
            ("VideoCodec=hevc&AllowVideoStreamCopy=false&hevc-rangetype=HDR10", "hevc", true),
            ("VideoCodec=copy&AllowVideoStreamCopy=true", "h264", false),
            ("VideoCodec=h264&AllowVideoStreamCopy=true", "h264", false),
            ("VideoCodec=h264", "h264", false),
            ("VideoCodec=hevc,h264&AllowVideoStreamCopy=true", "hevc", false),
            ("VideoCodec=h264", nil, false)
        ]
        for provider in [ProviderKind.jellyfin, .emby] {
            for (query, codec, forced) in cases {
                let issued = "/Videos/movie/master.m3u8?\(query)&PlaySessionId=owned"
                var source = try mediaSource(url: issued, codec: codec)
                try source.requestSDRForH264Transcode(provider: provider, forceVideoTranscode: forced)
                XCTAssertEqual(source.TranscodingUrl, issued, query)
            }
            var direct = try mediaSource(url: nil)
            try direct.requestSDRForH264Transcode(provider: provider, forceVideoTranscode: false)
            XCTAssertNil(direct.TranscodingUrl)
        }
    }

    func testAutomaticCodecConversionAndExplicitNoCopyRequestSDR() throws {
        for provider in [ProviderKind.jellyfin, .emby] {
            for (query, codec) in [
                ("vIdEoCoDeC=H264&AllowVideoStreamCopy=true", "hevc"),
                ("VideoCodec=h264&AllowVideoStreamCopy=false", "h264"),
                ("VideoCodec=H264,%20HEVC&AllowVideoStreamCopy=FALSE", "hevc")
            ] {
                var source = try mediaSource(url: "/Videos/movie/master.m3u8?\(query)", codec: codec)
                try source.requestSDRForH264Transcode(provider: provider, forceVideoTranscode: false)
                let result = try XCTUnwrap(URLComponents(string: XCTUnwrap(source.TranscodingUrl))?.queryItems)
                let name = provider == .emby ? "h264-videorange" : "h264-rangetype"
                XCTAssertEqual(result.first { $0.name == name }?.value, "SDR")
            }
        }
    }

    func testMalformedIssuedURLDoesNotBecomeAPlayableFallback() throws {
        var source = try mediaSource(url: "http://[invalid")
        XCTAssertThrowsError(try source.requestSDRForH264Transcode(provider: .emby, forceVideoTranscode: true)) {
            XCTAssertEqual($0 as? StreamingQualityError, .unavailable)
        }
    }

    func testOrdinaryAndBoundedH264ConversionsRequestSDRWithoutRelabelingSource() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            for range in ["HDR10", "DOVI", "SDR"] {
                for route in ["automatic", "forced", "bounded"] {
                    let (provider, http) = try fixture(kind: kind, range: range)
                    let request: PlaybackRequest
                    if route == "bounded" {
                        request = try await provider.playbackInfo(
                            for: "movie", mediaSourceID: "version", forceTranscode: false,
                            streaming: .init(quality: .hd720, codec: .preferH264)
                        )
                    } else {
                        request = try await provider.playbackInfo(
                            for: "movie", mediaSourceID: "version", forceTranscode: route == "forced"
                        )
                    }
                    guard case .authenticatedHTTP(let locator) = request.playbackSource else {
                        return XCTFail("Expected the negotiated rendition")
                    }
                    let name = kind == .emby ? "h264-videorange" : "h264-rangetype"
                    XCTAssertEqual(locator.resource.queryItems.first { $0.name == name }?.value, "SDR")
                    XCTAssertEqual(locator.mediaSourceID, "version")
                    XCTAssertEqual(request.playSessionID, "owned-session")
                    XCTAssertEqual(request.sourceMetadata?.video?.videoRangeType, range)
                    XCTAssertTrue(request.isTranscoding)
                    if route == "bounded" {
                        XCTAssertEqual(request.negotiatedStreamingVideoCodec, .h264)
                        XCTAssertEqual(locator.resource.queryItems.first { $0.name == "VideoBitrate" }?.value, "1872000")
                        XCTAssertNil(request.originalFileSource)
                        XCTAssertNil(request.localRemuxSource)
                    }
                    XCTAssertFalse(http.sentPaths.contains { $0.hasSuffix("/ActiveEncodings") })
                }
            }
        }
    }

    func testHEVCPreferenceAndItsH264FallbackKeepSeparateRangeRequests() throws {
        for provider in [ProviderKind.jellyfin, .emby] {
            let original = try mediaSource(url: "/Videos/movie/master.m3u8?VideoCodec=hevc&hevc-profile=main10")
            for preference in [StreamingCodecPreference.preferHEVC, .preferH264] {
                var source = original
                source.TranscodingUrl = try source.boundedTranscodingURL(
                    .init(quality: .hd720, codec: preference), supportsHEVC: true
                )
                try source.requestSDRForH264Transcode(provider: provider, forceVideoTranscode: true)
                let query = try XCTUnwrap(URLComponents(string: XCTUnwrap(source.TranscodingUrl))?.queryItems)
                let name = provider == .emby ? "h264-videorange" : "h264-rangetype"
                XCTAssertEqual(query.first { $0.name == name }?.value, preference == .preferH264 ? "SDR" : nil)
                XCTAssertEqual(query.first { $0.name == "hevc-profile" }?.value, "main10")
                XCTAssertEqual(source.MediaStreams?.first?.VideoRangeType, "HDR10")
            }
        }
    }

    private func mediaSource(url: String?, codec: String? = "hevc", range: String = "HDR10") throws -> MediaSourceInfo {
        var video: [String: Any] = ["Index": 0, "Type": "Video", "VideoRangeType": range, "BitDepth": 10]
        if let codec { video["Codec"] = codec }
        var source: [String: Any] = [
            "Id": "version", "Container": "mp4", "SupportsDirectPlay": false,
            "Bitrate": 30_000_000, "MediaStreams": [video]
        ]
        if let url { source["TranscodingUrl"] = url }
        return try JSONDecoder().decode(MediaSourceInfo.self, from: JSONSerialization.data(withJSONObject: source))
    }

    private func fixture(kind: ProviderKind, range: String) throws -> (JellyfinProvider, StubHTTPClient) {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/Users/user/Items/movie", json: #"{"Id":"movie","Name":"Movie","Type":"Movie"}"#)
        http.stub(pathSuffix: "/Items/movie/PlaybackInfo", json: """
        {"PlaySessionId":"owned-session","MediaSources":[{
          "Id":"version","Container":"mp4","SupportsDirectPlay":false,"Bitrate":30000000,
          "TranscodingUrl":"/Videos/movie/master.m3u8?VideoCodec=h264&AllowVideoStreamCopy=false&MediaSourceId=version",
          "MediaStreams":[{"Index":0,"Type":"Video","Codec":"hevc","BitDepth":10,"VideoRangeType":"\(range)"}]
        }]}
        """)
        let provider = JellyfinProvider(session: .init(
            server: .init(id: "server", name: "Server", baseURL: URL(string: "https://media.example.test")!, provider: kind),
            userID: "user", userName: "User", deviceID: "device", accessToken: "fixture"
        ), http: http)
        return (provider, http)
    }
}
