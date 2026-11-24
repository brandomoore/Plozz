import CoreModels
import Foundation
import XCTest
@testable import ProviderSilo

extension SiloProviderTests {
    private func watchItem(kind: MediaItemKind, fields: String) throws -> MediaItem {
        let raw = try credential().encoded()
        let provider = try SiloProvider(
            context: context(raw), credentials: SiloCredentialStub(raw), http: SiloHTTPStub([:])
        )
        let dto = try JSONDecoder().decode(SiloItem.self, from: Data("""
        {"content_id":"item","type":"\(kind.rawValue)","title":"Title",\(fields)}
        """.utf8))
        return provider.map(dto)
    }

    private func watchFile(id: String = "file", duration: Double) -> String {
        """
        {"file_id":"\(id)","resolution":"1080p","codec_video":"h264","codec_audio":"aac",
         "container":"mkv","file_size":100,"duration":\(duration),"bitrate":2000}
        """
    }

    func testContainerRollupsPreserveRemainingCountsAndPartialHistory() throws {
        for kind in [MediaItemKind.series, .season] {
            let item = try watchItem(kind: kind, fields: """
                "user_data":{"played":false,"watched_count":3,"unplayed_count":7,"in_progress_count":2}
                """)
            XCTAssertEqual(item.unwatchedEpisodeCount, 7, "In-progress episodes are already included")
            XCTAssertEqual(try XCTUnwrap(item.playedPercentage), 0.3, accuracy: 0.0001)
            XCTAssertFalse(item.isPlayed)
            XCTAssertTrue(item.hasBeenPlayed)
            XCTAssertEqual(item.librarySortValues?.watched, false)
        }
    }

