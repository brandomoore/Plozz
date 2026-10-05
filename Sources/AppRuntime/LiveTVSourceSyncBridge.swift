import CoreModels
import CoreNetworking
import CryptoKit
import FeatureLiveTVCore
import Foundation
import Observation

@MainActor
@Observable
public final class LiveTVSourceSyncBridge {
    public enum Status: Equatable { case ready, pendingFiles(Int), unavailable }
    public private(set) var statuses: [String: Status] = [:]
    @ObservationIgnored private let profiles: ProfilesModel
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: @MainActor (String) -> any LiveTVSourcesStoring
    @ObservationIgnored private let cache: @MainActor (String) throws -> LiveTVIndexedCache
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var latestSequence: UInt64 = 0
    @ObservationIgnored private let transferPreparation = LiveTVSourceTransferPreparation()

    public init(
        profiles: ProfilesModel, defaults: UserDefaults = .standard,
        store: @escaping @MainActor (String) -> any LiveTVSourcesStoring,
        cache: @escaping @MainActor (String) throws -> LiveTVIndexedCache
    ) {
        self.profiles = profiles
        self.defaults = defaults
        self.store = store
        self.cache = cache
    }

    public func capture(_ snapshot: SyncChannelSnapshot) async throws -> [SyncRecordID: Data] {
        let root = profiles.rootNamespaceOwnerID
        await begin()
        defer { end() }
        try admit(snapshot)
        var result = snapshot.records
        let removed = try removedProfiles()
        for name in result.keys {
            guard let key = LiveTVPortableRecordKey.parse(name), removed.contains(key.profileID) else { continue }
            if key.kind == .source { result[name] = try LiveTVSourceSyncManifest(source: nil).canonicalData() }
            else if key.kind == .snapshot { result[name] = nil }
        }
        for profile in profiles.profiles where !removed.contains(profile.id) {
            do {
                let pending = try await applyProfile(profile.id, snapshot: snapshot, root: root)
                try check(profile.id, snapshot: snapshot, root: root)
                let original = try configuration(profile.id, epoch: snapshot.authority)
                var updated = original
                var checkpoint = original.syncCheckpoint ?? .init(profileID: profile.id, accountEpoch: snapshot.authority)
                let present = Set(original.playlists.map(\.id))
                for source in original.playlists {
                    let name = key(profile.id, .source, source.id)
                    let fingerprint = try LiveTVSourceSyncManifest.sourceDigest(source)
                    if checkpoint.observed[source.id] == fingerprint,
                       checkpoint.pendingCaptures[source.id] == nil, result[name] != nil { continue }
                    var file: LiveTVSourceSyncManifest.File?
                    if let id = source.importedPlaylistID {
                        let transfer = try await cache(profile.id).exportImportedPlaylist(id: id)
                        try check(profile.id, snapshot: snapshot, root: root)
                        guard try load(profile.id) == original else { throw CancellationError() }
                        file = .init(transfer)
                        removeChunks(sourceID: source.id, profileID: profile.id, records: &result)
                        for (index, chunk) in transfer.chunks.enumerated() {
                            result[key(profile.id, .snapshot, source.id + ".\(index)")] = chunk
                        }
                    }
                    let manifest = LiveTVSourceSyncManifest(source: source, file: file)
                    let bytes = try manifest.canonicalData()
                    result[name] = bytes
                    checkpoint.observed[source.id] = fingerprint
                    checkpoint.pendingCaptures[source.id] = Data(SHA256.hash(data: bytes))
                    checkpoint.importedFiles[source.id] = try manifest.fileFingerprint()
                }
                for id in checkpoint.observed.keys where !present.contains(id) {
                    let name = key(profile.id, .source, id)
                    let bytes = try LiveTVSourceSyncManifest(source: nil).canonicalData()
                    if result[name] != bytes || checkpoint.pendingCaptures[id] != nil {
                        checkpoint.pendingCaptures[id] = Data(SHA256.hash(data: bytes))
                    }
                    result[name] = bytes
                    removeChunks(sourceID: id, profileID: profile.id, records: &result)
                    checkpoint.observed[id] = Data()
                    checkpoint.importedFiles[id] = nil
                }
                guard result.values.reduce(0, { $0 + $1.count }) <= 256 * 1_024 * 1_024 else {
                    throw LiveTVPortableStateError.tooLarge
                }
                updated.syncCheckpoint = checkpoint
                try check(profile.id, snapshot: snapshot, root: root)
                guard try load(profile.id) == original else { throw CancellationError() }
                if updated != original { try save(updated, profileID: profile.id) }
                statuses[profile.id] = pending > 0 ? .pendingFiles(pending) : .ready
            } catch {
                if error is CancellationError { throw error }
                statuses[profile.id] = .unavailable
                PlozzLog.sync.error("Live TV source capture unavailable (code \((error as NSError).code))")
                throw error
            }
        }
        guard snapshot.authority == epoch, SyncSetupFeatureFlag(defaults: defaults).isEnabled,
              profiles.rootNamespaceOwnerID == root else { throw CancellationError() }
        return result
    }

