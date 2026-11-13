import Foundation
import XCTest
import CloudKit
import CoreModels
@testable import FeatureSyncCloud

final class CloudSyncAccountBoundaryTests: XCTestCase {
    private struct Persisted: Encodable { let ledger: SyncLedger }

    @MainActor
    func testTemporaryAccountFailuresRetryStatusAndIdentityWithoutSkippingAdmission() async throws {
        for failureStage in ["status", "status-error", "identity"] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("config.json")
            let calls = AccountCheckCounter()
            let status = CloudSyncStatus()
            let service = CloudConfigSyncService(.init(
                containerIdentifier: "iCloud.test", stateFileURL: file, isEnabled: { true },
                captureRecords: { $0 }, applyRecords: { _ in }, status: status))
            let available = await service.checkAccountAvailability(
                accountStatus: {
                    let call = await calls.next()
                    if call == 1 && failureStage == "status" { return .temporarilyUnavailable }
                    if call == 1 && failureStage == "status-error" { throw CKError(.accountTemporarilyUnavailable) }
                    return .available
                },
                accountIdentity: {
                    if failureStage == "identity", await calls.count == 1 {
                        throw CKError(.accountTemporarilyUnavailable)
                    }
                    return "verified-account"
                },
                retryDelays: [.zero, .zero])
            XCTAssertTrue(available, failureStage)
            let count = await calls.count
            XCTAssertEqual(count, 2)
            XCTAssertEqual(try JSONDecoder().decode(
                String.self, from: Data(contentsOf: file.appendingPathExtension("account"))), "verified-account")
        }
    }

    @MainActor
    func testTemporaryAccountRetriesAreBoundedAndOtherFailuresAreNotRetried() async throws {
        for code in [CKError.Code.accountTemporarilyUnavailable, .networkFailure, .permissionFailure] {
            let calls = AccountCheckCounter()
            let status = CloudSyncStatus()
            let service = CloudConfigSyncService(.init(
                containerIdentifier: "iCloud.test",
                stateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                isEnabled: { true }, captureRecords: { $0 }, applyRecords: { _ in }, status: status))
            let available = await service.checkAccountAvailability(
                accountStatus: { _ = await calls.next(); throw CKError(code) },
                accountIdentity: { XCTFail("Failed checks must not admit identity"); return "" },
                retryDelays: [.zero, .zero])
            XCTAssertFalse(available)
            let count = await calls.count
            XCTAssertEqual(count, code == .accountTemporarilyUnavailable ? 3 : 1)
            try await waitForStatus { status.lastErrorMessage != nil }
            XCTAssertEqual(status.lastErrorReason, code == .accountTemporarilyUnavailable
                           ? .accountTemporarilyUnavailable : nil)
            XCTAssertNotNil(status.lastDiagnostic)
        }
    }

    @MainActor
    func testRetryWaitRespectsCancellationDeactivationConsentAndNewerChecks() async throws {
        for interruption in ["cancel", "deactivate", "consent", "supersede"] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("config.json")
            let calls = AccountCheckCounter()
            let gate = AdmissionGate()
            let consent = TestAuthority()
            let status = CloudSyncStatus()
            status.setPhase(.idle)
            let service = CloudConfigSyncService(.init(
                containerIdentifier: "iCloud.test", stateFileURL: file,
                isEnabled: { consent.value == "0" },
                captureRecords: { $0 }, applyRecords: { _ in }, status: status))
            let lookup = Task {
                await service.checkAccountAvailability(
                    accountStatus: { _ = await calls.next(); return .temporarilyUnavailable },
                    accountIdentity: { XCTFail("Interrupted retries must not fetch identity"); return "" },
                    retryDelays: [.seconds(15)],
                    waitBeforeRetry: { _ in await gate.pauseFirstReset() })
            }
            await gate.waitUntilStarted()
            switch interruption {
            case "cancel": lookup.cancel()
            case "deactivate":
                await service.deactivate()
                try await waitForStatus { status.phase == .disabled }
            case "consent": consent.renew()
            default:
                let available = await service.checkAccountAvailability(
                    accountStatus: { .noAccount }, accountIdentity: { "" },
                    retryDelays: [.zero],
                    waitBeforeRetry: { _ in XCTFail("Confirmed no-account must not retry") })
                XCTAssertFalse(available)
                try await waitForStatus { status.phase == .signedOut }
            }
            await gate.release()
            let available = await lookup.value
            XCTAssertFalse(available)
            let count = await calls.count
            XCTAssertEqual(count, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("account").path))
            if interruption == "deactivate" { XCTAssertEqual(status.phase, .disabled) }
            if interruption == "supersede" { XCTAssertEqual(status.phase, .signedOut) }
        }
    }

    @MainActor
    func testOnlyConfirmedNoAccountRequestsSignIn() async throws {
        for accountStatus in [CKAccountStatus.noAccount, .restricted, .couldNotDetermine, .temporarilyUnavailable] {
            let status = CloudSyncStatus()
            status.setPhase(.idle)
            let service = CloudConfigSyncService(.init(
                containerIdentifier: "iCloud.test",
                stateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                isEnabled: { true }, captureRecords: { $0 }, applyRecords: { _ in }, status: status))
            let available = await service.checkAccountAvailability(
                accountStatus: { accountStatus },
                accountIdentity: { XCTFail("Unavailable accounts must not fetch an identity"); return "" })
            XCTAssertFalse(available)
            try await waitForStatus { status.phase == .signedOut || status.lastErrorMessage != nil }
            if accountStatus == .noAccount {
                XCTAssertEqual(status.phase, .signedOut)
                XCTAssertNil(status.lastErrorMessage)
            } else {
                XCTAssertNotEqual(status.phase, .signedOut)
                XCTAssertNotNil(status.lastErrorMessage)
                XCTAssertNotNil(status.lastDiagnostic)
            }
        }
    }

    @MainActor
    func testAccountAndIdentityLookupFailuresReportErrorsNotSignOut() async throws {
        for failIdentity in [false, true] {
            let status = CloudSyncStatus()
            status.setPhase(.idle)
            let service = CloudConfigSyncService(.init(
                containerIdentifier: "iCloud.test",
                stateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                isEnabled: { true }, captureRecords: { $0 }, applyRecords: { _ in }, status: status))
            let available = await service.checkAccountAvailability(
                accountStatus: {
                    if !failIdentity { throw CKError(.networkFailure) }
                    return .available
                },
                accountIdentity: { throw CKError(.networkFailure) })
            XCTAssertFalse(available)
            try await waitForStatus { status.lastErrorMessage != nil }
            XCTAssertNotEqual(status.phase, .signedOut)
            XCTAssertNotNil(status.lastDiagnostic)
        }
    }

    @MainActor
    func testUnreadableIdentityMarkerReportsErrorWithoutAdmittingAccount() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        try Data("invalid marker".utf8).write(to: file.appendingPathExtension("account"))
        let status = CloudSyncStatus()
        status.setPhase(.idle)
        let service = CloudConfigSyncService(.init(
            containerIdentifier: "iCloud.test", stateFileURL: file, isEnabled: { true },
            captureRecords: { $0 }, applyRecords: { _ in }, status: status))
        let available = await service.checkAccountAvailability(
            accountStatus: { .available }, accountIdentity: { "A" })
        XCTAssertFalse(available)
        try await waitForStatus { status.lastErrorMessage != nil }
        XCTAssertNotEqual(status.phase, .signedOut)
        XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("account")), Data("invalid marker".utf8))
    }

    @MainActor
    func testCancelledOrDeactivatedLookupCannotOverwriteCurrentStatus() async throws {
        for deactivate in [false, true] {
            let status = CloudSyncStatus()
            status.setPhase(.idle)
            let gate = AdmissionGate()
            let service = CloudConfigSyncService(.init(
                containerIdentifier: "iCloud.test",
                stateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                isEnabled: { true }, captureRecords: { $0 }, applyRecords: { _ in }, status: status))
            let lookup = Task {
                await service.checkAccountAvailability(
                    accountStatus: { await gate.pauseFirstReset(); return .noAccount },
                    accountIdentity: { XCTFail("Stale lookup must not fetch identity"); return "" })
            }
            await gate.waitUntilStarted()
            if deactivate {
                await service.deactivate()
                try await waitForStatus { status.phase == .disabled }
            } else {
                lookup.cancel()
            }
            await gate.release()
            let available = await lookup.value
            XCTAssertFalse(available)
            XCTAssertEqual(status.phase, deactivate ? .disabled : .idle)
            XCTAssertNil(status.lastErrorMessage)
        }
    }

    @MainActor
    func testNewerLookupSupersedesSuspendedIdentityAdmission() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        try JSONEncoder().encode("A").write(to: file.appendingPathExtension("account"))
        let gate = AdmissionGate()
        let status = CloudSyncStatus()
        let service = CloudConfigSyncService(.init(
            containerIdentifier: "iCloud.test", stateFileURL: file, isEnabled: { true },
            captureRecords: { $0 }, applyRecords: { _ in },
            onAccountSwitch: { await gate.pauseFirstReset() }, status: status))
        let older = Task {
            await service.checkAccountAvailability(accountStatus: { .available }, accountIdentity: { "B" })
        }
        await gate.waitUntilStarted()
        let latest = await service.checkAccountAvailability(accountStatus: { .noAccount }, accountIdentity: { "" })
        XCTAssertFalse(latest)
        try await waitForStatus { status.phase == .signedOut }
        await gate.release()
        let superseded = await older.value
        XCTAssertFalse(superseded)
        XCTAssertEqual(status.phase, .signedOut)
        XCTAssertNil(status.lastErrorMessage)
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(contentsOf: file.appendingPathExtension("account"))), "A")
    }

    @MainActor
    private func waitForStatus(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), "The account check must publish its status")
    }

    func testOlderAdmissionCannotOverwriteANewerAccountDuringReset() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        try JSONEncoder().encode("A").write(to: file.appendingPathExtension("account"))
        let gate = AdmissionGate()
        let service = CloudConfigSyncService(.init(
            containerIdentifier: "iCloud.test", stateFileURL: file, isEnabled: { true },
            captureRecords: { $0 }, applyRecords: { _ in },
            onAccountSwitch: { await gate.pauseFirstReset() }))
        let older = Task { await service.confirmAccountIdentity("B") }
        await gate.waitUntilStarted()
        let latest = await service.confirmAccountIdentity("C")
        XCTAssertTrue(latest)
        await gate.release()
        let superseded = await older.value
        XCTAssertFalse(superseded)
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(contentsOf: file.appendingPathExtension("account"))), "C")
        let same = await service.confirmAccountIdentity("C")
        XCTAssertTrue(same)
    }

    func testAccountResetCanChangeChannelAuthorityWithoutRestartLoop() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        try JSONEncoder().encode("A").write(to: file.appendingPathExtension("account"))
        let authority = TestAuthority()
        let service = CloudConfigSyncService(.init(
            containerIdentifier: "iCloud.test", stateFileURL: file, isEnabled: { true },
            captureRecords: { $0 }, applyRecords: { _ in }),
            channels: [.init(
                schema: .mediaStateV1, stateFileURL: folder.appendingPathComponent("watch.json"),
                captureRecords: { $0 }, applyRecords: { _ in },
                onAccountSwitch: { authority.renew() },
                captureSnapshot: { $0.records }, applySnapshot: { _ in },
                snapshotAuthority: { authority.value })])
        let admitted = await service.confirmAccountIdentity("B")
        XCTAssertTrue(admitted)
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(contentsOf: file.appendingPathExtension("account"))), "B")
        let again = await service.confirmAccountIdentity("B")
        XCTAssertTrue(again)
        XCTAssertEqual(authority.value, "1")
    }

    func testStagedOfflineDeletionRemainsInTheDurableSendQueue() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        var ledger = SyncLedger()
        _ = ledger.applyFetched(saved: ["keep", "remove"].map {
            .init(recordName: $0, value: Data($0.utf8), editedAt: 1, systemFields: Data())
        }, deleted: [], now: 1)
        try JSONEncoder().encode(Persisted(ledger: ledger)).write(to: file)
        let service = CloudConfigSyncService(.init(
            containerIdentifier: "iCloud.test", stateFileURL: file, isEnabled: { true },
            captureRecords: { _ in ["keep": Data("keep".utf8)] }, applyRecords: { _ in }))
        let admitted = await service.confirmAccountIdentity("A")
        XCTAssertTrue(admitted)
        let staged = await service.stageLocalChangesBeforeFetch()
        XCTAssertTrue(staged)
        let changes = await service.pendingLedgerChanges()
        XCTAssertTrue(changes.contains {
            if case .deleteRecord(let id) = $0 { return id.recordName == "remove" }
            return false
        })
    }

    func testColdStartAccountChangeResetsOldBaselineBeforeCapture() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        try JSONEncoder().encode("account-A").write(to: file.appendingPathExtension("account"))
        var ledger = SyncLedger()
        _ = ledger.applyFetched(saved: [.init(recordName: "descriptor:old", value: Data("old".utf8),
                                              editedAt: 1, systemFields: Data())], deleted: [], now: 1)
        try JSONEncoder().encode(Persisted(ledger: ledger)).write(to: file)
        let reset = ResetCounter()
        let service = CloudConfigSyncService(.init(
            containerIdentifier: "iCloud.test", stateFileURL: file, isEnabled: { true },
            captureRecords: { $0 }, applyRecords: { _ in },
            onAccountSwitch: { await reset.increment() }))
        let admitted = await service.confirmAccountIdentity("account-B")
        XCTAssertTrue(admitted)
        let restored = try await service.restoredLedgers()
        XCTAssertTrue(try XCTUnwrap(restored.first).entries.isEmpty)
        let count = await reset.count
        XCTAssertEqual(count, 1)
        let again = await service.confirmAccountIdentity("account-B")
        XCTAssertTrue(again)
        let sameCount = await reset.count
        XCTAssertEqual(sameCount, 1)
    }

    func testSameAccountStagesDisabledLocalEditBeforeRemoteApply() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        let key = "profile:one"
        var ledger = SyncLedger()
        _ = ledger.applyFetched(saved: [.init(recordName: key, value: Data("original".utf8),
                                              editedAt: 1, systemFields: Data())], deleted: [], now: 1)
        try JSONEncoder().encode(Persisted(ledger: ledger)).write(to: file)
        let latest = Data("latest-local".utf8)
        let service = CloudConfigSyncService(.init(
            containerIdentifier: "iCloud.test", stateFileURL: file, isEnabled: { true },
            captureRecords: { _ in [key: latest] }, applyRecords: { _ in }))
        let admitted = await service.confirmAccountIdentity("account-A")
        XCTAssertTrue(admitted)
        let staged = await service.stageLocalChangesBeforeFetch()
        XCTAssertTrue(staged)
        let ledgers = try await service.restoredLedgers()
        var restored = try XCTUnwrap(ledgers.first)
        _ = restored.applyFetched(saved: [.init(recordName: key, value: Data("earlier-remote".utf8),
                                                editedAt: 2, systemFields: Data())], deleted: [], now: 3)
        XCTAssertEqual(restored.entries[key]?.localValue, latest)
        XCTAssertTrue(restored.entries[key]?.dirty == true)
    }
}

private actor ResetCounter {
    var count = 0
    func increment() { count += 1 }
}

private actor AccountCheckCounter {
    var count = 0
    func next() -> Int { count += 1; return count }
}

private final class TestAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var revision = 0
    var value: String { lock.withLock { String(revision) } }
    func renew() { lock.withLock { revision += 1 } }
}

private actor AdmissionGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func pauseFirstReset() async {
        guard !started else { return }
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
