import CoreModels
import CoreSecureStore
import Foundation
import XCTest
@testable import FeatureSyncCloud

final class CloudSyncStateCodecTests: XCTestCase {
    func testAuthenticatedEncryptionRejectsTamperingAndMissingKeys() throws {
        let store = CodecTestSecureStore()
        let codec = CloudSyncStateCodec(context: "fixture", secureStore: store)
        let plaintext = Data("https://example.test/playlist?token=fixture-secret".utf8)
        let sealed = try codec.encode(plaintext)
        XCTAssertTrue(CloudSyncStateCodec.isSealed(sealed))
        XCTAssertNil(sealed.range(of: plaintext))
        XCTAssertEqual(try codec.decode(sealed), plaintext)
        var modified = sealed
        modified[modified.endIndex - 1] ^= 1
        XCTAssertThrowsError(try codec.decode(modified))
        XCTAssertThrowsError(try codec.decode(plaintext))
        let missingKey = CloudSyncStateCodec(context: "fixture", secureStore: CodecTestSecureStore())
        XCTAssertThrowsError(try missingKey.decode(sealed))
        XCTAssertThrowsError(try CloudSyncStateCodec(context: "another-channel", secureStore: store).decode(sealed))
    }

    func testCredentialLedgerMigratesWithoutChangingValuesAndFailsClosedWhenLocked() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("credentials.json")
        var expected = SyncLedger()
        _ = expected.reconcileLocal(desired: ["fixture": Data("private-fixture".utf8)], now: 10)
        try JSONEncoder().encode(expected).write(to: file)
        let store = CodecTestSecureStore()
        let codec = CloudSyncStateCodec(context: "fixture", secureStore: store)
        let configuration = CloudConfigSyncService.Configuration(
            containerIdentifier: "iCloud.test", stateFileURL: folder.appendingPathComponent("primary.json"),
            isEnabled: { false }, captureRecords: { $0 }, applyRecords: { _ in }
        )
        let channel = CloudConfigSyncService.ChannelConfiguration(
            schema: .trackerTokensV1, stateFileURL: file,
            captureRecords: { $0 }, applyRecords: { _ in }, stateCodec: codec
        )
        let service = CloudConfigSyncService(configuration, channels: [channel])
        let restored = try await service.restoredLedgers()
        XCTAssertTrue(try XCTUnwrap(restored.last).hasSamePersistedState(as: expected))
        let sealed = try Data(contentsOf: file)
        XCTAssertTrue(CloudSyncStateCodec.isSealed(sealed))
        store.setUnavailable(true)
        let nextService = CloudConfigSyncService(configuration, channels: [channel])
        do {
            _ = try await nextService.restoredLedgers()
            XCTFail("Unreadable encryption keys must never restore an empty credential ledger.")
        } catch {}
        let didRestore = await nextService.hasRestoredLocalState
        XCTAssertFalse(didRestore)
        XCTAssertEqual(try Data(contentsOf: file), sealed)
        store.setUnavailable(false)
        let retried = try await nextService.restoredLedgers()
        XCTAssertTrue(try XCTUnwrap(retried.last).hasSamePersistedState(as: expected))
    }

    func testWrappedCredentialLedgerMigratesAndUnchangedEntriesAreReused() throws {
        struct Legacy: Encodable { let ledger: SyncLedger }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("ledger")
        let codec = CloudSyncStateCodec(context: "fixture", secureStore: CodecTestSecureStore())
        var expected = SyncLedger()
        _ = expected.reconcileLocal(desired: ["one": Data("private-one".utf8), "two": Data("private-two".utf8)], now: 10)
        try JSONEncoder().encode(Legacy(ledger: expected)).write(to: file)
        let restored = try XCTUnwrap(CloudSyncSealedLedger.load(from: file, codec: codec))
        XCTAssertTrue(restored.hasSamePersistedState(as: expected))
        let entries = file.appendingPathExtension("entries")
        let before = try Set(FileManager.default.contentsOfDirectory(atPath: entries.path))
        XCTAssertEqual(before.count, 2)
        try CloudSyncSealedLedger.save(expected, to: file, codec: codec)
        XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: entries.path)), before)
        _ = expected.reconcileLocal(desired: ["one": Data("changed".utf8), "two": Data("private-two".utf8)], now: 20)
        try CloudSyncSealedLedger.save(expected, to: file, codec: codec)
        let after = try Set(FileManager.default.contentsOfDirectory(atPath: entries.path))
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(before.intersection(after).count, 1)
        XCTAssertTrue(try XCTUnwrap(CloudSyncSealedLedger.load(from: file, codec: codec)).hasSamePersistedState(as: expected))
    }

    func testRejectedSaveKeepsCommittedIndexAndLedgerReadable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("ledger")
        let codec = CloudSyncStateCodec(context: "fixture", secureStore: CodecTestSecureStore())
        var ledger = SyncLedger()
        _ = ledger.reconcileLocal(desired: ["one": Data("original".utf8)], now: 10)
        try CloudSyncSealedLedger.save(ledger, to: file, codec: codec)
        let original = ledger
        let index = try Data(contentsOf: file)
        _ = ledger.reconcileLocal(desired: ["one": Data(repeating: 65, count: 4 * 1_024 * 1_024)], now: 20)
        XCTAssertThrowsError(try CloudSyncSealedLedger.save(ledger, to: file, codec: codec))
        XCTAssertEqual(try Data(contentsOf: file), index)
        XCTAssertTrue(try XCTUnwrap(CloudSyncSealedLedger.load(from: file, codec: codec)).hasSamePersistedState(as: original))
    }

    func testMissingAndCorruptEntriesFailClosed() throws {
        for remove in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("ledger")
            let codec = CloudSyncStateCodec(context: "fixture", secureStore: CodecTestSecureStore())
            var ledger = SyncLedger()
            _ = ledger.reconcileLocal(desired: ["one": Data("original".utf8)], now: 10)
            try CloudSyncSealedLedger.save(ledger, to: file, codec: codec)
            let entry = try XCTUnwrap(FileManager.default.contentsOfDirectory(
                at: file.appendingPathExtension("entries"), includingPropertiesForKeys: nil
            ).first)
            if remove { try FileManager.default.removeItem(at: entry) }
            else { try Data("corrupt".utf8).write(to: entry) }
            XCTAssertThrowsError(try CloudSyncSealedLedger.load(from: file, codec: codec))
        }
    }

    func testFailedEncryptedChannelSaveDoesNotCommitPrimaryCursorAndCanRetry() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let primary = folder.appendingPathComponent("primary.json")
        let protected = folder.appendingPathComponent("protected")
        let store = CodecTestSecureStore()
        let codec = CloudSyncStateCodec(context: "fixture", secureStore: store)
        let service = CloudConfigSyncService(.init(
            containerIdentifier: "iCloud.test", stateFileURL: primary,
            isEnabled: { false }, captureRecords: { $0 }, applyRecords: { _ in }
        ), channels: [.init(
            schema: .liveTVSourcesV1, stateFileURL: protected,
            captureRecords: { $0 }, applyRecords: { _ in }, stateCodec: codec
        )])
        _ = try await service.restoredLedgers()
        store.setUnavailable(true)
        let failed = await service.persist()
        XCTAssertFalse(failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: primary.path),
                       "The engine cursor must not commit ahead of an unavailable channel.")
        store.setUnavailable(false)
        let retried = await service.persist()
        XCTAssertTrue(retried)
        XCTAssertTrue(FileManager.default.fileExists(atPath: primary.path))
        XCTAssertTrue(CloudSyncStateCodec.isSealed(try Data(contentsOf: protected)))
    }

    func testSourceLedgerCannotRestoreUnderADifferentAccountEpoch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("ledger")
        let codec = CloudSyncStateCodec(context: "fixture", secureStore: CodecTestSecureStore())
        var ledger = SyncLedger()
        _ = ledger.reconcileLocal(desired: ["one": Data("previous-account-source".utf8)], now: 10)
        try CloudSyncSealedLedger.save(ledger, to: file, codec: codec, authority: "first-account")
        XCTAssertNotNil(try CloudSyncSealedLedger.load(from: file, codec: codec, authority: "first-account"))
        XCTAssertNil(try CloudSyncSealedLedger.load(from: file, codec: codec, authority: "second-account"))
        XCTAssertNil(try CloudSyncSealedLedger.load(from: file, codec: codec))
        XCTAssertNotNil(try CloudSyncSealedLedger.load(from: file, codec: codec, authority: "first-account"),
                        "An ownership mismatch must not mutate the old encrypted index.")
    }

    func testAccountChangeClearsLiveLedgerAndOldFilesCannotReplayAfterFailedWrite() async throws {
        for failWrite in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("ledger")
            let store = CodecTestSecureStore()
            let codec = CloudSyncStateCodec(context: "fixture", secureStore: store)
            let epoch = CodecTestEpoch()
            var ledger = SyncLedger()
            _ = ledger.reconcileLocal(desired: ["one": Data("previous-account-source".utf8)], now: 10)
            try CloudSyncSealedLedger.save(ledger, to: file, codec: codec, authority: epoch.value)
            let config = CloudConfigSyncService.Configuration(
                containerIdentifier: "iCloud.test", stateFileURL: folder.appendingPathComponent("primary.json"),
                isEnabled: { false }, captureRecords: { $0 }, applyRecords: { _ in }
            )
            let channel = CloudConfigSyncService.ChannelConfiguration(
                schema: .liveTVSourcesV1, stateFileURL: file, captureRecords: { $0 }, applyRecords: { _ in },
                stateCodec: codec, captureSnapshot: { $0.records }, snapshotAuthority: { epoch.value }
            )
            let service = CloudConfigSyncService(config, channels: [channel])
            let before = try await service.restoredLedgers()
            XCTAssertEqual(before.last?.count, 1)
            epoch.set("second")
            store.setUnavailable(failWrite)
            let result = await service.persist()
            XCTAssertFalse(result, "An old-account operation must stop at the ownership change.")
            store.setUnavailable(false)
            let restarted = CloudConfigSyncService(config, channels: [channel])
            let restored = try await restarted.restoredLedgers()
            XCTAssertEqual(restored.last?.count, 0)
        }
    }
}

private final class CodecTestEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = "first"
    var value: String { lock.withLock { stored } }
    func set(_ value: String) { lock.withLock { stored = value } }
}

private final class CodecTestSecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var unavailable = false

    func setUnavailable(_ value: Bool) { lock.withLock { unavailable = value } }
    func setString(_ value: String, for key: String) throws { lock.withLock { values[key] = value } }
    func insertStringIfAbsent(_ value: String, for key: String) throws -> Bool {
        lock.withLock {
            guard values[key] == nil else { return false }
            values[key] = value
            return true
        }
    }
    func readString(for key: String) throws -> String? {
        try lock.withLock {
            if unavailable { throw CocoaError(.fileReadNoPermission) }
            return values[key]
        }
    }
    func string(for key: String) -> String? { lock.withLock { values[key] } }
    func removeValue(for key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}
