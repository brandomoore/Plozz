import CryptoKit
import Foundation
import Observation
import CoreModels
import CoreNetworking
import CoreSecureStore
import FeatureAuthCore
import FeatureSyncCloud
import ProviderSilo

/// This value belongs only in encrypted CloudKit fields or the local Keychain.
struct ProviderCredentialRecord: Codable, Sendable, Equatable {
    let version: Int
    let sourceDeviceID: String
    let account: Account
    let token: String?
    let share: String?
    let silo: SiloSyncCredential?
    var revoked: Bool?

    var recordName: String {
        let identity = sourceDeviceID + "\0" + account.id
        return "providerCredential:" + SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func matches(_ descriptor: SyncedAccountDescriptor) -> Bool {
        revoked != true && version == 1 && account.id == descriptor.id
            && account.server.provider == descriptor.provider
            && account.server.id == descriptor.serverID && account.userID == descriptor.userID
    }

    var tombstone: Self {
        .init(version: version, sourceDeviceID: sourceDeviceID, account: account,
              token: nil, share: nil, silo: nil, revoked: true)
    }
}

/// Shared automatic server setup. Cloud descriptors never authorize an endpoint:
/// requests use the account and URLs inside the encrypted credential record.
@MainActor
@Observable
public final class ProviderCredentialSync {
    private struct State: Codable {
        var records: [String: Data] = [:]
        var suppressed: [String: CredentialRevision] = [:]
    }
    private let accounts: any AccountPersisting
    private let storage: any SecureStoring
    private let defaults: UserDefaults
    private let authority: ProviderCredentialAuthority
    private let enabled: () -> Bool
    private let canRestore: () -> Bool
    private let didRestore: () -> Void
    private let enroll: @Sendable (SiloSyncCredential, Account, String) async throws -> UserSession
    private let discard: @Sendable (UserSession) async -> Void
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var authorityConfirmed = false
    private var resetPending = false
    private var latestSequence: UInt64?
    private var needsReconciliation = false
    private static let stateKey = "provider-credentials.v1"
    private static let resetKey = "com.plozz.providerSyncResetPending.v1"

    public init(
        accounts: any AccountPersisting,
        storage: any SecureStoring = KeychainStore(service: "com.plozz.provider-sync.v1"),
        defaults: UserDefaults = .standard,
        enabled: @escaping () -> Bool = { SyncSetupFeatureFlag().isEnabled },
        canRestore: @escaping () -> Bool = { true },
        didRestore: @escaping () -> Void,
        enroll: @escaping @Sendable (SiloSyncCredential, Account, String) async throws -> UserSession = { credential, account, deviceID in
            #if os(tvOS)
            let platform = "tvos"
            #else
            let platform = "ios"
            #endif
            return try await SiloAuthentication(baseURL: account.server.baseURL).enrollDevice(
                using: credential, serverID: account.server.id, serverName: account.server.name,
                deviceID: deviceID, platform: platform)
        },
        discard: @escaping @Sendable (UserSession) async -> Void = { session in
            do {
                try await SiloAuthentication(baseURL: session.server.baseURL).endVerificationSession(session)
            } catch {
                PlozzLog.auth.error("Could not revoke an unused automatic Silo sign-in")
            }
        }
    ) {
        self.accounts = accounts
        self.storage = storage
        self.defaults = defaults
        self.authority = ProviderCredentialAuthority(defaults: defaults)
        self.resetPending = defaults.bool(forKey: Self.resetKey)
        self.enabled = enabled
        self.canRestore = canRestore
        self.didRestore = didRestore
        self.enroll = enroll
        self.discard = discard
    }

    public func channel(stateFileURL: URL) -> CloudConfigSyncService.ChannelConfiguration {
        .init(
            schema: .providerCredentialsV1, stateFileURL: stateFileURL,
            captureRecords: { fallback in fallback },
            applyRecords: { _ in },
            onAccountSwitch: { [weak self] in await self?.accountChanged() },
            captureSnapshot: { [weak self] snapshot in
                guard let self else { return snapshot.records }
                return try await self.capture(snapshot)
            },
            applySnapshot: { [weak self] snapshot in await self?.apply(snapshot) },
            snapshotAuthority: { [authority] in authority.value }
        )
    }

    var snapshotAuthority: String { authority.value }

    private func capture(_ snapshot: SyncChannelSnapshot) throws -> [String: Data] {
        guard snapshot.authority == authority.value else { throw CancellationError() }
        return try capture(fallback: snapshot.records)
    }

