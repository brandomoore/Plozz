#if canImport(Sentry)
import CoreModels
import Sentry
import XCTest
@testable import CrashReporting

final class CrashRedactionTests: XCTestCase {
    func testPlaylistLimitEventContainsOnlyTypedLimitAndCounts() throws {
        let diagnostic = LiveTVPlaylistLimitDiagnostic(
            limit: .responseBodyBytes, observed: 20_971_521, maximum: 20_971_520
        )
        let event = SentryCrashReporter.playlistLimitEvent(diagnostic)
        event.context?["playlist_import"]?["url"] = "https://private.test/secret"
        event.context?["playlist_import"]?["name"] = "Private playlist"
        event.extra = ["contents": "Private channel titles"]
        let clean = try XCTUnwrap(CrashRedaction.scrub(event))
        XCTAssertEqual(clean.fingerprint, ["live_tv_playlist_limit", "responseBodyBytes"])
        XCTAssertEqual(clean.tags, [
            "report.kind": "playlist-import-limit", "import.limit": "responseBodyBytes"
        ])
        let counts = try XCTUnwrap(clean.context?["playlist_import"])
        XCTAssertEqual(Set(counts.keys), ["observed", "maximum"])
        XCTAssertEqual((counts["observed"] as? NSNumber)?.int64Value, 20_971_521)
        XCTAssertNil(clean.extra)
        XCTAssertNil(clean.user)
        XCTAssertNil(clean.request)
    }

    func testPlaylistLimitContextRejectsUnknownLimitsAndNonnumericValues() throws {
        let event = SentryCrashReporter.playlistLimitEvent(.init(limit: .entries, observed: 100_001, maximum: 100_000))
        event.context?["playlist_import"]?["observed"] = "https://private.test/secret"
        event.context?["playlist_import"]?["maximum"] = true
        XCTAssertNil(CrashRedaction.scrub(event)?.context)
        event.context = ["playlist_import": ["observed": 100_001, "maximum": 100_000]]
        event.tags?["import.limit"] = "unknown"
        XCTAssertNil(CrashRedaction.scrub(event)?.context)
    }

    func testPlaylistLimitReportsAreBoundedUntilReportingRestarts() {
        let gate = PlaylistDiagnosticGate()
        XCTAssertTrue(gate.accept(.entries))
        XCTAssertFalse(gate.accept(.entries))
        XCTAssertTrue(gate.accept(.inputBytes))
        gate.reset()
        XCTAssertTrue(gate.accept(.entries))
    }

    func testMemoryEvidenceSurvivesWithoutDeviceIdentityOrPrivateContexts() throws {
        let event = Event(level: .fatal)
        event.context = [
            "device": [
                "name": "Private device name", "id": "private-id",
                "memory_size": 4096, "free_memory": 512, "low_memory": true,
                "usable_memory": "https://private.test/token"
            ],
            "app": ["app_memory": 1024, "installation_id": "private-installation"],
            "playlist": ["url": "https://private.test/token"]
        ]
        let clean = try XCTUnwrap(CrashRedaction.scrub(event)?.context)
        XCTAssertEqual(Set(clean.keys), ["device", "app"])
        XCTAssertEqual(Set(try XCTUnwrap(clean["device"]).keys), ["memory_size", "free_memory", "low_memory"])
        XCTAssertEqual(clean["device"]?["free_memory"] as? Int, 512)
        XCTAssertEqual(clean["device"]?["low_memory"] as? Bool, true)
        XCTAssertEqual(Set(try XCTUnwrap(clean["app"]).keys), ["app_memory"])
    }

    func testScreenBreadcrumbOnlyRetainsAnAllowedCategory() throws {
        let crumb = Breadcrumb(level: .info, category: "plozz.screen")
        crumb.message = "settings"
        crumb.data = ["title": "Private title", "url": "https://private.test/token"]
        let clean = try XCTUnwrap(CrashRedaction.scrub(crumb))
        XCTAssertEqual(clean.message, "settings")
        XCTAssertNil(clean.data)
        crumb.message = "settings/private-profile"
        XCTAssertNil(CrashRedaction.scrub(crumb))
    }

    func testOnlyTypedSyncValuesSurvive() throws {
        let crumb = Breadcrumb(level: .error, category: "plozz.live_tv_sync")
        crumb.message = "Private playlist https://private.test/token"
        crumb.data = [
            "operation": "capture", "stage": "identities", "outcome": "failed",
            "reason": "storage", "code": 257, "description": "private path",
            "profile": "private profile", "url": "https://private.test/token"
        ]
        let clean = try XCTUnwrap(CrashRedaction.scrub(crumb))
        XCTAssertEqual(clean.message, "Live TV sync")
        XCTAssertEqual(Set(try XCTUnwrap(clean.data).keys),
                       ["operation", "stage", "outcome", "reason", "code"])
        XCTAssertEqual(clean.data?["code"] as? Int, 257)
        crumb.data?["stage"] = "https://private.test/token"
        XCTAssertNil(CrashRedaction.scrub(crumb))
    }

    func testAutomaticBreadcrumbsAndPrivateEventContainersAreDropped() throws {
        let event = Event(level: .error)
        event.user = User(userId: "private-profile")
        event.extra = ["playlist": "https://private.test/token"]
        event.context = ["private": ["title": "Private title"]]
        let network = Breadcrumb(level: .info, category: "http")
        network.message = "https://private.test/token"
        let automaticUI = Breadcrumb(level: .info, category: "ui.click")
        automaticUI.message = "Private title"
        let manual = Breadcrumb(level: .info, category: "plozz.screen")
        manual.message = "liveTV"
        event.breadcrumbs = [network, automaticUI, manual]
        let clean = try XCTUnwrap(CrashRedaction.scrub(event))
        XCTAssertNil(clean.user)
        XCTAssertNil(clean.extra)
        XCTAssertNil(clean.context)
        XCTAssertEqual(clean.breadcrumbs?.count, 1)
        XCTAssertEqual(clean.breadcrumbs?.first?.message, "liveTV")
    }

    func testSuccessCannotCarryFailureData() throws {
        let crumb = Breadcrumb(level: .info, category: "plozz.live_tv_sync")
        crumb.data = [
            "operation": "apply", "stage": "finish", "outcome": "succeeded",
            "reason": "private description", "code": "private secret"
        ]
        let data = try XCTUnwrap(CrashRedaction.scrub(crumb)?.data)
        XCTAssertEqual(Set(data.keys), ["operation", "stage", "outcome"])
    }
}
#endif
