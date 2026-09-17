import CoreModels
import CoreNetworking
import XCTest
@testable import ProviderJellyfin

private actor StubAuthenticatedStreamProber: AuthenticatedHTTPStreamProbing {
    let facts: ProbedStreamFacts?
    private(set) var locators: [AuthenticatedHTTPPlaybackLocator] = []

    init(facts: ProbedStreamFacts?) {
        self.facts = facts
    }

    func probe(locator: AuthenticatedHTTPPlaybackLocator) async -> ProbedStreamFacts? {
        locators.append(locator)
        return facts
    }
}

final class EmbyProviderParityTests: XCTestCase {
    private func makeSession(provider: ProviderKind = .emby) -> UserSession {
        UserSession(
            server: MediaServer(
                id: "emby-server",
                name: "Emby Home",
                baseURL: URL(string: "http://host:8096")!,
                provider: provider
            ),
            userID: "u1",
            userName: "Alice",
            deviceID: "d1",
            accessToken: "TOKEN"
        )
    }

    func testProviderUsesEmbyIdentityWhileSharingMediaBrowserImplementation() {
        let provider = JellyfinProvider(session: makeSession(), http: StubHTTPClient())

        XCTAssertEqual(provider.kind, .emby)
        XCTAssertTrue(provider.kind.usesMediaBrowserAPI)
    }