    func capture(fallback: [String: Data]) throws -> [String: Data] {
        guard enabled() else { return fallback }
        try finishAccountReset()
        let state = try load()
        let removed = RemovedAccountsStore(defaults: defaults).removedIDs
        var records: [String: Data] = [:]
        for (name, data) in fallback {
            let record = try decode(data, name: name)
            records[name] = removed.contains(record.account.id)
                ? try Self.encoder().encode(record.tombstone) : data
        }
        for account in accounts.loadAccounts() {
            guard !removed.contains(account.id),
                  state.suppressed[account.id] != account.credentialRevision else { continue }
            let record: ProviderCredentialRecord
            if account.server.provider == .mediaShare {
                let credential = try accounts.mediaShareCredential(for: account.id)
                if case .generatedKey = credential.authentication {
                    let revoked = ProviderCredentialRecord(
                        version: 1, sourceDeviceID: accounts.deviceID(), account: account,
                        token: nil, share: nil, silo: nil, revoked: true)
                    records[revoked.recordName] = try Self.encoder().encode(revoked)
                    continue
                }
                record = .init(version: 1, sourceDeviceID: accounts.deviceID(), account: account,
                               token: nil, share: try MediaShareCredentialCodec.encode(credential), silo: nil)
            } else {
                guard let raw = accounts.token(for: account.id) else {
                    // An unavailable local Keychain item is not a household sign-out.
                    continue
                }
                if account.server.provider == .iptv, try IPTVCredential.decode(raw).mode == .file {
                    // A legacy imported file needs its content, not just its catalog key.
                    let revoked = ProviderCredentialRecord(
                        version: 1, sourceDeviceID: accounts.deviceID(), account: account,
                        token: nil, share: nil, silo: nil, revoked: true)
                    records[revoked.recordName] = try Self.encoder().encode(revoked)
                    continue
                }
                if account.server.provider == .silo {
                    let credential = try SiloCredential.decode(raw)
                    guard credential.refreshPending != true else { continue }
                    record = .init(version: 1, sourceDeviceID: accounts.deviceID(), account: account,
                                   token: nil, share: nil, silo: SiloSyncCredential(credential))
                } else {
                    record = .init(version: 1, sourceDeviceID: accounts.deviceID(), account: account,
                                   token: raw, share: nil, silo: nil)
                }
            }
            records[record.recordName] = try Self.encoder().encode(record)
        }
        return records
    }

    func apply(_ snapshot: SyncChannelSnapshot) {
        guard enabled(), snapshot.authority == authority.value else { return }
        if let latestSequence, snapshot.sequence < latestSequence { return }
        do {
            try finishAccountReset()
            for (name, data) in snapshot.records { _ = try decode(data, name: name) }
            var state = try load()
            state.records = snapshot.records
            try save(state)
            latestSequence = snapshot.sequence
            authorityConfirmed = true
            reconcile()
        } catch {
            PlozzLog.sync.error("Provider credential sync could not persist its encrypted snapshot")
        }
    }

    public func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        authorityConfirmed = false
        latestSequence = nil
    }

    private func accountChanged() {
        cancel()
        defaults.set(true, forKey: Self.resetKey)
        authority.renew()
        resetPending = true
        do {
            try finishAccountReset()
        } catch {
            PlozzLog.sync.error("Provider credential sync could not clear previous iCloud account state")
        }
    }

    private func finishAccountReset() throws {
        guard resetPending else { return }
        var state = State()
        for account in accounts.loadAccounts() {
            state.suppressed[account.id] = account.credentialRevision
        }
        try save(state)
        resetPending = false
        defaults.removeObject(forKey: Self.resetKey)
    }

    public func eraseLocalState() throws {
        cancel()
        try storage.removeValue(for: Self.stateKey)
    }

    public func didAuthenticateLocally(accountID: String) {
        do {
            try finishAccountReset()
            var state = try load()
            guard state.suppressed.removeValue(forKey: accountID) != nil else { return }
            try save(state)
        } catch {
            PlozzLog.sync.error("Local sign-in succeeded, but its iCloud publication permission could not be saved")
        }
    }

    public func hasCredential(for accountID: String) -> Bool {
        guard authorityConfirmed, enabled() else { return false }
        do {
            return try load().records.contains { name, data in
                let record = try decode(data, name: name)
                return record.account.id == accountID && record.silo == nil && record.revoked != true
            }
        } catch {
            PlozzLog.sync.error("Provider credential availability could not be read")
            return false
        }
    }

    public var isReadyForManualSetup: Bool {
        authorityConfirmed && task == nil
    }

