import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

final class LiveTVLastSeenStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRowsRoundTripSealedAndOnlyForTheirProfile() async throws {
        let secrets = LastSeenSecrets()
        let store = LiveTVLastSeenStore(profileID: "one", directory: directory, secureStore: secrets)
        let loaded1 = await store.load()
        XCTAssertNil(loaded1)
        await store.save(snapshot())
        let loaded2 = await store.load()
        XCTAssertEqual(loaded2, snapshot())

        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).first)
        let bytes = try Data(contentsOf: file)
        XCTAssertNil(bytes.range(of: Data("Channel".utf8)), "Rows are not stored in the clear")

        // Another profile has its own file and key; handed this one's bytes it reads nothing.
        let other = LiveTVLastSeenStore(profileID: "two", directory: directory, secureStore: secrets)
        let loaded3 = await other.load()
        XCTAssertNil(loaded3)
        await other.save(snapshot())
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let otherFile = try XCTUnwrap(files.first { $0 != file })
        try bytes.write(to: otherFile)
        let loaded4 = await other.load()
        XCTAssertNil(loaded4)
    }

    func testDamagedOrUnkeyedRowsReadAsAbsent() async throws {
        let secrets = LastSeenSecrets()
        let store = LiveTVLastSeenStore(profileID: "one", directory: directory, secureStore: secrets)
        await store.save(snapshot())
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).first)
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: file)
        let loaded5 = await store.load()
        XCTAssertNil(loaded5)

        await store.save(snapshot())
        let loaded6 = await store.load()
        XCTAssertNotNil(loaded6)
        let unkeyed = await LiveTVLastSeenStore(
            profileID: "one", directory: directory, secureStore: LastSeenSecrets()
        ).load()
        XCTAssertNil(unkeyed)
    }

    func testRowsThatCouldCarryAStreamAddressAreNeverSaved() async {
        let store = LiveTVLastSeenStore(profileID: "one", directory: directory, secureStore: LastSeenSecrets())
        await store.save(snapshot())
        let stream = LiveTVPrototypeChannel(
            id: "c", number: 1, name: "Channel", category: "Live TV", symbol: "tv", accent: 0, source: .iptv,
            tagline: "", streamURL: URL(string: "https://example.test/stream?token=secret")
        )
        await store.save(LiveTVLastSeenSnapshot(
            sources: [.init(sourceID: "s", accountID: "a", kind: .iptv, entries: [.init(nativeID: "n", channel: stream)])],
            browse: .init(categories: [], categoryCounts: [:], totalCount: 1)
        ))
        let loaded7 = await store.load()
        XCTAssertNil(loaded7, "An unacceptable save also clears what was there")
    }

    func testErasureRemovesAllLastSeenFilesAndOnlyTheirKeys() async throws {
        let secrets = LastSeenSecrets()
        try secrets.setString("keep", for: "other.catalog.key")
        let first = LiveTVLastSeenStore(profileID: "one", directory: directory, secureStore: secrets)
        let removedProfile = LiveTVLastSeenStore(profileID: "removed", directory: directory, secureStore: secrets)
        await first.save(snapshot())
        await removedProfile.save(snapshot())
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let keys = files.map { "liveTV.lastSeen." + $0.deletingPathExtension().lastPathComponent + ".key" }
        XCTAssertEqual(keys.count, 2)
        for key in keys { XCTAssertNotNil(secrets.string(for: key)) }

        try LiveTVLastSeenStore.erase(profileIDs: ["one"], directory: directory, secureStore: secrets)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let loaded8 = await first.load()
        XCTAssertNil(loaded8)
        let loaded9 = await removedProfile.load()
        XCTAssertNil(loaded9)
        for key in keys { XCTAssertNil(secrets.string(for: key)) }
        XCTAssertEqual(secrets.string(for: "other.catalog.key"), "keep")
        // Erasure remains safe after the cache directory has already disappeared.
        try LiveTVLastSeenStore.erase(profileIDs: ["one"], directory: directory, secureStore: secrets)
    }

    func testErasureRemovesKeyWhenCacheWasEvicted() async throws {
        let secrets = LastSeenSecrets()
        let store = LiveTVLastSeenStore(profileID: "one", directory: directory, secureStore: secrets)
        await store.save(snapshot())
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).first)
        let key = "liveTV.lastSeen." + file.deletingPathExtension().lastPathComponent + ".key"
        try FileManager.default.removeItem(at: directory)
        try LiveTVLastSeenStore.erase(profileIDs: ["one"], directory: directory, secureStore: secrets)
        XCTAssertNil(secrets.string(for: key))
    }

    @MainActor
    func testMainActorCallerRunsKeychainWorkOffMainThread() async {
        let secrets = LastSeenSecrets()
        let store = LiveTVLastSeenStore(profileID: "one", directory: directory, secureStore: secrets)
        let rows = snapshot()
        await store.save(rows)
        let loaded = await store.load()
        XCTAssertEqual(loaded, rows)
        XCTAssertFalse(secrets.usedMainThread)
    }

    func testOverlappingSavesLeaveLastSnapshotOnDisk() async {
        let secrets = LastSeenSecrets()
        let store = LiveTVLastSeenStore(profileID: "one", directory: directory, secureStore: secrets)
        let rows = snapshot()
        await withTaskGroup(of: Void.self) { group in
            for count in 0..<100 {
                let value = LiveTVLastSeenSnapshot(
                    sources: rows.sources,
                    browse: .init(categories: [], categoryCounts: [:], totalCount: count)
                )
                group.addTask { await store.save(value) }
            }
            await group.waitForAll()
            await store.save(rows)
        }
        let reopened = LiveTVLastSeenStore(profileID: "one", directory: directory, secureStore: secrets)
        let loaded = await reopened.load()
        XCTAssertEqual(loaded, rows)
    }

    private func snapshot() -> LiveTVLastSeenSnapshot {
        let channel = LiveTVPrototypeChannel(
            id: "c", number: 1, name: "Channel", category: "News", symbol: "tv", accent: 0, source: .iptv,
            tagline: "", configuredSourceID: "s", groups: ["News"]
        )
        return LiveTVLastSeenSnapshot(
            sources: [.init(sourceID: "s", accountID: "a", kind: .iptv, entries: [.init(nativeID: "n", channel: channel)])],
            browse: .init(categories: ["News"], categoryCounts: ["News": 12], totalCount: 12)
        )
    }
}

private final class LastSeenSecrets: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var didUseMainThread = false
    var usedMainThread: Bool { lock.withLock { didUseMainThread } }
    func setString(_ value: String, for key: String) throws {
        lock.withLock {
            didUseMainThread = didUseMainThread || Thread.isMainThread
            values[key] = value
        }
    }
    func string(for key: String) -> String? { lock.withLock { values[key] } }
    func readString(for key: String) throws -> String? {
        lock.withLock {
            didUseMainThread = didUseMainThread || Thread.isMainThread
            return values[key]
        }
    }
    func removeValue(for key: String) throws { lock.withLock { values[key] = nil } }
}
