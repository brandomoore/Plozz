import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderJellyfin

/// Tests for Feature A (version mapping), B (Favorites-backed watchlist) and
/// C (metadata refresh) on the Jellyfin provider.
final class JellyfinVersionsWatchlistRefreshTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host:8096")!, provider: .jellyfin),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    // MARK: - Feature A: versions mapping

    func testRemoteDescriptionLanguagesReachEveryPickerWithoutInventingTracks() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let stub = StubHTTPClient()
            let sources = """
            [
              {"Id":"multi","IsRemote":true,"Container":"mkv",
               "Name":"🇫🇷 🇨🇦 🇬🇧 ✓ • 💾 87,8 Go • 🔎 Source\\n🎧 Atmos\\n📁 Film.MULTI.VF2.mkv",
               "MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264"},
                               {"Index":1,"Type":"Audio","Codec":"aac","Language":"eng","IsDefault":true},
                               {"Index":2,"Type":"Subtitle","Language":"jpn"}]},
              {"Id":"spanish","IsRemote":true,"Name":"🌍 Spanish",
               "MediaStreams":[{"Index":1,"Type":"Audio","Language":"spa"}]},
              {"Id":"multi-only","IsRemote":true,"Name":"🌍 Multi",
               "MediaStreams":[{"Index":1,"Type":"Audio","Language":"eng"}]},
              {"Id":"local","IsRemote":false,"Name":"🌍 French | English",
               "MediaStreams":[{"Index":1,"Type":"Audio","Language":"eng"}]},
              {"Id":"unknown-origin","Name":"🌍 French | English",
               "MediaStreams":[{"Index":1,"Type":"Audio","Language":"eng"}]},
              {"Id":"unlabelled","IsRemote":true,"Name":"Film.MULTI.French.English.mkv"},
              {"Id":"compact-multi","IsRemote":true,"Name":"🌍 🇫🇷 🇨🇦 🇬🇧 • 💾 87,8 Go • 🔎 Source",
               "MediaStreams":[{"Index":1,"Type":"Audio","Language":"eng"}]},
              {"Id":"compact-french","IsRemote":true,"Name":"🌍 🇫🇷 • 💾 26,2 Go • 🔎 Source",
               "MediaStreams":[{"Index":1,"Type":"Audio","Language":"eng"}]},
              {"Id":"named-multi","IsRemote":true,"Name":"🌍 French | Multi | English",
               "MediaStreams":[{"Index":1,"Type":"Audio","Language":"eng"}]}
            ]
            """
            stub.stub(pathSuffix: "/Users/u1/Items/i1", json: """
            {"Id":"i1","Name":"Title","Type":"Movie","MediaSources":\(sources)}
            """)
            stub.stub(pathSuffix: "/Items/i1/PlaybackInfo", json: #"{"MediaSources":\#(sources)}"#)
            var session = makeSession()
            session.server.provider = kind
            let provider = JellyfinProvider(session: session, http: stub)
            let item = try await provider.item(id: "i1")
            let locale = Locale(identifier: "en_US")
            XCTAssertEqual(item.versions.map { $0.audioLanguageNames(in: locale) }, [
                ["English", "French"], ["Spanish"], ["English"], ["English"], ["English"], [],
                ["English", "French"], ["English", "French"], ["English", "French"]
            ])
            XCTAssertEqual(item.mediaInfo?.audioLanguages, ["eng", "fr"])
            let row = MediaVersion.PickerPresentation(item.versions[0], locale: locale)
            XCTAssertEqual(row.prioritizedAudioLanguages(preferredLanguage: "eng", locale: locale), ["English", "French"])
            XCTAssertEqual(row.prioritizedAudioLanguages(preferredLanguage: "fra", locale: locale), ["French", "English"])
            XCTAssertEqual(row.audioLanguages.count - 1, 1)
            XCTAssertEqual(item.versions[0].playbackMediaSourceID, "multi")

            let request = try await provider.playbackInfo(for: "i1", mediaSourceID: "multi", forceTranscode: false)
            XCTAssertEqual(request.sourceMetadata?.audioLanguages, ["eng", "fr"])
            XCTAssertEqual(request.item.versions[0].audioLanguageNames(in: locale), ["English", "French"])
            XCTAssertEqual(request.audioTracks.map(\.language), ["eng"], "Description facts must not create track IDs.")
            XCTAssertEqual(request.audioTracks.map(\.id), [1])
            XCTAssertEqual(request.sourceMetadata?.audio?.codec, "aac")
            XCTAssertTrue(request.preferredAudioLanguages.isEmpty)
        }
    }

    func testRemoteDescriptionSizesDriveLabelsAndSortingWithoutChangingLocalFiles() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/Users/u1/Items/i1", json: """
            {"Id":"i1","Name":"Title","Type":"Movie","MediaSources":[
              {"Id":"smaller","IsRemote":true,"Size":7812500,"Name":"🌍 MULTI | 3,8 Mb | 3,6 Go"},
              {"Id":"larger","IsRemote":true,"Size":4882813,"Name":"🌍 MULTI | 5,5 Mb | 5,2 Go"},
              {"Id":"largest","IsRemote":true,"Size":26367188,"Name":"🌍 MULTI | 27 Mb | 26,2 Go"},
              {"Id":"local","IsRemote":false,"Size":9000000000,"Name":"Old 99 GB label"},
              {"Id":"unknown-origin","Size":8000000000,"Name":"Old 99 GB label"},
              {"Id":"bitrate-only","IsRemote":true,"Size":7000000000,"Name":"27 Mbps"},
              {"Id":"missing-size","IsRemote":true,"Name":"📦 946 Mo"},
              {"Id":"ambiguous","IsRemote":true,"Size":6000000000,"Name":"26 GB | 12 GB"}]}
            """)
            var session = makeSession()
            session.server.provider = kind
            let item = try await JellyfinProvider(session: session, http: stub).item(id: "i1")
            let sizes = item.versions.map(\.sizeBytes)
            XCTAssertEqual(sizes, [
                3_600_000_000, 5_200_000_000, 26_200_000_000, 9_000_000_000,
                8_000_000_000, 7_000_000_000, 946_000_000, 6_000_000_000
            ])
            XCTAssertEqual(item.versions.map { $0.sourceMetadata?.fileSizeBytes }, sizes)
            XCTAssertEqual(item.mediaInfo?.fileSizeBytes, 3_600_000_000)
            XCTAssertEqual(item.versions.sortedForPicker().map(\.id), [
                "largest", "local", "unknown-origin", "bitrate-only", "ambiguous", "larger", "smaller", "missing-size"
            ])
            XCTAssertEqual(item.versions[2].sizeLabel, "26.2 GB")
            XCTAssertNil(item.versions[2].bitrate, "An ambiguous Mb token must not become an invented bitrate.")
            XCTAssertEqual(item.versions[2].playbackMediaSourceID, "largest")
        }
    }

    func testExplicitPlaybackLoadsInventoryWithSourceLocalFacts() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            for itemType in ["Movie", "Episode"] {
                let stub = StubHTTPClient()
                stub.stub(pathSuffix: "/Users/u1/Items/i1", json: """
                {"Id":"i1","Name":"Title","Type":"\(itemType)",
                 "MediaStreams":[{"Index":0,"Type":"Video","Height":1080},
                                 {"Index":1,"Type":"Audio","Language":"eng"}],
                 "MediaSources":[{"Id":"placeholder","IsRemote":true}]}
                """)
                stub.stub(pathSuffix: "/Items/i1/PlaybackInfo", json: """
                {"PlaySessionId":"unused-metadata-id","MediaSources":[
                  {"Id":"real-4k","IsRemote":true,"Name":"4K\\n🌍 🇫🇷 🇨🇦 🇬🇧 • 💾 87,8 Go • 🔎 Source","Path":"https://media.example/opaque",
                   "MediaStreams":[{"Index":0,"Type":"Video","Codec":"hevc","Height":2160},
                                   {"Index":1,"Type":"Audio","Language":"fra"}]},
                  {"Id":"real-hd","IsRemote":true,"Name":"HD","Path":"/media/Film.mkv",
                   "MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264","Height":1080},
                                   {"Index":1,"Type":"Audio","Language":"jpn"}]}
                ]}
                """)
                var session = makeSession()
                session.server.provider = kind
                let item = try await JellyfinProvider(session: session, http: stub).playbackItem(id: "i1")
                XCTAssertEqual(item.versions.map(\.playbackMediaSourceID), ["real-4k", "real-hd"])
                let first = try XCTUnwrap(item.versions.first)
                let last = try XCTUnwrap(item.versions.last)
                XCTAssertEqual(first.height, 2160)
                XCTAssertEqual(first.audioLanguageNames(in: Locale(identifier: "en")), ["French", "English"])
                XCTAssertEqual(last.audioLanguageNames(in: Locale(identifier: "en")), ["Japanese"])
                XCTAssertNil(first.fileName)
                XCTAssertTrue(first.isDefault)
                XCTAssertEqual(stub.sentMethods, [.get, .get])
                XCTAssertTrue(stub.sentBodies.isEmpty)
                XCTAssertEqual(stub.sentPaths, ["/Users/u1/Items/i1", "/Items/i1/PlaybackInfo"])
                XCTAssertEqual(stub.queryItems(forPathSuffix: "/PlaybackInfo"), [.init(name: "UserId", value: "u1")])
                XCTAssertNotNil(stub.sentHeaders.last?["Authorization"])
            }
        }
    }

    func testInventoryFailurePreservesPlayableDetailWithoutInventingVersions() async throws {
        for json in [
            #"{"MediaSources":[]}"#, #"{"MediaSources":[{"Id":"same"},{"Id":"same"}]}"#,
            #"{"MediaSources":[{}]}"#, #"{"MediaSources":[{"Id":"  "}]}"#,
            #"{"MediaSources":[],"ErrorCode":"NoCompatibleStream"}"#
        ] {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/Users/u1/Items/i1", json:
                #"{"Id":"i1","Name":"Title","Type":"Movie","MediaSources":[{"Id":"placeholder","IsRemote":true}]}"#)
            stub.stub(pathSuffix: "/Items/i1/PlaybackInfo", json: json)
            let item = try await JellyfinProvider(session: makeSession(), http: stub).item(id: "i1")
            XCTAssertEqual(item.id, "i1")
            XCTAssertTrue(item.versions.isEmpty)
            XCTAssertEqual(stub.sentPaths, ["/Users/u1/Items/i1"])
        }
    }

    func testPlaybackInventoryFailureNeverFallsBackToPlaceholderMetadata() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            for json in [
                #"{"MediaSources":[]}"#, #"{"MediaSources":[{"Id":"same"},{"Id":"same"}]}"#,
                #"{"MediaSources":[{}]}"#, #"{"MediaSources":[{"Id":"  "}]}"#,
                #"{"MediaSources":[],"ErrorCode":"NoCompatibleStream"}"#
            ] {
                let stub = StubHTTPClient()
                stub.stub(pathSuffix: "/Users/u1/Items/i1", json:
                    #"{"Id":"i1","Name":"Title","Type":"Movie","MediaSources":[{"Id":"placeholder","IsRemote":true}]}"#)
                stub.stub(pathSuffix: "/Items/i1/PlaybackInfo", json: json)
                var session = makeSession()
                session.server.provider = kind
                let provider: any MediaProvider = JellyfinProvider(session: session, http: stub)
                do {
                    _ = try await provider.playbackItem(id: "i1")
                    XCTFail("A failed or malformed inventory must block playback.")
                } catch let error as AppError {
                    XCTAssertEqual(error, .invalidResponse)
                } catch let error as StreamingQualityError {
                    XCTAssertEqual(error, .noCompatibleStream)
                }
                XCTAssertEqual(stub.sentMethods, [.get, .get])
            }
        }
    }

    func testPlaybackResolvesInventoryRegardlessOfCachedCountOrRemoteFlag() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            for sources in [
                "null", "[]", #"[{"Id":"placeholder","IsRemote":true}]"#,
                #"[{"Id":"placeholder"}]"#, #"[{"Id":"placeholder","IsRemote":false}]"#,
                #"[{"Id":"cached-hd"},{"Id":"cached-sd"}]"#
            ] {
                let stub = StubHTTPClient()
                stub.stub(pathSuffix: "/Users/u1/Items/i1", json:
                    #"{"Id":"i1","Name":"Title","Type":"Episode","MediaSources":\#(sources)}"#)
                stub.stub(pathSuffix: "/Items/i1/PlaybackInfo", json:
                    #"{"MediaSources":[{"Id":"4k"},{"Id":"hd"}]}"#)
                var session = makeSession()
                session.server.provider = kind
                let provider: any MediaProvider = JellyfinProvider(session: session, http: stub)
                let item = try await provider.playbackItem(id: "i1")
                XCTAssertEqual(item.versions.map(\.playbackMediaSourceID), ["4k", "hd"])
                XCTAssertEqual(stub.sentMethods, [.get, .get])
                XCTAssertTrue(stub.sentBodies.isEmpty)
                XCTAssertEqual(stub.queryItems(forPathSuffix: "/PlaybackInfo"), [.init(name: "UserId", value: "u1")])
            }
        }
    }

    func testUnavailableBridgePlaceholderCannotCountAsAConfirmedSingleFile() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            for itemType in ["Movie", "Episode"] {
                let stub = StubHTTPClient()
                stub.stub(pathSuffix: "/Users/u1/Items/i1", json:
                    #"{"Id":"i1","Name":"Title","Type":"\#(itemType)"}"#)
                stub.stub(pathSuffix: "/Items/i1/PlaybackInfo", json: """
                {"MediaSources":[{"Id":"i1","IsRemote":true,"Name":"No streams · Unavailable",
                "Container":"mkv","SupportsDirectPlay":true,
                "MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264"},{"Index":1,"Type":"Audio","Codec":"ac3"}]}]}
                """)
                var session = makeSession()
                session.server.provider = kind
                do {
                    _ = try await JellyfinProvider(session: session, http: stub).playbackItem(id: "i1")
                    XCTFail("An unavailable-source placeholder must not open a player.")
                } catch {
                    XCTAssertEqual(error as? StreamingQualityError, .noStreams)
                }
                XCTAssertEqual(stub.sentMethods, [.get, .get])
            }
        }
    }

    func testPlaceholderRecognitionDoesNotRejectRealFilesOrUnrelatedNames() async throws {
        for source in [
            #"{"Id":"i1","IsRemote":false,"Name":"No streams · Unavailable"}"#,
            #"{"Id":"file","IsRemote":true,"Name":"No streams · Unavailable"}"#,
            #"{"Id":"i1","IsRemote":true,"Name":"No streams documentary"}"#
        ] {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/Users/u1/Items/i1", json: #"{"Id":"i1","Name":"Title","Type":"Movie"}"#)
            stub.stub(pathSuffix: "/Items/i1/PlaybackInfo", json: #"{"MediaSources":[\#(source)]}"#)
            let item = try await JellyfinProvider(session: makeSession(), http: stub).playbackItem(id: "i1")
            XCTAssertTrue(item.versions.isEmpty)
        }
    }

    func testPlaybackAcceptsConfirmedSingleFileWithoutKeepingCachedVersions() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/Users/u1/Items/i1", json:
                #"{"Id":"i1","Name":"Title","Type":"Movie","MediaSources":[{"Id":"old-one"},{"Id":"old-two"}]}"#)
            stub.stub(pathSuffix: "/Items/i1/PlaybackInfo", json:
                #"{"MediaSources":[{"Id":"only-file","IsRemote":false}]}"#)
            var session = makeSession()
            session.server.provider = kind
            let provider: any MediaProvider = JellyfinProvider(session: session, http: stub)
            let item = try await provider.playbackItem(id: "i1")
            XCTAssertTrue(item.versions.isEmpty, "A confirmed single file needs no version picker.")
            XCTAssertEqual(stub.sentMethods, [.get, .get])
        }
    }

    func testUnsupportedPlaybackInventoryAndCancellationBothPropagate() async throws {
        for cancelled in [false, true] {
            let provider = JellyfinProvider(
                session: makeSession(), http: InventoryFailureHTTP(cancelled: cancelled), playbackRequests: .init()
            )
            do {
                _ = try await provider.playbackItem(id: "i1")
                XCTFail("Read-only discovery failure must not start playback.")
            } catch let error as AppError {
                XCTAssertEqual(error, cancelled ? .cancelled : .notFound)
            }
        }
    }

    func testPassiveDetailsNeverRequestPlaybackInventory() async throws {
        for (type, sources) in [
            ("Movie", #"[]"#),
            ("Movie", #"[{"Id":"remote","IsRemote":true}]"#),
            ("Episode", #"[{"Id":"remote","IsRemote":true}]"#),
            ("Movie", #"[{"Id":"one","IsRemote":false}]"#),
            ("Movie", #"[{"Id":"one"}]"#),
            ("Movie", #"[{"Id":"one","IsRemote":true},{"Id":"two","IsRemote":true}]"#),
            ("Series", #"[{"Id":"one","IsRemote":true}]"#)
        ] {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/Users/u1/Items/i1", json:
                #"{"Id":"i1","Name":"Title","Type":"\#(type)","MediaSources":\#(sources)}"#)
            _ = try await JellyfinProvider(session: makeSession(), http: stub).item(id: "i1")
            XCTAssertEqual(stub.sentPaths, ["/Users/u1/Items/i1"])
        }
    }

    func testBrowsingDoesNotContactUnsupportedOrCancelledInventory() async throws {
        for cancelled in [false, true] {
            let provider = JellyfinProvider(session: makeSession(), http: InventoryFailureHTTP(cancelled: cancelled))
            let item = try await provider.item(id: "i1")
            XCTAssertTrue(item.versions.isEmpty)
            XCTAssertEqual(item.id, "i1")
        }
    }

    private struct InventoryFailureHTTP: HTTPClient {
        let cancelled: Bool
        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            if endpoint.path.hasSuffix("/PlaybackInfo") {
                throw cancelled ? AppError.cancelled : AppError.notFound
            }
            return (
                Data(#"{"Id":"i1","Name":"Title","Type":"Movie","MediaSources":[{"Id":"placeholder","IsRemote":true}]}"#.utf8),
                HTTPURLResponse(url: baseURL.appendingPathComponent(endpoint.path),
                                statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
    }

    func testItemMapsMultipleMediaSourcesToVersions() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/i1", json: """
        {"Id":"i1","Name":"Movie","Type":"Movie",
         "UserData":{"IsFavorite":true},
         "MediaSources":[
           {"Id":"src4k","Name":"4K Remux","Path":"/media/Movie.Extended.mkv",
            "Size":42000000000,"Bitrate":80000000,"RunTimeTicks":72000000000,
            "MediaStreams":[
              {"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160,"BitDepth":10,"VideoRangeType":"DOVI"},
              {"Index":1,"Type":"Audio","Codec":"aac","Channels":2,"Language":"fra"},
              {"Index":2,"Type":"Audio","Codec":"truehd","Channels":8,"Profile":"Dolby Atmos","Language":"eng","IsDefault":true},
              {"Index":3,"Type":"Subtitle","Language":"jpn"}]},
           {"Id":"src1080","Name":"1080p","Size":9000000000,
            "MediaStreams":[
              {"Index":0,"Type":"Video","Codec":"h264","Width":1920,"Height":1080,"VideoRangeType":"SDR"},
              {"Index":1,"Type":"Audio","Codec":"aac","Channels":2}]}
         ]}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "i1")
        XCTAssertTrue(item.hasMultipleVersions)
        XCTAssertEqual(item.versions.map(\.id), ["src4k", "src1080"])
        XCTAssertTrue(item.isFavorite)

        let uhd = item.versions[0]
        XCTAssertEqual(uhd.height, 2160)
        XCTAssertEqual(uhd.videoCodec, "hevc")
        XCTAssertEqual(uhd.hdrLabel, "Dolby Vision")
        XCTAssertEqual(uhd.audioLabel, "Dolby Atmos")
        XCTAssertEqual(uhd.audioFormatLabel, "Dolby TrueHD + Dolby Atmos + 7.1")
        XCTAssertEqual(uhd.audioLanguageNames(in: Locale(identifier: "en_US")), ["French", "English"])
        XCTAssertEqual(uhd.sourceMetadata?.video?.bitDepth, 10)
        XCTAssertEqual(uhd.fileName, "Movie.Extended.mkv")
        XCTAssertEqual(uhd.bitrateLabel, "80 Mbps")
        XCTAssertEqual(uhd.duration, 7200)
        XCTAssertTrue(uhd.isDefault)

        let hd = item.versions[1]
        XCTAssertEqual(hd.resolutionLabel, "1080p")
        XCTAssertEqual(hd.videoCodec, "h264")
        XCTAssertFalse(hd.isDefault)
        XCTAssertTrue(hd.audioLanguageNames().isEmpty, "Language facts must not leak between files.")
        XCTAssertEqual(hd.audioFormatLabel, "AAC Stereo")
    }

    func testSingleMediaSourceProducesNoVersionPicker() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/i2", json: """
        {"Id":"i2","Name":"Solo","Type":"Movie",
         "MediaSources":[{"Id":"only","MediaStreams":[
           {"Index":0,"Type":"Video","Codec":"h264","Height":1080}]}]}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let item = try await provider.item(id: "i2")
        XCTAssertFalse(item.hasMultipleVersions)
        XCTAssertEqual(item.versions, [])
        XCTAssertEqual(stub.sentPaths, ["/Users/u1/Items/i2"], "Local single-source details need no inventory request.")
    }

    func testFilenameHintOnlyChangesTheDisplayFilename() throws {
        let path = "https://media.example/stream?file_name=Film%20%26%20Friends.Extended.REMUX.mkv&id=tt123&media_type=movie"
        let sources = try JSONDecoder.plozz.decode([MediaSourceInfo].self, from: Data("""
        [
          {"Id":"remote","Name":"4K Remux","Path":"\(path)"},
          {"Id":"local","Path":"/movies/Film.mkv"}
        ]
        """.utf8))
        let versions = JellyfinProvider.versions(from: sources)
        XCTAssertEqual(versions[0].fileName, "Film & Friends.Extended.REMUX.mkv")
        XCTAssertEqual(versions[0].sourceMetadata?.fileName, versions[0].fileName)
        XCTAssertEqual(MediaVersion.PickerPresentation(versions[0]).releaseName, versions[0].fileName)
        XCTAssertEqual(versions[0].playbackMediaSourceID, "remote")
        XCTAssertEqual(sources[0].Path, path)
        XCTAssertEqual(versions[1].fileName, "Film.mkv")
    }

    func testOpaqueSourcePathKeepsServerLabelAndIdentity() throws {
        let path = "https://media.example/stream?source_name=Hidden.Extended.mkv&token=fixture"
        let sources = try JSONDecoder.plozz.decode([MediaSourceInfo].self, from: Data("""
        [
          {"Id":"remote","Name":"Server copy","Path":"\(path)","MediaStreams":[
            {"Index":0,"Type":"Video","Codec":"hevc","Height":2160}
          ]},
          {"Id":"local","Path":"/movies/Film.mkv"}
        ]
        """.utf8))
        let versions = JellyfinProvider.versions(from: sources)
        XCTAssertNil(versions[0].fileName)
        XCTAssertNil(versions[0].sourceMetadata?.fileName)
        XCTAssertEqual(versions[0].resolutionLabel, "4K")
        XCTAssertEqual(MediaVersion.PickerPresentation(versions[0]).releaseName, "Server copy")
        XCTAssertNil(versions[0].editionLabel)
        XCTAssertEqual(versions[0].playbackMediaSourceID, "remote")
        XCTAssertEqual(sources[0].Path, path)
    }

    // MARK: - Feature B: Favorites-backed watchlist

    func testSetWatchlistedPostsFavorite() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/FavoriteItems/i1", json: "{}")
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        try await provider.setWatchlisted(true, item: MediaItem(id: "i1", title: "M", kind: .movie))
        XCTAssertEqual(stub.method(forPathSuffix: "/Users/u1/FavoriteItems/i1"), .post)

        try await provider.setWatchlisted(false, item: MediaItem(id: "i1", title: "M", kind: .movie))
        XCTAssertEqual(stub.method(forPathSuffix: "/Users/u1/FavoriteItems/i1"), .delete)
    }

    func testWatchlistFetchesFavoriteItems() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items", json: """
        {"Items":[{"Id":"f1","Name":"Saved Movie","Type":"Movie","ProviderIds":{"Tmdb":"11"}}],"TotalRecordCount":1}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let saved = try await provider.watchlist()
        XCTAssertEqual(saved.map(\.title), ["Saved Movie"])
        XCTAssertEqual(saved.first?.providerIDs["Tmdb"], "11")
        let query = stub.queryItems(forPathSuffix: "/Users/u1/Items")
        XCTAssertEqual(query?.first { $0.name == "Filters" }?.value, "IsFavorite")
        XCTAssertEqual(
            query?.first { $0.name == "Limit" }?.value,
            "10000",
            "Limit is a page size, not a total watchlist cap"
        )
        XCTAssertEqual(query?.first { $0.name == "StartIndex" }?.value, "0")
        XCTAssertEqual(
            query?.first { $0.name == "EnableTotalRecordCount" }?.value,
            "true"
        )
        XCTAssertNil(
            query?.first { $0.name == "SortBy" },
            "Jellyfin/Emby expose no favorite-added timestamp; DateCreated is library chronology"
        )
        let fields = query?.first { $0.name == "Fields" }?.value ?? ""
        XCTAssertTrue(
            fields.split(separator: ",").contains(where: { $0.lowercased() == "providerids" }),
            "Favorites requests must include ProviderIds so Home watchlist de-dup can match across servers"
        )
    }

    func testWatchlistPagesPastTenThousandAndPreservesServerOrder() async throws {
        let stub = StubHTTPClient()
        let firstPage = (0..<10_000).map {
            #"{"Id":"f\#($0)","Name":"Film \#($0)","Type":"Movie"}"#
        }.joined(separator: ",")
        stub.stubSequence(pathSuffix: "/Users/u1/Items", jsons: [
            #"{"Items":[\#(firstPage)],"TotalRecordCount":10001}"#,
            #"{"Items":[{"Id":"f10000","Name":"Film 10000","Type":"Movie"}],"TotalRecordCount":10001}"#
        ])

        let items = try await JellyfinProvider(
            session: makeSession(),
            http: stub
        ).watchlist()

        XCTAssertEqual(items.count, 10_001)
        XCTAssertEqual(items.first?.title, "Film 0")
        XCTAssertEqual(items.last?.title, "Film 10000")
        XCTAssertEqual(
            stub.sentQueryItems.compactMap {
                $0.first { $0.name == "StartIndex" }?.value
            },
            ["0", "10000"]
        )
    }

    func testJellyfinAndEmbyWatchlistQueriesPreserveReleaseDatesAndUnknownFavoriteDates() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/Users/u1/Items", json: """
            {"Items":[
              {"Id":"movie","Name":"Alpha","Type":"Movie","PremiereDate":"2024-01-01T00:00:00Z","DateCreated":"2026-01-01T00:00:00Z"},
              {"Id":"show","Name":"Zulu","Type":"Series","PremiereDate":"2023-01-01T00:00:00Z"},
              {"Id":"undated","Name":"Oscar","Type":"Movie"}
            ],"TotalRecordCount":3}
            """)
            let session = UserSession(
                server: .init(id: "s", name: "Fixture", baseURL: URL(string: "http://host:8096")!, provider: kind),
                userID: "u1", userName: "Viewer", deviceID: "fixture", accessToken: "TOKEN"
            )
            let provider = JellyfinProvider(session: session, accountID: kind.rawValue, http: stub)
            let destination = try XCTUnwrap(MediaBrowserWatchlistDestination(provider: provider))
            let entries = try await destination.fetchEntries()
            XCTAssertEqual(entries.map(\.kind), [.movie, .series, .movie])
            XCTAssertTrue(entries.allSatisfy { $0.addedAt == nil })
            XCTAssertEqual(entries.first?.presentation?.releaseDate, Date(timeIntervalSince1970: 1_704_067_200))
            let items = try entries.map { entry in
                let presentation = try XCTUnwrap(entry.presentation)
                return MediaItem(id: presentation.title, title: presentation.title, kind: entry.kind,
                                 watchlistAddedAt: entry.addedAt, releaseDate: presentation.releaseDate,
                                 sourceAccountID: provider.accountID)
            }
            XCTAssertEqual(WatchlistBrowsePreferences(filter: .shows).items(from: items).map(\.title), ["Zulu"])
            XCTAssertEqual(WatchlistBrowsePreferences(filter: .movies).items(from: items).map(\.title), ["Alpha", "Oscar"])
            XCTAssertEqual(WatchlistBrowsePreferences(sort: .init(field: .releaseDate, direction: .ascending))
                .items(from: items).map(\.title), ["Zulu", "Alpha", "Oscar"])
            XCTAssertEqual(WatchlistBrowsePreferences.default.items(from: items), items)
            for entry in entries {
                let owned = await destination.resolveLibraryCopy(for: entry)
                XCTAssertEqual(owned?.source.providerKind, kind)
                XCTAssertEqual(owned?.source.accountID, provider.accountID)
                XCTAssertEqual(owned?.presentation?.releaseDate, entry.presentation?.releaseDate)
            }
        }
    }

    func testWatchlistRejectsOverlappingPages() async throws {
        let stub = StubHTTPClient()
        stub.stubSequence(pathSuffix: "/Users/u1/Items", jsons: [
            """
            {"Items":[
              {"Id":"f1","Name":"First","Type":"Movie"},
              {"Id":"f2","Name":"Second","Type":"Movie"}
            ],"TotalRecordCount":3}
            """,
            """
            {"Items":[{"Id":"f2","Name":"Repeated","Type":"Movie"}],
             "TotalRecordCount":3}
            """
        ])
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        do {
            _ = try await provider.client.favorites(userID: "u1", limit: 2)
            XCTFail("Expected overlapping pages to fail")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
    }

    func testWatchlistRejectsIncompletePages() async throws {
        let stub = StubHTTPClient()
        stub.stubSequence(pathSuffix: "/Users/u1/Items", jsons: [
            """
            {"Items":[{"Id":"f1","Name":"First","Type":"Movie"}],
             "TotalRecordCount":2}
            """,
            #"{"Items":[],"TotalRecordCount":2}"#
        ])
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        do {
            _ = try await provider.client.favorites(userID: "u1", limit: 1)
            XCTFail("Expected an incomplete read to fail")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
    }

    func testWatchlistRejectsChangingTotalCount() async throws {
        let stub = StubHTTPClient()
        stub.stubSequence(pathSuffix: "/Users/u1/Items", jsons: [
            """
            {"Items":[{"Id":"f1","Name":"First","Type":"Movie"}],
             "TotalRecordCount":2}
            """,
            """
            {"Items":[{"Id":"f2","Name":"Second","Type":"Movie"}],
             "TotalRecordCount":3}
            """
        ])
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        do {
            _ = try await provider.client.favorites(userID: "u1", limit: 1)
            XCTFail("Expected inconsistent totals to fail")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
    }

    func testDestinationFailsClosedWhenFavoriteCannotMap() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items", json: """
        {"Items":[{"Id":"episode","Name":"Unexpected","Type":"Episode"}],
         "TotalRecordCount":1}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)
        let destination = try XCTUnwrap(
            MediaBrowserWatchlistDestination(provider: provider)
        )

        do {
            _ = try await destination.fetchEntries()
            XCTFail("Expected malformed authoritative input to fail")
        } catch let error as WatchlistDestinationError {
            XCTAssertEqual(error, .transient)
        }
    }

    func testUniversalDestinationRequiresValidatedLocalCopyForJellyfinAndEmby() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/Users/u1/FavoriteItems/i1", json: "{}")
            stub.stub(pathSuffix: "/Users/u1/FavoriteItems/i2", json: "{}")
            let session = UserSession(
                server: MediaServer(
                    id: "s",
                    name: "Home",
                    baseURL: URL(string: "http://host:8096")!,
                    provider: kind
                ),
                userID: "u1",
                userName: "Alice",
                deviceID: "d1",
                accessToken: "TOKEN"
            )
            let provider = JellyfinProvider(
                session: session,
                accountID: "\(kind.rawValue)-account",
                http: stub
            )
            let destination = try XCTUnwrap(
                MediaBrowserWatchlistDestination(provider: provider)
            )
            let alias = MediaAliasID()
            let externalOnly = WatchlistMutationTarget(
                aliasID: alias,
                kind: .movie,
                externalIDs: [
                    WatchlistExternalID(namespace: .tmdb, value: "11")!
                ]
            )!
            let unvalidatedResolution = try await destination.resolve(externalOnly)
            XCTAssertNil(unvalidatedResolution)

            let bindingKey = try XCTUnwrap(
                MediaAliasProviderBindingKey(
                    providerKind: kind,
                    accountDescriptorID: provider.accountID,
                    providerItemID: "i1"
                )
            )
            let validated = WatchlistMutationTarget(
                aliasID: alias,
                kind: .movie,
                validatedBindings: [
                    bindingKey,
                    try XCTUnwrap(MediaAliasProviderBindingKey(
                        providerKind: kind,
                        accountDescriptorID: provider.accountID,
                        providerItemID: "i2"
                    ))
                ]
            )!
            let resolution = try await destination.resolve(validated)
            let binding = try XCTUnwrap(resolution)
            XCTAssertEqual(binding.opaqueValues, ["i1", "i2"])
            try await destination.apply(.present, to: binding)
            XCTAssertEqual(
                stub.method(forPathSuffix: "/Users/u1/FavoriteItems/i1"),
                .post
            )
            XCTAssertEqual(
                stub.method(forPathSuffix: "/Users/u1/FavoriteItems/i2"),
                .post
            )
        }
    }

    // MARK: - Feature C: metadata refresh

    func testRefreshMetadataPostsFullRefresh() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Items/i1/Refresh", json: "{}")
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        try await provider.refreshMetadata(itemID: "i1")
        XCTAssertEqual(stub.method(forPathSuffix: "/Items/i1/Refresh"), .post)
        let query = stub.queryItems(forPathSuffix: "/Items/i1/Refresh")
        XCTAssertEqual(query?.first { $0.name == "ReplaceAllMetadata" }?.value, "true")
    }
}
