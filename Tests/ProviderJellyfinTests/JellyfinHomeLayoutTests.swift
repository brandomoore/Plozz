import XCTest
import CoreModels
@testable import ProviderJellyfin

final class JellyfinHomeLayoutTests: XCTestCase {
    func testHomeFeedRequestsIncludeDateAddedMetadata() async throws {
        for kind: ProviderKind in [.jellyfin, .emby] {
            let stub = StubHTTPClient()
            let bare = """
            [{"Id":"old","Name":"Z old","Type":"Movie","DateCreated":"2026-01-01T00:00:00Z"},
             {"Id":"new","Name":"A new","Type":"Movie","DateCreated":"2026-02-01T00:00:00Z"}]
            """
            let envelope = #"{"Items":\#(bare),"TotalRecordCount":2,"StartIndex":0}"#
            let paths = [
                "/Users/selected-user/Items/Latest", "/Users/selected-user/Items/Resume", "/Shows/NextUp",
                "/Users/selected-user/Sections/native/Items", "/LiveTv/Recordings",
                "/Users/selected-user/Items", "/Movies/Recommendations"
            ]
            for path in paths {
                let json = path.hasSuffix("/Latest") ? bare : path.hasSuffix("/Recommendations")
                    ? #"[{"Items":\#(bare),"RecommendationType":"SimilarToRecentlyPlayed","CategoryId":"category"}]"#
                    : envelope
                stub.stub(pathSuffix: path, json: json)
            }
            let provider = JellyfinProvider(session: session(kind), http: stub)
            let latest = try await provider.homeRowPage(.latest(libraryIDs: ["movies"]), startIndex: 0, limit: 60)
            XCTAssertEqual(latest.items.count, 2)
            XCTAssertTrue(latest.items.allSatisfy { $0.librarySortValues?.dateAdded != nil })
            let chronological = latest.items.sorted {
                MediaItemSortOrder.isOrderedBefore($0, $1, sort: .init(field: .dateAdded, direction: .descending))
            }
            XCTAssertEqual(chronological.map(\.id), ["new", "old"])
            let client = JellyfinClient(
                baseURL: session(kind).server.baseURL, deviceProfile: .init(deviceID: "device"),
                providerKind: kind, http: stub
            )
            _ = try await client.resumeItems(userID: "selected-user", limit: 60)
            _ = try await client.nextUpItems(userID: "selected-user", limit: 60)
            _ = try await client.nativeHomeItems(userID: "selected-user", sectionID: "native", limit: 60, parentID: nil)
            _ = try await client.activeHomeRecordings(userID: "selected-user", limit: 60)
            _ = try await client.collectionMembers(userID: "selected-user", collectionID: "collection", page: .init())
            _ = try await client.movieRecommendations(userID: "selected-user", parentID: "movies", limit: 60)
            for path in paths {
                let query = try XCTUnwrap(stub.queryItems(forPathSuffix: path))
                let fields = query.first { $0.name.lowercased() == "fields" }?.value?.split(separator: ",") ?? []
                XCTAssertTrue(fields.contains("DateCreated"), "\(kind): \(path)")
            }
        }
    }