    public func reconcile() {
        guard authorityConfirmed, enabled(), canRestore() else { return }
        guard task == nil else {
            needsReconciliation = true
            return
        }
        needsReconciliation = false
        let current = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == current {
                    task = nil
                    if needsReconciliation { reconcile() }
                }
            }
            do {
                let state = try load()
                let candidates = try state.records.sorted { $0.key < $1.key }.map {
                    try decode($0.value, name: $0.key)
                }

                for record in candidates {
                    guard isCurrent(record, generation: current) else { continue }
                    do {
                        try await restore(record, generation: current)
                    } catch is CancellationError {
                        return
                    } catch SiloDeviceEnrollmentError.profilePINRequired {
                        PlozzLog.auth.info("Automatic Silo sign-in requires this profile's PIN")
                    } catch {
                        PlozzLog.auth.error("Automatic server sign-in failed; manual sign-in remains available")
                    }
                }
            } catch {
                PlozzLog.sync.error("Provider credential sync could not read its local Keychain state")
            }
        }
    }

    private func isCurrent(_ record: ProviderCredentialRecord, generation current: UInt64) -> Bool {
        guard !Task.isCancelled, generation == current, authorityConfirmed, enabled(), canRestore(),
              !accounts.loadAccounts().contains(where: { $0.id == record.account.id }),
              !RemovedAccountsStore(defaults: defaults).isRemoved(record.account.id) else { return false }
        do {
            guard let data = try load().records[record.recordName],
                  try decode(data, name: record.recordName) == record else { return false }
        } catch {
            PlozzLog.sync.error("Could not verify the current automatic sign-in credential")
            return false
        }
        return PendingSyncedServersStore(defaults: defaults).pending.contains(where: record.matches)
    }

    private func restore(_ record: ProviderCredentialRecord, generation current: UInt64) async throws {
        var account = record.account
        guard let descriptor = PendingSyncedServersStore(defaults: defaults).pending.first(where: record.matches) else {
            throw CancellationError()
        }
        account.server.name = descriptor.serverName
        if account.server.provider == .mediaShare {
            account.server.mediaShareLibraryConfiguration = descriptor.mediaShareLibraryConfiguration
        }
        account.credentialRevision = CredentialRevision()
        if account.server.provider == .silo {
            guard let credential = record.silo, record.token == nil, record.share == nil,
                  account.userID == "\(credential.accountID):\(credential.profileID)" else {
                throw AppError.invalidResponse
            }

            let session = try await enroll(credential, account, accounts.deviceID())
            guard isCurrent(record, generation: current) else {
                await discardUnusedSession(session)
                throw CancellationError()
            }
            do {
                guard session.server.provider == .silo, session.server.id == account.server.id,
                      session.userID == account.userID else { throw AppError.invalidResponse }
                account = Account(id: account.id, from: session, addedAt: account.addedAt)
                try accounts.add(account, token: session.accessToken)
            } catch {
                await discardUnusedSession(session)
                throw error
            }
        } else if account.server.provider == .mediaShare {
            guard let data = record.share, record.token == nil, record.silo == nil else {
                throw AppError.invalidResponse
            }
            let credential = try MediaShareCredentialCodec.decodeVersioned(data)
            if case .generatedKey = credential.authentication { throw AppError.invalidResponse }
            account.deviceID = accounts.deviceID()
            try accounts.addMediaShare(account, credential: credential, generatedPrivateKey: nil)
        } else {
            guard let token = record.token, !token.isEmpty, record.share == nil, record.silo == nil else {
                throw AppError.invalidResponse
            }
            if account.server.provider == .iptv, try IPTVCredential.decode(token).mode == .file {
                throw AppError.invalidResponse
            }
            try accounts.add(account, token: token)
        }
        didRestore()
    }

    private func load() throws -> State {
        guard let raw = try storage.readString(for: Self.stateKey) else { return State() }
        return try JSONDecoder().decode(State.self, from: Data(raw.utf8))
    }

    private func save(_ state: State) throws {
        try storage.setString(String(decoding: try Self.encoder().encode(state), as: UTF8.self), for: Self.stateKey)
    }

    private func decode(_ data: Data, name: String) throws -> ProviderCredentialRecord {
        let record = try JSONDecoder().decode(ProviderCredentialRecord.self, from: data)
        guard record.version == 1, record.recordName == name, !record.sourceDeviceID.isEmpty,
              !record.account.id.isEmpty, !record.account.server.id.isEmpty,
              !record.account.userID.isEmpty else { throw AppError.invalidResponse }
        return record
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    func finishPendingRestoration() async {
        while let task { await task.value }
    }

    private func discardUnusedSession(_ session: UserSession) async {
        let discard = self.discard
        await Task { await discard(session) }.value
    }
}

private final class ProviderCredentialAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private let defaults: UserDefaults
    private var current: String
    private static let key = "com.plozz.providerSyncAuthority.v1"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        current = defaults.string(forKey: Self.key) ?? UUID().uuidString
        defaults.set(current, forKey: Self.key)
    }

    var value: String { lock.withLock { current } }

    func renew() {
        lock.withLock {
            current = UUID().uuidString
            defaults.set(current, forKey: Self.key)
        }
    }
}
