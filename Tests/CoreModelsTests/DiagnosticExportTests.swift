import Foundation
import XCTest
@testable import CoreModels

final class DiagnosticExportTests: XCTestCase {
    func testAliasesPreserveEqualityOnlyWithinTheReportAndNeverContainTheOriginal() {
        let first = DiagnosticExportScope()
        let second = DiagnosticExportScope()
        let account = "https://private@example.test/account?token=secret"
        XCTAssertEqual(first.alias(for: account), first.alias(for: account))
        XCTAssertNotEqual(first.alias(for: account), first.alias(for: "other-account"))
        XCTAssertNotEqual(first.alias(for: account), second.alias(for: account))
        XCTAssertFalse(first.alias(for: account).contains("private"))
        XCTAssertFalse(first.alias(for: account).contains("secret"))
    }

    func testRelativeAgesAreFiniteBoundedAndDoNotRevealWallClockTime() {
        let now = Date(timeIntervalSince1970: 3_600)
        let scope = DiagnosticExportScope(now: now)
        XCTAssertEqual(scope.ageMilliseconds(for: now.addingTimeInterval(-2)), 2_000)
        XCTAssertEqual(scope.ageMilliseconds(for: now.addingTimeInterval(2)), 0)
        XCTAssertEqual(scope.ageMilliseconds(for: .distantPast), 172_800_000)
        XCTAssertNil(scope.ageMilliseconds(for: Date(timeIntervalSinceReferenceDate: .nan)))
    }

    func testSourceDigestsAndPlaybackIdentifiersKeepTheirCrossJournalRelationship() {
        let scope = DiagnosticExportScope()
        let session = UUID().uuidString
        XCTAssertEqual(scope.alias(for: session), scope.alias(forDigest: HandoffDiagnostics.correlationID(session)))
        XCTAssertFalse(scope.alias(for: session).contains(HandoffDiagnostics.correlationID(session)))
    }

    func testSourceExportKeepsIdentityRelationshipsWithoutPersistentHashesOrLaunchIDs() throws {
        let now = Date()
        let recorder = LiveTVSourceDiagnostics(url: nil, clock: { now })
        recorder.configuration(.init(servers: [
            .init(id: "private-source", name: "Private server", accountID: "private-account")
        ]), namespace: "private-profile")
        recorder.record(
            .sourceReadFailed, identities: [.account: "private-account", .profile: "private-profile"],
            counts: [.channels: 42], flags: [.authorized: true], reason: .timeout, stage: .error,
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                           userInfo: [NSLocalizedDescriptionKey: "https://private.test?token=secret"])
        )
        let scope = DiagnosticExportScope(now: now.addingTimeInterval(2))
        let body = try object(recorder.export(scope: scope))
        let entries = try XCTUnwrap(body["entries"] as? [[String: Any]])
        let first = try XCTUnwrap(entries.first)
        let last = try XCTUnwrap(entries.last)
        let source = try XCTUnwrap((first["sources"] as? [[String: Any]])?.first)
        let identities = try XCTUnwrap(last["identities"] as? [String: String])
        XCTAssertEqual(source["account"] as? String, identities["account"])
        XCTAssertEqual(first["launch"] as? String, last["launch"] as? String)
        XCTAssertEqual(last["ageMilliseconds"] as? Int, 2_000)
        XCTAssertEqual(last["reason"] as? String, "timeout")
        XCTAssertEqual(last["errorCode"] as? Int, NSURLErrorTimedOut)
        XCTAssertEqual((last["counts"] as? [String: Int])?["channels"], 42)
        XCTAssertNil(last["timestamp"])
        let text = try String(decoding: JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        for value in ["private", "Private", "secret", HandoffDiagnostics.correlationID("private-account"),
                      HandoffDiagnostics.correlationID("private-profile")] {
            XCTAssertFalse(text.contains(value), value)
        }
        let another = try object(recorder.export(scope: DiagnosticExportScope()))
        let anotherLaunch = (another["entries"] as? [[String: Any]])?.first?["launch"] as? String
        XCTAssertNotEqual(first["launch"] as? String, anotherLaunch)
    }

    func testPlaybackExportKeepsFailureCodecTimingAndAttemptRelationshipsWithoutSourceIdentity() async throws {
        let now = Date()
        let recorder = PlaybackDiagnosticJournal(url: nil, clock: { now })
        let session = UUID(), attempt = UUID()
        var request = PlaybackRequest(
            item: .init(id: "private-item", title: "Private movie", kind: .movie),
            streamURL: try XCTUnwrap(URL(string: "https://private.test/movie.m3u8?api_key=secret")),
            sourceMetadata: .init(container: "mkv", video: .init(codec: "hevc"), audio: .init(codec: "aac"))
        )
        request.serverName = "Private server"
        request.streamingSessionID = "private-session"
        let facts = PlaybackDiagnosticJournal.Facts(provider: .plex, engine: .plozzigen, request: request)
        recorder.record(.loading, session: session, attempt: attempt, facts: facts)
        recorder.record(.failed, session: session, attempt: attempt, facts: facts, elapsed: 1.25,
                        failure: .init(.serverHTTP(503)))
        let exported = await recorder.export(scope: DiagnosticExportScope(now: now.addingTimeInterval(2)))
        let body = try object(exported)
        let entries = try XCTUnwrap(body["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?["session"] as? String, entries.last?["session"] as? String)
        XCTAssertEqual(entries.first?["attempt"] as? String, entries.last?["attempt"] as? String)
        XCTAssertNotEqual(entries.first?["session"] as? String, entries.first?["attempt"] as? String)
        XCTAssertEqual(entries.last?["elapsedMilliseconds"] as? Int, 1_250)
        XCTAssertEqual(entries.last?["ageMilliseconds"] as? Int, 2_000)
        XCTAssertEqual((entries.last?["failure"] as? [String: Any])?["httpStatus"] as? Int, 503)
        let exportedFacts = try XCTUnwrap(entries.first?["facts"] as? [String: Any])
        XCTAssertEqual(exportedFacts["sourceVideo"] as? String, "hevc")
        XCTAssertEqual(exportedFacts["sourceAudio"] as? String, "aac")
        XCTAssertEqual(exportedFacts["hasServerSession"] as? Bool, true)
        let text = String(decoding: try JSONEncoder().encode(exported), as: UTF8.self)
        for value in ["private", "Private", "secret", session.uuidString, attempt.uuidString] {
            XCTAssertFalse(text.contains(value), value)
        }
        XCTAssertFalse(text.contains("timestamp"))
    }

    func testCorruptJournalsReportUnavailableEvidenceWithoutUploadingFileContents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("sources.json")
        let playbackURL = directory.appendingPathComponent("playback.json")
        let privateData = Data("private-server.example.test PRIVATE-SECRET".utf8)
        try privateData.write(to: sourceURL)
        try privateData.write(to: playbackURL)
        let source = LiveTVSourceDiagnostics(url: sourceURL).export(scope: DiagnosticExportScope())
        let playback = await PlaybackDiagnosticJournal(url: playbackURL).export(scope: DiagnosticExportScope())
        for body in [try object(source), try object(playback)] {
            XCTAssertEqual(body["storageAvailable"] as? Bool, false)
            XCTAssertEqual(body["storageIssue"] as? String, "readFailed")
            XCTAssertEqual((body["entries"] as? [Any])?.count, 0)
            let text = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
            XCTAssertFalse(text.contains("private-server"))
            XCTAssertFalse(text.contains("PRIVATE-SECRET"))
        }
    }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
}
