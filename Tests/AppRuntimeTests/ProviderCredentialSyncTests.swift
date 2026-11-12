import Foundation
import XCTest
import CoreModels
import CoreSecureStore
import FeatureAuthCore
import ProviderSilo
@testable import AppRuntime

@MainActor
final class ProviderCredentialSyncTests: XCTestCase {
    func testWebDAVCredentialsRestoreForPasswordAnonymousAndBearerAccounts() async throws {
        let authentications: [MediaShareAuthentication] = [
            .password(username: "Viewer", password: "fixture-password"),
            .anonymous, .bearer(token: "fixture-token")
        ]
        for authentication in authentications {
            let suite = "ProviderShareSync.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            func makeStore() throws -> AccountStore {
                let secure = InMemorySecureStore()
                return AccountStore(
                    secureStore: secure, mediaCredentialVault: MediaCredentialVault(secureStore: secure),
                    credentialJournal: try CredentialMutationJournal(
                        store: DurableLocalStateStore(secureStore: InMemorySecureStore())))
            }
            let source = try makeStore()
            let receiver = try makeStore()
            let account = makeAccount(.mediaShare)
            let credential = try MediaShareCredentialEnvelope(transport: .webDAV, authentication: authentication)
            try source.addMediaShare(account, credential: credential, generatedPrivateKey: nil)
            let publisher = ProviderCredentialSync(accounts: source, storage: InMemorySecureStore(),
                defaults: defaults, enabled: { true }, didRestore: {})
            let records = try publisher.capture(fallback: [:])
            var pending = PendingSyncedServersStore(defaults: defaults)
            pending.upsertSynced(SyncedAccountDescriptor(account: account))
            let bridge = ProviderCredentialSync(accounts: receiver, storage: InMemorySecureStore(),
                defaults: defaults, enabled: { true }, didRestore: {})
            bridge.apply(.init(sequence: 1, authority: bridge.snapshotAuthority, records: records))
            await bridge.finishPendingRestoration()
            XCTAssertEqual(try receiver.mediaShareCredential(for: account.id), credential)
        }
    }

    func testServersRestoreInEitherDeliveryOrderAndSurviveRestart() async throws {
        for provider in [ProviderKind.plex, .jellyfin, .emby, .iptv] {
            for credentialsFirst in [true, false] {
                let suite = "ProviderSync.\(UUID())"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let source = AccountStore(secureStore: InMemorySecureStore())
                let account = makeAccount(provider)
                let token = provider == .iptv
                    ? try IPTVCredential(mode: .playlist, address: URL(string: "https://trusted.test/list.m3u")!).encoded()
                    : "test-token"
                try source.add(account, token: token)
                let publisher = ProviderCredentialSync(
                    accounts: source, storage: InMemorySecureStore(), defaults: defaults,
                    enabled: { true }, didRestore: {})
                let records = try publisher.capture(fallback: [:])
                let receiverStorage = InMemorySecureStore()
                let receiver = AccountStore(secureStore: receiverStorage)
                let cache = InMemorySecureStore()
                var restoreCount = 0
                let bridge = ProviderCredentialSync(accounts: receiver, storage: cache, defaults: defaults,
                                                    enabled: { true }, didRestore: { restoreCount += 1 })
                var pending = PendingSyncedServersStore(defaults: defaults)
                if !credentialsFirst { pending.upsertSynced(SyncedAccountDescriptor(account: account)) }
                bridge.apply(.init(sequence: 1, authority: bridge.snapshotAuthority, records: records))
                await bridge.finishPendingRestoration()
                if credentialsFirst {
                    XCTAssertTrue(receiver.loadAccounts().isEmpty)
                    pending.upsertSynced(SyncedAccountDescriptor(account: account))
                    bridge.reconcile()
                    await bridge.finishPendingRestoration()
                }
                XCTAssertEqual(receiver.loadAccounts().map(\.id), [account.id])
                XCTAssertEqual(receiver.token(for: account.id), token)
                bridge.apply(.init(sequence: 2, authority: bridge.snapshotAuthority, records: records))
                await bridge.finishPendingRestoration()
                XCTAssertEqual(restoreCount, 1)
                let restarted = AccountStore(secureStore: receiverStorage)
                XCTAssertEqual(restarted.token(for: account.id), token)
            }
        }
    }

    func testDescriptorCannotRedirectCredentialToAnotherServer() async throws {
        let suite = "ProviderSyncIdentity.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = makeAccount(.jellyfin)
        let record = ProviderCredentialRecord(
            version: 1, sourceDeviceID: "source", account: account,
            token: "test-token", share: nil, silo: nil)
        let receiver = AccountStore(secureStore: InMemorySecureStore())
        let bridge = ProviderCredentialSync(accounts: receiver, storage: InMemorySecureStore(), defaults: defaults,
                                            enabled: { true }, didRestore: {})
        var descriptor = SyncedAccountDescriptor(account: account)
        descriptor.candidateBaseURLs = [URL(string: "https://untrusted.test")!]
        var pending = PendingSyncedServersStore(defaults: defaults)
        pending.upsertSynced(descriptor)
        bridge.apply(.init(sequence: 1, authority: bridge.snapshotAuthority,
                           records: [record.recordName: try JSONEncoder().encode(record)]))
        await bridge.finishPendingRestoration()
        XCTAssertEqual(receiver.loadAccounts().first?.server.baseURL, account.server.baseURL)
    }

    func testOptOutIgnoredServersAndHouseholdRemovalsNeverRestore() async throws {
        for mode in ["disabled", "ignored", "removed", "identity-mismatch"] {
            let suite = "ProviderSyncGate.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let account = makeAccount(.plex)
            var descriptor = SyncedAccountDescriptor(account: account)
            if mode == "identity-mismatch" { descriptor.userID = "another-user" }
            var pending = PendingSyncedServersStore(defaults: defaults)
            pending.upsertSynced(descriptor)
            if mode == "ignored" { pending.ignore(account.id) }
            var removed = RemovedAccountsStore(defaults: defaults)
            if mode == "removed" { removed.markRemoved(account.id, at: 1) }
            let record = ProviderCredentialRecord(version: 1, sourceDeviceID: "source", account: account,
                                                  token: "test-token", share: nil, silo: nil)
            let receiver = AccountStore(secureStore: InMemorySecureStore())
            let bridge = ProviderCredentialSync(accounts: receiver, storage: InMemorySecureStore(), defaults: defaults,
                                                enabled: { mode != "disabled" }, didRestore: {})
            bridge.apply(.init(sequence: 1, authority: bridge.snapshotAuthority,
                               records: [record.recordName: try JSONEncoder().encode(record)]))
            await bridge.finishPendingRestoration()
            XCTAssertTrue(receiver.loadAccounts().isEmpty, mode)
        }
    }

    func testAccountSwitchRetainsLocalLoginButDoesNotPublishItIntoNewCloudAccount() async throws {
        let suite = "ProviderSyncSwitch.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        let account = makeAccount(.plex)
        try accounts.add(account, token: "test-token")
        let bridge = ProviderCredentialSync(accounts: accounts, storage: InMemorySecureStore(), defaults: defaults,
                                            enabled: { true }, didRestore: {})
        XCTAssertEqual(try bridge.capture(fallback: [:]).count, 1)
        let channel = bridge.channel(stateFileURL: URL(fileURLWithPath: "/unused-test-state"))
        await channel.onAccountSwitch()
        XCTAssertTrue(try bridge.capture(fallback: [:]).isEmpty)
        XCTAssertEqual(accounts.token(for: account.id), "test-token")
        bridge.didAuthenticateLocally(accountID: account.id)
        XCTAssertEqual(try bridge.capture(fallback: [:]).count, 1)
    }

    func testRevocationAndCancellationDuringEnrollmentDiscardTheNewSession() async throws {
        for mode in ["revoked", "deleted", "cancelled", "disabled", "removed", "manualSetup"] {
            let suite = "ProviderEnrollmentRace.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var account = makeAccount(.silo)
            account.userID = "user:profile"
            let credential = try JSONDecoder().decode(SiloCredential.self, from: Data("""
                {"loginID":"\(UUID())","accountID":"user","profileID":"profile",
                 "accessToken":"source","refreshToken":"refresh","expiresAt":1000000000}
                """.utf8))
            let record = ProviderCredentialRecord(
                version: 1, sourceDeviceID: "source", account: account,
                token: nil, share: nil, silo: SiloSyncCredential(credential))
            var pending = PendingSyncedServersStore(defaults: defaults)
            pending.upsertSynced(SyncedAccountDescriptor(account: account))
            let receiver = AccountStore(secureStore: InMemorySecureStore())
            let gate = EnrollmentGate()
            let cleanup = CleanupObservation()
            var enabled = true
            let flag = SyncSetupFeatureFlag(defaults: defaults)
            let bridge = ProviderCredentialSync(
                accounts: receiver, storage: InMemorySecureStore(), defaults: defaults,
                enabled: { enabled && flag.allowsAutomaticSync }, didRestore: {},
                enroll: { _, account, deviceID in
                    await gate.pause()
                    return UserSession(server: account.server, userID: account.userID,
                        userName: account.userName, deviceID: deviceID, accessToken: "new-session")
                },
                discard: { _ in await cleanup.record(cancelled: Task.isCancelled) })
            bridge.apply(.init(sequence: 1, authority: bridge.snapshotAuthority,
                records: [record.recordName: try JSONEncoder().encode(record)]))
            await gate.waitUntilStarted()
            XCTAssertTrue(bridge.isRestoringSignIn)
            if mode == "cancelled" { bridge.cancel() }
            if mode == "disabled" { enabled = false }
            if mode == "manualSetup" {
                flag.isManualSetupPending = true
                bridge.cancel()
                XCTAssertTrue(flag.isEnabled, "Manual setup preserves consent")
            }
            if mode == "removed" {
                var removed = RemovedAccountsStore(defaults: defaults)
                removed.markRemoved(account.id, at: 1)
            }
            if mode == "revoked" || mode == "deleted" {
                bridge.apply(.init(sequence: 2, authority: bridge.snapshotAuthority,
                    records: mode == "revoked"
                        ? [record.recordName: try JSONEncoder().encode(record.tombstone)] : [:]))
            }
            await gate.release()
            await cleanup.waitUntilRecorded()
            await bridge.finishPendingRestoration()
            XCTAssertFalse(bridge.isRestoringSignIn)
            XCTAssertTrue(receiver.loadAccounts().isEmpty, mode)
            let cancelled = await cleanup.wasCancelled
            XCTAssertEqual(cancelled, false, "Cleanup must not inherit cancellation: \(mode)")
        }
    }

    func testLastRemovedCredentialPublishesAnExplicitRevocation() throws {
        let suite = "ProviderRevocation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        let account = makeAccount(.plex)
        try accounts.add(account, token: "secret")
        let bridge = ProviderCredentialSync(accounts: accounts, storage: InMemorySecureStore(), defaults: defaults,
            enabled: { true }, didRestore: {})
        let original = try bridge.capture(fallback: [:])
        var removed = RemovedAccountsStore(defaults: defaults)
        removed.markRemoved(account.id, at: 1)
        let captured = try bridge.capture(fallback: original)
        let record = try JSONDecoder().decode(ProviderCredentialRecord.self, from: XCTUnwrap(captured.values.first))
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(record.revoked, true)
        XCTAssertNil(record.token)
    }

    private func makeAccount(_ provider: ProviderKind) -> Account {
        Account(id: "account", server: MediaServer(id: "server", name: "Server",
                baseURL: URL(string: "https://trusted.test")!, provider: provider),
                userID: "user", userName: "Viewer", deviceID: "source")
    }
}

private actor EnrollmentGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func pause() async {
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

private actor CleanupObservation {
    var wasCancelled: Bool?
    private var waiter: CheckedContinuation<Void, Never>?
    func record(cancelled: Bool) {
        wasCancelled = cancelled
        waiter?.resume()
        waiter = nil
    }
    func waitUntilRecorded() async {
        if wasCancelled != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
