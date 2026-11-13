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
                ownership: InMemorySecureStore(),
                defaults: defaults, enabled: { true }, didRestore: {})
            try publisher.accountVerified("A", authority: publisher.snapshotAuthority)
            publisher.didAuthenticateLocally(accountID: account.id)
            let records = try publisher.capture(fallback: [:])
            var pending = PendingSyncedServersStore(defaults: defaults)
            pending.upsertSynced(SyncedAccountDescriptor(account: account))
            let bridge = ProviderCredentialSync(accounts: receiver, storage: InMemorySecureStore(),
                ownership: InMemorySecureStore(),
                defaults: defaults, enabled: { true }, didRestore: {})
            try bridge.accountVerified("A", authority: bridge.snapshotAuthority)
            bridge.apply(.init(sequence: 1, authority: bridge.snapshotAuthority, records: records, cloudAccountID: "A"))
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
                    accounts: source, storage: InMemorySecureStore(), ownership: InMemorySecureStore(), defaults: defaults,
                    enabled: { true }, didRestore: {})
                try publisher.accountVerified("A", authority: publisher.snapshotAuthority)
                publisher.didAuthenticateLocally(accountID: account.id)
                let records = try publisher.capture(fallback: [:])
                let receiverStorage = InMemorySecureStore()
                let receiver = AccountStore(secureStore: receiverStorage)
                let cache = InMemorySecureStore()
                var restoreCount = 0
                var progressCount = 0
                let bridge = ProviderCredentialSync(accounts: receiver, storage: cache,
                                                    ownership: InMemorySecureStore(), defaults: defaults,
                                                    enabled: { true }, didRestore: { restoreCount += 1 },
                                                    onProgress: { progressCount += 1 })
                var pending = PendingSyncedServersStore(defaults: defaults)
                if !credentialsFirst { pending.upsertSynced(SyncedAccountDescriptor(account: account)) }
                try bridge.accountVerified("A", authority: bridge.snapshotAuthority)
                bridge.apply(.init(sequence: 1, authority: bridge.snapshotAuthority, records: records, cloudAccountID: "A"))
                await bridge.finishPendingRestoration()
                if credentialsFirst {
                    XCTAssertTrue(receiver.loadAccounts().isEmpty)
                    XCTAssertEqual(progressCount, 0, "No candidate means no invented progress")
                    pending.upsertSynced(SyncedAccountDescriptor(account: account))
                    bridge.reconcile()
                    await bridge.finishPendingRestoration()
                }
                XCTAssertEqual(receiver.loadAccounts().map(\.id), [account.id])
                XCTAssertEqual(receiver.token(for: account.id), token)
                bridge.apply(.init(sequence: 2, authority: bridge.snapshotAuthority, records: records, cloudAccountID: "A"))
                await bridge.finishPendingRestoration()
                XCTAssertEqual(restoreCount, 1)
                XCTAssertEqual(progressCount, 2, "Only actual attempt start/completion count, not duplicate snapshots")
                let restarted = AccountStore(secureStore: receiverStorage)
                XCTAssertEqual(restarted.token(for: account.id), token)
                XCTAssertTrue(bridge.mayPublish(accountID: account.id))
                XCTAssertNil(bridge.publicationPermission)
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
        let bridge = ProviderCredentialSync(accounts: receiver, storage: InMemorySecureStore(),
                                            ownership: InMemorySecureStore(), defaults: defaults,
                                            enabled: { true }, didRestore: {})
        var descriptor = SyncedAccountDescriptor(account: account)
        descriptor.candidateBaseURLs = [URL(string: "https://untrusted.test")!]
        var pending = PendingSyncedServersStore(defaults: defaults)
        pending.upsertSynced(descriptor)
        try bridge.accountVerified("A", authority: bridge.snapshotAuthority)
        bridge.apply(.init(sequence: 1, authority: bridge.snapshotAuthority,
                           records: [record.recordName: try JSONEncoder().encode(record)], cloudAccountID: "A"))
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
            let bridge = ProviderCredentialSync(accounts: receiver, storage: InMemorySecureStore(),
                                                ownership: InMemorySecureStore(), defaults: defaults,
                                                enabled: { mode != "disabled" }, didRestore: {})
            if mode != "disabled" { try bridge.accountVerified("A", authority: bridge.snapshotAuthority) }
            bridge.apply(.init(sequence: 1, authority: bridge.snapshotAuthority,
                               records: [record.recordName: try JSONEncoder().encode(record)], cloudAccountID: "A"))
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
        let bridge = ProviderCredentialSync(accounts: accounts, storage: InMemorySecureStore(),
                                            ownership: InMemorySecureStore(), defaults: defaults,
                                            enabled: { true }, didRestore: {})
        try bridge.accountVerified("A", authority: bridge.snapshotAuthority)
        bridge.didAuthenticateLocally(accountID: account.id)
        XCTAssertEqual(try bridge.capture(fallback: [:]).count, 1)
        let channel = bridge.channel(stateFileURL: URL(fileURLWithPath: "/unused-test-state"))
        await channel.onAccountSwitch()
        try bridge.accountVerified("B", authority: bridge.snapshotAuthority)
        XCTAssertTrue(try bridge.capture(fallback: [:]).isEmpty)
        XCTAssertNil(bridge.publicationPermission, "A known foreign owner cannot be claimed through migration consent")
        XCTAssertEqual(accounts.token(for: account.id), "test-token")
        bridge.didAuthenticateLocally(accountID: account.id)
        XCTAssertEqual(try bridge.capture(fallback: [:]).count, 1)
    }

    func testRevocationAndCancellationDuringEnrollmentDiscardTheNewSession() async throws {
        for mode in ["revoked", "deleted", "cancelled", "disabled", "removed", "manualSetup", "ownershipFailure"] {
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
            var progressCount = 0
            let ownership: any SecureStore = mode == "ownershipFailure"
                ? UnavailableOwnershipStore(failRead: false) : InMemorySecureStore()
            let bridge = ProviderCredentialSync(
                accounts: receiver, storage: InMemorySecureStore(), ownership: ownership, defaults: defaults,
                enabled: { enabled && flag.allowsAutomaticSync }, didRestore: {},
                onProgress: { progressCount += 1 },
                enroll: { _, account, deviceID in
                    await gate.pause()
                    var enrolled = credential
                    enrolled.accessToken = "new-session"
                    return UserSession(server: account.server, userID: account.userID,
                        userName: account.userName, deviceID: deviceID, accessToken: try enrolled.encoded())
                },
                discard: { _ in await cleanup.record(cancelled: Task.isCancelled) })
            try bridge.accountVerified("A", authority: bridge.snapshotAuthority)
            bridge.apply(.init(sequence: 1, authority: bridge.snapshotAuthority,
                records: [record.recordName: try JSONEncoder().encode(record)], cloudAccountID: "A"))
            await gate.waitUntilStarted()
            XCTAssertTrue(bridge.isRestoringSignIn)
            XCTAssertEqual(progressCount, 1)
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
                        ? [record.recordName: try JSONEncoder().encode(record.tombstone)] : [:], cloudAccountID: "A"))
            }
            await gate.release()
            await cleanup.waitUntilRecorded()
            await bridge.finishPendingRestoration()
            XCTAssertFalse(bridge.isRestoringSignIn)
            if mode == "cancelled" || mode == "manualSetup" || mode == "disabled" {
                XCTAssertEqual(progressCount, 1, "Late cancelled work must not announce new progress")
            }
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
        let bridge = ProviderCredentialSync(accounts: accounts, storage: InMemorySecureStore(),
            ownership: InMemorySecureStore(), defaults: defaults,
            enabled: { true }, didRestore: {})
        try bridge.accountVerified("A", authority: bridge.snapshotAuthority)
        bridge.didAuthenticateLocally(accountID: account.id)
        let original = try bridge.capture(fallback: [:])
        var removed = RemovedAccountsStore(defaults: defaults)
        removed.markRemoved(account.id, at: 1)
        let captured = try bridge.capture(fallback: original)
        let record = try JSONDecoder().decode(ProviderCredentialRecord.self, from: XCTUnwrap(captured.values.first))
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(record.revoked, true)
        XCTAssertNil(record.token)
    }

    func testFreshSystemUserCannotExportHouseholdCredentialsAndOwnerSurvivesRestart() throws {
        let suiteA = "ProviderOwnerA.\(UUID())"
        let suiteB = "ProviderOwnerB.\(UUID())"
        let defaultsA = try XCTUnwrap(UserDefaults(suiteName: suiteA))
        let defaultsB = try XCTUnwrap(UserDefaults(suiteName: suiteB))
        defer {
            defaultsA.removePersistentDomain(forName: suiteA)
            defaultsB.removePersistentDomain(forName: suiteB)
        }
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        let account = makeAccount(.jellyfin)
        try accounts.add(account, token: "original")
        let ownership = InMemorySecureStore()
        let owner = ProviderCredentialSync(
            accounts: accounts, storage: InMemorySecureStore(), ownership: ownership,
            defaults: defaultsA, enabled: { true }, didRestore: {})
        try owner.accountVerified("A", authority: owner.snapshotAuthority)
        owner.didAuthenticateLocally(accountID: account.id)
        XCTAssertEqual(try owner.capture(fallback: [:]).count, 1)

        // No previous identity marker or account-switch notification exists for B.
        let otherUser = ProviderCredentialSync(
            accounts: accounts, storage: InMemorySecureStore(), ownership: ownership,
            defaults: defaultsB, enabled: { true }, didRestore: {})
        try otherUser.accountVerified("B", authority: otherUser.snapshotAuthority)
        XCTAssertTrue(try otherUser.capture(fallback: [:]).isEmpty)
        XCTAssertFalse(otherUser.mayPublish(accountID: account.id))
        XCTAssertNil(otherUser.publicationPermission)
        XCTAssertEqual(accounts.token(for: account.id), "original")

        try accounts.add(account, token: "refreshed")
        XCTAssertNotEqual(accounts.loadAccounts().first?.credentialRevision, account.credentialRevision)
        XCTAssertFalse(owner.mayPublish(accountID: account.id), "A replacement is not an automatic refresh")
        owner.didAuthenticateLocally(accountID: account.id)
        let restarted = ProviderCredentialSync(
            accounts: accounts, storage: InMemorySecureStore(), ownership: ownership,
            defaults: defaultsA, enabled: { true }, didRestore: {})
        try restarted.accountVerified("A", authority: restarted.snapshotAuthority)
        let captured = try restarted.capture(fallback: [:])
        let record = try JSONDecoder().decode(ProviderCredentialRecord.self, from: XCTUnwrap(captured.values.first))
        XCTAssertEqual(record.token, "refreshed")
        XCTAssertTrue(try otherUser.capture(fallback: [:]).isEmpty)
        XCTAssertNil(restarted.publicationPermission)
    }

    func testUnownedMigrationRequiresPermissionAndRemembersBothChoices() throws {
        for allow in [true, false] {
            let suite = "ProviderMigration.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let accounts = AccountStore(secureStore: InMemorySecureStore())
            let account = makeAccount(.plex)
            try accounts.add(account, token: "local")
            let cache = InMemorySecureStore()
            let ownership = InMemorySecureStore()
            let bridge = ProviderCredentialSync(
                accounts: accounts, storage: cache, ownership: ownership, defaults: defaults,
                enabled: { true }, didRestore: {})
            try bridge.accountVerified("A", authority: bridge.snapshotAuthority)
            XCTAssertTrue(try bridge.capture(fallback: [:]).isEmpty)
            let request = try XCTUnwrap(bridge.publicationPermission)
            XCTAssertEqual(request.accounts.map(\.id), [account.id])
            XCTAssertTrue(bridge.resolvePublicationPermission(request, allow: allow))
            XCTAssertFalse(bridge.resolvePublicationPermission(request, allow: true), "Consent is single-use")
            let restarted = ProviderCredentialSync(
                accounts: accounts, storage: cache, ownership: ownership, defaults: defaults,
                enabled: { true }, didRestore: {})
            try restarted.accountVerified("A", authority: restarted.snapshotAuthority)
            XCTAssertNil(restarted.publicationPermission)
            XCTAssertEqual(try restarted.capture(fallback: [:]).count, allow ? 1 : 0)
            XCTAssertEqual(accounts.token(for: account.id), "local", "Declining must preserve local playback")
        }
    }

    func testMigrationConsentSurvivesServerMetadataRefreshAndRemembersTheDisplayedChoice() throws {
        for allow in [true, false] {
            let suite = "ProviderMigrationMetadata.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let accounts = AccountStore(secureStore: InMemorySecureStore())
            let account = makeAccount(.jellyfin)
            try accounts.add(account, token: "local")
            let bridge = ProviderCredentialSync(
                accounts: accounts, storage: InMemorySecureStore(), ownership: InMemorySecureStore(),
                defaults: defaults, enabled: { true }, didRestore: {})
            try bridge.accountVerified("A", authority: bridge.snapshotAuthority)
            let displayed = try XCTUnwrap(bridge.publicationPermission)

            var server = account.server
            server.name = "Refreshed server name"
            server.version = "10.11.0"
            try accounts.updateServerMetadata(expected: account, server: server)
            XCTAssertTrue(try bridge.capture(fallback: [:]).isEmpty)

            XCTAssertEqual(bridge.publicationPermission, displayed,
                           "Background metadata discovery must not replace the visible consent request")
            XCTAssertTrue(bridge.resolvePublicationPermission(displayed, allow: allow))
            XCTAssertNil(bridge.publicationPermission)
            bridge.cancel()
            try bridge.accountVerified("A", authority: bridge.snapshotAuthority)
            XCTAssertNil(bridge.publicationPermission, "Reverification must not ask about the same sign-in again")
            XCTAssertEqual(try bridge.capture(fallback: [:]).count, allow ? 1 : 0)
        }
    }

    func testMigrationConsentCannotAuthorizeChangedCredentialsOrAnotherAccount() async throws {
        for interruption in ["account", "credential", "disabled", "parental", "removed"] {
            let suite = "ProviderMigrationRace.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let accounts = AccountStore(secureStore: InMemorySecureStore())
            let account = makeAccount(.plex)
            try accounts.add(account, token: "original")
            var enabled = true
            var authorized = true
            let bridge = ProviderCredentialSync(
                accounts: accounts, storage: InMemorySecureStore(), ownership: InMemorySecureStore(),
                defaults: defaults, enabled: { enabled }, canRestore: { authorized }, didRestore: {})
            try bridge.accountVerified("A", authority: bridge.snapshotAuthority)
            let request = try XCTUnwrap(bridge.publicationPermission)
            switch interruption {
            case "account":
                let oldAuthority = bridge.snapshotAuthority
                await bridge.channel(stateFileURL: URL(fileURLWithPath: "/unused")).onAccountSwitch()
                try bridge.accountVerified("B", authority: bridge.snapshotAuthority)
                XCTAssertThrowsError(try bridge.accountVerified("A", authority: oldAuthority))
            case "credential": try accounts.add(account, token: "replacement")
            case "disabled": enabled = false
            case "parental": authorized = false
            default: try accounts.remove(id: account.id)
            }
            _ = bridge.resolvePublicationPermission(request, allow: true)
            XCTAssertFalse(bridge.mayPublish(accountID: account.id), interruption)
        }
    }

    func testUnverifiedLocalAuthenticationDoesNotGrantFutureCloudAccountOwnership() throws {
        let suite = "ProviderUnverified.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        let account = makeAccount(.plex)
        try accounts.add(account, token: "local")
        let bridge = ProviderCredentialSync(
            accounts: accounts, storage: InMemorySecureStore(), ownership: InMemorySecureStore(),
            defaults: defaults, enabled: { true }, didRestore: {})
        try bridge.accountVerified("A", authority: bridge.snapshotAuthority)
        bridge.didAuthenticateLocally(accountID: account.id)
        bridge.cancel()
        try accounts.add(account, token: "another-users-replacement")
        bridge.didAuthenticateLocally(accountID: account.id)
        XCTAssertThrowsError(try bridge.capture(fallback: [:]))
        try bridge.accountVerified("B", authority: bridge.snapshotAuthority)
        XCTAssertTrue(try bridge.capture(fallback: [:]).isEmpty)
        XCTAssertNotNil(bridge.publicationPermission)
        XCTAssertFalse(bridge.mayPublish(accountID: account.id))
    }

    func testAutomaticSiloTokenRotationRetainsTheAuthenticatedLoginOwner() throws {
        let suite = "ProviderOwnerRefresh.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        let account = makeAccount(.silo)
        var credential = try JSONDecoder().decode(SiloCredential.self, from: Data("""
            {"loginID":"\(UUID())","accountID":"user","profileID":"profile",
             "accessToken":"original","refreshToken":"refresh","expiresAt":1000000000}
            """.utf8))
        let original = try credential.encoded()
        try accounts.add(account, token: original)
        let bridge = ProviderCredentialSync(
            accounts: accounts, storage: InMemorySecureStore(), ownership: InMemorySecureStore(),
            defaults: defaults, enabled: { true }, didRestore: {})
        try bridge.accountVerified("A", authority: bridge.snapshotAuthority)
        bridge.didAuthenticateLocally(accountID: account.id)
        credential.accessToken = "rotated"
        try accounts.rotateCredential(accountID: account.id, revision: account.credentialRevision,
                                      expected: original, replacement: credential.encoded())
        XCTAssertTrue(bridge.mayPublish(accountID: account.id))
        let records = try bridge.capture(fallback: [:])
        let record = try JSONDecoder().decode(ProviderCredentialRecord.self, from: XCTUnwrap(records.values.first))
        XCTAssertEqual(record.silo?.accessToken, "rotated")
        XCTAssertNil(bridge.publicationPermission)
    }

    func testPartialCredentialReplacementCannotReuseOldOwnerEvenWhenMetadataSaveFails() throws {
        let suite = "ProviderOwnerPartialWrite.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accountStorage = PublicationFailureStore()
        let accounts = AccountStore(secureStore: accountStorage)
        let account = makeAccount(.plex)
        try accounts.add(account, token: "original")
        let ownership = PublicationFailureStore()
        let bridge = ProviderCredentialSync(
            accounts: accounts, storage: InMemorySecureStore(), ownership: ownership,
            defaults: defaults, enabled: { true }, didRestore: {})
        try bridge.accountVerified("A", authority: bridge.snapshotAuthority)
        bridge.didAuthenticateLocally(accountID: account.id)
        accountStorage.failWrites(to: "com.plozz.accounts.v2")
        XCTAssertThrowsError(try accounts.replaceAuthenticatedSession(
            account.session(token: "replacement"), expected: account))
        XCTAssertEqual(accounts.loadAccounts().first?.credentialRevision, account.credentialRevision)
        XCTAssertEqual(accounts.token(for: account.id), "replacement")
        XCTAssertFalse(bridge.mayPublish(accountID: account.id))
        XCTAssertTrue(try bridge.capture(fallback: [:]).isEmpty)

        ownership.failWrites(to: nil)
        bridge.cancel()
        bridge.didAuthenticateLocally(accountID: account.id)
        try bridge.accountVerified("A", authority: bridge.snapshotAuthority)
        XCTAssertFalse(bridge.mayPublish(accountID: account.id), "Failed owner invalidation must not grant export")
        XCTAssertTrue(try bridge.capture(fallback: [:]).isEmpty)
    }

    func testUnavailableOwnershipStorageNeverFallsBackToMigrationOrSuccessfulConsent() throws {
        for failRead in [true, false] {
            let suite = "ProviderOwnershipFailure.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let accounts = AccountStore(secureStore: InMemorySecureStore())
            let account = makeAccount(.plex)
            try accounts.add(account, token: "local")
            let bridge = ProviderCredentialSync(
                accounts: accounts, storage: InMemorySecureStore(),
                ownership: UnavailableOwnershipStore(failRead: failRead),
                defaults: defaults, enabled: { true }, didRestore: {})
            if failRead {
                XCTAssertThrowsError(try bridge.accountVerified("A", authority: bridge.snapshotAuthority))
                XCTAssertNil(bridge.publicationPermission)
                XCTAssertThrowsError(try bridge.capture(fallback: [:]))
            } else {
                try bridge.accountVerified("A", authority: bridge.snapshotAuthority)
                let request = try XCTUnwrap(bridge.publicationPermission)
                XCTAssertFalse(bridge.resolvePublicationPermission(request, allow: true))
                XCTAssertNotNil(bridge.publicationPermission)
                XCTAssertTrue(try bridge.capture(fallback: [:]).isEmpty)
            }
            XCTAssertFalse(bridge.mayPublish(accountID: account.id))
            XCTAssertEqual(accounts.token(for: account.id), "local")
        }
    }

    func testWithdrawnAdmissionCannotBeReopenedByCachedSnapshotsOrOldVerification() async throws {
        let suite = "ProviderAdmissionWithdrawal.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        let account = makeAccount(.plex)
        try accounts.add(account, token: "local")
        let bridge = ProviderCredentialSync(
            accounts: accounts, storage: InMemorySecureStore(), ownership: InMemorySecureStore(),
            defaults: defaults, enabled: { true }, didRestore: {})
        let channel = bridge.channel(stateFileURL: URL(fileURLWithPath: "/unused"))
        let oldVerification = channel.accountVerificationAuthority()
        try await channel.onAccountVerified("A", oldVerification)
        bridge.didAuthenticateLocally(accountID: account.id)
        let snapshot = SyncChannelSnapshot(
            sequence: 1, authority: bridge.snapshotAuthority, records: [:], cloudAccountID: "A")
        bridge.cancel()
        bridge.apply(snapshot)
        XCTAssertFalse(bridge.isReadyForManualSetup)
        let capture = try XCTUnwrap(channel.captureSnapshot)
        do {
            _ = try await capture(snapshot)
            XCTFail("An old capture cannot verify an account")
        } catch is CancellationError {}
        do {
            try await channel.onAccountVerified("A", oldVerification)
            XCTFail("A verification started before withdrawal cannot reopen admission")
        } catch is CancellationError {}
        XCTAssertFalse(bridge.mayPublish(accountID: account.id))
        try await channel.onAccountVerified("A", channel.accountVerificationAuthority())
        XCTAssertTrue(bridge.mayPublish(accountID: account.id))
    }

    func testRestorationOwnershipFailureNeverInstallsAnUnownedHouseholdCredential() async throws {
        let suite = "ProviderRestoreOwnerFailure.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = makeAccount(.plex)
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        let bridge = ProviderCredentialSync(
            accounts: accounts, storage: InMemorySecureStore(),
            ownership: UnavailableOwnershipStore(failRead: false),
            defaults: defaults, enabled: { true }, didRestore: { XCTFail("Failed ownership is not restoration") })
        var pending = PendingSyncedServersStore(defaults: defaults)
        pending.upsertSynced(SyncedAccountDescriptor(account: account))
        let record = ProviderCredentialRecord(
            version: 1, sourceDeviceID: "source", account: account, token: "secret", share: nil, silo: nil)
        try bridge.accountVerified("A", authority: bridge.snapshotAuthority)
        bridge.apply(.init(sequence: 1, authority: bridge.snapshotAuthority,
                           records: [record.recordName: try JSONEncoder().encode(record)], cloudAccountID: "A"))
        await bridge.finishPendingRestoration()
        XCTAssertTrue(accounts.loadAccounts().isEmpty)
        XCTAssertNil(accounts.token(for: account.id))
        XCTAssertNil(bridge.publicationPermission)
    }

    func testPendingMigrationCannotApproveATokenOnlyReplacement() throws {
        let suite = "ProviderMigrationPartialWrite.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secure = PublicationFailureStore()
        let accounts = AccountStore(secureStore: secure)
        let account = makeAccount(.plex)
        try accounts.add(account, token: "original")
        let bridge = ProviderCredentialSync(
            accounts: accounts, storage: InMemorySecureStore(), ownership: InMemorySecureStore(),
            defaults: defaults, enabled: { true }, didRestore: {})
        try bridge.accountVerified("A", authority: bridge.snapshotAuthority)
        let request = try XCTUnwrap(bridge.publicationPermission)
        secure.failWrites(to: "com.plozz.accounts.v2")
        XCTAssertThrowsError(try accounts.replaceAuthenticatedSession(
            account.session(token: "replacement"), expected: account))
        XCTAssertFalse(bridge.resolvePublicationPermission(request, allow: true))
        XCTAssertFalse(bridge.mayPublish(accountID: account.id))
        XCTAssertTrue(try bridge.capture(fallback: [:]).isEmpty)
        XCTAssertNotEqual(bridge.publicationPermission?.id, request.id)
    }

    private func makeAccount(_ provider: ProviderKind) -> Account {
        Account(id: "account", server: MediaServer(id: "server", name: "Server",
                baseURL: URL(string: "https://trusted.test")!, provider: provider),
                userID: "user", userName: "Viewer", deviceID: "source")
    }
}

