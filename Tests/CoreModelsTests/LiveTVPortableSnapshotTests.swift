import Foundation
import XCTest
@testable import CoreModels

private final class SyncLimitRecorder: @unchecked Sendable {
    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [LiveTVSyncLimitDiagnostic] = []
        var values: [LiveTVSyncLimitDiagnostic] { lock.withLock { recorded } }
        func append(_ value: LiveTVSyncLimitDiagnostic) { lock.withLock { recorded.append(value) } }
    }

    private let buffer = Buffer()
    private var observer: NSObjectProtocol?
    var values: [LiveTVSyncLimitDiagnostic] { buffer.values }

    init() {
        let buffer = buffer
        observer = NotificationCenter.default.addObserver(
            forName: LiveTVSyncLimitDiagnostic.notification, object: nil, queue: nil
        ) { notification in
            if let value = notification.object as? LiveTVSyncLimitDiagnostic { buffer.append(value) }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

final class LiveTVPortableSnapshotTests: XCTestCase {
    func testSyncLimitDiagnosticsDoNotPublishUnknownOrUnexceededMeasurements() {
        let recorder = SyncLimitRecorder()
        for (observed, maximum) in [(1, 1), (0, 1), (-1, 1), (2, 0), (Int.max, 1)] {
            LiveTVSyncLimitDiagnostic.record(.recordBytes, observed: observed, maximum: maximum)
        }
        XCTAssertTrue(recorder.values.isEmpty)
    }

    func testOversizedRecordKeepsOriginalErrorAndReportsExistingByteCount() throws {
        let recorder = SyncLimitRecorder()
        let bytes = Data(repeating: 0, count: LiveTVPortableRecord.maximumBytes + 1)
        XCTAssertThrowsError(try LiveTVPortableRecord.decode(
            bytes, key: .init(profileID: "private", kind: .channel, entityID: "private")
        )) {
            XCTAssertEqual($0 as? LiveTVPortableStateError, .tooLarge)
        }
        XCTAssertEqual(recorder.values, [try XCTUnwrap(LiveTVSyncLimitDiagnostic(
            limit: .recordBytes, observed: bytes.count, maximum: LiveTVPortableRecord.maximumBytes
        ))])
    }

    func testOversizedLibraryExportReportsActualEncodedBytesWithoutPublishingAPrefix() throws {
        let title = String(repeating: "x", count: 8_000)
        let items = try (0..<8_400).map { index in
            try LibraryChannelItem(
                item: .init(id: "item-\(index)", title: title, kind: .movie, runtime: 60),
                library: .init(accountID: "account", libraryID: "library"), serverID: "server", userID: "user"
            )
        }
        let snapshot = try LibraryChannelSnapshot(items: items, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let definition = LibraryChannelDefinition(profileID: "profile", revisions: [
            .init(snapshotID: snapshot.id, recipe: .init(
                name: "Movies", libraries: [.init(accountID: "account", libraryID: "library")]
            ), epochSeconds: 1_700_000_000)
        ])
        let recorder = SyncLimitRecorder()
        XCTAssertThrowsError(try LiveTVPortableLibraryExport(definitions: [definition], snapshots: [snapshot])) {
            XCTAssertEqual($0 as? LiveTVPortableStateError, .tooLarge)
        }
        let measured = try XCTUnwrap(recorder.values.first)
        XCTAssertEqual(recorder.values.count, 1)
        XCTAssertEqual(measured.limit, .libraryExportBytes)
        XCTAssertEqual(measured.maximum, 64 * 1_024 * 1_024)
        var expected = 0
        for part in try LiveTVPortableSnapshots.partition(snapshot) {
            expected += try LiveTVPortableRecord(snapshot: part).encoded().count
            if expected > measured.maximum { break }
        }
        XCTAssertEqual(measured.observed, expected)
    }

    func testSuccessfulExportDoesNotInvokeDiagnosticsObservers() throws {
        let snapshot = try makeSnapshot(count: 800)
        let definition = LibraryChannelDefinition(profileID: "profile", revisions: [
            .init(snapshotID: snapshot.id, recipe: .init(
                name: "Movies", libraries: [.init(accountID: "account", libraryID: "library")]
            ), epochSeconds: 1_700_000_000)
        ])
        let recorder = SyncLimitRecorder()
        for _ in 0..<3 {
            let export = try LiveTVPortableLibraryExport(definitions: [definition], snapshots: [snapshot])
            XCTAssertEqual(export.state.snapshots, [snapshot])
        }
        XCTAssertTrue(recorder.values.isEmpty, "Successful serialization must not do diagnostic work per record.")
    }

    func testPartitionedImmutableInputsProduceSameScheduleAndOffset() throws {
        let snapshot = try makeSnapshot(count: 800)
        let parts = try LiveTVPortableSnapshots.partition(snapshot)
        XCTAssertGreaterThan(parts.count, 1)
        for part in parts {
            let record = LiveTVPortableRecord(snapshot: part)
            let key = LiveTVPortableRecordKey(profileID: "profile", kind: .snapshot, entityID: part.entityID)
            let data = try record.encoded()
            XCTAssertLessThanOrEqual(data.count, LiveTVPortableRecord.maximumBytes)
            XCTAssertEqual(try LiveTVPortableRecord.decode(data, key: key), record)
        }

        let received = try LiveTVPortableSnapshots.assemble(parts.reversed())
        XCTAssertEqual(received, snapshot)
        let recipe = LibraryChannelRecipe(
            name: "Movies", libraries: [.init(accountID: "account", libraryID: "library")],
            ordering: .seededShuffle, seed: 54321
        )
        let definition = LibraryChannelDefinition(profileID: "profile", revisions: [
            .init(snapshotID: snapshot.id, recipe: recipe, epochSeconds: 1_700_000_000)
        ], publishedThrough: 1_700_086_400)
        let originalSchedule = try LibraryChannelSchedule(definition: definition, snapshots: [snapshot.id: snapshot])
        let receivedSchedule = try LibraryChannelSchedule(definition: definition, snapshots: [received.id: received])
        for seconds in [1_700_000_001.5, 1_700_003_605.25, 1_800_000_000.0] {
            let now = Date(timeIntervalSince1970: seconds)
            let original = try originalSchedule.slot(at: now)
            let remote = try receivedSchedule.slot(at: now)
            XCTAssertEqual(remote.item, original.item)
            XCTAssertEqual(remote.startSeconds, original.startSeconds)
            XCTAssertEqual(remote.offset(at: now), original.offset(at: now))
        }
    }

    func testMissingDuplicateAndMixedRevisionPartsNeverPublishSnapshot() throws {
        let first = try LiveTVPortableSnapshots.partition(makeSnapshot(count: 800))
        let other = try LiveTVPortableSnapshots.partition(makeSnapshot(count: 800))
        XCTAssertThrowsError(try LiveTVPortableSnapshots.assemble(Array(first.dropLast())))
        XCTAssertThrowsError(try LiveTVPortableSnapshots.assemble([first[0], first[0]]))
        var mixed = first
        mixed[mixed.count - 1] = other.last!
        XCTAssertThrowsError(try LiveTVPortableSnapshots.assemble(mixed))
    }

    func testSameSnapshotIDWithChangedInputsFailsDigestCheck() throws {
        let parts = try LiveTVPortableSnapshots.partition(makeSnapshot(count: 300))
        let data = try JSONEncoder().encode(parts[0])
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var items = try XCTUnwrap(value["items"] as? [[String: Any]])
        items[0]["durationSeconds"] = 999
        value["items"] = items
        let changed = try JSONDecoder().decode(
            LiveTVPortableSnapshotPart.self, from: JSONSerialization.data(withJSONObject: value)
        )
        XCTAssertThrowsError(try LiveTVPortableSnapshots.assemble([changed] + parts.dropFirst()))
    }

    func testLibraryDefinitionCannotCrossProfileAndRejectsExtremeEpochWithoutTrapping() throws {
        let snapshot = try makeSnapshot(count: 1)
        let definition = LibraryChannelDefinition(profileID: "profile", revisions: [
            .init(snapshotID: snapshot.id, recipe: .init(
                name: "Movies", libraries: [.init(accountID: "account", libraryID: "library")]
            ), epochSeconds: Int64.min)
        ])
        let record = LiveTVPortableRecord(library: definition)
        XCTAssertThrowsError(try record.validate(key: .init(
            profileID: "profile", kind: .library, entityID: definition.id.uuidString
        )))
        XCTAssertThrowsError(try record.validate(key: .init(
            profileID: "another", kind: .library, entityID: definition.id.uuidString
        )))
    }

    func testPortableIdentifierFastPathPreservesTheSubstringPolicy() {
        var values = [
            "", "account|server-user_123", "a:b", "a/b", ":://", ":/:/", "://",
            "https://server", "server?token", "server\nuser", "server\ruser",
            "caf\u{e9}", "cafe\u{301}", "user\u{1f600}", "?\u{301}", ":\u{301}//",
            "https://caf\u{e9}", "user\u{200b}?value", "user\u{200b}\nvalue",
            String(repeating: "a", count: 512), String(repeating: "a", count: 513),
            String(repeating: "\u{e9}", count: 256), String(repeating: "\u{e9}", count: 257)
        ]
        for byte in UInt8(0)...127 {
            let character = String(UnicodeScalar(byte))
            values.append("prefix\(character)suffix")
            values.append(":\(character)/")
            values.append(":/\(character)")
        }
        let alphabet = ["a", ":", "/", "?", "\n"]
        for first in alphabet {
            for second in alphabet {
                for third in alphabet {
                    values.append(first + second + third)
                }
            }
        }
        let record = LiveTVPortableRecord(serverEnrollmentSuppressed: true)
        for value in values {
            let expected = !value.isEmpty && value.utf8.count <= 512
                && !value.contains("://") && !value.contains("?") && !value.contains("\n")
            let key = LiveTVPortableRecordKey(
                profileID: "profile", kind: .serverEnrollment, entityID: value
            )
            if expected {
                XCTAssertNoThrow(try record.validate(key: key), value.debugDescription)
            } else {
                XCTAssertThrowsError(try record.validate(key: key), value.debugDescription) {
                    XCTAssertEqual($0 as? LiveTVPortableStateError, .invalidRecord)
                }
            }
        }
    }

    private func makeSnapshot(count: Int) throws -> LibraryChannelSnapshot {
        let items = try (0..<count).map { index in
            try LibraryChannelItem(
                item: MediaItem(id: "item-\(index)", title: "Programme \(index)", kind: .movie, runtime: Double(60 + index)),
                library: .init(accountID: "account", libraryID: "library"), serverID: "server", userID: "user"
            )
        }
        return try LibraryChannelSnapshot(items: items, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}
