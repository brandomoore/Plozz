import XCTest
@testable import CoreModels

final class DiagnosticsReportTests: XCTestCase {
    func testReportRetainsPublicAndAppleVersionsWithoutDuplicatingLegacyVersion() {
        for displayVersion in ["2026.9.29", "2026.9.25"] {
            let report = DiagnosticsReport(
                appVersion: displayVersion, appBuild: "45", providers: "Plex",
                repoURL: "https://github.com/brandomoore/Plozz",
                marketingVersion: "2026.9.25"
            )
            XCTAssertTrue(report.environmentBlock.contains("Plozz: \(displayVersion) (build 45)"))
            XCTAssertEqual(
                report.environmentBlock.contains("Apple version: 2026.9.25"),
                displayVersion != "2026.9.25"
            )
        }
    }

    func testNewIssueURLContainsEnvironmentAndRedactedLogTail() throws {
        let report = DiagnosticsReport(
            appVersion: "1.2",
            appBuild: "34",
            providers: "Jellyfin, Plex",
            repoURL: "https://github.com/thatcube/Plozz/",
            recentLogTail: "safe recent activity"
        )

        let url = try XCTUnwrap(report.newIssueURL)
        let components = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )
        let values = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        XCTAssertEqual(url.path, "/thatcube/Plozz/issues/new")
        XCTAssertEqual(values["labels"], "bug")
        XCTAssertEqual(values["title"], "[Bug] ")
        XCTAssertTrue(values["body"]?.contains("Plozz: 1.2 (build 34)") == true)
        XCTAssertTrue(values["body"]?.contains("Provider(s): Jellyfin, Plex") == true)
        XCTAssertTrue(values["body"]?.contains("safe recent activity") == true)
    }

    func testRecentLogTailIsBounded() {
        let report = DiagnosticsReport(
            appVersion: "1",
            appBuild: "1",
            providers: "None",
            repoURL: "https://github.com/thatcube/Plozz",
            recentLogTail: String(repeating: "x", count: 500)
        )

        XCTAssertEqual(report.recentLogTail.count, 401)
        XCTAssertTrue(report.recentLogTail.hasPrefix("…"))
    }

    func testEpisodeRailCanBeCopiedFromReportQRWithoutPostingOrExportingItemIdentity() throws {
        var selected = MediaItem(id: "private-id", title: "private-title", kind: .episode,
                                 seasonNumber: 1, episodeNumber: 6, sourceAccountID: "private-server")
        selected.scheduledAirDate = Date.distantFuture
        let selection = EpisodeRailDiagnostic(list: .init(origin: .seasonRequest, returnedEpisodes: 5),
                                              libraryCards: 5, upcomingCards: 5, selected: selected)
        let report = DiagnosticsReport(appVersion: "1", appBuild: "2", providers: "Jellyfin",
                                       repoURL: "https://github.com/example/example",
                                       recentLogTail: "unrelated log line", episodeRail: selection)
        let body = try XCTUnwrap(URLComponents(string: report.newIssueURLString)?.queryItems?.first { $0.name == "body" }?.value)
        XCTAssertTrue(body.contains("list=seasonRequest returned_episodes=5"))
        XCTAssertTrue(body.contains("cards=10 library=5 upcoming=5"))
        XCTAssertTrue(body.contains("selected=upcoming season=1 episode=6"))
        XCTAssertFalse(body.contains("private-"))
        XCTAssertFalse(body.contains("unrelated log line"))
        selected.scheduledAirDate = nil
        let cached = EpisodeRailDiagnostic(list: .snapshot, libraryCards: 10, upcomingCards: 0, selected: selected)
        XCTAssertTrue(cached.supportText.contains("list=snapshot returned_episodes=unknown"))
        XCTAssertTrue(cached.supportText.contains("selected=snapshot"))
    }

    @MainActor
    func testProfileSwitchInvalidatesEvenARetainedDetailOrSupportForm() {
        let store = EpisodeRailDiagnosticStore()
        let selection = EpisodeRailDiagnostic(list: .snapshot, libraryCards: 1, upcomingCards: 0,
                                              selected: MediaItem(id: "1", title: "", kind: .episode))
        store.record(selection)
        XCTAssertEqual(store.lastSelection, selection)
        store.invalidate()
        XCTAssertNil(store.lastSelection)
        store.record(selection)
        XCTAssertNil(store.lastSelection)
    }
}