private struct UnavailableOwnershipStore: SecureStore {
    let failRead: Bool
    func readString(for key: String) throws -> String? {
        if failRead { throw CocoaError(.fileReadNoPermission) }
        return nil
    }
    func string(for key: String) -> String? { nil }
    func setString(_ value: String, for key: String) throws { throw CocoaError(.fileWriteNoPermission) }
    func insertStringIfAbsent(_ value: String, for key: String) throws -> Bool { throw CocoaError(.fileWriteNoPermission) }
    func removeValue(for key: String) throws { throw CocoaError(.fileWriteNoPermission) }
}

private final class PublicationFailureStore: SecureStore, @unchecked Sendable {
    private let store = InMemorySecureStore()
    private let lock = NSLock()
    private var failingKey: String?
    private var failsAll = false
    func failWrites(to key: String?) {
        lock.withLock { failingKey = key; failsAll = key == nil }
    }
    func readString(for key: String) throws -> String? { try store.readString(for: key) }
    func string(for key: String) -> String? { store.string(for: key) }
    func setString(_ value: String, for key: String) throws {
        if lock.withLock({ failsAll || failingKey == key }) { throw CocoaError(.fileWriteNoPermission) }
        try store.setString(value, for: key)
    }
    func insertStringIfAbsent(_ value: String, for key: String) throws -> Bool {
        if lock.withLock({ failsAll || failingKey == key }) { throw CocoaError(.fileWriteNoPermission) }
        return try store.insertStringIfAbsent(value, for: key)
    }
    func removeValue(for key: String) throws {
        if lock.withLock({ failsAll || failingKey == key }) { throw CocoaError(.fileWriteNoPermission) }
        try store.removeValue(for: key)
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
