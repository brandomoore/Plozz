#if canImport(Sentry)
import CoreModels
import CoreNetworking
import Foundation
import Sentry
import XCTest
@testable import CrashReporting
@testable import CoreModels

final class CrashDiagnosticsTests: XCTestCase {
    @MainActor
    func testConnectionEvidenceIsIncludedOnlyAfterSubmissionConsent() async throws {
        let diagnostics = ServerConnectionDiagnostics()
        let search = SearchDiagnosticJournal()
        search.start()
        let source = try XCTUnwrap(search.beginSearch()?.source(
            index: 0, provider: .silo, limit: 40, disabledLibraries: 0
        ))
        source.finish(error: .serverUnreachable)
        do {
            try await diagnostics.capture(
                provider: .jellyfin, stage: .addressValidation,
                baseURL: URL(string: "https://private-server.invalid")
            ) {
                HTTPResponseDiagnostics.recordTransportFailure(URLError(.cannotFindHost))
                throw AppError.serverUnreachable
            }
        } catch {
            XCTAssertEqual(error as? AppError, .serverUnreachable)
        }
        for enabled in [false, true] {
            var exports = 0
            var searchExports = 0
            var captures = 0
            XCTAssertEqual(CrashDiagnostics.send(
                note: "Cannot connect", isEnabled: enabled,
                sourceDiagnostics: { self.sourceExport() },
                searchDiagnostics: {
                    searchExports += 1
                    return search.export(scope: DiagnosticExportScope())
                },
                connectionDiagnostics: {
                    exports += 1
                    return diagnostics.export(scope: DiagnosticExportScope())
                },
                captureEvent: { _, attachment in
                    captures += 1
                    let connections = self.payload(attachment)["connections"] as? [String: Any]
                    let entries = connections?["entries"] as? [[String: Any]]
                    let facts = entries?.first?["facts"] as? [String: Any]
                    XCTAssertEqual(facts?["stage"] as? String, "addressValidation")
                    XCTAssertEqual((facts?["transport"] as? [[String: Any]])?.first?["urlErrorCode"] as? Int, -1003)
                    let search = self.payload(attachment)["search"] as? [String: Any]
                    let searchEntries = search?["entries"] as? [[String: Any]]
                    let searchFacts = searchEntries?.first?["facts"] as? [String: Any]
                    XCTAssertEqual(searchFacts?["provider"] as? String, "silo")
                    XCTAssertEqual(searchFacts?["outcome"] as? String, "failed")
                    XCTAssertFalse(String(decoding: attachment.data ?? Data(), as: UTF8.self).contains("private-server"))
                    return SentryId()
                },
                captureFeedback: { _ in SentryId() }
            ), enabled)
            XCTAssertEqual(exports, enabled ? 1 : 0)
            XCTAssertEqual(searchExports, enabled ? 1 : 0)
            XCTAssertEqual(captures, enabled ? 1 : 0)
        }
    }

    @MainActor
    func testPlaybackEvidenceSharesTheConsentedAttachment() async {
        let journal = PlaybackDiagnosticJournal(url: nil)
        let scope = DiagnosticExportScope()
        journal.record(
            .failed, session: UUID(), attempt: UUID(),
            facts: .init(provider: .plex, engine: .plozzigen),
            failure: .init(.serverHTTP(503))
        )
        let playback = await journal.export(scope: scope)
        for enabled in [false, true] {
            var captures = 0
            XCTAssertEqual(CrashDiagnostics.send(
                note: "Playback failed", isEnabled: enabled,
                sourceDiagnostics: { self.sourceExport(scope: scope) },
                playbackDiagnostics: playback,
                captureEvent: { _, attachment in
                    captures += 1
                    let playback = self.payload(attachment)["playback"] as? [String: Any]
                    let entries = playback?["entries"] as? [[String: Any]]
                    XCTAssertEqual(entries?.first?["event"] as? String, "failed")
                    XCTAssertEqual((entries?.first?["failure"] as? [String: Any])?["httpStatus"] as? Int, 503)
                    return SentryId()
                },
                captureFeedback: { _ in SentryId() }
            ), enabled)
            XCTAssertEqual(captures, enabled ? 1 : 0)
        }
    }

