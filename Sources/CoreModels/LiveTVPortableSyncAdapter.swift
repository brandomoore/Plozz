import CryptoKit
import Foundation

/// Immutable, validated schedule inputs and their encoded cloud records.
/// Prepare this away from the main actor; capture only commits the result.
public struct LiveTVPortableLibraryExport: Sendable {
    public let state: LibraryChannelPortableState
    fileprivate let snapshotRecords: [String: SnapshotRecord]

    fileprivate struct SnapshotRecord: Sendable {
        let value: LiveTVPortableRecord
        let bytes: Data
    }

    public init(definitions: [LibraryChannelDefinition], snapshots: [LibraryChannelSnapshot]) throws {
        state = try LibraryChannelPortableState(definitions: definitions, snapshots: snapshots)
        var records: [String: SnapshotRecord] = [:]
        var byteCount = 0
        for snapshot in snapshots {
            try Task.checkCancellation()
            guard let profileID = definitions.first?.profileID else {
                throw LibraryChannelError.invalidSnapshot
            }
            for part in try LiveTVPortableSnapshots.partition(snapshot) {
                let record = LiveTVPortableRecord(snapshot: part)
                try record.validate(key: .init(profileID: profileID, kind: .snapshot, entityID: part.entityID))
                let bytes = try record.encoded()
                byteCount += bytes.count
                guard byteCount <= 64 * 1_024 * 1_024 else { throw LiveTVPortableStateError.tooLarge }
                records[part.entityID] = SnapshotRecord(value: record, bytes: bytes)
            }
        }
        snapshotRecords = records
    }
}

public struct LiveTVPortableImport: Sendable {
    /// Identifies the journal that produced this report, including across
    /// resolvingLibrarySnapshots(). It is not a runtime authority/consent token.
    public fileprivate(set) var journalRevision: LiveTVPortableSyncAdapter.JournalRevision?
    public var appliedCount = 0
    public var rejectedCount = 0
    public var pendingPlaylists: [String: LiveTVPortableSource] = [:]
    public var localFileSources: [String: LiveTVPortableSource] = [:]
    public var libraryDefinitions: [LibraryChannelDefinition] = []
    public var deletedLibraryIDs: Set<UUID> = []
    public var disabledLibraryIDs: Set<UUID> = []
    public var libraryReviewIDs: Set<UUID> = []
    public var snapshots: [LibraryChannelSnapshot] = []
    public var incompleteSnapshotIDs: Set<UUID> = []
    public var guideMappings: [String: LiveTVPortableGuideMapping?] = [:]
    public var identityHints: [String: LiveTVPortableChannelIdentityHint?] = [:]
    fileprivate var snapshotParts: [UUID: [LiveTVPortableSnapshotPart]]?
    fileprivate var pendingDefinitions: [LibraryChannelDefinition] = []

    public init() {}

    /// Reconstructs immutable inputs without reading or changing local stores.
    public func resolvingLibrarySnapshots() -> Self {
        guard let snapshotParts else { return self }
        var result = self
        var complete: [UUID: LibraryChannelSnapshot] = [:]
        let requiredSnapshots = Set(pendingDefinitions.flatMap(\.revisions).map(\.snapshotID))
        for (id, pieces) in snapshotParts where requiredSnapshots.contains(id) {
            do { complete[id] = try LiveTVPortableSnapshots.assemble(pieces) }
            catch { result.incompleteSnapshotIDs.insert(id) }
        }
        for definition in pendingDefinitions {
            let required = Set(definition.revisions.map(\.snapshotID))
            let missing = required.subtracting(complete.keys)
            result.incompleteSnapshotIDs.formUnion(missing)
            if missing.isEmpty { result.libraryDefinitions.append(definition) }
        }
        result.snapshots = complete.values.sorted { $0.id.uuidString < $1.id.uuidString }
        result.snapshotParts = nil
        result.pendingDefinitions = []
        return result
    }
}

/// Adapter for the existing SyncLedger/CloudConfigSyncService contract. The
/// source and preferences stores stay authoritative; this journal retains
/// tombstones and unavailable peer descriptors, not playback or guide caches.
public final class LiveTVPortableSyncAdapter: @unchecked Sendable {
    public struct JournalRevision: Equatable, Sendable {
        fileprivate let coordinatorID: UUID
        fileprivate let accountEpoch: String
        fileprivate let revision: UUID
    }

    public enum PreparationError: Error, Equatable, Sendable {
        case preparationRequired
        case preparationSuperseded
        case journalChanged
        case accountChanged
    }

    private struct StoredRecord: Codable, Sendable {
        let name: String
        let value: Data
        let appliedConsentRevision: String?
        let pendingRemoteFingerprint: String?
    }

    private struct ObservedLocal: Codable, Sendable {
        var sourceIDs: Set<String> = []
        var libraryIDs: Set<String> = []
        var favoriteOrder: [String] = []
        var pendingMappingIDs: Set<String> = []
        var pendingLibraryIDs: Set<String> = []
        var pendingIdentityIDs: Set<String> = []
        var clearedIdentityHintFingerprints: [String: String]?
        var libraryReviewIDs: Set<String>?
        var hydratedConsentRevision: String?
    }

    private struct Journal: Sendable {
        var records: [String: Data] = [:]
        var stored: [String: StoredRecord] = [:]
        var decoded: [String: LiveTVPortableRecord] = [:]
        var directoryExists = false
    }

    private struct ValidatedRecord: Sendable {
        let bytes: Data
        // A nil value records a rejected incoming payload, never trusted journal data.
        let value: LiveTVPortableRecord?
        private let rejectedByteCount: Int?
        private let rejectedFingerprint: String?

        init(bytes: Data, value: LiveTVPortableRecord?) {
            self.value = value
            if value == nil {
                self.bytes = Data()
                rejectedByteCount = bytes.count
                rejectedFingerprint = LiveTVPortableSyncAdapter.digest(bytes)
            } else {
                self.bytes = bytes
                rejectedByteCount = nil
                rejectedFingerprint = nil
            }
        }

        func matches(_ candidate: Data) -> Bool {
            if value != nil { return bytes == candidate }
            return rejectedByteCount == candidate.count
                && rejectedFingerprint == LiveTVPortableSyncAdapter.digest(candidate)
        }

        func hasSamePayload(as other: Self) -> Bool {
            if value != nil, other.value != nil { return bytes == other.bytes }
            return value == nil && other.value == nil
                && rejectedByteCount == other.rejectedByteCount
                && rejectedFingerprint == other.rejectedFingerprint
        }
    }

    private struct PreparedJournal: Sendable {
        var revision: UUID
        var journal: Journal?
        var observed: ObservedLocal?
        var incoming: [String: ValidatedRecord] = [:]
        var retainedIncoming: [String: ValidatedRecord] = [:]
        var incomingBytes = 0
        var local: [String: ValidatedRecord] = [:]
        var localBytes = 0
    }

    /// Only adapters for the same physical journal serialize mutations. The
    /// revision lock is never held during filesystem access or JSON validation.
    private final class JournalCoordinator: @unchecked Sendable {
        let identity = UUID()
        let operationLock = NSRecursiveLock()
        private let revisionLock = NSLock()
        private var revision = UUID()
        private var writing = false

        func snapshot() -> (revision: UUID, writing: Bool) {
            revisionLock.lock()
            defer { revisionLock.unlock() }
            return (revision, writing)
        }

        func beginWrite() -> UUID {
            revisionLock.lock()
            defer { revisionLock.unlock() }
            revision = UUID()
            writing = true
            return revision
        }

        func endWrite() {
            revisionLock.lock()
            writing = false
            revisionLock.unlock()
        }
    }

    private final class CoordinatorRegistry: @unchecked Sendable {
        private struct Entry {
            weak var coordinator: JournalCoordinator?
        }
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        func coordinator(for directory: URL) -> JournalCoordinator {
            let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
            lock.lock()
            defer { lock.unlock() }
            if let existing = entries[path]?.coordinator { return existing }
            entries = entries.filter { $0.value.coordinator != nil }
            let coordinator = JournalCoordinator()
            entries[path] = Entry(coordinator: coordinator)
            return coordinator
        }
    }