    func testFullLatestShelfPropagatesSourceFailureRatherThanPublishingEmpty() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/selected-user/Items/Latest", json: "[]", status: 503)
        let provider = JellyfinProvider(session: session(), http: stub)
        do {
            _ = try await provider.homeRowPage(.latest(libraryIDs: ["movies"]), startIndex: 0, limit: 60)
            XCTFail("An unavailable source is not an exhausted shelf")
        } catch {
            XCTAssertNotNil(error as? AppError)
        }
    }

    func testFullServerShelfExtendsPastPreviewCapForJellyfinAndEmby() async throws {
        for kind: ProviderKind in [.jellyfin, .emby] {
            let stub = StubHTTPClient()
            let items = (0..<135).map { #"{"Id":"\#($0)","Type":"Movie","Name":"Title \#($0)"}"# }
                .joined(separator: ",")
            let section: ServerHomeSection
            let path: String
            if kind == .emby {
                section = .init(id: "emby:native", kind: .recommendations, libraryID: "movies")
                path = "/Users/selected-user/Sections/native/Items"
                stub.stub(pathSuffix: path, json: #"{"Items":[\#(items)],"TotalRecordCount":135}"#)
            } else {
                section = .init(id: "web:recentlyadded:movies", kind: .recentlyAdded, libraryID: "movies")
                path = "/Users/selected-user/Items/Latest"
                stub.stub(pathSuffix: path, json: "[\(items)]")
            }
            let provider = JellyfinProvider(session: session(kind), http: stub)
            let feed = HomeRowFeed.server(section, excludedLibraryIDs: [], anchorIDs: ["0"])
            let second = try await provider.homeRowPage(feed, startIndex: 60, limit: 60)
            XCTAssertEqual(second.items.map(\.id), (60..<120).map(String.init))
            XCTAssertEqual(second.nextOffset, 120)
            let last = try await provider.homeRowPage(feed, startIndex: 120, limit: 60)
            XCTAssertEqual(last.items.count, 15)
            XCTAssertNil(last.nextOffset)
            XCTAssertTrue(last.items.allSatisfy { $0.libraryID == "movies" })
            let query = try XCTUnwrap(stub.queryItems(forPathSuffix: path))
            XCTAssertEqual(query.first { $0.name == "Limit" }?.value, "181")
        }
    }

    private func session(_ kind: ProviderKind = .jellyfin) -> UserSession {
        UserSession(
            server: MediaServer(
                id: "home", name: "Home", baseURL: URL(string: "https://media.test/base")!,
                provider: kind
            ),
            userID: "selected-user", userName: "Viewer", deviceID: "device", accessToken: "TEST_TOKEN"
        )
    }

    private let views = """
    {"Items":[
      {"Id":"shows","Name":"Television","CollectionType":"tvshows"},
      {"Id":"music","Name":"Music","CollectionType":"music"},
      {"Id":"books","Name":"Books","CollectionType":"books"},
      {"Id":"movies","Name":"Movies","CollectionType":"movies"},
      {"Id":"live","Name":"Live","CollectionType":"livetv"},
      {"Id":"playlists","Name":"Playlists","CollectionType":"playlists"}
    ]}
    """

    private func preferences(_ values: [String]) -> String {
        let pairs = (0..<10).map { index in
            "\"homesection\(index)\":\"\(index < values.count ? values[index] : "none")\""
        }
        return "{\"CustomPrefs\":{\(pairs.joined(separator: ","))}}"
    }

    func testWebPreferencesPreserveSlotsAndLatestLibraryOrderWithoutMediaDiscovery() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/DisplayPreferences/usersettings", json: preferences([
            "latestmedia", "resumebook", "resume", "resumeaudio", "librarybuttons",
            "livetv", "nextup", "activerecordings"
        ]))
        stub.stub(pathSuffix: "/Users/selected-user/Views", json: views)
        let provider = JellyfinProvider(session: session(), accountID: "account-one", http: stub)
        let response = try await provider.serverHomeLayout()
        let layout = try XCTUnwrap(response)

        XCTAssertEqual(layout.source, .webPreferences)
        XCTAssertEqual(layout.sections.map(\.kind), [
            .recentlyAdded, .recentlyAdded, .continueWatching, .libraries,
            .liveTV, .nextUp, .recordings
        ])
        XCTAssertEqual(layout.sections.prefix(2).compactMap(\.libraryID), ["shows", "movies"])
        XCTAssertEqual(layout.sections.prefix(2).compactMap(\.title), ["Television", "Movies"])
        XCTAssertTrue(layout.omitsMusic)
        XCTAssertTrue(layout.omitsReading)
        XCTAssertEqual(stub.sentPaths, [
            "/DisplayPreferences/usersettings", "/Users/selected-user/Views"
        ])
        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/DisplayPreferences/usersettings"))
        XCTAssertEqual(query, [
            URLQueryItem(name: "userId", value: "selected-user"),
            URLQueryItem(name: "client", value: "emby")
        ])
        XCTAssertTrue(stub.sentMethods.allSatisfy { $0 == .get })
        XCTAssertTrue(stub.sentHeaders.allSatisfy {
            $0["Authorization"] == JellyfinDeviceProfile(deviceID: "device")
                .authorizationHeaderValue(token: "TEST_TOKEN")
        })
    }

    func testMissingAndEmptySlotsUseDocumentedDefaultsWhileNoneStaysHidden() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/DisplayPreferences/usersettings", json: """
        {"CustomPrefs":{"homesection0":"folders","homesection1":"","homesection4":"none"}}
        """)
        stub.stub(pathSuffix: "/Users/selected-user/Views", json: views)
        let response = try await JellyfinProvider(session: session(), http: stub).serverHomeLayout()
        let layout = try XCTUnwrap(response)
        XCTAssertEqual(layout.sections.map(\.kind), [
            .libraries, .continueWatching, .nextUp, .recentlyAdded, .recentlyAdded
        ])
        XCTAssertTrue(layout.omitsMusic)
        XCTAssertTrue(layout.omitsReading)
    }

    func testNullCustomPreferencesPreserveConfiguredLayoutOnBothServers() async throws {
        for kind: ProviderKind in [.jellyfin, .emby] {
            let stub = StubHTTPClient()
            if kind == .emby {
                stub.stub(pathSuffix: "/Users/selected-user/HomeSections", json: "{}", status: 404)
            }
            let json = preferences(["latestmedia", "resume", "nextup", "folders"])
                .replacingOccurrences(of: #""CustomPrefs":{"#, with: #""CustomPrefs":{"tvhome":null,"unknown":null,"#)
            stub.stub(pathSuffix: "/DisplayPreferences/usersettings", json: json)
            stub.stub(pathSuffix: "/Users/selected-user/Views", json: views)

            let response = try await JellyfinProvider(session: session(kind), http: stub).serverHomeLayout()
            let layout = try XCTUnwrap(response)
            XCTAssertEqual(layout.source, .webPreferences)
            XCTAssertEqual(layout.sections.map(\.id), [
                "web:0:latestmedia:shows", "web:0:latestmedia:movies",
                "web:1:resume", "web:2:nextup", "web:3:folders"
            ])
            XCTAssertEqual(stub.sentPaths, (kind == .emby ? ["/Users/selected-user/HomeSections"] : []) + [
                "/DisplayPreferences/usersettings", "/Users/selected-user/Views"
            ])
        }
    }

    func testNullSlotsUseDefaultsWhileExplicitNoneStaysHidden() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/DisplayPreferences/usersettings", json: """
        {"CustomPrefs":{"homesection0":null,"homesection1":null,"homesection4":"none","tvhome":null}}
        """)
        stub.stub(pathSuffix: "/Users/selected-user/Views", json: views)

        let response = try await JellyfinProvider(session: session(), http: stub).serverHomeLayout()
        let layout = try XCTUnwrap(response)
        XCTAssertEqual(layout.sections.map(\.id), [
            "web:0:smalllibrarytiles", "web:1:resume", "web:5:nextup",
            "web:6:latestmedia:shows", "web:6:latestmedia:movies"
        ])
        XCTAssertTrue(layout.omitsMusic)
        XCTAssertTrue(layout.omitsReading)
    }

    func testNonStringCustomPreferencesStillFailDecoding() async throws {
        for value in ["true", "42", "[]", "{}"] {
            for key in ["tvhome", "homesection0"] {
                let stub = StubHTTPClient()
                stub.stub(pathSuffix: "/DisplayPreferences/usersettings", json: """
                {"CustomPrefs":{"\(key)":\(value)}}
                """)
                do {
                    _ = try await JellyfinProvider(session: session(), http: stub).serverHomeLayout()
                    XCTFail("Non-string preference must throw")
                } catch {
                    XCTAssertEqual(error as? AppError, .decoding)
                }
                XCTAssertEqual(stub.sentPaths, ["/DisplayPreferences/usersettings"])
            }
        }
    }

    func testLatestIsBoundedScopedAndFiltersNonVideoWithoutChangingPlaybackIDs() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/selected-user/Items/Latest", json: """
        [{"Id":"movie-one","Type":"Movie"},{"Id":"audio","Type":"Audio"},
         {"Id":"book","Type":"Book"},{"Id":"channel","Type":"TvChannel"},
         {"Id":"movie-two","Type":"Movie"}]
        """)
        let provider = JellyfinProvider(session: session(), http: stub)
        let section = ServerHomeSection(id: "web:0:latestmedia:movies", kind: .recentlyAdded, libraryID: "movies")
        let items = try await provider.serverHomeItems(section: section, limit: 1, excludingLibraryIDs: [])
        XCTAssertEqual(items.map(\.id), ["movie-one"])
        XCTAssertEqual(items.first?.libraryID, "movies")
        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/Items/Latest"))
        XCTAssertTrue(query.contains(.init(name: "ParentId", value: "movies")))
        XCTAssertTrue(query.contains(.init(name: "Limit", value: "1")))
        XCTAssertTrue(query.contains(.init(name: "IncludeItemTypes", value: "Movie,Series,Season,Episode,Video")))
        let requestCount = stub.sentPaths.count
        let hidden = try await provider.serverHomeItems(
            section: section, limit: 20, excludingLibraryIDs: ["movies"]
        )
        XCTAssertTrue(hidden.isEmpty)
        XCTAssertEqual(stub.sentPaths.count, requestCount)
    }

    func testResumeAndNextUpRemainSeparateAndExcludeHiddenLibrariesAtTheServer() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/selected-user/Views", json: views)
        stub.stub(pathSuffix: "/Items/Resume", json: #"{"TotalRecordCount":1,"Items":[{"Id":"resume","Type":"Episode"}]}"#)
        stub.stub(pathSuffix: "/Shows/NextUp", json: #"{"Items":[{"Id":"next","Type":"Episode"}]}"#)
        let provider = JellyfinProvider(session: session(), http: stub)
        let resume = try await provider.serverHomeItems(
            section: .init(id: "web:1:resume", kind: .continueWatching),
            limit: .max, excludingLibraryIDs: ["movies"]
        )
        XCTAssertEqual(resume.map(\.id), ["resume"])
        XCTAssertEqual(resume.first?.libraryID, "shows")
        XCTAssertFalse(stub.sentPaths.contains("/Shows/NextUp"))
        let next = try await provider.serverHomeItems(
            section: .init(id: "web:5:nextup", kind: .nextUp),
            limit: 5, excludingLibraryIDs: ["movies"]
        )
        XCTAssertEqual(next.map(\.id), ["next"])
        for suffix in ["/Items/Resume", "/Shows/NextUp"] {
            let query = try XCTUnwrap(stub.queryItems(forPathSuffix: suffix))
            XCTAssertTrue(query.contains(.init(name: "ParentId", value: "shows")))
        }
        XCTAssertEqual(stub.queryItems(forPathSuffix: "/Items/Resume")?
            .first { $0.name == "Limit" }?.value, "100")
        XCTAssertEqual(stub.queryItems(forPathSuffix: "/Shows/NextUp")?
            .first { $0.name == "UserId" }?.value, "selected-user")
    }

    func testLiveTVAndLibrariesNeverStartAHomeNetworkRequest() async throws {
        let stub = StubHTTPClient()
        let provider = JellyfinProvider(session: session(), http: stub)
        for kind: ServerHomeSection.Kind in [.liveTV, .libraries] {
            let items = try await provider.serverHomeItems(
                section: .init(id: "web:4:livetv", kind: kind),
                limit: 12, excludingLibraryIDs: []
            )
            XCTAssertTrue(items.isEmpty)
        }
        XCTAssertTrue(stub.sentPaths.isEmpty)
    }

    func testNativeContinueWatchingPreservesCompleteFeedUsingBoundedPagesOnBothServers() async throws {
        func page(_ range: Range<Int>) -> String {
            let rows = range.map { #"{"Id":"\#($0)","Type":"Movie"}"# }.joined(separator: ",")
            return #"{"Items":[\#(rows)],"TotalRecordCount":103,"StartIndex":\#(range.lowerBound)}"#
        }
        for kind: ProviderKind in [.jellyfin, .emby] {
            let stub = StubHTTPClient()
            let path = kind == .emby ? "/Sections/resume/Items" : "/Items/Resume"
            stub.stubSequence(pathSuffix: path, jsons: [page(0..<100), page(100..<103)])
            let items = try await JellyfinProvider(session: session(kind), http: stub).serverHomeItems(
                section: .init(
                    id: kind == .emby ? "emby:resume" : "web:1:resume",
                    kind: .continueWatching, libraryID: "movies"
                ), limit: .max, excludingLibraryIDs: ["hidden"]
            )
            XCTAssertEqual(items.map(\.id), (0..<103).map(String.init))
            XCTAssertTrue(items.allSatisfy { $0.libraryID == "movies" })
            XCTAssertEqual(stub.sentQueryItems.map {
                $0.first { $0.name == "StartIndex" }?.value
            }, ["0", "100"])
            XCTAssertTrue(stub.sentQueryItems.allSatisfy {
                $0.contains(.init(name: "Limit", value: "100"))
                    && $0.contains(.init(name: "ParentId", value: "movies"))
            })
        }
    }

    func testActiveRecordingsUseDocumentedReadOnlyBoundedEndpoint() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/LiveTv/Recordings", json: #"{"Items":[{"Id":"recording","Type":"Movie"}]}"#)
        let provider = JellyfinProvider(session: session(), http: stub)
        let section = ServerHomeSection(id: "web:0:activerecordings", kind: .recordings)
        let items = try await provider.serverHomeItems(section: section, limit: 7, excludingLibraryIDs: [])
        XCTAssertEqual(items.map(\.id), ["recording"])
        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/LiveTv/Recordings"))
        for item in [
            URLQueryItem(name: "UserId", value: "selected-user"),
            .init(name: "IsInProgress", value: "true"),
            .init(name: "Limit", value: "7"),
            .init(name: "EnableTotalRecordCount", value: "false")
        ] {
            XCTAssertTrue(query.contains(item))
        }
        let hidden = try await provider.serverHomeItems(
            section: section, limit: 7, excludingLibraryIDs: ["movies"]
        )
        XCTAssertTrue(hidden.isEmpty)
        XCTAssertEqual(stub.sentPaths, ["/LiveTv/Recordings"])
        XCTAssertEqual(stub.sentMethods, [.get])
    }

    func testEmbyNativeSectionsKeepServerOrderAndCustomNamesWithoutTitleClassification() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/selected-user/HomeSections", json: """
        [
          {"Id":"mystery","SectionType":"UnspecifiedFutureValue","Name":"Continue Watching",
           "CustomName":"My selection","ParentId":"movies","ItemTypes":["Movie"]},
          {"Id":"reading","ItemTypes":["Book"]},
          {"Id":"listening","ParentId":"music"},
          {"Id":"resume","Query":{"IsResumable":true},"IncludeNextUpInResume":true},
          {"Id":"live","CollectionType":"livetv"},
          {"Id":"libraries","ItemTypes":["CollectionFolder"]},
          {"Id":"latestmedia_movies","SectionType":"latestmedia","Name":"Latest Movies",
           "CustomName":"Fresh picks","CollectionType":"movies","ParentId":"movies",
           "ItemTypes":[],"Query":{"IsPlayed":false}},
          {"Id":"another","SectionType":"AnotherFutureValue","Name":"Recently Added"}
        ]
        """)
        stub.stub(pathSuffix: "/Users/selected-user/Views", json: views)
        let response = try await JellyfinProvider(session: session(.emby), http: stub).serverHomeLayout()
        let layout = try XCTUnwrap(response)
        XCTAssertEqual(layout.source, .server)
        XCTAssertEqual(layout.sections.map(\.id), [
            "emby:mystery", "emby:resume", "emby:live", "emby:libraries", "emby:latestmedia_movies", "emby:another"
        ])
        XCTAssertEqual(layout.sections.map(\.kind), [
            .recommendations, .continueWatching, .liveTV, .libraries, .recentlyAdded, .recommendations
        ])
        XCTAssertEqual(layout.sections.first?.title, "My selection")
        XCTAssertEqual(layout.sections.first?.libraryID, "movies")
        XCTAssertEqual(layout.sections[4].title, "Fresh picks")
        XCTAssertEqual(layout.sections[4].libraryID, "movies")
        XCTAssertTrue(layout.sections[1].includesNextUp)
        XCTAssertTrue(layout.omitsMusic)
        XCTAssertTrue(layout.omitsReading)
        XCTAssertFalse(stub.sentPaths.contains("/DisplayPreferences/usersettings"))
    }

    func testEmbyNativeItemsUseSectionIdentityEnvelopeBoundAndAllowedParent() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/selected-user/Views", json: views)
        stub.stub(pathSuffix: "/Users/selected-user/Sections/native-row/Items", json: """
        {"Items":[{"Id":"episode","Type":"Episode"},{"Id":"audio","Type":"Audio"},
          {"Id":"channel","Type":"TvChannel"}],"TotalRecordCount":999}
        """)
        let provider = JellyfinProvider(session: session(.emby), http: stub)
        let items = try await provider.serverHomeItems(
            section: .init(id: "emby:native-row", kind: .recommendations),
            limit: .max, excludingLibraryIDs: ["movies"]
        )
        XCTAssertEqual(items.map(\.id), ["episode"])
        XCTAssertEqual(items.first?.libraryID, "shows")
        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/Sections/native-row/Items"))
        XCTAssertTrue(query.contains(.init(name: "Limit", value: "100")))
        XCTAssertTrue(query.contains(.init(name: "StartIndex", value: "0")))
        XCTAssertTrue(query.contains(.init(name: "ParentId", value: "shows")))
        XCTAssertFalse(query.contains { ["IncludeItemTypes", "MediaTypes"].contains($0.name) })
        XCTAssertEqual(stub.sentPaths.count, 2)
    }

    func testNativeAudioSectionsCannotBeRetargetedToDuplicateVideoResumeItems() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/selected-user/HomeSections", json: """
        [
          {"Id":"watching","Name":"Continue Watching","Query":{"IsResumable":true}},
          {"Id":"listening","Name":"Continue Listening","SectionType":"ServerOwnedAudio"},
          {"Id":"reading","Name":"Continue Reading","SectionType":"ServerOwnedBooks"}
        ]
        """)
        stub.stub(pathSuffix: "/Users/selected-user/Views", json: views)
        let video = #"{"Items":[{"Id":"movie","Type":"Movie"}],"TotalRecordCount":1}"#
        stub.stub(pathSuffix: "/Sections/watching/Items", json: video)
        for (id, type) in [("listening", "Audio"), ("reading", "Book")] {
            let path = "/Sections/\(id)/Items"
            stub.stub(pathSuffix: path, requiring: [
                .init(name: "IncludeItemTypes", value: "Movie,Series,Season,Episode,Video")
            ], json: video)
            stub.stub(pathSuffix: path, json: """
            {"Items":[{"Id":"\(id)-item","Type":"\(type)"}],"TotalRecordCount":1}
            """)
        }
        let provider = JellyfinProvider(session: session(.emby), http: stub)
        let fetchedLayout = try await provider.serverHomeLayout()
        let layout = try XCTUnwrap(fetchedLayout)
        XCTAssertEqual(layout.sections.map(\.id), ["emby:watching", "emby:listening", "emby:reading"])
        for limit in [20, Int.max] {
            let results = await provider.serverHomeItems(
                sections: layout.sections, limit: limit, excludingLibraryIDs: []
            )
            XCTAssertEqual(try XCTUnwrap(results["emby:watching"]).get().map(\.id), ["movie"])
            for id in ["listening", "reading"] {
                XCTAssertTrue(try XCTUnwrap(results["emby:\(id)"]).get().isEmpty,
                              "Unsupported native sections must not become video resume rows.")
            }
        }
        XCTAssertFalse(stub.sentPaths.contains { $0.hasSuffix("/Items/Resume") })
        XCTAssertTrue(stub.sentQueryItems.allSatisfy { query in
            !query.contains { ["IncludeItemTypes", "MediaTypes"].contains($0.name) }
        })
    }

    func testEmby404FallsBackToWebPreferencesButOtherFailuresNeverDo() async throws {
        let fallback = StubHTTPClient()
        fallback.stub(pathSuffix: "/Users/selected-user/HomeSections", json: "{}", status: 404)
        fallback.stub(pathSuffix: "/DisplayPreferences/usersettings", json: preferences(["resume"]))
        fallback.stub(pathSuffix: "/Users/selected-user/Views", json: views)
        let layout = try await JellyfinProvider(session: session(.emby), http: fallback).serverHomeLayout()
        XCTAssertEqual(layout?.source, .webPreferences)
        XCTAssertEqual(Array(fallback.sentPaths.prefix(2)), [
            "/Users/selected-user/HomeSections", "/DisplayPreferences/usersettings"
        ])

        for status in [401, 403, 500] {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/Users/selected-user/HomeSections", json: "{}", status: status)
            do {
                _ = try await JellyfinProvider(session: session(.emby), http: stub).serverHomeLayout()
                XCTFail("HTTP \(status) must throw")
            } catch {
                XCTAssertEqual(error as? AppError, status == 500 ? .invalidResponse : .unauthorized)
            }
            XCTAssertEqual(stub.sentPaths, ["/Users/selected-user/HomeSections"])
        }
        for failure: AppError in [.serverUnreachable, .cancelled] {
            let stub = StubHTTPClient()
            stub.error = failure
            do {
                _ = try await JellyfinProvider(session: session(.emby), http: stub).serverHomeLayout()
                XCTFail("Transport failure must throw")
            } catch {
                XCTAssertEqual(error as? AppError, failure)
            }
            XCTAssertEqual(stub.sentPaths, ["/Users/selected-user/HomeSections"])
        }
    }

    func testMalformedNativeLayoutAndMissingViewsAreNotUnsupportedEndpoints() async throws {
        for malformed in [true, false] {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/Users/selected-user/HomeSections", json: malformed ? "{}" : "[]")
            do {
                _ = try await JellyfinProvider(session: session(.emby), http: stub).serverHomeLayout()
                XCTFail("Failure must not become a fallback layout")
            } catch {
                XCTAssertEqual(error as? AppError, malformed ? .decoding : .notFound)
            }
            XCTAssertFalse(stub.sentPaths.contains("/DisplayPreferences/usersettings"))
        }
    }

    func testWebPreferencesFailuresThrowAndOnly404MeansUnsupported() async throws {
        for status in [200, 401, 404, 500] {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/DisplayPreferences/usersettings", json: "[]", status: status)
            do {
                let layout = try await JellyfinProvider(session: session(), http: stub).serverHomeLayout()
                XCTAssertEqual(status, 404)
                XCTAssertNil(layout)
            } catch {
                XCTAssertEqual(
                    error as? AppError,
                    status == 200 ? .decoding : (status == 401 ? .unauthorized : .invalidResponse)
                )
            }
            XCTAssertEqual(stub.sentPaths, ["/DisplayPreferences/usersettings"])
        }
    }

    func testBatchesShareViewsOnceAndReloadLibraryScopeAndItemsOnSubsequentLoads() async throws {
        for kind: ProviderKind in [.jellyfin, .emby] {
            let stub = StubHTTPClient()
            stub.stubSequence(pathSuffix: "/Users/selected-user/Views", jsons: [
                views, views.replacingOccurrences(of: #""Id":"shows""#, with: #""Id":"new-shows""#)
            ])
            let sections: [ServerHomeSection] = kind == .emby ? [
                .init(id: "emby:first", kind: .recommendations),
                .init(id: "emby:second", kind: .recommendations)
            ] : [
                .init(id: "web:1:resume", kind: .continueWatching),
                .init(id: "web:5:nextup", kind: .nextUp)
            ]
            let paths = kind == .emby ? [
                "/Users/selected-user/Sections/first/Items", "/Users/selected-user/Sections/second/Items"
            ] : ["/Users/selected-user/Items/Resume", "/Shows/NextUp"]
            for (index, path) in paths.enumerated() {
                stub.stubSequence(pathSuffix: path, jsons: [
                    #"{"Items":[{"Id":"old-\#(index)","Type":"Episode"}]}"#,
                    #"{"Items":[{"Id":"new-\#(index)","Type":"Episode"}]}"#
                ])
            }
            let provider: any MediaProvider = JellyfinProvider(session: session(kind), http: stub)
            let first = await provider.serverHomeItems(
                sections: sections, limit: 8, excludingLibraryIDs: ["movies"]
            )
            XCTAssertEqual(Set(first.keys), Set(sections.map(\.id)))
            for (index, section) in sections.enumerated() {
                let items = try XCTUnwrap(first[section.id]).get()
                XCTAssertEqual(items.map(\.id), ["old-\(index)"])
                XCTAssertEqual(items.first?.libraryID, "shows")
            }
            XCTAssertEqual(stub.sentPaths, ["/Users/selected-user/Views"] + paths)

            let second = await provider.serverHomeItems(
                sections: sections, limit: 8, excludingLibraryIDs: ["movies"]
            )
            for (index, section) in sections.enumerated() {
                let items = try XCTUnwrap(second[section.id]).get()
                XCTAssertEqual(items.map(\.id), ["new-\(index)"])
                XCTAssertEqual(items.first?.libraryID, "new-shows")
                let query = try XCTUnwrap(stub.queryItems(forPathSuffix: paths[index]))
                XCTAssertTrue(query.contains(.init(name: "ParentId", value: "new-shows")))
                XCTAssertTrue(query.contains(.init(name: "Limit", value: "8")))
            }
            let expectedBatchPaths = ["/Users/selected-user/Views"] + paths
            XCTAssertEqual(stub.sentPaths, expectedBatchPaths + expectedBatchPaths)
        }
    }

    func testFailedBatchViewsAreNotRetriedPerRowAndDoNotBlockLibraryScopedRows() async throws {
        for kind: ProviderKind in [.jellyfin, .emby] {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/Users/selected-user/Views", json: "{}", status: 401)
            let sections: [ServerHomeSection]
            let scopedPath: String
            if kind == .emby {
                sections = [
                    .init(id: "emby:first", kind: .recommendations),
                    .init(id: "emby:second", kind: .recommendations),
                    .init(id: "emby:scoped", kind: .recommendations, libraryID: "shows")
                ]
                scopedPath = "/Users/selected-user/Sections/scoped/Items"
                stub.stub(pathSuffix: scopedPath, json: #"{"Items":[{"Id":"scoped","Type":"Episode"}]}"#)
            } else {
                sections = [
                    .init(id: "web:1:resume", kind: .continueWatching),
                    .init(id: "web:5:nextup", kind: .nextUp),
                    .init(id: "web:6:latestmedia:shows", kind: .recentlyAdded, libraryID: "shows")
                ]
                scopedPath = "/Users/selected-user/Items/Latest"
                stub.stub(pathSuffix: scopedPath, json: #"[{"Id":"scoped","Type":"Episode"}]"#)
            }
            let provider: any MediaProvider = JellyfinProvider(session: session(kind), http: stub)
            let results = await provider.serverHomeItems(
                sections: sections, limit: 8, excludingLibraryIDs: ["movies"]
            )
            for section in sections.prefix(2) {
                XCTAssertThrowsError(try XCTUnwrap(results[section.id]).get()) {
                    XCTAssertEqual($0 as? AppError, .unauthorized)
                }
            }
            let scoped = try XCTUnwrap(results[sections[2].id]).get()
            XCTAssertEqual(scoped.map(\.id), ["scoped"])
            XCTAssertEqual(scoped.first?.libraryID, "shows")
            XCTAssertEqual(stub.sentPaths, ["/Users/selected-user/Views", scopedPath])
        }
    }

    func testBatchRowFailurePreservesLaterRowsAndDoesNotReenumerateViews() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/selected-user/Views", json: views)
        stub.stub(pathSuffix: "/Items/Resume", json: "{}", status: 401)
        stub.stub(pathSuffix: "/Shows/NextUp", json: #"{"Items":[{"Id":"next","Type":"Episode"}]}"#)
        let sections: [ServerHomeSection] = [
            .init(id: "web:1:resume", kind: .continueWatching),
            .init(id: "web:5:nextup", kind: .nextUp)
        ]
        let provider: any MediaProvider = JellyfinProvider(session: session(), http: stub)
        let results = await provider.serverHomeItems(
            sections: sections, limit: 8, excludingLibraryIDs: ["movies"]
        )
        XCTAssertThrowsError(try XCTUnwrap(results[sections[0].id]).get()) {
            XCTAssertEqual($0 as? AppError, .unauthorized)
        }
        XCTAssertEqual(try XCTUnwrap(results[sections[1].id]).get().map(\.id), ["next"])
        XCTAssertEqual(stub.sentPaths, [
            "/Users/selected-user/Views",
            "/Users/selected-user/Items/Resume", "/Shows/NextUp"
        ])
    }

    func testBatchesWithoutLibraryExclusionOrItemWorkNeverFetchViews() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Items/Resume", json: #"{"Items":[]}"#)
        stub.stub(pathSuffix: "/Shows/NextUp", json: #"{"Items":[]}"#)
        let provider: any MediaProvider = JellyfinProvider(session: session(), http: stub)
        let sections: [ServerHomeSection] = [
            .init(id: "web:1:resume", kind: .continueWatching),
            .init(id: "web:5:nextup", kind: .nextUp)
        ]
        let unscoped = await provider.serverHomeItems(sections: sections, limit: 8, excludingLibraryIDs: [])
        let zeroLimit = await provider.serverHomeItems(sections: sections, limit: 0, excludingLibraryIDs: ["movies"])
        for response in [unscoped, zeroLimit] {
            for section in sections {
                XCTAssertTrue(try XCTUnwrap(response[section.id]).get().isEmpty)
            }
        }
        let noWork: [ServerHomeSection] = [
            .init(id: "web:0:folders", kind: .libraries),
            .init(id: "web:4:livetv", kind: .liveTV),
            .init(id: "web:7:activerecordings", kind: .recordings),
            .init(id: "web:6:latestmedia:movies", kind: .recentlyAdded, libraryID: "movies")
        ]
        let hidden = await provider.serverHomeItems(sections: noWork, limit: 8, excludingLibraryIDs: ["movies"])
        for section in noWork {
            XCTAssertTrue(try XCTUnwrap(hidden[section.id]).get().isEmpty)
        }
        XCTAssertEqual(stub.sentPaths, ["/Users/selected-user/Items/Resume", "/Shows/NextUp"])
    }
}