    @MainActor
    func testEveryDiagnosticSendAppendsSourceSnapshotAfterConsentCheck() {
        var snapshots = 0
        XCTAssertFalse(CrashDiagnostics.send(
            note: "Sources disappeared", isEnabled: false,
            activity: { XCTFail("No activity collection without consent"); return PlozzLog.activityExport() },
            sourceDiagnostics: { snapshots += 1; return self.sourceExport() },
            preparationDiagnostics: {
                XCTFail("No preparation collection without consent")
                return PlaybackPreparationDiagnostics.export(scope: DiagnosticExportScope())
            },
            libraryDiagnostics: {
                XCTFail("No library collection without consent")
                return LibraryDiagnosticJournal().export(scope: DiagnosticExportScope())
            },
            searchDiagnostics: {
                XCTFail("No search collection without consent")
                return SearchDiagnosticJournal().export(scope: DiagnosticExportScope())
            },
            captureEvent: { _, _ in XCTFail("No consent"); return .empty },
            captureFeedback: { _ in XCTFail("No consent"); return .empty }
        ))
        XCTAssertEqual(snapshots, 0)
        XCTAssertTrue(CrashDiagnostics.send(
            note: "Sources disappeared", isEnabled: true,
            sourceDiagnostics: { snapshots += 1; return self.sourceExport() },
            captureEvent: { _, attachment in
                XCTAssertNotNil(self.payload(attachment)["sources"])
                return SentryId()
            },
            captureFeedback: { _ in SentryId() }
        ))
        XCTAssertEqual(snapshots, 1)
    }

    @MainActor
    func testSubmissionLinksExplicitFeedbackWithoutIncludingItInTheTechnicalAttachment() {
        let capturedID = SentryId()
        var didCaptureEvent = false
        var didCaptureFeedback = false

        let sent = CrashDiagnostics.send(
            note: "  Sources disappeared\n",
            isEnabled: true,
            sourceDiagnostics: { self.sourceExport() },
            captureEvent: { event, attachment in
                didCaptureEvent = true
                XCTAssertEqual(event.level, .info)
                XCTAssertEqual(event.message?.formatted, "User diagnostics report")
                XCTAssertEqual(event.tags?["report.kind"], "user-diagnostics")
                XCTAssertEqual(attachment.filename, "plozz-diagnostics.json")
                XCTAssertEqual(attachment.contentType, "application/json")
                XCTAssertEqual(self.payload(attachment)["format"] as? String, "plozz-user-diagnostics-2")
                XCTAssertFalse(String(decoding: attachment.data ?? Data(), as: UTF8.self).contains("Sources disappeared"))
                return capturedID
            },
            captureFeedback: { feedback in
                didCaptureFeedback = true
                XCTAssertTrue(didCaptureEvent)
                XCTAssertNil(feedback.type, "Feedback must enter the SDK through beforeSend.")
                XCTAssertEqual(feedback.tags?["report.kind"], "user-feedback")
                let payload = feedback.context?["feedback"] ?? [:]
                XCTAssertEqual(Set(payload.keys), ["message", "source", "associated_event_id"])
                XCTAssertEqual(payload["message"] as? String, "Sources disappeared")
                XCTAssertEqual(payload["source"] as? String, "custom")
                XCTAssertEqual(payload["associated_event_id"] as? String, capturedID.sentryIdString)
                return SentryId()
            }
        )

        XCTAssertTrue(sent)
        XCTAssertTrue(didCaptureEvent)
        XCTAssertTrue(didCaptureFeedback)
    }

    @MainActor
    func testInactiveReportingSubmitsNeitherEventNorFeedback() {
        XCTAssertFalse(CrashDiagnostics.send(
            note: "note", isEnabled: false,
            captureEvent: { _, _ in
                XCTFail("Inactive reporting must not capture diagnostics.")
                return SentryId()
            },
            captureFeedback: { _ in
                XCTFail("Inactive reporting must not capture feedback.")
                return .empty
            }
        ))
    }