    private let profileID: String
    private let directory: URL
    private let defaults: UserDefaults
    private let accountEpoch: String
    private let preferences: LiveTVPreferencesStore
    private let namespace: String?
    private let requiresPreparedJournal: Bool
    private let coordinator: JournalCoordinator
    private var preparedJournal: PreparedJournal?
    private var preparationID = UUID()
    private static let coordinators = CoordinatorRegistry()
    private static let maximumRecords = 50_000
    private static let maximumJournalBytes = 128 * 1_024 * 1_024
    private static let maximumInputBytes = 64 * 1_024 * 1_024

    public convenience init(
        directory: URL, profileID: String, defaults: UserDefaults = .standard,
        requiresPreparedJournal: Bool = false
    ) {
        self.init(
            directory: directory, profileID: profileID, defaults: defaults,
            namespace: profileID == ProfileStore.defaultProfileID ? nil : profileID,
            requiresPreparedJournal: requiresPreparedJournal
        )
    }

    /// Production callers can require preparation so a stale/missing cache fails
    /// before mutation instead of performing a synchronous disk read or decode.
    /// The bounded, read-only pendingPlaylistDescriptor Save guard is an exception.
    public init(
        directory: URL, profileID: String, defaults: UserDefaults = .standard, namespace: String?,
        requiresPreparedJournal: Bool = false
    ) {
        self.profileID = profileID
        self.defaults = defaults
        self.namespace = namespace
        self.requiresPreparedJournal = requiresPreparedJournal
        let epoch = LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults)
        accountEpoch = epoch
        let journalDirectory = directory
            .appendingPathComponent(epoch, isDirectory: true)
            .appendingPathComponent(Self.digest(profileID), isDirectory: true)
        self.directory = journalDirectory
        coordinator = Self.coordinators.coordinator(for: journalDirectory)
        preferences = LiveTVPreferencesStore(
            defaults: defaults, namespace: namespace
        )
    }

    /// Reads and fully validates the journal, observation, and incoming/fallback
    /// variants on a detached worker. Invalid incoming values remain rejections
    /// for apply; invalid persisted data fails preparation. No local authority or
    /// consent is captured: callers must recheck their runtime authority after
    /// awaiting, and capture/apply still check live consent.
    ///
    /// Supply every non-nil variant the next operation may consume. Adapter-owned
    /// writes invalidate other instances; external journal edits require discarding
    /// every reader. Empty warmups preserve earlier variants. New inputs take
    /// priority over older extras when the bounded cache is full (at most two
    /// extra variants per key, in addition to the journal value). The journal
    /// retains its 128 MiB limit; validated extras and newly encoded local values
    /// each have a separate 64 MiB limit. Rejections retain only fingerprints.
    /// A concurrent write retries the snapshot, bounded to three attempts.
    public func prepareForOperation(records: [SyncRecordID: Data?] = [:]) async throws {
        try Task.checkCancellation()
        let request = beginPreparation()
        let worker = Task.detached(priority: .userInitiated) { [self] in
            try prepareJournal(records: records, request: request)
        }
        do {
            try await withTaskCancellationHandler {
                try await worker.value
                try Task.checkCancellation()
            } onCancel: {
                worker.cancel()
            }
        } catch {
            cancelPreparation(request: request)
            throw error
        }
    }

    /// Invalidates an in-flight preparation too. Large parsed snapshots are
    /// released on a utility worker, not on the caller's actor.
    public func discardPreparedJournal() {
        coordinator.operationLock.lock()
        preparationID = UUID()
        discardPreparedJournalLocked()
        coordinator.operationLock.unlock()
    }

    /// Returns only an already prepared revision; never performs disk I/O.
    public func preparedJournalRevision() throws -> JournalRevision {
        coordinator.operationLock.lock()
        defer { coordinator.operationLock.unlock() }
        try ensureCurrentPreparation()
        guard let preparedJournal, preparedJournal.journal != nil, preparedJournal.observed != nil else {
            throw PreparationError.preparationRequired
        }
        return JournalRevision(
            coordinatorID: coordinator.identity, accountEpoch: accountEpoch, revision: preparedJournal.revision
        )
    }

    /// A lightweight advisory check. Still recheck runtime authority after an
    /// await; use conditional acknowledgements rather than check-then-write.
    public func isCurrentJournalRevision(_ token: JournalRevision) -> Bool {
        guard token.coordinatorID == coordinator.identity, token.accountEpoch == accountEpoch,
              accountEpoch == LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults) else { return false }
        let fence = coordinator.snapshot()
        return !fence.writing && fence.revision == token.revision
    }

    public var isEnabled: Bool {
        accountEpoch == LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults)
            && SyncSetupFeatureFlag(defaults: defaults).isEnabled
            && LiveTVPortableSyncPreferenceStore(defaults: defaults, profileID: profileID, namespace: namespace).isEnabled
    }

    /// The fallback is returned unchanged while consent is off, storage fails, or
    /// the caller cannot hydrate a store. Disabling sync is NOT a remote deletion.
    public func capture(
        sourceStore: any LiveTVSourcesStoring,
        libraryDefinitions: [LibraryChannelDefinition]? = nil,
        snapshots: [LibraryChannelSnapshot] = [],
        preparedLibrary: LiveTVPortableLibraryExport? = nil,
        guideMappings: [String: LiveTVPortableGuideMapping]? = nil,
        unresolvedGuideMappingIDs: Set<String> = [],
        identityHints: [String: LiveTVPortableChannelIdentityHint]? = nil,
        fallback: [SyncRecordID: Data]
    ) throws -> [SyncRecordID: Data] {
        let baseline = scoped(fallback)
        guard isEnabled else { return baseline }
        let libraryExport: LiveTVPortableLibraryExport?
        if let preparedLibrary {
            guard libraryDefinitions == preparedLibrary.state.definitions,
                  snapshots == preparedLibrary.state.snapshots else {
                throw LibraryChannelError.invalidSnapshot
            }
            libraryExport = preparedLibrary
        } else if let libraryDefinitions {
            libraryExport = try LiveTVPortableLibraryExport(definitions: libraryDefinitions, snapshots: snapshots)
        } else if !snapshots.isEmpty {
            throw LibraryChannelError.snapshotUnavailable
        } else {
            libraryExport = nil
        }
        let shareableMappings = guideMappings?.filter { $0.value.isSafe }
        coordinator.operationLock.lock()
        defer { coordinator.operationLock.unlock() }
        guard isEnabled else { return baseline }
        let journal = try readJournal()
        _ = try readObserved()
        try requirePreparedInputs(baseline.mapValues(Optional.some))
        var completed = false
        defer { if !completed { invalidateAfterFailedOperation() } }
        var records = journal.records
        let consentRevision = consent.consentRevision
        let localConfiguration = try sourceConfiguration(sourceStore)
        let localPrefs = try preferences.load()
        let localChannelIDs = localPrefs.favoriteIDs.union(localPrefs.hiddenChannelIDs)
            .union(localPrefs.channelOverrides.keys).union(shareableMappings?.keys.map { $0 } ?? [])
        let localSourceIDs = Set(localConfiguration.playlists.map(\.id) + localConfiguration.servers.map(\.id))
        let localLibraryIDs = Set((libraryDefinitions ?? []).map { $0.id.uuidString })
        let previousObservation = try readObserved()
        var hydration: SyncLocalChanges = [:]
        for (name, value) in baseline where records[name] != value {
            guard let recordKey = LiveTVPortableRecordKey.parse(name) else { continue }
            if let previousBytes = records[name] {
                let retriesFailedApply = journal.stored[name]?.pendingRemoteFingerprint == Self.digest(value)
                let replaysOptIn = consentRevision != nil
                    && previousObservation.hydratedConsentRevision != consentRevision
                    && journal.stored[name]?.appliedConsentRevision != consentRevision
                guard retriesFailedApply || replaysOptIn else { continue }
                let previous = try decodedRecord(previousBytes, key: recordKey)
                if try localValueIsUnchanged(
                    key: recordKey, previous: previous, configuration: localConfiguration,
                    preferences: localPrefs, libraries: libraryDefinitions,
                    mappings: shareableMappings, unresolvedMappingIDs: unresolvedGuideMappingIDs,
                    hints: identityHints, observed: previousObservation
                ) {
                    hydration[name] = value
                }
                continue
            }
            let locallyOwned: Bool
            switch recordKey.kind {
            case .channel: locallyOwned = localChannelIDs.contains(recordKey.entityID)
            case .source: locallyOwned = localSourceIDs.contains(recordKey.entityID)
            case .library: locallyOwned = localLibraryIDs.contains(recordKey.entityID)
            case .snapshot: locallyOwned = false
            case .serverEnrollment:
                locallyOwned = try suppression.records()[recordKey.entityID] != nil
            }
            if !locallyOwned { hydration[name] = value }
        }
        // A cloud engine can have fetched while this collection was disabled.
        // Replay missed values once per opt-in, except records already applied
        // under this consent. An older queued capture cannot roll those back.
        if !hydration.isEmpty {
            _ = try apply(hydration, sourceStore: sourceStore, includeLibrarySnapshots: false)
            records = try readRecords()
        }
        for (name, value) in baseline where records[name] == nil {
            guard let key = LiveTVPortableRecordKey.parse(name),
                  (try? decodedRecord(value, key: key)) != nil else { continue }
            records[name] = value
        }
        var observed = try readObserved()
        let configuration = try sourceConfiguration(sourceStore)
        let localPreferences = try preferences.load()
        let hidden = Dictionary(uniqueKeysWithValues: localPreferences.hiddenChannels.map { ($0.id, $0.name) })
        let favoriteNames = Dictionary(uniqueKeysWithValues: localPreferences.favoriteChannels.map { ($0.id, $0.name) })
        let favoritePositions = Dictionary(uniqueKeysWithValues: localPreferences.favoriteOrder.enumerated().map { ($0.element, $0.offset) })
        let existingChannelIDs = records.keys.compactMap(LiveTVPortableRecordKey.parse)
            .filter { $0.kind == .channel }.map(\.entityID)
        let channelIDs = Set(existingChannelIDs)
            .union(localPreferences.favoriteIDs).union(hidden.keys).union(localPreferences.channelOverrides.keys)
            .union(shareableMappings?.keys.map { $0 } ?? [])
        // Native-ID hints accompany user-authored state, not every downloaded
        // station. A large catalog with no preferences is not a cloud collection.
        for id in channelIDs.sorted() {
            let key = key(.channel, id)
            let previousRecord = try records[key.recordName].map { try decodedRecord($0, key: key) }
            let previous = previousRecord?.channel
            let mapping = observed.pendingMappingIDs.contains(id) || unresolvedGuideMappingIDs.contains(id)
                ? previous?.guideMapping : shareableMappings.map { $0[id] } ?? previous?.guideMapping
            let hint = Self.capturedIdentityHint(
                id: id, local: identityHints?[id], previous: previous?.identityHint, observed: observed
            )
            if previousRecord?.isDeleted == true, !localPreferences.favoriteIDs.contains(id),
               hidden[id] == nil, localPreferences.channelOverrides[id] == nil,
               mapping == nil, hint == nil { continue }
            let position = observed.favoriteOrder == localPreferences.favoriteOrder
                ? (previous == nil ? favoritePositions[id] : previous?.favoritePosition)
                : favoritePositions[id]
            let local = LiveTVPortableRecord(channel: LiveTVPortableChannel(
                isFavorite: localPreferences.favoriteIDs.contains(id), hiddenName: hidden[id],
                favoriteName: favoriteNames[id], favoritePosition: localPreferences.favoriteIDs.contains(id) ? position : nil,
                metadata: localPreferences.channelOverrides[id],
                guideMapping: mapping, identityHint: hint
            ))
            try put(local, key: key, into: &records)
            if hint != nil { observed.clearedIdentityHintFingerprints?[id] = nil }
        }
        observed.favoriteOrder = localPreferences.favoriteOrder

        let sourceIDs = Set(configuration.playlists.map(\.id) + configuration.servers.map(\.id))
        for source in configuration.playlists {
            try put(.init(source: .init(
                kind: source.importedPlaylistID == nil ? .playlist : .importedPlaylist,
                name: source.name, isEnabled: source.isEnabled,
                discoversPlaylistGuides: source.discoversPlaylistGuides,
                guideLookbackDays: source.guideLookbackDays, guideLookaheadDays: source.guideLookaheadDays
            )), key: key(.source, source.id), into: &records)
        }
        for source in configuration.servers {
            let sourceKey = key(.source, source.id)
            let prior = try records[sourceKey.recordName].map { try decodedRecord($0, key: sourceKey) }.flatMap(\.source)
            if !source.isEnabled,
               try suppression.records()[source.accountID] == nil || prior?.isEnabled == true {
                try suppression.setSuppressed(true, accountID: source.accountID)
            }
            try put(.init(source: .init(
                kind: .server, name: source.name, isEnabled: source.isEnabled, accountID: source.accountID
            )), key: key(.source, source.id), into: &records)
        }
        for removed in observed.sourceIDs.subtracting(sourceIDs) {
            let removedKey = key(.source, removed)
            if let bytes = records[removedKey.recordName],
               let accountID = try decodedRecord(bytes, key: removedKey).source?.accountID {
                try suppression.setSuppressed(true, accountID: accountID)
            }
            try put(.init(isDeleted: true), key: key(.source, removed), into: &records)
        }
        observed.sourceIDs = sourceIDs
        for (accountID, suppressed) in try suppression.records() {
            try put(.init(serverEnrollmentSuppressed: suppressed), key: key(.serverEnrollment, accountID), into: &records)
        }

        if let libraryDefinitions {
            let ids = Set(libraryDefinitions.map { $0.id.uuidString })
            for definition in libraryDefinitions where !observed.pendingLibraryIDs.contains(definition.id.uuidString) {
                try put(.init(library: definition), key: key(.library, definition.id.uuidString), into: &records)
            }
            for removed in observed.libraryIDs.subtracting(ids) {
                try put(.init(isDeleted: true), key: key(.library, removed), into: &records)
                observed.pendingLibraryIDs.remove(removed)
                observed.libraryReviewIDs?.remove(removed)
            }
            observed.libraryIDs = ids
        }
        for (entityID, prepared) in libraryExport?.snapshotRecords ?? [:] {
            let key = key(.snapshot, entityID)
            if let original = records[key.recordName],
               try decodedRecord(original, key: key) == prepared.value { continue }
            try cacheLocal(prepared.value, bytes: prepared.bytes, key: key)
            records[key.recordName] = prepared.bytes
        }
        observed.hydratedConsentRevision = consentRevision
        try write(records)
        try writeObserved(observed)
        completed = true
        return records
    }

    /// Applies only this profile's explicit records. Playlist descriptors without
    /// local secure setup remain pending; no URL or parent grant is synthesized.
    public func apply(
        _ changes: SyncLocalChanges, sourceStore: any LiveTVSourcesStoring,
        includeLibrarySnapshots: Bool = true
    ) throws -> LiveTVPortableImport {
        guard isEnabled else { return LiveTVPortableImport() }
        coordinator.operationLock.lock()
        defer { coordinator.operationLock.unlock() }
        guard isEnabled else { return LiveTVPortableImport() }
        var records = try readRecords()
        _ = try readObserved()
        try requirePreparedInputs(changes)
        var completed = false
        defer { if !completed { invalidateAfterFailedOperation() } }
        var report = LiveTVPortableImport()
        var accepted: [(LiveTVPortableRecordKey, LiveTVPortableRecord)] = []
        var changedMappingIDs = Set<String>()
        var changedIdentityIDs = Set<String>()
        var clearedHints: [String: String] = [:]
        var restoredHints: Set<String> = []
        var changedLibraryIDs: Set<String> = []
        var incomingFingerprints: [String: String] = [:]
        for (name, value) in changes where records[name] != nil {
            guard let recordKey = LiveTVPortableRecordKey.parse(name), recordKey.profileID == profileID else { continue }
            let bytes = try value ?? tombstoneBytes(key: recordKey)
            guard (try? decodedRecord(bytes, key: recordKey)) != nil else { continue }
            incomingFingerprints[name] = Self.digest(bytes)
        }
        // Keep a bounded receipt before touching fallible local stores. It
        // permits retrying this exact remote value, not an older queued fallback.
        if !incomingFingerprints.isEmpty { try write(records, receivedFingerprints: incomingFingerprints) }
        let currentSources = try sourceConfiguration(sourceStore)
        for name in changes.keys.sorted() {
            guard let recordKey = LiveTVPortableRecordKey.parse(name),
                  recordKey.profileID == profileID else { continue }
            do {
                let record: LiveTVPortableRecord
                let bytes: Data
                if let value = changes[name] ?? nil {
                    record = try decodedRecord(value, key: recordKey)
                    bytes = value
                } else {
                    record = LiveTVPortableRecord(isDeleted: true)
                    bytes = try tombstoneBytes(key: recordKey)
                }
                if let source = record.source {
                    if let existing = currentSources.playlists.first(where: { $0.id == recordKey.entityID }) {
                        let expected: LiveTVPortableSource.Kind = existing.importedPlaylistID == nil ? .playlist : .importedPlaylist
                        guard source.kind == expected else { throw LiveTVPortableStateError.invalidRecord }
                    }
                    if let existing = currentSources.servers.first(where: { $0.id == recordKey.entityID }),
                       source.kind != .server || existing.accountID != source.accountID {
                        throw LiveTVPortableStateError.invalidRecord
                    }
                }
                if recordKey.kind == .channel {
                    let previous = try records[name].map { try decodedRecord($0, key: recordKey) }
                    if previous?.channel?.guideMapping != record.channel?.guideMapping {
                        changedMappingIDs.insert(recordKey.entityID)
                    }
                    if previous?.channel?.identityHint != record.channel?.identityHint {
                        changedIdentityIDs.insert(recordKey.entityID)
                    }
                    if record.channel?.identityHint != nil {
                        restoredHints.insert(recordKey.entityID)
                    } else if let previousHint = previous?.channel?.identityHint {
                        clearedHints[recordKey.entityID] = Self.hintFingerprint(previousHint)
                    }
                }
                if recordKey.kind == .library {
                    let previous = try records[name].map { try decodedRecord($0, key: recordKey) }
                    if previous?.library != record.library || previous?.isDeleted != record.isDeleted {
                        changedLibraryIDs.insert(recordKey.entityID)
                    }
                }
                records[name] = bytes
                accepted.append((recordKey, record))
            } catch {
                report.rejectedCount += 1
            }
        }
        var configuration = try sourceConfiguration(sourceStore)
        let originalConfiguration = configuration
        let originalSuppression = try suppression.records()
        let savedPreferences = try preferences.load()
        var favorites = savedPreferences.favoriteIDs
        var hidden = Dictionary(uniqueKeysWithValues: savedPreferences.hiddenChannels.map { ($0.id, $0.name) })
        var favoriteNames = Dictionary(uniqueKeysWithValues: savedPreferences.favoriteChannels.map { ($0.id, $0.name) })
        var favoritePositions = Dictionary(uniqueKeysWithValues: savedPreferences.favoriteOrder.enumerated().map { ($0.element, $0.offset) })
        if try readObserved().favoriteOrder == savedPreferences.favoriteOrder {
            for (name, value) in records {
                guard let recordKey = LiveTVPortableRecordKey.parse(name), recordKey.kind == .channel else { continue }
                favoritePositions[recordKey.entityID] = try decodedRecord(value, key: recordKey)
                    .channel?.favoritePosition
            }
        }
        var metadata = savedPreferences.channelOverrides
        for (recordKey, record) in accepted {
            switch recordKey.kind {
            case .serverEnrollment:
                try suppression.setSuppressed(record.serverEnrollmentSuppressed ?? true, accountID: recordKey.entityID)
            case .channel:
                if record.channel?.isFavorite == true { favorites.insert(recordKey.entityID) }
                else { favorites.remove(recordKey.entityID) }
                hidden[recordKey.entityID] = record.channel?.hiddenName
                favoriteNames[recordKey.entityID] = record.channel?.favoriteName
                favoritePositions[recordKey.entityID] = record.channel?.favoritePosition
                metadata[recordKey.entityID] = record.channel?.metadata
                report.guideMappings.updateValue(record.channel?.guideMapping, forKey: recordKey.entityID)
                report.identityHints.updateValue(record.channel?.identityHint, forKey: recordKey.entityID)
            case .source:
                applySource(record, id: recordKey.entityID, configuration: &configuration)
            case .library, .snapshot:
                break
            }
        }
        let updatedPreferences = LiveTVPreferences(
            favoriteIDs: favorites, recentChannelIDs: savedPreferences.recentChannelIDs,
            hiddenChannels: hidden.keys.sorted().map { LiveTVHiddenChannel(id: $0, name: hidden[$0]!) },
            favoriteOrder: favorites.sorted {
                let left = favoritePositions[$0] ?? Int.max
                let right = favoritePositions[$1] ?? Int.max
                return left == right ? $0 < $1 : left < right
            },
            favoriteChannels: favoriteNames.keys.sorted().map { LiveTVHiddenChannel(id: $0, name: favoriteNames[$0]!) },
            channelOverrides: metadata, browse: savedPreferences.browse,
            favoriteMultiviews: savedPreferences.favoriteMultiviews
        )
        // Source validation happens before any writes. A failed local store keeps
        // the caller's cloud fallback intact; the next capture never fabricates emptiness.
        try configuration.validate()
        if originalConfiguration != configuration {
            try suppression.prepareChange(previous: originalConfiguration, updated: configuration)
            if let policyStore = sourceStore as? any LiveTVPortableSourcesStoring {
                try policyStore.applySyncedConfiguration(configuration)
            } else {
                try sourceStore.save(configuration)
            }
        }
        if updatedPreferences != savedPreferences { try preferences.save(updatedPreferences) }
        let suppressionDidChange = try suppression.records() != originalSuppression
        try write(records, appliedNames: Set(accepted.map { $0.0.recordName }))
        var observed = try readObserved()
        observed.favoriteOrder = updatedPreferences.favoriteOrder
        observed.pendingMappingIDs.formUnion(changedMappingIDs)
        observed.pendingIdentityIDs.formUnion(changedIdentityIDs)
        var cleared = observed.clearedIdentityHintFingerprints ?? [:]
        for id in restoredHints { cleared[id] = nil }
        cleared.merge(clearedHints, uniquingKeysWith: { _, new in new })
        observed.clearedIdentityHintFingerprints = cleared.isEmpty ? nil : cleared
        observed.libraryReviewIDs?.subtract(changedLibraryIDs)
        for (key, _) in accepted {
            if key.kind == .library { observed.pendingLibraryIDs.insert(key.entityID) }
        }
        try writeObserved(observed)
        report.appliedCount = accepted.count
        let reportRevision = try preparedJournalRevision()
        try populatePending(
            records, configuration: configuration, report: &report,
            includeLibrarySnapshots: includeLibrarySnapshots
        )
        guard isCurrentJournalRevision(reportRevision) else { throw PreparationError.journalChanged }
        report.journalRevision = reportRevision
        if report.appliedCount > 0 {
            NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidChange, object: profileID)
            if originalConfiguration != configuration || updatedPreferences != savedPreferences || suppressionDidChange {
                NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidApply, object: profileID)
            }
        }
        completed = true
        return report
    }

    public func pending(
        sourceStore: any LiveTVSourcesStoring, includeLibrarySnapshots: Bool = true
    ) throws -> LiveTVPortableImport {
        coordinator.operationLock.lock()
        defer { coordinator.operationLock.unlock() }
        let records = try readRecords()
        _ = try readObserved()
        let reportRevision = try preparedJournalRevision()
        let configuration = try sourceStore.load()
        guard isCurrentJournalRevision(reportRevision) else { throw PreparationError.journalChanged }
        var report = LiveTVPortableImport()
        try populatePending(
            records, configuration: configuration, report: &report,
            includeLibrarySnapshots: includeLibrarySnapshots
        )
        guard isCurrentJournalRevision(reportRevision) else { throw PreparationError.journalChanged }
        report.journalRevision = reportRevision
        return report
    }

    /// Final synchronous Save guard for one known playlist descriptor. Unlike a
    /// full pending report, this bounded lookup is allowed without preparation:
    /// it reads at most that source's wrapper, never observations or snapshots.
    /// Local setup and authority still belong to the caller and its source store.
    public func pendingPlaylistDescriptor(
        sourceID: String, sourceStore: any LiveTVSourcesStoring
    ) throws -> LiveTVPortableSource? {
        coordinator.operationLock.lock()
        defer { coordinator.operationLock.unlock() }
        guard !sourceID.isEmpty, sourceID.utf8.count <= 1_024,
              !profileID.isEmpty, profileID.utf8.count <= 512 else {
            throw LiveTVPortableStateError.invalidRecord
        }
        let recordKey = key(.source, sourceID)
        guard LiveTVPortableRecordKey.parse(recordKey.recordName) == recordKey else {
            throw LiveTVPortableStateError.invalidRecord
        }
        try ensureCurrentPreparation()
        let configuration = try sourceStore.load()
        try configuration.validate()
        try ensureCurrentPreparation()
        guard !configuration.playlists.contains(where: { $0.id == sourceID }) else { return nil }
        let record: LiveTVPortableRecord
        if let journal = preparedJournal?.journal {
            guard let cached = journal.decoded[recordKey.recordName] else { return nil }
            record = cached
        } else {
            let url = directory.appendingPathComponent(Self.digest(recordKey.recordName))
                .appendingPathExtension("record")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= LiveTVPortableRecord.maximumBytes * 2 else { throw LiveTVPortableStateError.tooLarge }
            let data = try Data(contentsOf: url)
            guard data.count <= LiveTVPortableRecord.maximumBytes * 2 else { throw LiveTVPortableStateError.tooLarge }
            let stored = try JSONDecoder().decode(StoredRecord.self, from: data)
            guard stored.name == recordKey.recordName else { throw LiveTVPortableStateError.wrongProfile }
            record = try decodedRecord(stored.value, key: recordKey, allowUnpreparedSource: true)
        }
        try ensureCurrentPreparation()
        guard !record.isDeleted, let source = record.source, source.kind == .playlist else { return nil }
        return source
    }

    /// Called by the existing CloudKit account-change hook. Local sources and
    /// preferences remain intact, but the new household needs fresh opt-in.
    public func resetForAccountChange() throws {
        coordinator.operationLock.lock()
        defer { coordinator.operationLock.unlock() }
        preparationID = UUID()
        discardPreparedJournalLocked()
        LiveTVPortableSyncPreferenceStore(defaults: defaults, profileID: profileID, namespace: namespace).isEnabled = false
        try mutateJournal {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
    }

    public func deferredGuideMappings() throws -> [String: LiveTVPortableGuideMapping?] {
        coordinator.operationLock.lock()
        defer { coordinator.operationLock.unlock() }
        let ids = try readObserved().pendingMappingIDs
        guard !ids.isEmpty else { return [:] }
        var mappings: [String: LiveTVPortableGuideMapping?] = [:]
        for id in ids {
            let key = key(.channel, id)
            guard let record = try readRecord(key) else { continue }
            mappings.updateValue(record.channel?.guideMapping, forKey: id)
        }
        return mappings
    }

    public func acknowledgeMappings(_ ids: Set<String>) throws {
        coordinator.operationLock.lock()
        defer { coordinator.operationLock.unlock() }
        var observed = try readObserved()
        observed.pendingMappingIDs.subtract(ids)
        try writeObserved(observed)
    }

    public func deferredIdentityHints() throws -> [String: LiveTVPortableChannelIdentityHint?] {
        coordinator.operationLock.lock()
        defer { coordinator.operationLock.unlock() }
        let ids = try readObserved().pendingIdentityIDs
        guard !ids.isEmpty else { return [:] }
        var hints: [String: LiveTVPortableChannelIdentityHint?] = [:]
        for id in ids {
            let key = key(.channel, id)
            guard let record = try readRecord(key) else { continue }
            hints.updateValue(record.channel?.identityHint, forKey: id)
        }
        return hints
    }

    public func acknowledgeIdentityHints(_ ids: Set<String>) throws {
        coordinator.operationLock.lock()
        defer { coordinator.operationLock.unlock() }
        var observed = try readObserved()
        observed.pendingIdentityIDs.subtract(ids)
        try writeObserved(observed)
    }

    public func acknowledgeLibraries(_ ids: Set<UUID>) throws {
        coordinator.operationLock.lock()
        defer { coordinator.operationLock.unlock() }
        var observed = try readObserved()
        observed.pendingLibraryIDs.subtract(ids.map(\.uuidString))
        observed.libraryReviewIDs?.subtract(ids.map(\.uuidString))
        try writeObserved(observed)
    }

    /// Check and acknowledge under the same journal lock. False means the report
    /// became obsolete; do not acknowledge its IDs using a newly acquired token.
    /// Batch review IDs here when one report contains both outcomes.
    @discardableResult
    public func acknowledgeLibraries(
        _ ids: Set<UUID>, markingForReview reviewIDs: Set<UUID> = [], ifCurrent token: JournalRevision
    ) throws -> Bool {
        coordinator.operationLock.lock()
        defer { coordinator.operationLock.unlock() }
        guard isCurrentJournalRevision(token) else { return false }
        guard !ids.isEmpty || !reviewIDs.isEmpty else { return true }
        var observed = try readObserved()
        let acknowledged = Set(ids.map(\.uuidString))
        observed.pendingLibraryIDs.subtract(acknowledged)
        observed.libraryReviewIDs?.subtract(acknowledged)
        if !reviewIDs.isEmpty {
            observed.libraryReviewIDs = (observed.libraryReviewIDs ?? [])
                .union(reviewIDs.map(\.uuidString)).subtracting(acknowledged)
        }
        try writeObserved(observed)
        return true
    }

    public func markLibrariesForReview(_ ids: Set<UUID>) throws {
        coordinator.operationLock.lock()
        defer { coordinator.operationLock.unlock() }
        var observed = try readObserved()
        observed.libraryReviewIDs = (observed.libraryReviewIDs ?? []).union(ids.map(\.uuidString))
        try writeObserved(observed)
    }

    @discardableResult
    public func markLibrariesForReview(_ ids: Set<UUID>, ifCurrent token: JournalRevision) throws -> Bool {
        try acknowledgeLibraries([], markingForReview: ids, ifCurrent: token)
    }

    private func applySource(
        _ record: LiveTVPortableRecord, id: String, configuration: inout LiveTVSourcesConfiguration
    ) {
        if record.isDeleted {
            configuration.playlists.removeAll { $0.id == id }
            configuration.servers.removeAll { $0.id == id }
            return
        }
        guard let source = record.source else { return }
        if source.kind == .playlist || source.kind == .importedPlaylist,
           let index = configuration.playlists.firstIndex(where: { $0.id == id }) {
            let expected: LiveTVPortableSource.Kind = configuration.playlists[index].importedPlaylistID == nil
                ? .playlist : .importedPlaylist
            guard source.kind == expected else { return }
            configuration.playlists[index].name = source.name
            configuration.playlists[index].isEnabled = source.isEnabled
            configuration.playlists[index].discoversPlaylistGuides = source.discoversPlaylistGuides ?? true
            configuration.playlists[index].guideLookbackDays = source.guideLookbackDays ?? 1
            configuration.playlists[index].guideLookaheadDays = source.guideLookaheadDays ?? 7
        } else if source.kind == .server,
                  let index = configuration.servers.firstIndex(where: { $0.id == id }),
                  configuration.servers[index].accountID == source.accountID {
            // A descriptor cannot retarget an existing authorization or enroll an
            // account. Native authorized server discovery owns those decisions.
            configuration.servers[index].name = source.name
            configuration.servers[index].isEnabled = source.isEnabled
        }
    }

    private func populatePending(
        _ records: [String: Data], configuration: LiveTVSourcesConfiguration,
        report: inout LiveTVPortableImport, includeLibrarySnapshots: Bool
    ) throws {
        var parts: [UUID: [LiveTVPortableSnapshotPart]] = [:]
        var definitions: [LibraryChannelDefinition] = []
        let observed = try readObserved()
        let pendingLibraryIDs = observed.pendingLibraryIDs
        report.libraryReviewIDs = Set((observed.libraryReviewIDs ?? [])
            .intersection(pendingLibraryIDs).compactMap(UUID.init(uuidString:)))
        let localPlaylists = Set(configuration.playlists.map(\.id))
        let names = records.keys.sorted()
        for name in names {
            guard let bytes = records[name], let recordKey = LiveTVPortableRecordKey.parse(name) else { continue }
            guard recordKey.kind == .source
                || (recordKey.kind == .library && pendingLibraryIDs.contains(recordKey.entityID)) else { continue }
            let record = try decodedRecord(bytes, key: recordKey)
            if let source = record.source, source.kind == .playlist, !localPlaylists.contains(recordKey.entityID) {
                report.pendingPlaylists[recordKey.entityID] = source
            }
            if let source = record.source, source.kind == .importedPlaylist,
               !localPlaylists.contains(recordKey.entityID) {
                report.localFileSources[recordKey.entityID] = source
            }
            if recordKey.kind == .library, pendingLibraryIDs.contains(recordKey.entityID),
               record.isDeleted, let id = UUID(uuidString: recordKey.entityID) {
                report.deletedLibraryIDs.insert(id)
            }
            if let definition = record.library, pendingLibraryIDs.contains(recordKey.entityID) {
                definitions.append(definition)
                if !definition.isEnabled { report.disabledLibraryIDs.insert(definition.id) }
            }
        }
        let requiredSnapshots = Set(definitions.flatMap(\.revisions).map(\.snapshotID))
        if !requiredSnapshots.isEmpty {
            for name in names {
                guard let bytes = records[name], let key = LiveTVPortableRecordKey.parse(name), key.kind == .snapshot,
                      let part = try decodedRecord(bytes, key: key).snapshot,
                      requiredSnapshots.contains(part.snapshotID) else { continue }
                parts[part.snapshotID, default: []].append(part)
            }
        }
        report.snapshotParts = parts
        report.pendingDefinitions = definitions
        if includeLibrarySnapshots { report = report.resolvingLibrarySnapshots() }
    }

    private func localValueIsUnchanged(
        key: LiveTVPortableRecordKey, previous: LiveTVPortableRecord,
        configuration: LiveTVSourcesConfiguration, preferences: LiveTVPreferences,
        libraries: [LibraryChannelDefinition]?,
        mappings: [String: LiveTVPortableGuideMapping]?,
        unresolvedMappingIDs: Set<String>,
        hints: [String: LiveTVPortableChannelIdentityHint]?, observed: ObservedLocal
    ) throws -> Bool {
        let id = key.entityID
        switch key.kind {
        case .channel:
            let hidden = preferences.hiddenChannels.first { $0.id == id }?.name
            let favoriteName = preferences.favoriteChannels.first { $0.id == id }?.name
            let mapping = observed.pendingMappingIDs.contains(id) || unresolvedMappingIDs.contains(id)
                ? previous.channel?.guideMapping : mappings.map { $0[id] } ?? previous.channel?.guideMapping
            let hint = Self.capturedIdentityHint(
                id: id, local: hints?[id], previous: previous.channel?.identityHint, observed: observed
            )
            if previous.isDeleted, !preferences.favoriteIDs.contains(id), hidden == nil,
               preferences.channelOverrides[id] == nil, mapping == nil, hint == nil { return true }
            let position = observed.favoriteOrder == preferences.favoriteOrder
                ? previous.channel?.favoritePosition : preferences.favoriteOrder.firstIndex(of: id)
            return previous == LiveTVPortableRecord(channel: .init(
                isFavorite: preferences.favoriteIDs.contains(id), hiddenName: hidden,
                favoriteName: favoriteName, favoritePosition: preferences.favoriteIDs.contains(id) ? position : nil,
                metadata: preferences.channelOverrides[id],
                guideMapping: mapping, identityHint: hint
            ))
        case .source:
            if let source = configuration.playlists.first(where: { $0.id == id }) {
                return previous.source == LiveTVPortableSource(
                    kind: source.importedPlaylistID == nil ? .playlist : .importedPlaylist,
                    name: source.name, isEnabled: source.isEnabled,
                    discoversPlaylistGuides: source.discoversPlaylistGuides,
                    guideLookbackDays: source.guideLookbackDays, guideLookaheadDays: source.guideLookaheadDays
                )
            }
            if let source = configuration.servers.first(where: { $0.id == id }) {
                return previous.source == LiveTVPortableSource(
                    kind: .server, name: source.name, isEnabled: source.isEnabled, accountID: source.accountID
                )
            }
            return previous.isDeleted || !observed.sourceIDs.contains(id)
        case .library:
            guard let libraries else { return true }
            if observed.pendingLibraryIDs.contains(id) { return true }
            if let definition = libraries.first(where: { $0.id.uuidString == id }) {
                return previous.library == definition
            }
            return previous.isDeleted || !observed.libraryIDs.contains(id)
        case .snapshot:
            return true
        case .serverEnrollment:
            let current = try suppression.records()[id]
            return current == nil || previous.serverEnrollmentSuppressed == current
        }
    }

    private func key(_ kind: LiveTVPortableRecordKey.Kind, _ id: String) -> LiveTVPortableRecordKey {
        .init(profileID: profileID, kind: kind, entityID: id)
    }

    private var suppression: LiveTVServerEnrollmentSuppressionStore {
        LiveTVServerEnrollmentSuppressionStore(defaults: defaults, profileID: profileID, namespace: namespace)
    }

    private var consent: LiveTVPortableSyncPreferenceStore {
        LiveTVPortableSyncPreferenceStore(defaults: defaults, profileID: profileID, namespace: namespace)
    }

    private func sourceConfiguration(_ store: any LiveTVSourcesStoring) throws -> LiveTVSourcesConfiguration {
        if let policyStore = store as? any LiveTVPortableSourcesStoring {
            return try policyStore.loadSyncConfiguration()
        }
        return try store.load()
    }

    private func scoped(_ records: [String: Data]) -> [String: Data] {
        records.filter { LiveTVPortableRecordKey.parse($0.key)?.profileID == profileID }
    }

    private func put(
        _ record: LiveTVPortableRecord, key: LiveTVPortableRecordKey, into records: inout [String: Data]
    ) throws {
        try record.validate(key: key)
        if let original = records[key.recordName],
           try decodedRecord(original, key: key) == record { return }
        let bytes = try record.encoded()
        try cacheLocal(record, bytes: bytes, key: key)
        records[key.recordName] = bytes
    }

    private func tombstoneBytes(key: LiveTVPortableRecordKey) throws -> Data {
        let record = LiveTVPortableRecord(isDeleted: true)
        try record.validate(key: key)
        let bytes = try record.encoded()
        try cacheLocal(record, bytes: bytes, key: key)
        return bytes
    }

    private func cacheLocal(
        _ record: LiveTVPortableRecord, bytes: Data, key: LiveTVPortableRecordKey
    ) throws {
        try ensureCurrentPreparation()
        let count = (preparedJournal?.localBytes ?? 0)
            - (preparedJournal?.local[key.recordName]?.bytes.count ?? 0) + bytes.count
        guard count <= Self.maximumInputBytes,
              preparedJournal?.local[key.recordName] != nil
                || (preparedJournal?.local.count ?? 0) < Self.maximumRecords else {
            // Legacy synchronous callers can still decode on demand; a cache
            // capacity limit must not turn their otherwise valid record into a rejection.
            guard requiresPreparedJournal else { return }
            throw LiveTVPortableStateError.tooLarge
        }
        preparedJournal?.local[key.recordName] = ValidatedRecord(bytes: bytes, value: record)
        preparedJournal?.localBytes = count
    }

    private func cacheIncoming(
        _ record: LiveTVPortableRecord?, bytes: Data, key: LiveTVPortableRecordKey
    ) {
        let cached = ValidatedRecord(bytes: bytes, value: record)
        let count = (preparedJournal?.incomingBytes ?? 0)
            - (preparedJournal?.incoming[key.recordName]?.bytes.count ?? 0) + cached.bytes.count
        guard count <= Self.maximumInputBytes,
              preparedJournal?.incoming[key.recordName] != nil
                || (preparedJournal?.incoming.count ?? 0)
                    + (preparedJournal?.retainedIncoming.count ?? 0) < Self.maximumRecords else { return }
        preparedJournal?.incoming[key.recordName] = cached
        preparedJournal?.incomingBytes = count
    }

    private func cachedRecord(_ bytes: Data, key: LiveTVPortableRecordKey) -> ValidatedRecord? {
        let name = key.recordName
        if preparedJournal?.journal?.records[name] == bytes,
           let value = preparedJournal?.journal?.decoded[name] {
            return ValidatedRecord(bytes: bytes, value: value)
        }
        if let value = preparedJournal?.incoming[name], value.matches(bytes) { return value }
        if let value = preparedJournal?.retainedIncoming[name], value.matches(bytes) { return value }
        if let value = preparedJournal?.local[name], value.bytes == bytes { return value }
        return nil
    }

    private func decodedRecord(
        _ bytes: Data, key: LiveTVPortableRecordKey, allowUnpreparedSource: Bool = false
    ) throws -> LiveTVPortableRecord {
        try ensureCurrentPreparation()
        guard bytes.count <= LiveTVPortableRecord.maximumBytes else { throw LiveTVPortableStateError.tooLarge }
        if let cached = cachedRecord(bytes, key: key) {
            guard let value = cached.value else { throw LiveTVPortableStateError.invalidRecord }
            return value
        }
        guard !requiresPreparedJournal || (allowUnpreparedSource && key.kind == .source) else {
            throw PreparationError.preparationRequired
        }
        let value: LiveTVPortableRecord
        do {
            value = try LiveTVPortableRecord.decode(bytes, key: key)
        } catch {
            cacheIncoming(nil, bytes: bytes, key: key)
            throw error
        }
        cacheIncoming(value, bytes: bytes, key: key)
        return value
    }

    /// Missing preparation must throw before apply can turn a cache miss into a
    /// rejected record or persist a receipt / partially change a local store.
    private func requirePreparedInputs(_ records: [String: Data?]) throws {
        guard requiresPreparedJournal else { return }
        for (name, bytes) in records {
            guard let key = LiveTVPortableRecordKey.parse(name), key.profileID == profileID,
                  let bytes, bytes.count <= LiveTVPortableRecord.maximumBytes else { continue }
            guard cachedRecord(bytes, key: key) != nil else { throw PreparationError.preparationRequired }
        }
    }

    private func ensureCurrentPreparation() throws {
        guard accountEpoch == LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults) else {
            discardPreparedJournalLocked()
            throw PreparationError.accountChanged
        }
        let fence = coordinator.snapshot()
        if preparedJournal?.revision != fence.revision || fence.writing {
            discardPreparedJournalLocked()
        }
        if preparedJournal == nil {
            preparedJournal = PreparedJournal(revision: fence.revision)
        }
    }

    private func discardPreparedJournalLocked() {
        guard let retired = preparedJournal else { return }
        preparedJournal = nil
        Self.releaseOffMain(retired)
    }

    private static func releaseOffMain(_ retired: PreparedJournal) {
        DispatchQueue.global(qos: .utility).async {
            withExtendedLifetime(retired) {}
        }
    }

    private func prepareJournal(records inputs: [String: Data?], request: UUID) throws {
        try Task.checkCancellation()
        for _ in 0..<3 {
            try Task.checkCancellation()
            let fence = coordinator.snapshot()
            guard !fence.writing else { continue }
            do {
                var prepared = try preparationSnapshot(request: request, revision: fence.revision)
                if prepared.journal == nil { prepared.journal = try loadJournal() }
                if prepared.observed == nil { prepared.observed = try loadObserved() }
                var incoming: [String: ValidatedRecord] = [:]
                var retained: [String: ValidatedRecord] = [:]
                var total = 0
                var validCount = 0
                var rejectedCount = 0
                for (name, input) in inputs {
                    try Task.checkCancellation()
                    guard let key = LiveTVPortableRecordKey.parse(name), key.profileID == profileID else { continue }
                    // Nil changes are trusted tombstones. Oversized records can
                    // be rejected by byte count at apply's per-record catch site
                    // without retaining them or spending the valid inputs' budget.
                    guard let bytes = input, bytes.count <= LiveTVPortableRecord.maximumBytes else { continue }
                    if prepared.journal?.records[name] == bytes { continue }
                    let entry: ValidatedRecord
                    if let cached = prepared.incoming[name], cached.matches(bytes) {
                        entry = cached
                    } else if let cached = prepared.retainedIncoming[name], cached.matches(bytes) {
                        entry = cached
                    } else if let cached = prepared.local[name], cached.bytes == bytes {
                        entry = cached
                    } else {
                        let value = try? LiveTVPortableRecord.decode(bytes, key: key)
                        try Task.checkCancellation()
                        entry = ValidatedRecord(bytes: bytes, value: value)
                    }
                    total += entry.bytes.count
                    if entry.value == nil { rejectedCount += 1 } else { validCount += 1 }
                    guard total <= Self.maximumInputBytes, validCount <= Self.maximumRecords,
                          rejectedCount <= Self.maximumRecords else { throw LiveTVPortableStateError.tooLarge }
                    incoming[name] = entry
                }
                for previous in [prepared.incoming, prepared.retainedIncoming] {
                    for (name, entry) in previous {
                        try Task.checkCancellation()
                        if entry.value != nil, prepared.journal?.records[name] == entry.bytes { continue }
                        if let current = incoming[name],
                           current.hasSamePayload(as: entry) || retained[name] != nil { continue }
                        let fitsCount = entry.value == nil
                            ? rejectedCount < Self.maximumRecords : validCount < Self.maximumRecords
                        guard fitsCount, entry.bytes.count <= Self.maximumInputBytes - total else { continue }
                        if incoming[name] == nil { incoming[name] = entry }
                        else { retained[name] = entry }
                        total += entry.bytes.count
                        if entry.value == nil { rejectedCount += 1 } else { validCount += 1 }
                    }
                }
                prepared.incoming = incoming
                prepared.retainedIncoming = retained
                prepared.incomingBytes = total
                if try installPreparation(prepared, request: request) { return }
            } catch {
                try Task.checkCancellation()
                if error is PreparationError { throw error }
                let current = coordinator.snapshot()
                if current.revision != fence.revision || current.writing { continue }
                throw error
            }
        }
        throw PreparationError.journalChanged
    }

    private func beginPreparation() -> UUID {
        coordinator.operationLock.lock()
        defer { coordinator.operationLock.unlock() }
        preparationID = UUID()
        return preparationID
    }

    private func cancelPreparation(request: UUID) {
        coordinator.operationLock.lock()
        defer { coordinator.operationLock.unlock() }
        guard preparationID == request else { return }
        preparationID = UUID()
        discardPreparedJournalLocked()
    }

    private func preparationSnapshot(request: UUID, revision: UUID) throws -> PreparedJournal {
        coordinator.operationLock.lock()
        defer { coordinator.operationLock.unlock() }
        try Task.checkCancellation()
        guard preparationID == request else { throw PreparationError.preparationSuperseded }
        try ensureCurrentPreparation()
        if let preparedJournal, preparedJournal.revision == revision { return preparedJournal }
        return PreparedJournal(revision: revision)
    }

    private func installPreparation(_ prepared: PreparedJournal, request: UUID) throws -> Bool {
        coordinator.operationLock.lock()
        defer { coordinator.operationLock.unlock() }
        try Task.checkCancellation()
        guard preparationID == request else { throw PreparationError.preparationSuperseded }
        guard accountEpoch == LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults) else {
            throw PreparationError.accountChanged
        }
        let fence = coordinator.snapshot()
        guard !fence.writing, fence.revision == prepared.revision else { return false }
        discardPreparedJournalLocked()
        preparedJournal = prepared
        return true
    }

    private func readRecords() throws -> [String: Data] {
        try readJournal().records
    }

    private func readRecord(_ key: LiveTVPortableRecordKey) throws -> LiveTVPortableRecord? {
        try readJournal().decoded[key.recordName]
    }

    private func readJournal() throws -> Journal {
        try ensureCurrentPreparation()
        if let journal = preparedJournal?.journal { return journal }
        guard !requiresPreparedJournal else { throw PreparationError.preparationRequired }
        let journal = try loadJournal()
        preparedJournal?.journal = journal
        return journal
    }

    /// Called without the operation lock by preparation. A revision fence makes
    /// mixed/partially written snapshots unpublishable, including failed writes.
    private func loadJournal() throws -> Journal {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: directory.path) else { return Journal() }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "record" }
        guard files.count <= Self.maximumRecords else { throw LiveTVPortableStateError.tooLarge }
        var journal = Journal(directoryExists: true)
        var total = 0
        for file in files {
            try Task.checkCancellation()
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= LiveTVPortableRecord.maximumBytes * 2 else { throw LiveTVPortableStateError.tooLarge }
            guard size <= Self.maximumJournalBytes - total else { throw LiveTVPortableStateError.tooLarge }
            let data = try Data(contentsOf: file)
            guard data.count <= LiveTVPortableRecord.maximumBytes * 2,
                  data.count <= Self.maximumJournalBytes - total else { throw LiveTVPortableStateError.tooLarge }
            total += data.count
            let stored = try JSONDecoder().decode(StoredRecord.self, from: data)
            guard let recordKey = LiveTVPortableRecordKey.parse(stored.name),
                  recordKey.profileID == profileID,
                  file.deletingPathExtension().lastPathComponent == Self.digest(stored.name) else {
                throw LiveTVPortableStateError.wrongProfile
            }
            journal.decoded[stored.name] = try LiveTVPortableRecord.decode(stored.value, key: recordKey)
            journal.records[stored.name] = stored.value
            journal.stored[stored.name] = stored
        }
        return journal
    }

    private func write(
        _ records: [String: Data], appliedNames: Set<String> = [], receivedFingerprints: [String: String] = [:]
    ) throws {
        guard records.count <= Self.maximumRecords,
              records.values.reduce(0, { $0 + $1.count }) <= Self.maximumInputBytes else {
            throw LiveTVPortableStateError.tooLarge
        }
        var journal = try readJournal()
        let currentConsentRevision = consent.consentRevision
        var updates: [(StoredRecord, LiveTVPortableRecord?)] = []
        for (name, bytes) in records {
            let old = journal.stored[name]
            let payloadUnchanged = old?.name == name && old?.value == bytes
            let revision = appliedNames.contains(name) ? currentConsentRevision : old?.appliedConsentRevision
            let pending = receivedFingerprints[name] ?? (
                appliedNames.contains(name) || !payloadUnchanged ? nil : old?.pendingRemoteFingerprint
            )
            let stored = StoredRecord(
                name: name, value: bytes, appliedConsentRevision: revision, pendingRemoteFingerprint: pending
            )
            if payloadUnchanged, old?.appliedConsentRevision == revision,
               old?.pendingRemoteFingerprint == pending { continue }
            guard let key = LiveTVPortableRecordKey.parse(name), key.profileID == profileID else {
                throw LiveTVPortableStateError.wrongProfile
            }
            let value: LiveTVPortableRecord?
            if payloadUnchanged { value = nil }
            else { value = try decodedRecord(bytes, key: key) }
            updates.append((stored, value))
        }
        guard !updates.isEmpty || !journal.directoryExists else { return }
        let changesPayload = updates.contains { $0.1 != nil }
        try mutateJournal {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (stored, _) in updates {
                let url = directory.appendingPathComponent(Self.digest(stored.name)).appendingPathExtension("record")
                try JSONEncoder().encode(stored).write(to: url, options: .atomic)
            }
            for (stored, value) in updates {
                journal.stored[stored.name] = stored
                // Receipt-only updates must not copy the shared payload dictionaries.
                if let value {
                    journal.records[stored.name] = stored.value
                    journal.decoded[stored.name] = value
                }
            }
            journal.directoryExists = true
            if let revision = preparedJournal?.revision {
                let retired = PreparedJournal(
                    revision: revision, journal: preparedJournal?.journal,
                    local: changesPayload ? (preparedJournal?.local ?? [:]) : [:]
                )
                preparedJournal?.journal = journal
                if changesPayload {
                    preparedJournal?.local = [:]
                    preparedJournal?.localBytes = 0
                }
                Self.releaseOffMain(retired)
            }
        }
    }

    private func readObserved() throws -> ObservedLocal {
        try ensureCurrentPreparation()
        if let observed = preparedJournal?.observed { return observed }
        guard !requiresPreparedJournal else { throw PreparationError.preparationRequired }
        let observed = try loadObserved()
        preparedJournal?.observed = observed
        return observed
    }

    private func loadObserved() throws -> ObservedLocal {
        try Task.checkCancellation()
        let url = directory.appendingPathComponent("observed-local.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return ObservedLocal() }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 2 * 1_024 * 1_024 else { throw LiveTVPortableStateError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= 2 * 1_024 * 1_024 else { throw LiveTVPortableStateError.tooLarge }
        return try JSONDecoder().decode(ObservedLocal.self, from: data)
    }

    private func writeObserved(_ observed: ObservedLocal) throws {
        let data = try JSONEncoder().encode(observed)
        guard data.count <= 2 * 1_024 * 1_024 else { throw LiveTVPortableStateError.tooLarge }
        try mutateJournal {
            try data.write(to: directory.appendingPathComponent("observed-local.json"), options: .atomic)
            preparedJournal?.observed = observed
        }
    }

    private func mutateJournal(_ operation: () throws -> Void) throws {
        let revision = coordinator.beginWrite()
        do {
            try operation()
            coordinator.endWrite()
            preparedJournal?.revision = revision
        } catch {
            coordinator.endWrite()
            discardPreparedJournalLocked()
            throw error
        }
    }

    private func invalidateAfterFailedOperation() {
        _ = coordinator.beginWrite()
        coordinator.endWrite()
        discardPreparedJournalLocked()
    }

    private static func capturedIdentityHint(
        id: String, local: LiveTVPortableChannelIdentityHint?, previous: LiveTVPortableChannelIdentityHint?,
        observed: ObservedLocal
    ) -> LiveTVPortableChannelIdentityHint? {
        guard !observed.pendingIdentityIDs.contains(id), let local else { return previous }
        // An unchanged downloaded catalog must not echo an explicitly removed
        // association back into sync. Different evidence may establish a new one.
        guard observed.clearedIdentityHintFingerprints?[id] != hintFingerprint(local) else { return previous }
        return local
    }

    private static func hintFingerprint(_ hint: LiveTVPortableChannelIdentityHint) -> String {
        digest(hint.sourceID + "\u{1F}" + hint.nativeID)
    }

    private static func digest(_ value: String) -> String {
        digest(Data(value.utf8))
    }

    private static func digest(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }
}
