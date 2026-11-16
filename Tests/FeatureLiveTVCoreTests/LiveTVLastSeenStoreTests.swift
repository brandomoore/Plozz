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
            sources: [.init(
                sourceID: "s", accountID: "a", kind: .iptv,
                entries: [.init(nativeID: "n", channel: stream)], viewerScopeID: "viewer"
            )],
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

    func testErasureMustUseCatalogSecretsEvenAfterSourceCredentialsAreRemoved() async throws {
        // Stand-ins for the separate sources/catalog Keychain services; no live Keychain access.
        let sourceSecrets = LastSeenSecrets()
        let catalogSecrets = LastSeenSecrets()
        try sourceSecrets.setString("owned-fixture", for: "source.credential")
        try catalogSecrets.setString("keep", for: "unrelated.catalog.key")
        let store = LiveTVLastSeenStore(profileID: "before-reset", directory: directory, secureStore: catalogSecrets)
        await store.save(snapshot())
        let snapshotKeys = catalogSecrets.keys.subtracting(["unrelated.catalog.key"])
        XCTAssertEqual(snapshotKeys.count, 1)

        try sourceSecrets.removeValue(for: "source.credential")
        XCTAssertTrue(sourceSecrets.keys.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        for key in snapshotKeys { XCTAssertNotNil(catalogSecrets.string(for: key)) }
        let beforeErase = await store.load()
        XCTAssertNotNil(beforeErase, "Removing source credentials is not snapshot erasure")

        try LiveTVLastSeenStore.erase(
            profileIDs: ["before-reset"], directory: directory, secureStore: catalogSecrets
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        for key in snapshotKeys { XCTAssertNil(catalogSecrets.string(for: key)) }
        XCTAssertEqual(catalogSecrets.keys, ["unrelated.catalog.key"])
        let afterErase = await store.load()
        XCTAssertNil(afterErase)
    }

    func testMissingEmptyAndLegacyViewerScopesAreNotPersisted() async throws {
        let secrets = LastSeenSecrets()
        let store = LiveTVLastSeenStore(profileID: "one", directory: directory, secureStore: secrets)
        let rows = snapshot()
        for scope: String? in [nil, ""] {
            await store.save(rows)
            let scoped = LiveTVLastSeenSnapshot(sources: [.init(
                sourceID: "s", accountID: "a", kind: .iptv,
                entries: rows.sources[0].entries, viewerScopeID: scope
            )], browse: rows.browse)
            await store.save(scoped)
            let loaded = await store.load()
            XCTAssertNil(loaded)
        }

        // Older Codable payloads genuinely omit the field rather than encoding null.
        let encoded = try JSONEncoder().encode(rows)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var sources = try XCTUnwrap(document["sources"] as? [[String: Any]])
        sources[0].removeValue(forKey: "viewerScopeID")
        document["sources"] = sources
        let legacy = try JSONDecoder().decode(
            LiveTVLastSeenSnapshot.self, from: JSONSerialization.data(withJSONObject: document)
        )
        XCTAssertNil(legacy.sources[0].viewerScopeID)
        await store.save(legacy)
        let loaded = await store.load()
        XCTAssertNil(loaded)
    }

    func testPausedSavesAcrossInstancesCannotResurrectErasedFilesOrCatalogKeys() async throws {
        let secrets = LastSeenSecrets()
        try secrets.setString("keep", for: "other.catalog.key")
        let rows = snapshot()
        let first = LiveTVLastSeenStore(profileID: "one", directory: directory, secureStore: secrets)
        let second = LiveTVLastSeenStore(profileID: "two", directory: directory, secureStore: secrets)
        await first.save(rows)
        await second.save(rows)
        let keys = secrets.keys.filter { $0.hasPrefix("liveTV.lastSeen.") }
        XCTAssertEqual(keys.count, 2)

        let started = expectation(description: "Save admitted before erasure")
        let gate = LastSeenSaveGate(started: started)
        let paused = LiveTVLastSeenStore(
            profileID: "one", directory: directory.appendingPathComponent(".", isDirectory: true),
            secureStore: secrets, beforeSave: { await gate.wait() }
        )
        let inFlight = Task { await paused.save(rows) }
        await fulfillment(of: [started], timeout: 2)
        // This operation is admitted now, but its actor invocation starts only after erase.
        let notYetInvoked = second.prepareSave()
        do {
            try LiveTVLastSeenStore.erase(profileIDs: ["one", "two"], directory: directory, secureStore: secrets)
        } catch {
            await gate.release()
            await inFlight.value
            throw error
        }
        await gate.release()
        await inFlight.value
        await notYetInvoked(rows)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        for key in keys { XCTAssertNil(secrets.string(for: key)) }
        XCTAssertEqual(secrets.keys, ["other.catalog.key"])
        XCTAssertEqual(secrets.string(for: "other.catalog.key"), "keep")
        let erased = await first.load()
        XCTAssertNil(erased)

        // Erasure is a generation boundary, not a permanent ban on these instances.
        await paused.save(rows)
        await second.save(rows)
        let firstLoaded = await first.load()
        let secondLoaded = await second.load()
        XCTAssertEqual(firstLoaded, rows)
        XCTAssertEqual(secondLoaded, rows)
        for key in keys { XCTAssertNotNil(secrets.string(for: key)) }
    }

    func testCancellingASuspendedSaveDoesNotPersistRowsOrCreateAKey() async throws {
        let secrets = LastSeenSecrets()
        let started = expectation(description: "Save suspended before commit")
        let gate = LastSeenSaveGate(started: started)
        let store = LiveTVLastSeenStore(
            profileID: "one", directory: directory, secureStore: secrets, beforeSave: { await gate.wait() }
        )
        let rows = snapshot()
        let save = Task { await store.save(rows) }
        await fulfillment(of: [started], timeout: 2)
        save.cancel()
        await gate.release()
        await save.value
        let loaded = await store.load()
        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(secrets.keys.isEmpty)

        // Cancellation retires this write, not all future writes by this instance.
        await store.save(rows)
        let subsequent = await store.load()
        XCTAssertEqual(subsequent, rows)
        XCTAssertEqual(secrets.keys.count, 1)
    }

    func testPreErasureNilAndInvalidOperationsCannotDeleteANewSnapshot() async throws {
        let secrets = LastSeenSecrets()
        let first = LiveTVLastSeenStore(profileID: "one", directory: directory, secureStore: secrets)
        let otherInstance = LiveTVLastSeenStore(profileID: "one", directory: directory, secureStore: secrets)
        let staleNil = first.prepareSave()
        let staleInvalid = otherInstance.prepareSave()
        try LiveTVLastSeenStore.erase(profileIDs: ["one"], directory: directory, secureStore: secrets)
        let rows = snapshot()
        await first.save(rows)
        let invalid = LiveTVLastSeenSnapshot(sources: [], browse: rows.browse)
        await staleNil(nil)
        await staleInvalid(invalid)
        let loaded = await otherInstance.load()
        XCTAssertEqual(loaded, rows)
    }

    func testErasureDoesNotInvalidateAdmittedSaveInAnotherDirectory() async throws {
        let secrets = LastSeenSecrets()
        let otherDirectory = directory.appendingPathComponent("sibling")
        let erasedDirectory = directory.appendingPathComponent("erased")
        let other = LiveTVLastSeenStore(profileID: "one", directory: otherDirectory, secureStore: secrets)
        let write = other.prepareSave()
        try LiveTVLastSeenStore.erase(profileIDs: [], directory: erasedDirectory, secureStore: secrets)
        let rows = snapshot()
        await write(rows)
        let loaded = await other.load()
        XCTAssertEqual(loaded, rows)
    }

    private func snapshot() -> LiveTVLastSeenSnapshot {
        let channel = LiveTVPrototypeChannel(
            id: "c", number: 1, name: "Channel", category: "News", symbol: "tv", accent: 0, source: .iptv,
            tagline: "", configuredSourceID: "s", groups: ["News"]
        )
        return LiveTVLastSeenSnapshot(
            sources: [.init(
                sourceID: "s", accountID: "a", kind: .iptv,
                entries: [.init(nativeID: "n", channel: channel)], viewerScopeID: "viewer"
            )],
            browse: .init(categories: ["News"], categoryCounts: ["News": 12], totalCount: 12)
        )
    }
}

private actor LastSeenSaveGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(started: XCTestExpectation) { self.started = started }

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class LastSeenSecrets: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var didUseMainThread = false
    var usedMainThread: Bool { lock.withLock { didUseMainThread } }
    var keys: Set<String> { lock.withLock { Set(values.keys) } }
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