    @MainActor
    func testRejectedEventDoesNotReportSuccessOrSubmitUnlinkedFeedback() {
        var didCaptureEvent = false
        XCTAssertFalse(CrashDiagnostics.send(
            note: "note", isEnabled: true,
            sourceDiagnostics: { self.sourceExport() },
            captureEvent: { _, _ in
                didCaptureEvent = true
                return .empty
            },
            captureFeedback: { _ in
                XCTFail("Rejected diagnostics must not create feedback.")
                return .empty
            }
        ))
        XCTAssertTrue(didCaptureEvent)
    }

    @MainActor
    func testRejectedFeedbackDoesNotReportSuccess() {
        var didCaptureFeedback = false
        XCTAssertFalse(CrashDiagnostics.send(
            note: "note", isEnabled: true,
            sourceDiagnostics: { self.sourceExport() },
            captureEvent: { _, _ in SentryId() },
            captureFeedback: { _ in
                didCaptureFeedback = true
                return .empty
            }
        ))
        XCTAssertTrue(didCaptureFeedback)
    }

    @MainActor
    func testBlankNotesDoNotCollectOrSubmitDiagnostics() {
        for note: String? in [nil, "", " \n\t\r ", "\u{00A0}\u{2003}\u{2028}"] {
            XCTAssertNil(CrashDiagnostics.normalizedNote(note))
            XCTAssertFalse(CrashDiagnostics.send(
                note: note, isEnabled: true,
                activity: {
                    XCTFail("No activity collection without a message")
                    return PlozzLog.activityExport(entries: [])
                },
                sourceDiagnostics: {
                    XCTFail("No source collection without a message")
                    return self.sourceExport()
                },
                preparationDiagnostics: {
                    XCTFail("No preparation collection without a message")
                    return PlaybackPreparationDiagnostics.export(scope: DiagnosticExportScope())
                },
                libraryDiagnostics: {
                    XCTFail("No library collection without a message")
                    return LibraryDiagnosticJournal().export(scope: DiagnosticExportScope())
                },
                connectionDiagnostics: {
                    XCTFail("No connection collection without a message")
                    return ServerConnectionDiagnostics().export(scope: DiagnosticExportScope())
                },
                captureEvent: { _, _ in
                    XCTFail("No diagnostic event without a message")
                    return .empty
                },
                captureFeedback: { _ in
                    XCTFail("No feedback without a message")
                    return .empty
                }
            ))
        }
    }

    func testMessageValidationPreservesContentAndTrimsSurroundingWhitespace() {
        XCTAssertEqual(CrashDiagnostics.normalizedNote(" \nSources disappeared\nAfter refresh\t "), "Sources disappeared\nAfter refresh")
        XCTAssertEqual(CrashDiagnostics.normalizedNote("x"), "x")
    }

    @MainActor
    func testEmptyActivityRemainsExplicitWithARequiredMessage() {
        var didCaptureFeedback = false
        XCTAssertTrue(CrashDiagnostics.send(
            note: "Playback failed", isEnabled: true,
            activity: { PlozzLog.activityExport(entries: []) },
            sourceDiagnostics: { self.sourceExport() },
            captureEvent: { event, attachment in
                XCTAssertEqual(event.message?.formatted, "User diagnostics report")
                let activity = self.payload(attachment)["activity"] as? [String: Any]
                XCTAssertEqual((activity?["entries"] as? [Any])?.count, 0)
                return SentryId()
            },
            captureFeedback: { feedback in
                didCaptureFeedback = true
                XCTAssertEqual(feedback.context?["feedback"]?["message"] as? String, "Playback failed")
                return SentryId()
            }
        ))
        XCTAssertTrue(didCaptureFeedback)
    }