    public func apply(_ snapshot: SyncChannelSnapshot) async {
        let root = profiles.rootNamespaceOwnerID
        await begin()
        defer { end() }
        do {
            try admit(snapshot)
            let removed = try removedProfiles()
            for profile in profiles.profiles where !removed.contains(profile.id) {
                do {
                    let pending = try await applyProfile(profile.id, snapshot: snapshot, root: root)
                    statuses[profile.id] = pending > 0 ? .pendingFiles(pending) : .ready
                } catch {
                    if error is CancellationError { throw error }
                    statuses[profile.id] = .unavailable
                    PlozzLog.sync.error("Live TV source apply unavailable (code \((error as NSError).code))")
                }
            }
        } catch {
            if !(error is CancellationError) { PlozzLog.sync.error("Live TV source snapshot unavailable") }
        }
    }

    private func applyProfile(_ profileID: String, snapshot: SyncChannelSnapshot, root: String?) async throws -> Int {
        try check(profileID, snapshot: snapshot, root: root)
        let original = try configuration(profileID, epoch: snapshot.authority)
        var updated = original
        var checkpoint = original.syncCheckpoint ?? .init(profileID: profileID, accountEpoch: snapshot.authority)
        var pending = 0
        let names = Set(snapshot.records.keys).union(snapshot.deleted).sorted()
        for name in names {
            guard let record = LiveTVPortableRecordKey.parse(name),
                  record.profileID == profileID, record.kind == .source else { continue }
            let manifest: LiveTVSourceSyncManifest
            if let bytes = snapshot.records[name] {
                guard bytes.count <= 512 * 1_024 else { throw LiveTVPortableStateError.tooLarge }
                manifest = try JSONDecoder().decode(LiveTVSourceSyncManifest.self, from: bytes)
            } else {
                manifest = LiveTVSourceSyncManifest(source: nil)
            }
            try manifest.validate(id: record.entityID)
            let local = original.playlists.first { $0.id == record.entityID }
            let localDigest = try LiveTVSourceSyncManifest.sourceDigest(local)
            if let observed = checkpoint.observed[record.entityID] {
                if localDigest != observed { continue }
            } else if let local, local != manifest.source {
                continue
            }
            if let captured = checkpoint.pendingCaptures[record.entityID],
               snapshot.localCaptureDigests[name] != captured { continue }
            if let source = manifest.source, let id = source.importedPlaylistID, let file = manifest.file {
                let fingerprint = try manifest.fileFingerprint()
                let storage = try cache(profileID)
                let exists = try await storage.hasImportedPlaylist(id: id)
                try check(profileID, snapshot: snapshot, root: root)
                guard try load(profileID) == original else { throw CancellationError() }
                if !exists || checkpoint.importedFiles[source.id] != fingerprint {
                    var chunks: [Data] = []
                    for index in 0..<file.chunks {
                        guard let chunk = snapshot.records[key(profileID, .snapshot, source.id + ".\(index)")] else { break }
                        chunks.append(chunk)
                    }
                    guard chunks.count == file.chunks else { pending += 1; continue }
                    let transfer = try await transferPreparation.prepare(chunks: chunks, baseURL: file.baseURL)
                    try check(profileID, snapshot: snapshot, root: root)
                    guard try load(profileID) == original else { throw CancellationError() }
                    guard transfer.byteCount == file.bytes, transfer.digest == file.digest else {
                        throw LiveTVPortableStateError.invalidRecord
                    }
                    try await storage.restoreSyncedImportedPlaylist(transfer, id: id)
                    try check(profileID, snapshot: snapshot, root: root)
                    guard try load(profileID) == original else { throw CancellationError() }
                }
                checkpoint.importedFiles[source.id] = fingerprint
            }
            if let source = manifest.source {
                if let index = updated.playlists.firstIndex(where: { $0.id == source.id }) {
                    updated.playlists[index] = source
                } else {
                    updated.playlists.append(source)
                }
            } else {
                updated.playlists.removeAll { $0.id == record.entityID }
                checkpoint.importedFiles[record.entityID] = nil
            }
            checkpoint.observed[record.entityID] = try LiveTVSourceSyncManifest.sourceDigest(manifest.source)
            checkpoint.pendingCaptures[record.entityID] = nil
            if local == nil, manifest.source != nil { checkpoint.receivedSourceIDs.insert(record.entityID) }
        }
        updated.syncCheckpoint = checkpoint
        try updated.validate()
        try check(profileID, snapshot: snapshot, root: root)
        guard try load(profileID) == original else { throw CancellationError() }
        if updated != original {
            try save(updated, profileID: profileID)
            NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidApply, object: profileID)
        }
        return pending
    }

    public func removeProfile(_ id: String) throws {
        var removed = try removedProfiles()
        removed.insert(id)
        defaults.set(removed.sorted(), forKey: removedKey)
        statuses[id] = nil
    }

    public func accountDidChange() {
        latestSequence = 0
        statuses = [:]
        for profile in profiles.profiles {
            do { _ = try configuration(profile.id, epoch: epoch) }
            catch {
                statuses[profile.id] = .unavailable
                PlozzLog.sync.error("Live TV sources remain quarantined after account change")
            }
        }
    }

    private func configuration(_ id: String, epoch: String) throws -> LiveTVSourcesConfiguration {
        var result = try load(id)
        if let previous = result.syncCheckpoint,
           previous.accountEpoch != epoch || previous.profileID != id {
            result.playlists.removeAll { previous.receivedSourceIDs.contains($0.id) }
            result.syncCheckpoint = .init(profileID: id, accountEpoch: epoch)
            try save(result, profileID: id)
        }
        return result
    }

    private func load(_ id: String) throws -> LiveTVSourcesConfiguration {
        let sourceStore = store(id)
        return try (sourceStore as? any LiveTVPortableSourcesStoring)?.loadSyncConfiguration() ?? sourceStore.load()
    }

    private func save(_ value: LiveTVSourcesConfiguration, profileID: String) throws {
        let sourceStore = store(profileID)
        if let policy = sourceStore as? any LiveTVPortableSourcesStoring {
            try policy.applySyncedConfiguration(value)
        } else {
            try sourceStore.save(value)
        }
    }

    private var epoch: String { LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults) }
    private var removedKey: String { "com.plozz.liveTV.sources.removed." + epoch }
    private func removedProfiles() throws -> Set<String> {
        guard let value = defaults.object(forKey: removedKey) else { return [] }
        guard let ids = value as? [String] else { throw LiveTVPortableStateError.invalidRecord }
        return Set(ids)
    }

    private func admit(_ snapshot: SyncChannelSnapshot) throws {
        guard snapshot.records.count <= 50_000,
              snapshot.records.values.reduce(0, { $0 + $1.count }) <= 256 * 1_024 * 1_024 else {
            throw LiveTVPortableStateError.tooLarge
        }
        guard !Task.isCancelled, snapshot.authority == epoch, epoch != "invalid",
              SyncSetupFeatureFlag(defaults: defaults).isEnabled,
              snapshot.sequence >= latestSequence else { throw CancellationError() }
        latestSequence = snapshot.sequence
    }

    private actor LiveTVSourceTransferPreparation {
        func prepare(chunks: [Data], baseURL: URL?) throws -> LiveTVImportedPlaylistTransfer {
            try Task.checkCancellation()
            return try LiveTVImportedPlaylistTransfer(chunks: chunks, baseURL: baseURL)
        }
    }

    private func check(_ id: String, snapshot: SyncChannelSnapshot, root: String?) throws {
        guard !Task.isCancelled, snapshot.authority == epoch, profiles.rootNamespaceOwnerID == root,
              SyncSetupFeatureFlag(defaults: defaults).isEnabled,
              profiles.profiles.contains(where: { $0.id == id }), !(try removedProfiles()).contains(id) else {
            throw CancellationError()
        }
    }

    private func key(_ profile: String, _ kind: LiveTVPortableRecordKey.Kind, _ id: String) -> String {
        LiveTVPortableRecordKey(profileID: profile, kind: kind, entityID: id).recordName
    }

    private func removeChunks(sourceID: String, profileID: String, records: inout [String: Data]) {
        for name in records.keys {
            guard let part = LiveTVPortableRecordKey.parse(name), part.profileID == profileID,
                  part.kind == .snapshot, let dot = part.entityID.lastIndex(of: "."),
                  String(part.entityID[..<dot]) == sourceID else { continue }
            records[name] = nil
        }
    }

    private func begin() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func end() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
}
