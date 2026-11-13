import Foundation
import XCTest
import CloudKit
import CoreModels
import CoreSecureStore
@testable import FeatureSyncCloud

final class CloudSyncAccountBoundaryTests: XCTestCase {
    private struct Persisted: Encodable { let ledger: SyncLedger }

    @MainActor
    func testCloudCompletionCannotClearFailedCaptureUntilSameChannelRecovers() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("media.json")
        var ledger = SyncLedger()
        _ = ledger.applyFetched(saved: [.init(recordName: "item", value: Data("saved".utf8),
                                              editedAt: 1, systemFields: Data())], deleted: [], now: 1)
        try JSONEncoder().encode(Persisted(ledger: ledger)).write(to: file)
        let calls = AccountCheckCounter()
        let status = CloudSyncStatus()
        status.setPhase(.idle, syncedNow: true)
        let lastSuccess = status.lastSyncedAt
        let service = CloudConfigSyncService(.init(
            containerIdentifier: "iCloud.test", stateFileURL: folder.appendingPathComponent("config.json"),
            isEnabled: { true }, captureRecords: { $0 }, applyRecords: { _ in }, status: status),
            channels: [.init(
                schema: .mediaStateV1, stateFileURL: file, captureRecords: { $0 }, applyRecords: { _ in },
                captureSnapshot: { snapshot in
                    if await calls.next() == 1 { throw CocoaError(.fileReadCorruptFile) }
                    return snapshot.records
                })])
        let admitted = await service.confirmAccountIdentity("account", reverifyIdentity: { "account" })
        XCTAssertTrue(admitted)
        let failed = await service.stageLocalChangesBeforeFetch()
        XCTAssertFalse(failed)
        try await waitForStatus { status.lastErrorReason == .localDataUnavailable }
        status.setPhase(.error)
        await service.setStatus(.idle, syncedNow: true)
        await service.setStatus(.syncing)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(status.phase, .error)
        XCTAssertEqual(status.lastSyncedAt, lastSuccess)
        XCTAssertNotNil(status.lastDiagnostic)
        let recovered = await service.stageLocalChangesBeforeFetch()
        XCTAssertTrue(recovered)
        await service.setStatus(.idle, syncedNow: true)
        try await waitForStatus { status.phase == .idle && status.lastErrorReason == nil }
        XCTAssertNotEqual(status.lastSyncedAt, lastSuccess)
        XCTAssertNil(status.lastDiagnostic)
    }

    @MainActor
    func testPersistentCaptureFailuresPreserveDataAndReportOnlyAfterBoundedAttempts() async throws {
        for cancelledSnapshot in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("media.json")
            var ledger = SyncLedger()
            _ = ledger.applyFetched(saved: [.init(recordName: "item", value: Data("saved".utf8),
                                                  editedAt: 1, systemFields: Data())], deleted: [], now: 1)
            try JSONEncoder().encode(Persisted(ledger: ledger)).write(to: file)
            let calls = AccountCheckCounter()
            let status = CloudSyncStatus()
            let service = CloudConfigSyncService(.init(
                containerIdentifier: "iCloud.test", stateFileURL: folder.appendingPathComponent("config.json"),
                isEnabled: { true }, captureRecords: { $0 }, applyRecords: { _ in }, status: status),
                channels: [.init(
                    schema: .mediaStateV1, stateFileURL: file, captureRecords: { $0 }, applyRecords: { _ in },
                    captureSnapshot: { _ in
                        _ = await calls.next()
                        if cancelledSnapshot { throw CancellationError() }
                        throw CocoaError(.fileReadCorruptFile)
                    })])
            let admitted = await service.confirmAccountIdentity("account", reverifyIdentity: { "account" })
            XCTAssertTrue(admitted)
            let staged = await service.stageLocalChangesBeforeFetch()
            XCTAssertFalse(staged)
            let count = await calls.count
            XCTAssertEqual(count, cancelledSnapshot ? 4 : 1)
            try await waitForStatus { status.lastErrorReason == .localDataUnavailable }
            XCTAssertTrue(status.lastDiagnostic?.contains("Channel capture unavailable") == true)
            let ledgers = try await service.restoredLedgers()
            XCTAssertEqual(ledgers[1].entries["item"]?.localValue, Data("saved".utf8))
            await service.deactivate()
        }
    }

    @MainActor
    func testSupersededOrDisabledPreparationCannotCommitOrReportAStaleFailure() async throws {
        for interrupt in ["supersede", "deactivate", "cancel", "consent", "authority"] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("media.json")
            var ledger = SyncLedger()
            _ = ledger.applyFetched(saved: [.init(recordName: "item", value: Data("old".utf8),
                                                  editedAt: 1, systemFields: Data())], deleted: [], now: 1)
            try JSONEncoder().encode(Persisted(ledger: ledger)).write(to: file)
            let calls = AccountCheckCounter()
            let gate = AdmissionGate()
            let consent = TestAuthority()
            let authority = TestAuthority()
            let status = CloudSyncStatus()
            let service = CloudConfigSyncService(.init(
                containerIdentifier: "iCloud.test", stateFileURL: folder.appendingPathComponent("config.json"),
                isEnabled: { consent.value == "0" }, captureRecords: { $0 }, applyRecords: { _ in }, status: status),
                channels: [.init(
                    schema: .mediaStateV1, stateFileURL: file, captureRecords: { $0 }, applyRecords: { _ in },
                    captureSnapshot: { _ in
                        if await calls.next() == 1 {
                            await gate.pauseFirstReset()
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        return ["item": Data("new".utf8)]
                    }, snapshotAuthority: { authority.value })])
            let admitted = await service.confirmAccountIdentity("account", reverifyIdentity: { "account" })
            XCTAssertTrue(admitted)
            let older = Task { await service.stageLocalChangesBeforeFetch() }
            await gate.waitUntilStarted()
            if interrupt == "supersede" {
                let latest = await service.stageLocalChangesBeforeFetch()
                XCTAssertTrue(latest)
            } else if interrupt == "deactivate" {
                await service.deactivate()
            } else if interrupt == "consent" {
                consent.renew()
            } else if interrupt == "authority" {
                authority.renew()
            } else {
                older.cancel()
            }
            await gate.release()
            let staged = await older.value
            XCTAssertFalse(staged)
            XCTAssertNil(status.lastErrorMessage)
            let ledgers = try await service.restoredLedgers()
            XCTAssertEqual(ledgers[1].entries["item"]?.localValue,
                           Data((interrupt == "supersede" ? "new" : "old").utf8))
        }
    }

    @MainActor
    func testSupersededLocalCaptureRetriesWithoutReportingDataFailure() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("media.json")
        var ledger = SyncLedger()
        _ = ledger.applyFetched(saved: [.init(recordName: "item", value: Data("old".utf8),
                                              editedAt: 1, systemFields: Data())], deleted: [], now: 1)
        try JSONEncoder().encode(Persisted(ledger: ledger)).write(to: file)
        let calls = AccountCheckCounter()
        let status = CloudSyncStatus()
        let service = CloudConfigSyncService(.init(
            containerIdentifier: "iCloud.test", stateFileURL: folder.appendingPathComponent("config.json"),
            isEnabled: { true }, captureRecords: { $0 }, applyRecords: { _ in }, status: status),
            channels: [.init(
                schema: .mediaStateV1, stateFileURL: file, captureRecords: { $0 }, applyRecords: { _ in },
                captureSnapshot: { _ in
                    if await calls.next() == 1 { throw CancellationError() }
                    return ["item": Data("new".utf8)]
                })])
        let admitted = await service.confirmAccountIdentity("account", reverifyIdentity: { "account" })
        XCTAssertTrue(admitted)
        let staged = await service.stageLocalChangesBeforeFetch()
        XCTAssertTrue(staged, "A superseded snapshot must be recaptured, not treated as damaged local data")
        let count = await calls.count
        XCTAssertEqual(count, 2)
        let ledgers = try await service.restoredLedgers()
        XCTAssertEqual(ledgers[1].entries["item"]?.localValue, Data("new".utf8))
        XCTAssertNil(status.lastErrorMessage)
    }

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
        let older = Task { await service.confirmAccountIdentity("B", reverifyIdentity: { "B" }) }
        await gate.waitUntilStarted()
        let latest = await service.confirmAccountIdentity("C", reverifyIdentity: { "C" })
        XCTAssertTrue(latest)
        await gate.release()
        let superseded = await older.value
        XCTAssertFalse(superseded)
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(contentsOf: file.appendingPathExtension("account"))), "C")
        let same = await service.confirmAccountIdentity("C", reverifyIdentity: { "C" })
        XCTAssertTrue(same)
    }

    func testFirstVerifiedIdentityReachesCredentialChannelBeforeCapture() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let calls = AccountCheckCounter()
        let service = CloudConfigSyncService(.init(
            containerIdentifier: "iCloud.test", stateFileURL: folder.appendingPathComponent("config.json"),
            isEnabled: { true }, captureRecords: { $0 }, applyRecords: { _ in }),
            channels: [.init(
                schema: .providerCredentialsV1, stateFileURL: folder.appendingPathComponent("credentials.json"),
                captureRecords: { $0 }, applyRecords: { _ in },
                stateCodec: .init(context: "identity-test", secureStore: InMemorySecureStore()),
                captureSnapshot: { snapshot in
                    XCTAssertEqual(snapshot.cloudAccountID, "A")
                    let count = await calls.count
                    XCTAssertEqual(count, 1)
                    return snapshot.records
                },
                snapshotAuthority: { "authority" },
                onAccountVerified: { identity, authority in
                    XCTAssertEqual(identity, "A")
                    XCTAssertEqual(authority, "authority")
                    _ = await calls.next()
                }, accountVerificationAuthority: { "authority" })])
        let admitted = await service.confirmAccountIdentity("A", reverifyIdentity: { "A" })
        XCTAssertTrue(admitted)
        let staged = await service.stageLocalChangesBeforeFetch()
        XCTAssertTrue(staged)
    }

    func testSupersededVerifiedIdentityCallbackCannotAdmitOldCloudAccount() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = AdmissionGate()
        let authority = TestAuthority()
        let service = CloudConfigSyncService(.init(
            containerIdentifier: "iCloud.test", stateFileURL: folder.appendingPathComponent("config.json"),
            isEnabled: { true }, captureRecords: { $0 }, applyRecords: { _ in }),
            channels: [.init(
                schema: .providerCredentialsV1, stateFileURL: folder.appendingPathComponent("credentials.json"),
                captureRecords: { $0 }, applyRecords: { _ in }, onAccountSwitch: { authority.renew() },
                stateCodec: .init(context: "identity-race-test", secureStore: InMemorySecureStore()),
                captureSnapshot: { snapshot in
                    XCTAssertEqual(snapshot.cloudAccountID, "B")
                    return snapshot.records
                },
                snapshotAuthority: { authority.value },
                onAccountVerified: { identity, expected in
                    if identity == "A" { await gate.pauseFirstReset() }
                    guard authority.value == expected else { throw CancellationError() }
                }, accountVerificationAuthority: { authority.value })])
        let older = Task { await service.confirmAccountIdentity("A", reverifyIdentity: { "A" }) }
        await gate.waitUntilStarted()
        let admitted = await service.confirmAccountIdentity("B", reverifyIdentity: { "B" })
        XCTAssertTrue(admitted)
        await gate.release()
        let superseded = await older.value
        XCTAssertFalse(superseded)
        let staged = await service.stageLocalChangesBeforeFetch()
        XCTAssertTrue(staged)
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
        let admitted = await service.confirmAccountIdentity("B", reverifyIdentity: { "B" })
        XCTAssertTrue(admitted)
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(contentsOf: file.appendingPathExtension("account"))), "B")
        let again = await service.confirmAccountIdentity("B", reverifyIdentity: { "B" })
        XCTAssertTrue(again)
        XCTAssertEqual(authority.value, "1")
    }

    func testVerificationWithdrawalDuringIdentityLookupCannotAdmitCachedAccount() async throws {
        for previous in ["", "B"] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("config.json")
            if !previous.isEmpty {
                try JSONEncoder().encode(previous).write(to: file.appendingPathExtension("account"))
            }
            let gate = AdmissionGate()
            let authority = TestAuthority()
            let service = CloudConfigSyncService(.init(
                containerIdentifier: "iCloud.test", stateFileURL: file,
                isEnabled: { true }, captureRecords: { $0 }, applyRecords: { _ in }),
                channels: [.init(
                    schema: .mediaStateV1, stateFileURL: folder.appendingPathComponent("channel.json"),
                    captureRecords: { $0 }, applyRecords: { _ in }, onAccountSwitch: { authority.renew() },
                    onAccountVerified: { _, expected in
                        guard authority.value == expected else { throw CancellationError() }
                    }, accountVerificationAuthority: { authority.value })])
            let older = Task {
                await service.checkAccountAvailability(accountStatus: { .available }, accountIdentity: {
                    await gate.pauseFirstReset()
                    return "A"
                })
            }
            await gate.waitUntilStarted()
            authority.renew()
            await gate.release()
            let admitted = await older.value
            XCTAssertFalse(admitted, previous)
            XCTAssertEqual(authority.value, "1", "Withdrawn verification must not start an account reset")
            let fresh = await service.checkAccountAvailability(accountStatus: { .available }, accountIdentity: { "A" })
            XCTAssertTrue(fresh, previous)
        }
    }

    func testAccountSwitchRequiresFreshIdentityUnderItsPostResetFence() async throws {
        for mode in ["success", "changed", "withdrawn"] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("config.json")
            try JSONEncoder().encode("A").write(to: file.appendingPathExtension("account"))
            let gate = AdmissionGate()
            let calls = AccountCheckCounter()
            let authority = TestAuthority()
            let service = CloudConfigSyncService(.init(
                containerIdentifier: "iCloud.test", stateFileURL: file,
                isEnabled: { true }, captureRecords: { $0 }, applyRecords: { _ in }),
                channels: [.init(
                    schema: .mediaStateV1, stateFileURL: folder.appendingPathComponent("channel.json"),
                    captureRecords: { $0 }, applyRecords: { _ in }, onAccountSwitch: { authority.renew() },
                    onAccountVerified: { _, expected in
                        guard authority.value == expected else { throw CancellationError() }
                    }, accountVerificationAuthority: { authority.value })])
            let lookup = Task {
                await service.checkAccountAvailability(accountStatus: { .available }, accountIdentity: {
                    guard await calls.next() > 1 else { return "B" }
                    await gate.pauseFirstReset()
                    return mode == "changed" ? "C" : "B"
                })
            }
            await gate.waitUntilStarted()
            XCTAssertEqual(authority.value, "1")
            if mode == "withdrawn" { authority.renew() }
            await gate.release()
            let admitted = await lookup.value
            XCTAssertEqual(admitted, mode == "success", mode)
            let count = await calls.count
            XCTAssertEqual(count, 2)
            XCTAssertEqual(try JSONDecoder().decode(
                String.self, from: Data(contentsOf: file.appendingPathExtension("account"))),
                mode == "success" ? "B" : "A")
        }
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
        let admitted = await service.confirmAccountIdentity("A", reverifyIdentity: { "A" })
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
        let admitted = await service.confirmAccountIdentity("account-B", reverifyIdentity: { "account-B" })
        XCTAssertTrue(admitted)
        let restored = try await service.restoredLedgers()
        XCTAssertTrue(try XCTUnwrap(restored.first).entries.isEmpty)
        let count = await reset.count
        XCTAssertEqual(count, 1)
        let again = await service.confirmAccountIdentity("account-B", reverifyIdentity: { "account-B" })
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
        let admitted = await service.confirmAccountIdentity("account-A", reverifyIdentity: { "account-A" })
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