    func testBeforeSendRetainsFeedbackAssociationButRemovesIdentityAndArbitraryFields() throws {
        let associatedID = SentryId()
        let feedback = SentryFeedback(
            message: "Sources disappeared", name: "Private name", email: "private@example.test",
            source: .custom, associatedEventId: associatedID
        )
        let event = Event(level: .info)
        event.tags = ["report.kind": "user-feedback"]
        event.user = User(userId: "private-user")
        event.serverName = "private-server"
        event.extra = ["private": "extra"]
        event.context = [
            "feedback": feedback.serialize().merging(["unexpected": "private"]) { _, new in new },
            "private": ["url": "https://private.test"]
        ]

        let clean = try XCTUnwrap(SentryCrashReporter.prepareEvent(event, diagnostics: PerformanceDiagnostics()))
        let payload = try XCTUnwrap(clean.context?["feedback"])
        XCTAssertEqual(clean.type, "feedback")
        XCTAssertEqual(Set(payload.keys), ["message", "source", "associated_event_id"])
        XCTAssertEqual(payload["message"] as? String, "Sources disappeared")
        XCTAssertEqual(payload["source"] as? String, "custom")
        XCTAssertEqual(payload["associated_event_id"] as? String, associatedID.sentryIdString)
        XCTAssertNil(clean.user)
        XCTAssertNil(clean.serverName)
        XCTAssertNil(clean.extra)
        XCTAssertNil(clean.context?["private"])
    }

