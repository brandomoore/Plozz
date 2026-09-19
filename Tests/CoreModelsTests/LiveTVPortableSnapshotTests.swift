import Foundation
import XCTest
@testable import CoreModels

final class LiveTVPortableSnapshotTests: XCTestCase {
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