    func testMissingZeroAndUnstartedRollupsRemainDistinct() throws {
        let missing = try watchItem(kind: .series, fields: #""user_data":{"played":false}"#)
        XCTAssertNil(missing.unwatchedEpisodeCount)
        XCTAssertNil(missing.playedPercentage)
        let complete = try watchItem(kind: .series, fields: """
            "user_data":{"played":true,"watched_count":10,"unplayed_count":0}
            """)
        XCTAssertEqual(complete.unwatchedEpisodeCount, 0)
        XCTAssertEqual(complete.playedPercentage, 1)
        XCTAssertTrue(complete.isPlayed)
        let unstarted = try watchItem(kind: .season, fields: """
            "user_data":{"played":false,"watched_count":0,"unplayed_count":10}
            """)
        XCTAssertEqual(unstarted.unwatchedEpisodeCount, 10)
        XCTAssertNil(unstarted.playedPercentage)
        XCTAssertFalse(unstarted.hasBeenPlayed)
        let empty = try watchItem(kind: .season, fields: """
            "user_data":{"played":false,"watched_count":0,"unplayed_count":0}
            """)
        XCTAssertEqual(empty.unwatchedEpisodeCount, 0)
        XCTAssertNil(empty.playedPercentage)
        XCTAssertFalse(empty.isPlayed)
    }

    func testLeafResumeProgressUsesSecondsAndNeverEpisodeCounts() throws {
        for kind in [MediaItemKind.movie, .episode] {
            let item = try watchItem(kind: kind, fields: """
                "runtime":60,
                "user_data":{"played":false,"position_seconds":900,"duration_seconds":1800,
                             "watched_count":0,"unplayed_count":1}
                """)
            XCTAssertEqual(item.runtime, 1800)
            XCTAssertEqual(item.resumePosition, 900)
            XCTAssertEqual(item.playedPercentage, 0.5)
            XCTAssertNil(item.unwatchedEpisodeCount)
            XCTAssertFalse(item.isPlayed)
        }
        let runtimeFallback = try watchItem(kind: .movie, fields: #""runtime":60,"position_seconds":900"#)
        XCTAssertEqual(runtimeFallback.playedPercentage, 0.25)
        let noRuntime = try watchItem(kind: .episode, fields: #""position_seconds":900"#)
        XCTAssertNil(noRuntime.playedPercentage)
    }

    func testExplicitResumeIncludingZeroOutranksOldSortProgressAndRetainsWatchedHistory() throws {
        for position in [0, 300] {
            let item = try watchItem(kind: .movie, fields: """
                "position_seconds":\(position),"duration_seconds":1200,
                "sort_metrics":{"progress_ratio":1},
                "user_state":{"played":true,"is_favorite":false,"in_watchlist":false},
                "user_data":{"played":true,"position_seconds":600,"duration_seconds":1800}
                """)
            XCTAssertEqual(item.playedPercentage, Double(position) / 1200)
            XCTAssertEqual(item.resumePosition, Double(position))
            XCTAssertTrue(item.isPlayed)
            XCTAssertTrue(item.hasBeenPlayed)
        }
        let sortOnly = try watchItem(kind: .movie, fields: #""sort_metrics":{"progress_ratio":0.4}"#)
        XCTAssertEqual(sortOnly.playedPercentage, 0.4)
    }

    func testSingleFileRuntimePreservesSecondsForMoviesAndEpisodes() throws {
        for kind in [MediaItemKind.movie, .episode] {
            let item = try watchItem(kind: kind, fields: """
                "runtime":169,"position_seconds":1044.003,
                "versions":[\(watchFile(duration: 10144))]
                """)
            XCTAssertEqual(item.runtime, 10144)
            XCTAssertEqual(item.resumePosition, 1044.003)
            XCTAssertEqual(try XCTUnwrap(item.playedPercentage), 1044.003 / 10144, accuracy: 0.000001)
        }
    }

    func testExplicitProgressDurationsOutrankSingleFileFallback() throws {
        for (fields, expected) in [
            (#""duration_seconds":1200,"user_data":{"played":false,"duration_seconds":1800}"#, 1200.0),
            (#""user_data":{"played":false,"duration_seconds":1800}"#, 1800.0)
        ] {
            let item = try watchItem(kind: .movie, fields: """
                "runtime":60,"versions":[\(watchFile(duration: 600))],\(fields)
                """)
            XCTAssertEqual(item.runtime, expected)
        }
    }

    func testMissingInvalidAndAmbiguousFilesDoNotSupplyAPlaybackRuntime() throws {
        for versions in [
            "[]", "[\(watchFile(duration: 0))]", "[\(watchFile(duration: -1))]",
            "[\(watchFile(id: "first", duration: 600)),\(watchFile(id: "second", duration: 650))]"
        ] {
            let item = try watchItem(kind: .movie, fields: #""runtime":60,"versions":\#(versions)"#)
            XCTAssertEqual(item.runtime, 3600)
        }
        for kind in [MediaItemKind.series, .season] {
            let item = try watchItem(kind: kind, fields: """
                "runtime":60,"versions":[\(watchFile(duration: 600))]
                """)
            XCTAssertEqual(item.runtime, 3600)
        }
    }

    func testSingleFileRuntimeAllowsMatchingTrackerResumeWithoutRelaxingMismatchGuard() throws {
        let item = try watchItem(kind: .movie, fields: """
            "runtime":169,"tmdb_id":"550","versions":[\(watchFile(duration: 10144))]
            """)
        let account = Account(
            id: "account1", server: context(try credential().encoded()).session.server,
            userID: "user1:profile1", userName: "Viewer", deviceID: "device1"
        )
        for (runtime, expected) in [
            (10144.233, TrackerHistoryImportPlan.Comparison.ready),
            (10146.5, .incompatibleRuntime)
        ] {
            let observation = try TrackerHistoryObservation(
                recordID: "resume", kind: .movie, identities: [.external(source: "tmdb", value: "550")],
                fact: .resume(seconds: 1044.003, runtime: runtime, updatedAt: nil)
            )
            let plan = TrackerHistoryImportPlan(
                snapshot: try .init(
                    trackerID: "tracker", connectionID: "connection", observations: [observation], expectedCount: 1
                ),
                serverScope: .init(profile: .init(id: "profile", name: "Test"), accounts: [account]),
                candidates: [.init(
                    accountID: account.id, item: item, canWriteWatched: true, canWriteResume: true, isPlaying: false
                )]
            )
            XCTAssertEqual(plan.rows.first?.comparison, expected)
            let change: TrackerHistoryImportPlan.Change? = expected == .ready ? .resume(1044.003) : nil
            XCTAssertEqual(plan.rows.first?.change, change)
        }
    }

    func testInvalidRollupsDoNotBecomeEpisodeBadgesOrOverflow() throws {
        let invalid = try watchItem(kind: .series, fields: """
            "user_data":{"played":false,"watched_count":-1,"unplayed_count":-2}
            """)
        XCTAssertNil(invalid.unwatchedEpisodeCount)
        XCTAssertNil(invalid.playedPercentage)
        let large = try watchItem(kind: .series, fields: """
            "user_data":{"played":false,"watched_count":\(Int.max),"unplayed_count":\(Int.max)}
            """)
        XCTAssertEqual(large.playedPercentage, 0.5)
        XCTAssertNil(SiloProvider.playbackFraction(position: -1, duration: 100))
        XCTAssertNil(SiloProvider.playbackFraction(position: 10, duration: 0))
        XCTAssertNil(SiloProvider.playbackFraction(position: .infinity, duration: 100))
        XCTAssertEqual(SiloProvider.playbackFraction(position: 120, duration: 100), 1)
    }

    func testCatalogCompletionFlagsNeedOnlyTheExistingPageRequest() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub(["/api/v2/catalog": """
            {"items":[
             {"content_id":"series:1","type":"series","title":"Watched",
              "user_state":{"played":true,"is_favorite":false,"in_watchlist":false}},
             {"content_id":"series:2","type":"series","title":"Not complete",
              "user_state":{"played":false,"is_favorite":false,"in_watchlist":false}}
            ],"total":2,"total_exact":true,"window_cursor":""}
            """])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let page = try await provider.items(in: "library", kind: .series, page: .init())
        XCTAssertEqual(page.items.map(\.isPlayed), [true, false])
        XCTAssertTrue(page.items.allSatisfy { $0.unwatchedEpisodeCount == nil })
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), ["/api/v2/catalog"])
        XCTAssertEqual(requests.first?.headers["X-Profile-Id"], "profile1")
    }

    func testSeasonListingUsesExistingRollupsWithoutDetailFanout() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub([
            "/api/v2/catalog/items/series:1": #"{"content_id":"series:1","type":"series","title":"Show"}"#,
            "/api/v2/catalog/series/series:1/seasons": """
            {"items":[{"content_id":"season:1","title":"Season 1","season_number":1,
              "user_data":{"played":false,"watched_count":4,"unplayed_count":6}},
             {"content_id":"season:2","title":"Season 2","season_number":2,
              "user_data":{"played":true,"watched_count":8,"unplayed_count":0}}]}
            """
        ])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let items = try await provider.children(of: "series:1")
        XCTAssertEqual(items.map(\.kind), [.season, .season])
        XCTAssertEqual(items.map(\.unwatchedEpisodeCount), [6, 0])
        XCTAssertEqual(items.map(\.playedPercentage), [0.4, 1])
        XCTAssertEqual(items.map(\.isPlayed), [false, true])
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), [
            "/api/v2/catalog/items/series:1", "/api/v2/catalog/series/series:1/seasons"
        ])
    }

    func testNativeHomeUpdatesResumePercentageWithoutAdditionalRequests() async throws {
        for position in [0, 300] {
            let raw = try credential().encoded()
            let http = SiloHTTPStub([
                "/api/v2/home/sections/resume/items": """
                {"id":"resume","section_type":"continue_watching","items":[
                 {"content_id":"series:1","type":"series","title":"Show","play_content_id":"episode:1",
                  "position_seconds":\(position),"duration_seconds":1200},
                 {"content_id":"movie:1","type":"movie","title":"Movie",
                  "position_seconds":600,"duration_seconds":2400}]}
                """,
                "/api/v2/catalog/items/episode:1": """
                {"content_id":"episode:1","type":"episode","title":"Episode","series_id":"series:1",
                 "user_data":{"played":false,"position_seconds":900,"duration_seconds":1800}}
                """
            ])
            let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
            let items = try await provider.serverHomeItems(
                section: .init(id: "resume", kind: .continueWatching), limit: 10, excludingLibraryIDs: []
            )
            XCTAssertEqual(items.map(\.playedPercentage), [Double(position) / 1200, 0.25])
            XCTAssertEqual(items.first?.resumePosition, Double(position))
            let requests = await http.requests
            XCTAssertEqual(requests.map(\.path), [
                "/api/v2/home/sections/resume/items", "/api/v2/catalog/items/episode:1"
            ])
        }
    }
}