    @MainActor
    func testSDKCaptureRunsPrivacyHookBeforeFeedbackClassification() throws {
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-feedback-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: cache) }
        let options = Options()
        options.dsn = "https://test@127.0.0.1:1/1"
        options.cacheDirectoryPath = cache.path
        options.sendClientReports = false
        options.attachStacktrace = false
        var didPrepareFeedback = false
        options.beforeSend = { event in
            if event.tags?["report.kind"] == "user-feedback" {
                didPrepareFeedback = true
                XCTAssertNil(event.type)
                let clean = SentryCrashReporter.prepareEvent(event, diagnostics: PerformanceDiagnostics())
                XCTAssertEqual(clean?.type, "feedback")
                XCTAssertEqual(clean?.context?["feedback"]?["message"] as? String, "Sources disappeared")
                XCTAssertNil(clean?.user)
                XCTAssertNil(clean?.context?["os"])
                XCTAssertNil(clean?.context?["culture"])
            }
            return nil // Exercise SDK preparation without enqueuing or uploading an event.
        }
        let client = try XCTUnwrap(SentryClient(options: options))
        defer { client.close() }
        XCTAssertFalse(CrashDiagnostics.send(
            note: "Sources disappeared", isEnabled: true,
            sourceDiagnostics: { self.sourceExport() },
            captureEvent: { _, _ in SentryId() },
            captureFeedback: { client.capture(event: $0) }
        ))
        XCTAssertTrue(didPrepareFeedback)
    }

    @MainActor
    func testCompleteAttachmentExcludesRawActivityIdentitiesAndSearchContent() async throws {
        let privateValues = [
            "https://alice:private-password@media.private.test:8096/items/private-item?api_key=private-token",
            "192.168.1.24", "2001:db8::24", "private-account", "private-profile",
            "Private Movie Title", "private-search-phrase", "/Users/private-person/Movies/private-file.mkv",
            "private@example.test"
        ]
        PlozzLog.networking.error(privateValues.joined(separator: " "))
        let scope = DiagnosticExportScope()
        let sources = LiveTVSourceDiagnostics(url: nil)
        sources.record(.sourceReadFailed, identities: [.account: privateValues[3], .profile: privateValues[4]],
                       counts: [.channels: 42], reason: .timeout,
                       error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                                      userInfo: [NSLocalizedDescriptionKey: privateValues[0]]))
        let playback = PlaybackDiagnosticJournal(url: nil)
        let session = UUID(), attempt = UUID()
        let request = PlaybackRequest(
            item: .init(id: "private-item", title: privateValues[5], kind: .movie),
            streamURL: try XCTUnwrap(URL(string: privateValues[0])),
            sourceMetadata: .init(container: "mkv", video: .init(codec: "hevc"), audio: .init(codec: "aac"))
        )
        playback.record(.loading, session: session, attempt: attempt,
                        facts: .init(provider: .jellyfin, engine: .plozzigen, request: request))
        playback.record(.failed, session: session, attempt: attempt,
                        facts: .init(provider: .jellyfin, engine: .plozzigen, request: request),
                        failure: .init(.serverHTTP(401)))
        let journal = await playback.export(scope: scope)
        let library = LibraryDiagnosticJournal()
        library.record(.init(provider: .plex, operation: .libraryBrowse, failures: [
            .init(
                section: .collections, error: .unknown(privateValues.joined(separator: " ")),
                responses: [.init(
                    route: .collectionCandidates, httpStatus: 200, bytes: 512, payload: .object,
                    error: DecodingError.typeMismatch([String].self, .init(
                        codingPath: [], debugDescription: privateValues.joined(separator: " ")
                    ))
                )],
                paging: [.init(stage: .collectionCandidates, reason: .emptyID, start: 0, rows: 3, total: 4)]
            )
        ]))
        do {
            let _: Int = try await PlaybackPreparationDiagnostics.capture(provider: .jellyfin, operation: .versions) {
                HTTPResponseDiagnostics.recordRequest(.init(
                    route: .playbackInventory, method: "GET", elapsedMilliseconds: 10_000,
                    httpStatus: 502, urlErrorCode: nil, bytes: 512, format: .unknown,
                    requestTimeoutMilliseconds: 10_000, resourceTimeoutMilliseconds: 12_000
                ))
                throw AppError.unknown(privateValues[0])
            }
            XCTFail("The original preparation failure must still throw")
        } catch {
            XCTAssertEqual(error as? AppError, .unknown(privateValues[0]))
        }
        let operations = PerformanceDiagnostics()
        operations.start()
        operations.begin(.serverRequest, provider: .jellyfin)?
            .finish(.failed, metrics: .init(bytes: 128, requests: 1), httpStatus: 401)
        let searches = SearchDiagnosticJournal()
        searches.start()
        let search = try XCTUnwrap(searches.beginSearch())
        let siloSearch = try XCTUnwrap(search.source(index: 0, provider: .silo, limit: 40, disabledLibraries: 1))
        siloSearch.libraries(available: 3, excluded: 1)
        siloSearch.beginLibrary(index: 0)
        siloSearch.beginPage(limit: 40, usedCursor: false)
        siloSearch.http(.init(route: .searchCatalog, httpStatus: 503))
        siloSearch.finish(error: .unknown(privateValues.joined(separator: " ")))
        XCTAssertTrue(CrashDiagnostics.send(
            note: "My report message", isEnabled: true,
            activity: { PlozzLog.activityExport(scope: scope) },
            sourceDiagnostics: { sources.export(scope: scope) },
            preparationDiagnostics: { PlaybackPreparationDiagnostics.export(scope: scope) },
            libraryDiagnostics: { library.export(scope: scope) },
            searchDiagnostics: { searches.export(scope: scope) },
            playbackDiagnostics: journal, operations: operations,
            captureEvent: { _, attachment in
                let body = self.payload(attachment)
                let text = self.strings(in: body).joined(separator: "\n")
                for value in privateValues + [session.uuidString, attempt.uuidString,
                                               HandoffDiagnostics.correlationID("private-account")] {
                    XCTAssertFalse(text.contains(value), value)
                }
                XCTAssertFalse(text.contains("My report message"))
                let records = (body["playback"] as? [String: Any])?["entries"] as? [[String: Any]]
                XCTAssertEqual(records?.count, 2)
                XCTAssertEqual(records?.first?["session"] as? String, records?.last?["session"] as? String)
                XCTAssertEqual(records?.first?["attempt"] as? String, records?.last?["attempt"] as? String)
                XCTAssertEqual((records?.first?["facts"] as? [String: Any])?["sourceVideo"] as? String, "hevc")
                XCTAssertNotNil(body["operations"])
                let searchEntries = (body["search"] as? [String: Any])?["entries"] as? [[String: Any]]
                let searchFacts = searchEntries?.first?["facts"] as? [String: Any]
                XCTAssertEqual(searchFacts?["provider"] as? String, "silo")
                XCTAssertEqual(searchFacts?["outcome"] as? String, "failed")
                XCTAssertEqual(searchFacts?["reason"] as? String, "unknown")
                XCTAssertEqual(searchFacts?["availableLibraryCount"] as? Int, 3)
                XCTAssertEqual((searchFacts?["http"] as? [[String: Any]])?.first?["httpStatus"] as? Int, 503)
                let libraryEntry = (body["library"] as? [String: Any])?["entries"] as? [[String: Any]]
                let libraryFacts = libraryEntry?.first?["facts"] as? [String: Any]
                let libraryFailure = (libraryFacts?["failures"] as? [[String: Any]])?.first
                XCTAssertEqual(libraryFailure?["section"] as? String, "collections")
                XCTAssertEqual((libraryFailure?["responses"] as? [[String: Any]])?.first?["reason"] as? String, "wrongType")
                XCTAssertEqual((libraryFailure?["paging"] as? [[String: Any]])?.first?["reason"] as? String, "emptyID")
                let preparation = (body["preparation"] as? [String: Any])?["entries"] as? [[String: Any]]
                XCTAssertTrue(preparation?.contains {
                    let facts = $0["facts"] as? [String: Any]
                    let requests = facts?["requests"] as? [[String: Any]]
                    return requests?.first?["httpStatus"] as? Int == 502
                        && requests?.first?["requestTimeoutMilliseconds"] as? Int == 10_000
                } == true)
                return SentryId()
            },
            captureFeedback: { feedback in
                XCTAssertEqual(feedback.context?["feedback"]?["message"] as? String, "My report message")
                return SentryId()
            }
        ))
    }

    private func sourceExport(scope: DiagnosticExportScope = DiagnosticExportScope()) -> LiveTVSourceDiagnostics.Export {
        LiveTVSourceDiagnostics(url: nil).export(scope: scope)
    }

    private func payload(_ attachment: Attachment) -> [String: Any] {
        guard let data = attachment.data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Expected a valid JSON diagnostic attachment")
            return [:]
        }
        return object
    }

    private func strings(in value: Any) -> [String] {
        if let text = value as? String { return [text] }
        if let values = value as? [Any] { return values.flatMap(strings(in:)) }
        if let values = value as? [String: Any] {
            return Array(values.keys) + values.values.flatMap(strings(in:))
        }
        return []
    }

    func testMalformedFeedbackIsRejectedInsteadOfSendingAnEmptyFeedbackEvent() {
        let valid = SentryFeedback(
            message: "Sources disappeared", name: nil, email: nil,
            source: .custom, associatedEventId: SentryId()
        ).serialize()
        for (key, value): (String, Any?) in [
            ("message", nil), ("message", " \n\t "), ("message", 42),
            ("source", nil), ("source", "widget"),
            ("associated_event_id", nil), ("associated_event_id", "private"),
            ("associated_event_id", SentryId.empty.sentryIdString)
        ] {
            var payload = valid
            payload[key] = value
            let event = Event(level: .info)
            event.type = "feedback"
            event.context = ["feedback": payload]
            XCTAssertNil(CrashRedaction.scrub(event), key)
        }
        let missingContext = Event(level: .info)
        missingContext.type = "feedback"
        XCTAssertNil(CrashRedaction.scrub(missingContext))
    }

    func testNonFeedbackEventsCannotRetainFeedbackContext() throws {
        let event = Event(level: .info)
        event.context = ["feedback": SentryFeedback(
            message: "Sources disappeared", name: nil, email: nil,
            source: .custom, associatedEventId: SentryId()
        ).serialize()]
        XCTAssertNil(try XCTUnwrap(CrashRedaction.scrub(event)).context?["feedback"])
    }
}
#endif