    func testUndatedNextUpUsesLatestEpisodeActivityWhenSeriesHasNoDate() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/Users/u1/Items/Resume", json: """
            {"Items":[{"Id":"old","Name":"Old movie","Type":"Movie","UserData":{
              "PlaybackPositionTicks":100000000,"LastPlayedDate":"2026-09-01T00:00:00Z"
            }}],"TotalRecordCount":1}
            """)
            stub.stub(pathSuffix: "/Shows/NextUp", json: """
            {"Items":[{"Id":"next","Name":"Next episode","Type":"Episode","SeriesId":"show",
              "UserData":{"PlaybackPositionTicks":0,"Played":false}}],"TotalRecordCount":1}
            """)
            stub.stub(pathSuffix: "/Users/u1/Items", requiring: [
                URLQueryItem(name: "Ids", value: "show")
            ], json: """
            {"Items":[{"Id":"show","Type":"Series","UserData":{"Played":false}}]}
            """)
            stub.stub(pathSuffix: "/Users/u1/Items", requiring: [
                URLQueryItem(name: "ParentId", value: "show")
            ], json: """
            {"Items":[{"Id":"completed","Type":"Episode","SeriesId":"show",
              "UserData":{"Played":true,"LastPlayedDate":"2026-09-08T21:00:00Z"}}]}
            """)
            let provider = JellyfinProvider(session: makeSession(provider: kind), http: stub)
            let items = try await provider.continueWatching(limit: 1)
            let next = try XCTUnwrap(items.first)
            XCTAssertEqual(next.id, "next", "\(kind): recent next-up must not sink behind old resumes")
            XCTAssertEqual(next.lastPlayedAt, JellyfinProvider.parseDate("2026-09-08T21:00:00Z"))
            XCTAssertFalse(next.isPlayed)
            XCTAssertEqual(next.resumePosition, 0)
            let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/Users/u1/Items"))
            XCTAssertEqual(query.first { $0.name == "ParentId" }?.value, "show")
            XCTAssertEqual(query.first { $0.name == "SortBy" }?.value, "DatePlayed")
            XCTAssertEqual(query.first { $0.name == "SortOrder" }?.value, "Descending")
            XCTAssertEqual(query.first { $0.name == "Limit" }?.value, "1")
            XCTAssertEqual(query.first { $0.name == "IncludeItemTypes" }?.value, "Episode")
        }
    }

    func testNextUpDateDoesNotComeFromAnUnrelatedSeries() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/Resume", json: #"{"Items":[]}"#)
        stub.stub(pathSuffix: "/Shows/NextUp", json: """
        {"Items":[{"Id":"next","Type":"Episode","SeriesId":"show","UserData":{"Played":false}}]}
        """)
        stub.stub(pathSuffix: "/Users/u1/Items", requiring: [
            URLQueryItem(name: "Ids", value: "show")
        ], json: #"{"Items":[{"Id":"show","Type":"Series","UserData":{}}]}"#)
        stub.stub(pathSuffix: "/Users/u1/Items", requiring: [
            URLQueryItem(name: "ParentId", value: "show")
        ], json: """
        {"Items":[{"Id":"other","Type":"Episode","SeriesId":"another-show",
          "UserData":{"LastPlayedDate":"2026-09-08T21:00:00Z"}}]}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)
        let items = try await provider.continueWatching(limit: 10)
        XCTAssertEqual(items.map(\.id), ["next"])
        XCTAssertNil(items.first?.lastPlayedAt)
    }

    func testSubtitleDeliveryPreservesSRTWithoutAddingWebVTTPositioning() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/Users/u1/Items/episode1", json: """
            {"Id":"episode1","Name":"Episode","Type":"Episode","MediaSources":[
              {"Id":"source1","MediaStreams":[
                {"Index":2,"Type":"Subtitle","Codec":"SRT","IsExternal":true,"IsTextSubtitleStream":true},
                {"Index":3,"Type":"Subtitle","Codec":"subrip","IsTextSubtitleStream":true},
                {"Index":4,"Type":"Subtitle","Codec":"webvtt","IsTextSubtitleStream":true},
                {"Index":5,"Type":"Subtitle","Codec":"ass","IsTextSubtitleStream":true},
                {"Index":6,"Type":"Subtitle","Codec":"hdmv_pgs_subtitle","IsTextSubtitleStream":false}
              ]}
            ]}
            """)
            let provider = JellyfinProvider(session: makeSession(provider: kind), http: stub)
            let tracks = try await provider.subtitleTracks(forItemID: "episode1")
            XCTAssertEqual(tracks.count, 5)
            for (track, format) in zip(tracks.prefix(4), ["srt", "srt", "vtt", "vtt"]) {
                guard case .authenticatedHTTP(let locator)? = track.deliverySource else {
                    return XCTFail("Expected subtitle delivery source")
                }
                XCTAssertEqual(locator.provider, kind)
                XCTAssertEqual(locator.resource.path, "Videos/episode1/source1/Subtitles/\(track.id)/0/Stream.\(format)")
                XCTAssertEqual(locator.formatHint.container, format)
            }
            XCTAssertTrue(tracks[0].isExternal)
            XCTAssertFalse(tracks[1].isExternal)
            XCTAssertTrue(tracks[4].isImageBasedSubtitle)
            XCTAssertNil(tracks[4].deliverySource)
        }
    }

    func testEmbyUsesMediaBrowserExtrasRoutesAndMapping() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Items/movie1/LocalTrailers", json: "[]")
        stub.stub(pathSuffix: "/Items/movie1/SpecialFeatures", json: """
        [{"Id":"extra1","Name":"Deleted Scene","Type":"Video","ExtraType":"DeletedScene"}]
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let extras = try await provider.extras(for: "movie1")

        XCTAssertEqual(extras.map(\.item.id), ["extra1"])
        XCTAssertEqual(extras.map(\.kind), [.deletedScene])
        XCTAssertEqual(provider.kind, .emby)
        XCTAssertTrue(stub.sentPaths.contains { $0.hasSuffix("/Users/u1/Items/movie1/SpecialFeatures") })
    }

    func testEmbyMapsChapterMarkersToIntroAndCreditsSegments() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/episode1", json: """
        {
          "Id":"episode1",
          "Name":"Episode",
          "Type":"Episode",
          "RunTimeTicks":18000000000,
          "Chapters":[
            {"StartPositionTicks":600000000,"MarkerType":"IntroStart"},
            {"StartPositionTicks":1200000000,"MarkerType":"IntroEnd"},
            {"StartPositionTicks":16800000000,"MarkerType":"CreditsStart"}
          ]
        }
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let segments = try await provider.mediaSegments(for: "episode1")

        XCTAssertEqual(segments.map(\.kind), [.intro, .credits])
        XCTAssertEqual(segments[0].start, 60)
        XCTAssertEqual(segments[0].end, 120)
        XCTAssertEqual(segments[1].start, 1680)
        XCTAssertEqual(segments[1].end, 1800)
        XCTAssertFalse(stub.sentPaths.contains { $0.contains("MediaSegments") })
    }

    func testEmbyPlaybackUsesBIFTrickplayAndEmbyAuthenticatedResources() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/movie1", json: """
        {"Id":"movie1","Name":"Movie","Type":"Movie","RunTimeTicks":36000000000,
         "Studios":[{"Name":"Emby Studio","Id":1234}],
         "MediaStreams":[
           {"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160,
            "VideoRange":"SDR","ExtendedVideoType":"DolbyVision",
            "ExtendedVideoSubType":"DoviProfile81"},
           {"Index":1,"Type":"Audio","Codec":"truehd","Channels":8,"IsDefault":true}
         ],
         "MediaSources":[
           {"Id":"src1","Name":"4K Remux","Container":"mkv",
            "MediaStreams":[
              {"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160,
               "VideoRange":"SDR"},
              {"Index":1,"Type":"Audio","Codec":"truehd","Channels":8,"IsDefault":true}
            ]},
           {"Id":"src2","Name":"1080p","Container":"mp4",
            "MediaStreams":[
              {"Index":0,"Type":"Video","Codec":"h264","Width":1920,"Height":1080,
               "VideoRange":"SDR"}
            ]}
         ]}
        """)
        stub.stub(pathSuffix: "/Items/movie1/PlaybackInfo", json: """
        {"MediaSources":[{"Id":"src1","Container":"mp4","SupportsDirectPlay":true}],
         "PlaySessionId":"ps1"}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let request = try await provider.playbackInfo(
            for: "movie1",
            mediaSourceID: "src1",
            forceTranscode: false
        )

        XCTAssertEqual(request.sourceProvider, .emby)
        XCTAssertEqual(request.item.studios, ["Emby Studio"])
        XCTAssertEqual(
            request.item.technicalBadges.map(\.label),
            ["4K", "Dolby Vision", "Dolby TrueHD", "HDR10"]
        )
        XCTAssertEqual(request.sourceMetadata?.video?.dolbyVisionProfile, 8)
        XCTAssertEqual(request.sourceMetadata?.video?.videoRangeType, "DOVIWithHDR10")
        XCTAssertEqual(
            request.item.versions.first?.technicalBadges.map(\.label),
            ["4K", "Dolby Vision", "Dolby TrueHD", "HDR10"]
        )
        XCTAssertEqual(
            request.item.versions.last?.technicalBadges.map(\.label),
            ["1080p", "SDR"]
        )
        guard case .some(.authenticatedHTTP(let locator)) = request.scrubPreview?.plexBIFResource else {
            return XCTFail("expected authenticated Emby BIF resource")
        }
        XCTAssertEqual(locator.provider, .emby)
        XCTAssertEqual(locator.resource.path, "Videos/movie1/index.bif")
        XCTAssertEqual(locator.resource.queryItems.first?.name, "Width")
        XCTAssertEqual(locator.resource.queryItems.first?.value, "320")

        let body = try XCTUnwrap(stub.sentBodies.first {
            $0.key.hasSuffix("/Items/movie1/PlaybackInfo")
        }?.value)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["MediaSourceId"] as? String, "src1")
        XCTAssertEqual(json["EnableTranscoding"] as? Bool, true)
    }

    func testEmbyExtendedHDRTypeOverridesCoarseSDRRange() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/air", json: """
        {"Id":"air","Name":"Air","Type":"Movie",
         "MediaStreams":[
           {"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160,
            "VideoRange":"SDR","ExtendedVideoType":"Hdr10"}
         ]}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "air")

        XCTAssertEqual(item.technicalBadges.map(\.label), ["4K", "HDR10"])
        XCTAssertFalse(item.technicalBadges.map(\.label).contains("SDR"))
    }

    func testHDR10PlusSurvivesEmbyAndJellyfinItemAndPlaybackMapping() async throws {
        for kind in [ProviderKind.emby, .jellyfin] {
            for container in ["mkv", "mp4"] {
                let hdrField = kind == .emby
                    ? "\"ExtendedVideoType\":\"Hdr10Plus\""
                    : "\"VideoRangeType\":\"HDR10Plus\""
                let streams = """
                [{"Index":0,"Type":"Video","Codec":"hevc","CodecTag":"hvc1",
                  "Width":3840,"Height":2160,"VideoRange":"HDR",\(hdrField)},
                 {"Index":1,"Type":"Audio","Codec":"aac","Channels":2,"IsDefault":true}]
                """
                let stub = StubHTTPClient()
                stub.stub(pathSuffix: "/Users/u1/Items/hdr", json: """
                {"Id":"hdr","Name":"HDR fixture","Type":"Movie","RunTimeTicks":1200000000,
                 "MediaStreams":\(streams),
                 "MediaSources":[{"Id":"hdr-source","Container":"\(container)","MediaStreams":\(streams)}]}
                """)
                stub.stub(pathSuffix: "/Items/hdr/PlaybackInfo", json: """
                {"MediaSources":[{"Id":"hdr-source","Container":"\(container)",
                  "SupportsDirectPlay":true,"MediaStreams":\(streams)}],"PlaySessionId":"session"}
                """)
                let provider = JellyfinProvider(session: makeSession(provider: kind), http: stub,
                                                hybridEngineEnabled: true)
                let request = try await provider.playbackInfo(for: "hdr")
                XCTAssertFalse(request.isTranscoding)
                XCTAssertEqual(request.item.mediaInfo?.dynamicRangeBadges.map(\.label), ["HDR10+"])
                XCTAssertEqual(request.sourceMetadata?.video?.videoRangeType, "HDR10Plus")
                XCTAssertEqual(request.localRemuxSource?.sourceMetadata.video?.videoRangeType, "HDR10Plus")
                XCTAssertEqual(SourceDynamicRange.providerHint(from: request.sourceMetadata), .hdr10Plus)
            }
        }
    }

    func testEmbyWithoutHDR10PlusEvidenceKeepsGenericHDR10Badge() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/hdr", json: """
        {"Id":"hdr","Name":"HDR fixture","Type":"Movie","MediaStreams":[
          {"Index":0,"Type":"Video","Codec":"hevc","VideoRange":"HDR","ExtendedVideoType":"Hdr10"}
        ]}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)
        let item = try await provider.item(id: "hdr")
        XCTAssertEqual(item.mediaInfo?.dynamicRangeBadges.map(\.label), ["HDR10"])
    }

    func testEmbyBuildsSecretFreeDirectLocatorForAtmosProbe() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/atmos", json: """
        {"Id":"atmos","Name":"Atmos Movie","Type":"Movie",
         "MediaStreams":[
           {"Index":0,"Type":"Video","Codec":"hevc"},
           {"Index":1,"Type":"Audio","Codec":"eac3","Channels":6,"IsDefault":true}
         ],
         "MediaSources":[
           {"Id":"source-1","ETag":"etag-1","Container":"mkv","Size":123456,
            "MediaStreams":[
              {"Index":0,"Type":"Video","Codec":"hevc"},
              {"Index":1,"Type":"Audio","Codec":"eac3","Channels":6,"IsDefault":true}
            ]}
         ]}
        """)
        stub.stub(pathSuffix: "/Items/atmos/PlaybackInfo", json: """
        {"MediaSources":[
          {"Id":"source-1","ETag":"etag-1","Container":"mkv","Size":123456,
           "SupportsDirectPlay":true,
           "MediaStreams":[
             {"Index":0,"Type":"Video","Codec":"hevc"},
             {"Index":1,"Type":"Audio","Codec":"eac3","Channels":6,"IsDefault":true}
           ]}
        ],"PlaySessionId":"play-atmos"}
        """)
        let prober = StubAuthenticatedStreamProber(
            facts: ProbedStreamFacts(
                audioCodec: "eac3",
                audioChannels: 6,
                audioIsAtmos: true
            )
        )
        let provider = JellyfinProvider(
            session: makeSession(),
            http: stub,
            authenticatedStreamProber: prober
        )
        let item = try await provider.item(id: "atmos")

        let facts = await provider.supplementalStreamFacts(for: item)

        XCTAssertEqual(facts?.audioIsAtmos, true)
        let capturedLocators = await prober.locators
        let locator = try XCTUnwrap(capturedLocators.first)
        XCTAssertEqual(locator.provider, .emby)
        XCTAssertEqual(locator.deliveryMode, .directFile)
        XCTAssertEqual(locator.purpose, .originalFile)
        XCTAssertEqual(locator.resource.path, "Videos/atmos/stream.mkv")
        XCTAssertTrue(locator.resource.queryItems.contains {
            $0.name == "mediaSourceId" && $0.value == "source-1"
        })
        XCTAssertFalse(String(describing: locator).contains("TOKEN"))

        _ = await provider.supplementalStreamFacts(for: item)
        let cachedLocators = await prober.locators
        XCTAssertEqual(cachedLocators.count, 1, "same revision should reuse the cached probe")

        let request = try await provider.playbackInfo(
            for: "atmos",
            mediaSourceID: "source-1",
            forceTranscode: false
        )
        XCTAssertEqual(request.item.mediaInfo?.audio?.profile, "Dolby Atmos")
        XCTAssertEqual(request.sourceMetadata?.audio?.profile, "Dolby Atmos")
        XCTAssertTrue(request.audioTracks.first { $0.isDefault }?.isAtmos ?? false)
        XCTAssertTrue(request.item.technicalBadges.map(\.label).contains("Dolby Atmos"))
    }

    func testAtmosProbeCapabilityIsEmbyOnly() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/plain", json: """
        {"Id":"plain","Name":"Plain","Type":"Movie",
         "MediaStreams":[{"Index":0,"Type":"Audio","Codec":"eac3","Channels":6}],
         "MediaSources":[{"Id":"source","Container":"mkv",
          "MediaStreams":[{"Index":0,"Type":"Audio","Codec":"eac3","Channels":6}]}]}
        """)
        let prober = StubAuthenticatedStreamProber(
            facts: ProbedStreamFacts(audioIsAtmos: true)
        )
        let provider = JellyfinProvider(
            session: makeSession(provider: .jellyfin),
            http: stub,
            authenticatedStreamProber: prober
        )
        let item = try await provider.item(id: "plain")

        let facts = await provider.supplementalStreamFacts(for: item)
        let capturedLocators = await prober.locators

        XCTAssertNil(facts)
        XCTAssertTrue(capturedLocators.isEmpty)
    }

    func testProbeDescriptorStoreEvictsLeastRecentlyUsedItems() async throws {
        let store = MediaBrowserProbeDescriptorStore()
        for index in 0...256 {
            let data = Data("""
            [{"Id":"source-\(index)","ETag":"etag-\(index)","Container":"mkv","Size":\(index + 1)}]
            """.utf8)
            let sources = try JSONDecoder().decode([MediaSourceInfo].self, from: data)
            await store.remember(itemID: "item-\(index)", sources: sources)
        }

        let evicted = await store.descriptor(for: "item-0")
        let retained = await store.descriptor(for: "item-256")
        XCTAssertNil(evicted)
        XCTAssertNotNil(retained)
    }

    func testEmbyEpisodesAreNormalizedIntoNumericOrder() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items", json: """
        {"Items":[
          {"Id":"extra","Name":"Behind the Scenes","Type":"Video"},
          {"Id":"e10","Name":"Episode 10","Type":"Episode","ParentIndexNumber":1,"IndexNumber":10},
          {"Id":"e2","Name":"Episode 2","Type":"Episode","ParentIndexNumber":1,"IndexNumber":2},
          {"Id":"e1","Name":"Episode 1","Type":"Episode","ParentIndexNumber":1,"IndexNumber":1}
        ],"TotalRecordCount":4}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let children = try await provider.children(of: "season1")

        XCTAssertEqual(children.map(\.id), ["e1", "e2", "e10", "extra"])
        let query = try XCTUnwrap(
            stub.queryItems(forPathSuffix: "/Users/u1/Items")
        )
        XCTAssertEqual(
            query.first(where: { $0.name == "SortBy" })?.value,
            "ParentIndexNumber,IndexNumber,SortName"
        )
    }

    func testEmbyThemeMusicUsesCombinedThemeMediaEndpoint() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Items/show1/ThemeMedia", json: """
        {
          "ThemeSongsResult":{
            "Items":[{"Id":"song1","Name":"Main Theme","Type":"Audio"}],
            "TotalRecordCount":1
          }
        }
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let resolvedTheme = try await provider.themeMusic(for: "show1")
        let theme = try XCTUnwrap(resolvedTheme)

        XCTAssertEqual(theme.title, "Main Theme")
        guard case .authenticatedHTTP(let locator) = theme.playbackSource else {
            return XCTFail("expected authenticated theme resource")
        }
        XCTAssertEqual(locator.provider, .emby)
        XCTAssertEqual(locator.resource.path, "Audio/song1/universal")
    }
}
