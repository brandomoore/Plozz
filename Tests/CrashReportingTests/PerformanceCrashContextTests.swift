#if canImport(Sentry)
import CoreModels
import Foundation
import Sentry
import XCTest
@testable import CrashReporting

final class PerformanceCrashContextTests: XCTestCase {
    func testBeforeSendAttachesIncompleteOperationsToExistingUserDiagnosticEvent() throws {
        let diagnostics = PerformanceDiagnostics()
        diagnostics.start()
        defer { diagnostics.stop() }
        let span = try XCTUnwrap(diagnostics.begin(.homeLoad, provider: .plex, metrics: .init(accounts: 2)))
        defer { span.finish(.cancelled) }
        let event = Event(level: .info)
        event.tags = ["report.kind": "user-diagnostics"]
        event.message = SentryMessage(formatted: "User diagnostics report")
        let clean = try XCTUnwrap(SentryCrashReporter.prepareEvent(event, diagnostics: diagnostics))
        XCTAssertTrue(clean === event)
        XCTAssertEqual(clean.tags?["report.kind"], "user-diagnostics")
        let context = try XCTUnwrap(clean.context?[CrashPerformanceContext.key])
        let active = try XCTUnwrap(context["active"] as? [[String: Any]])
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?["operation"] as? String, "homeLoad")
        XCTAssertEqual(active.first?["provider"] as? String, "plex")
        XCTAssertNil(active.first?["outcome"])
        XCTAssertEqual((active.first?["metrics"] as? [String: Any])?["accounts"] as? Int, 2)
    }

    func testBeforeSendRemovesInjectedOrStaleContextWhileOptedOut() throws {
        let diagnostics = PerformanceDiagnostics()
        let event = Event(level: .error)
        event.context = [CrashPerformanceContext.key: context()]
        XCTAssertNil(SentryCrashReporter.prepareEvent(event, diagnostics: diagnostics)?.context?[CrashPerformanceContext.key])
        diagnostics.start()
        let span = try XCTUnwrap(diagnostics.begin(.shareScan))
        event.timestamp = Date()
        XCTAssertNotNil(SentryCrashReporter.prepareEvent(event, diagnostics: diagnostics)?.context?[CrashPerformanceContext.key])
        diagnostics.stop()
        span.finish(.failed)
        XCTAssertNil(SentryCrashReporter.prepareEvent(event, diagnostics: diagnostics)?.context?[CrashPerformanceContext.key])
        diagnostics.start()
        defer { diagnostics.stop() }
        XCTAssertNil(SentryCrashReporter.prepareEvent(event, diagnostics: diagnostics)?.context?[CrashPerformanceContext.key])
        event.timestamp = Date()
        let clean = try XCTUnwrap(SentryCrashReporter.prepareEvent(event, diagnostics: diagnostics))
        let active = clean.context?[CrashPerformanceContext.key]?["active"] as? [Any]
        let recent = clean.context?[CrashPerformanceContext.key]?["recent"] as? [Any]
        XCTAssertEqual(active?.count, 0)
        XCTAssertEqual(recent?.count, 0)
    }

    func testReplayedCrashDoesNotReceiveRelaunchOperationsOrKeepUnattributedContext() throws {
        let event = Event(level: .fatal)
        event.timestamp = Date().addingTimeInterval(-60)
        event.context = [CrashPerformanceContext.key: context()]
        let exception = Exception(value: "SIGABRT", type: "Crash")
        event.exceptions = [exception]
        let diagnostics = PerformanceDiagnostics()
        diagnostics.start()
        defer { diagnostics.stop() }
        let span = try XCTUnwrap(diagnostics.begin(.homeLoad, provider: .plex))
        defer { span.finish(.cancelled) }

        let clean = try XCTUnwrap(SentryCrashReporter.prepareEvent(event, diagnostics: diagnostics))
        XCTAssertTrue(clean === event)
        XCTAssertEqual(clean.level, .fatal)
        XCTAssertEqual(clean.exceptions?.count, 1)
        XCTAssertNil(clean.context?[CrashPerformanceContext.key])
        XCTAssertEqual(diagnostics.snapshot()?.active.count, 1)
    }

    func testUnknownOrFutureEventTimeDoesNotReceiveCurrentOperations() throws {
        let diagnostics = PerformanceDiagnostics()
        diagnostics.start()
        defer { diagnostics.stop() }
        let span = try XCTUnwrap(diagnostics.begin(.serverRequest))
        defer { span.finish(.cancelled) }

        for timestamp: Date? in [nil, Date().addingTimeInterval(60)] {
            let event = Event(level: .error)
            event.timestamp = timestamp
            event.context = [CrashPerformanceContext.key: context()]
            let clean = try XCTUnwrap(SentryCrashReporter.prepareEvent(event, diagnostics: diagnostics))
            XCTAssertTrue(clean === event)
            XCTAssertNil(clean.context?[CrashPerformanceContext.key])
        }
    }

    func testFatalReportWithSDKFallbackTimestampDoesNotReceiveRelaunchContext() throws {
        let diagnostics = PerformanceDiagnostics()
        diagnostics.start()
        defer { diagnostics.stop() }
        let span = try XCTUnwrap(diagnostics.begin(.homeLoad))
        defer { span.finish(.cancelled) }
        let event = Event(level: .fatal)
        event.timestamp = Date()
        let clean = try XCTUnwrap(SentryCrashReporter.prepareEvent(event, diagnostics: diagnostics))
        XCTAssertNil(clean.context?[CrashPerformanceContext.key])
        XCTAssertEqual(clean.level, .fatal)
    }

    func testStrictRedactionRebuildsOnlyTypedFieldsAndRemovesPrivatePayloads() throws {
        var raw = context()
        raw["url"] = "https://private.test/secret"
        raw["accountID"] = "Private account"
        raw["payload"] = ["Private title": "credential"]
        var item = record()
        item["name"] = "Private title"
        item["error"] = "https://private.test/secret"
        item["headers"] = ["Authorization": "Private credential"]
        item["metrics"] = ["items": 10, "bytes": 4096, "userID": "Private viewer"]
        raw["recent"] = [item]
        let event = Event(level: .error)
        event.context = [CrashPerformanceContext.key: raw, "private": ["url": "https://private.test"]]
        let clean = try XCTUnwrap(CrashRedaction.scrub(event)?.context?[CrashPerformanceContext.key])
        XCTAssertEqual(Set(clean.keys), ["schema", "elapsedMilliseconds", "maxActive", "dropped", "active", "recent", "slow"])
        let recent = try XCTUnwrap(clean["recent"] as? [[String: Any]])
        let value = try XCTUnwrap(recent.first)
        XCTAssertEqual(Set(value.keys), [
            "operation", "provider", "startedMilliseconds", "elapsedMilliseconds", "startedOnMain",
            "activeAtStart", "outcome", "metrics", "httpStatus", "networkCode"
        ])
        XCTAssertEqual(Set(try XCTUnwrap(value["metrics"] as? [String: Any]).keys), ["items", "bytes"])
        let text = String(decoding: try JSONSerialization.data(withJSONObject: clean), as: UTF8.self)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("private"))
        XCTAssertFalse(text.contains("https"))
        XCTAssertNil(event.context?["private"])
    }

    func testUnknownOperationOutcomeAndProviderRejectRecordButKeepCrash() throws {
        for key in ["operation", "outcome", "provider"] {
            for invalid: Any in ["https://private.test/secret", "futureKind", 5, true, NSNull()] {
                var item = record()
                item[key] = invalid
                try assertRecordRejected(item)
            }
        }
        for provider in ProviderKind.allCases {
            var item = record()
            item["provider"] = provider.rawValue
            var raw = context()
            raw["recent"] = [item]
            let clean = try XCTUnwrap(CrashPerformanceContext.scrub(raw))
            XCTAssertEqual((clean["recent"] as? [[String: Any]])?.first?["provider"] as? String, provider.rawValue)
        }
    }

    func testEveryApprovedOperationSurvivesStrictRedaction() throws {
        let operations: [PerformanceDiagnostics.Operation] = [
            .homeLoad, .homeFetch, .homeMerge, .homePublish, .serverRequest, .serverDecode,
            .shareScan, .playlistFetch, .playlistParse, .playlistImport, .playlistCommit, .guideFetch,
            .liveTVRefresh, .automaticChannels
        ]
        for operation in operations {
            var item = record()
            item["operation"] = operation.rawValue
            var raw = context()
            raw["recent"] = [item]
            let cleaned = try XCTUnwrap(CrashPerformanceContext.scrub(raw))
            XCTAssertEqual(
                (cleaned["recent"] as? [[String: Any]])?.first?["operation"] as? String, operation.rawValue
            )
        }
    }

    func testHostileKnownRecordMeasurementsRejectRecord() throws {
        for key in ["startedMilliseconds", "elapsedMilliseconds", "activeAtStart", "httpStatus", "networkCode"] {
            for invalid: Any in [true, "12", Double.nan, Double.infinity, 1.5, Int.max, Int.min, NSNull()] {
                var item = record()
                item[key] = invalid
                try assertRecordRejected(item)
            }
        }
        for invalid: Any in [0, 1, "true", "Private device", NSNull()] {
            var item = record()
            item["startedOnMain"] = invalid
            try assertRecordRejected(item)
        }
        for (key, invalid) in [
            ("startedMilliseconds", -1), ("elapsedMilliseconds", -1), ("elapsedMilliseconds", 1_001),
            ("activeAtStart", 0), ("activeAtStart", 33), ("httpStatus", 99), ("httpStatus", 600),
            ("networkCode", 0), ("networkCode", -4_001)
        ] {
            var item = record()
            item[key] = invalid
            try assertRecordRejected(item)
        }
        var beyondCapture = record()
        beyondCapture["startedMilliseconds"] = 999
        beyondCapture["elapsedMilliseconds"] = 2
        try assertRecordRejected(beyondCapture)
    }

    func testHostileMetricsRejectRecordWithoutEncodingUntrustedPayloads() throws {
        for key in ["items", "bytes", "rows", "credits", "accounts", "requests"] {
            for invalid: Any in [true, "12", -1, Int.max, Double.nan, Double.infinity, 1.5, ["url": "Private"]] {
                var item = record()
                item["metrics"] = [key: invalid]
                try assertRecordRejected(item)
            }
        }
        var item = record()
        item["metrics"] = ["payload", "Private"]
        try assertRecordRejected(item)
    }

    func testMalformedHeadersOrUnboundedArraysDropContextButNotEvent() throws {
        for key in ["schema", "elapsedMilliseconds", "maxActive", "dropped"] {
            for invalid: Any in [true, "1", -1, Double.nan, Double.infinity, 1.5, Int.max, NSNull()] {
                var raw = context()
                raw[key] = invalid
                let event = Event(level: .fatal)
                event.context = [CrashPerformanceContext.key: raw]
                XCTAssertNotNil(CrashRedaction.scrub(event))
                XCTAssertNil(event.context?[CrashPerformanceContext.key])
            }
        }
        for (key, capacity) in [
            ("active", PerformanceDiagnostics.maximumActive),
            ("recent", PerformanceDiagnostics.maximumRecent),
            ("slow", PerformanceDiagnostics.maximumSlow)
        ] {
            var raw = context()
            raw[key] = Array(repeating: record(), count: capacity + 1)
            XCTAssertNil(CrashPerformanceContext.scrub(raw))
            raw[key] = "Private payload"
            XCTAssertNil(CrashPerformanceContext.scrub(raw))
        }
        var raw = context()
        raw["schema"] = 2
        XCTAssertNil(CrashPerformanceContext.scrub(raw))
        raw = context()
        raw["maxActive"] = 33
        XCTAssertNil(CrashPerformanceContext.scrub(raw))
        raw = context()
        raw["elapsedMilliseconds"] = PerformanceDiagnostics.maximumMilliseconds + 1
        XCTAssertNil(CrashPerformanceContext.scrub(raw))
    }

    func testActiveCannotPretendToBeCompletedAndReservedSlowRecordsMustBeSlow() throws {
        var raw = context()
        raw["active"] = [record()]
        var cleaned = try XCTUnwrap(CrashPerformanceContext.scrub(raw))
        XCTAssertEqual((cleaned["active"] as? [Any])?.count, 0)
        raw = context()
        raw["slow"] = [record()]
        cleaned = try XCTUnwrap(CrashPerformanceContext.scrub(raw))
        XCTAssertEqual((cleaned["slow"] as? [Any])?.count, 0)
        var slow = record()
        slow["elapsedMilliseconds"] = 250
        raw["slow"] = [slow]
        cleaned = try XCTUnwrap(CrashPerformanceContext.scrub(raw))
        XCTAssertEqual((cleaned["slow"] as? [Any])?.count, 1)
        raw["recent"] = [slow]
        cleaned = try XCTUnwrap(CrashPerformanceContext.scrub(raw))
        XCTAssertEqual((cleaned["recent"] as? [Any])?.count, 0)
    }

    func testProtectedHomeAndUIEvidenceAreStrictlyRebuilt() throws {
        var raw = context()
        var home = record()
        home["operation"] = "homePublish"
        home["private"] = "Private title"
        raw["homeRecent"] = [home, record()]
        raw["homeSlow"] = [] as [Any]
        raw["homeDropped"] = 4
        raw["homeUIDropped"] = 2
        var window = homeUI()
        window["profile"] = "Private viewer"
        var metrics = try XCTUnwrap(window["metrics"] as? [String: Any])
        metrics["server"] = "https://private.invalid"
        window["metrics"] = metrics
        raw["homeUI"] = [window]
        let clean = try XCTUnwrap(CrashPerformanceContext.scrub(raw))
        XCTAssertEqual((clean["homeRecent"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(clean["homeDropped"] as? Int, 4)
        let windows = try XCTUnwrap(clean["homeUI"] as? [[String: Any]])
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(Set(try XCTUnwrap(windows.first).keys), ["startedMilliseconds", "elapsedMilliseconds", "metrics"])
        XCTAssertEqual((windows.first?["metrics"] as? [String: Any])?.count, 9)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: clean), as: UTF8.self)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("private"))
        XCTAssertFalse(text.contains("https"))
    }

    func testMalformedHomeWindowsAndUnboundedHistoriesAreRejected() throws {
        for key in [
            "samples", "delayedSamples", "maximumDelayMilliseconds", "scrollingSamples", "loadingSamples",
            "heightChanges", "maximumHeightDeltaPoints", "maximumActiveScans", "maximumActiveListers"
        ] {
            for value: Any in [true, "1", -1, 0.5, Double.infinity, Int.max, NSNull()] {
                var window = homeUI()
                var metrics = try XCTUnwrap(window["metrics"] as? [String: Any])
                metrics[key] = value
                window["metrics"] = metrics
                var raw = context()
                raw["homeUI"] = [window]
                XCTAssertEqual((CrashPerformanceContext.scrub(raw)?["homeUI"] as? [Any])?.count, 0, key)
            }
        }
        for (key, value) in [("samples", 0), ("scrollingSamples", 11), ("loadingSamples", 11),
                             ("delayedSamples", 11), ("maximumDelayMilliseconds", 901)] {
            var window = homeUI()
            var metrics = try XCTUnwrap(window["metrics"] as? [String: Any])
            metrics[key] = value
            window["metrics"] = metrics
            var raw = context()
            raw["homeUI"] = [window]
            XCTAssertEqual((CrashPerformanceContext.scrub(raw)?["homeUI"] as? [Any])?.count, 0)
        }
        for (key, count) in [("homeRecent", 17), ("homeSlow", 17), ("homeUI", 61)] {
            var raw = context()
            raw[key] = Array(repeating: homeUI(), count: count)
            XCTAssertNil(CrashPerformanceContext.scrub(raw))
        }
        for key in ["homeDropped", "homeUIDropped"] {
            var raw = context()
            raw[key] = true
            XCTAssertNil(CrashPerformanceContext.scrub(raw))
        }
    }

    private func homeUI() -> [String: Any] {
        [
            "startedMilliseconds": 10, "elapsedMilliseconds": 900,
            "metrics": [
                "samples": 10, "delayedSamples": 1, "maximumDelayMilliseconds": 180,
                "scrollingSamples": 8, "loadingSamples": 10, "heightChanges": 2,
                "maximumHeightDeltaPoints": 250, "maximumActiveScans": 2, "maximumActiveListers": 8
            ]
        ]
    }

    private func assertRecordRejected(_ item: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        var raw = context()
        raw["recent"] = [item]
        let event = Event(level: .fatal)
        event.context = [CrashPerformanceContext.key: raw]
        let cleaned = try XCTUnwrap(CrashRedaction.scrub(event), file: file, line: line)
        XCTAssertEqual(
            (cleaned.context?[CrashPerformanceContext.key]?["recent"] as? [Any])?.count, 0, file: file, line: line
        )
    }

    private func context() -> [String: Any] {
        [
            "schema": 1, "elapsedMilliseconds": 1_000, "maxActive": 2, "dropped": 0,
            "active": [] as [Any], "recent": [record()], "slow": [] as [Any]
        ]
    }

    private func record() -> [String: Any] {
        [
            "operation": "serverRequest", "provider": "plex", "startedMilliseconds": 10,
            "elapsedMilliseconds": 20, "startedOnMain": false, "activeAtStart": 2,
            "outcome": "failed", "metrics": ["items": 10, "bytes": 4096],
            "httpStatus": 503, "networkCode": -1001
        ]
    }
}
#endif
