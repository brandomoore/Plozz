import CoreModels
import CoreNetworking
import CoreSecureStore
import FeatureLiveTVCore
import Foundation
import Observation

/// Shared composition for both shells. Portable state and encrypted source
/// transfer are separate channels on the existing CloudKit engine.
@MainActor
@Observable
public final class LiveTVPortableSyncBridge {
    public enum Status: Equatable, Sendable {
        case localOnly, ready, unavailable
        case pendingLibraryInputs, pendingLibraryReview
        case pendingSetup(Int)
        case pendingSchedules(Int)
        case pendingChannelMatches(Int)
    }

    public private(set) var statuses: [String: Status] = [:]
    @ObservationIgnored private let profiles: ProfilesModel
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let followsMainSync: Bool
    @ObservationIgnored public lazy var sourceSync = LiveTVSourceSyncBridge(
        profiles: profiles, defaults: defaults, store: sourceStore, cache: LiveTVCatalogStorage.cache
    )
    @ObservationIgnored private let sourceStore: @MainActor (String) -> any LiveTVSourcesStoring
    @ObservationIgnored private let definitions: (@MainActor (String) -> any LibraryChannelDefinitionStoring)?
    @ObservationIgnored private let snapshots: (any LibraryChannelSnapshotStoring)?
    @ObservationIgnored private let guideCache: @MainActor (String) -> LiveTVIndexedCache?
    @ObservationIgnored private let captureIdentityHints: @MainActor (String) async throws -> [String: LiveTVPortableChannelIdentityHint]?
    @ObservationIgnored private let applyIdentityHints: @MainActor (String, [String: LiveTVPortableChannelIdentityHint?]) async throws -> Bool
    @ObservationIgnored private let libraryPreparation = LiveTVPortableLibraryPreparation()
    @ObservationIgnored private var operationInProgress = false
    @ObservationIgnored private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var operationAuthority: [String: ProfileAuthority] = [:]
    @ObservationIgnored private var operationAdapters: [String: LiveTVPortableSyncAdapter] = [:]
    @ObservationIgnored private var diagnosticFailures: [String: LiveTVSyncDiagnostic] = [:]

    private struct ProfileAuthority: Equatable {
        let namespace: String?
        let consentRevision: String
    }

    public init(
        profiles: ProfilesModel, directory: URL, defaults: UserDefaults = .standard,
        followsMainSync: Bool = false,
        sourceStore: (@MainActor (String) -> any LiveTVSourcesStoring)? = nil,
        definitions: (@MainActor (String) -> any LibraryChannelDefinitionStoring)? = nil,
        snapshots: (any LibraryChannelSnapshotStoring)? = nil,
        guideCache: @escaping @MainActor (String) -> LiveTVIndexedCache? = { _ in nil },
        captureIdentityHints: @escaping @MainActor (String) async throws -> [String: LiveTVPortableChannelIdentityHint]? = { _ in nil },
        applyIdentityHints: @escaping @MainActor (String, [String: LiveTVPortableChannelIdentityHint?]) async throws -> Bool = { _, _ in false }
    ) {
        self.profiles = profiles
        self.directory = directory
        self.defaults = defaults
        self.followsMainSync = followsMainSync
        self.sourceStore = sourceStore ?? { profileID in
            LiveTVSourceStorage.approvalAwareStore(
                profileID: profileID,
                namespace: profileID == profiles.rootNamespaceOwnerID ? nil : profileID
            )
        }
        self.definitions = definitions
        self.snapshots = snapshots
        self.guideCache = guideCache
        self.captureIdentityHints = captureIdentityHints
        self.applyIdentityHints = applyIdentityHints
    }

    public func capture(fallback: [SyncRecordID: Data]) async -> [SyncRecordID: Data] {
        let epoch = LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults)
        let authority = currentAuthority()
        await beginOperation()
        defer { endOperation() }
        operationAuthority = authority
        guard epoch == LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults) else { return [:] }
        guard !Task.isCancelled else { return fallback }
        return await captureSerially(fallback: fallback)
    }

    private func captureSerially(fallback: [SyncRecordID: Data]) async -> [SyncRecordID: Data] {
        let epoch = LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults)
        let incomingRecords = fallback.mapValues(Optional.some)
        var result = fallback
        let removed: Set<String>
        do { removed = try removedProfiles() }
        catch {
            recordFailure(error, operation: .capture, stage: .removedProfiles)
            return fallback
        }
        clearDiagnosticFailures(.capture, profileID: "")
        if !removed.isEmpty {
            result = result.filter {
                guard let key = LiveTVPortableRecordKey.parse($0.key) else { return true }
                return !removed.contains(key.profileID)
            }
        }
        for profile in profiles.profiles where !removed.contains(profile.id) {
            guard epoch == LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults) else { return [:] }
            let adapter = adapter(profile.id)
            guard adapter.isEnabled else {
                statuses[profile.id] = .localOnly
                continue
            }
            guard mayApply(profile.id, epoch: epoch) else { continue }
            var stage = trace(.capture, .prepareJournal)
            do {
                try await prepare(adapter, profileID: profile.id, epoch: epoch, records: incomingRecords)
                var libraryIssue: Status?
                stage = trace(.capture, .libraryState)
                let deferred = try await pendingLibraryState(adapter, profileID: profile.id, epoch: epoch)
                guard mayApply(profile.id, epoch: epoch) else { continue }
                do { try await applyLibrary(deferred, profileID: profile.id, epoch: epoch) }
                catch {
                    libraryIssue = Self.libraryStatus(for: error)
                    recordFailure(error, operation: .capture, stage: stage, profileID: profile.id)
                }
                stage = trace(.capture, .identities)
                try await applyDeferredIdentities(adapter, profileID: profile.id, epoch: epoch)
                stage = trace(.capture, .guideMappings)
                try await applyDeferredMappings(adapter, profileID: profile.id, epoch: epoch)
                guard mayApply(profile.id, epoch: epoch) else { continue }
                var libraryState: LiveTVPortableLibraryExport?
                stage = trace(.capture, .libraryState)
                do { libraryState = try await captureLibraryState(profileID: profile.id, epoch: epoch) }
                catch {
                    libraryIssue = Self.libraryStatus(for: error)
                    recordFailure(error, operation: .capture, stage: stage, profileID: profile.id)
                }
                guard mayApply(profile.id, epoch: epoch) else { continue }
                stage = trace(.capture, .guideMappings)
                let cache = guideCache(profile.id)
                let mappingAuthority = try cache.map { _ in try guideAuthority(profile.id) }
                let mappings: LiveTVPortableGuideMappingExport?
                if let cache, let mappingAuthority {
                    mappings = try await cache.portableSyncGuideMappings(configuration: mappingAuthority.configuration)
                } else {
                    mappings = nil
                }
                stage = trace(.capture, .identities)
                let identities = try await captureIdentityHints(profile.id)
                guard mayApply(profile.id, epoch: epoch) else { continue }
                stage = trace(.capture, .prepareJournal)
                try await prepare(
                    adapter, profileID: profile.id, epoch: epoch,
                    records: incomingRecords, preparedLibrary: libraryState
                )
                if let mappingAuthority {
                    guard try guideAuthority(profile.id) == mappingAuthority else { continue }
                }
                if let state = libraryState,
                   try definitions?(profile.id).load() != state.state.definitions {
                    libraryState = nil
                    libraryIssue = .pendingLibraryReview
                }
                stage = trace(.capture, .captureRecords)
                let captured = try await adapter.committingJournal {
                    guard mayApply(profile.id, epoch: epoch) else { throw CancellationError() }
                    return try adapter.capture(
                        sourceStore: sourceStore(profile.id), libraryDefinitions: libraryState?.state.definitions,
                        snapshots: libraryState?.state.snapshots ?? [], preparedLibrary: libraryState,
                        guideMappings: mappings?.mappings,
                        unresolvedGuideMappingIDs: mappings?.unresolvedChannelIDs ?? [],
                        identityHints: identities?.filter {
                            mappingAuthority?.authorization.allowsPlaylist($0.value.sourceID) ?? true
                        }, fallback: fallback
                    )
                }
                guard mayApply(profile.id, epoch: epoch) else { continue }
                stage = trace(.capture, .identities)
                try await applyDeferredIdentities(adapter, profileID: profile.id, epoch: epoch)
                stage = trace(.capture, .guideMappings)
                try await applyDeferredMappings(adapter, profileID: profile.id, epoch: epoch)
                guard mayApply(profile.id, epoch: epoch) else { continue }
                stage = trace(.capture, .libraryState)
                let pending = try await pendingLibraryState(adapter, profileID: profile.id, epoch: epoch)
                guard mayApply(profile.id, epoch: epoch) else { continue }
                do { try await applyLibrary(pending, profileID: profile.id, epoch: epoch) }
                catch {
                    libraryIssue = Self.libraryStatus(for: error)
                    recordFailure(error, operation: .capture, stage: stage, profileID: profile.id)
                }
                guard mayApply(profile.id, epoch: epoch) else { continue }
                result.merge(captured, uniquingKeysWith: { _, new in new })
                stage = trace(.capture, .validateRecords)
                try await updateStatus(pending, profileID: profile.id, epoch: epoch, operation: .capture)
                if let libraryIssue { statuses[profile.id] = libraryIssue }
                finishDiagnostic(.capture, profileID: profile.id)
            } catch {
                if error is CancellationError { continue }
                if mayApply(profile.id, epoch: epoch) {
                    statuses[profile.id] = .unavailable
                    recordFailure(error, operation: .capture, stage: stage, profileID: profile.id)
                }
            }
        }
        guard epoch == LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults) else { return [:] }
        let latestRemoved: Set<String>
        do { latestRemoved = try removedProfiles() }
        catch {
            recordFailure(error, operation: .capture, stage: .removedProfiles)
            return fallback
        }
        guard !latestRemoved.isEmpty else { return result }
        return result.filter {
            guard let key = LiveTVPortableRecordKey.parse($0.key) else { return true }
            return !latestRemoved.contains(key.profileID)
        }
    }

    public func apply(_ changes: SyncLocalChanges) async {
        let epoch = LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults)
        let authority = currentAuthority()
        await beginOperation()
        defer { endOperation() }
        operationAuthority = authority
        guard !Task.isCancelled,
              epoch == LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults) else { return }
        await applySerially(changes, epoch: epoch)
    }

    private func applySerially(_ changes: SyncLocalChanges, epoch: String) async {
        let known = Set(profiles.profiles.map(\.id))
        let removed: Set<String>
        do { removed = try removedProfiles() }
        catch {
            recordFailure(error, operation: .apply, stage: .removedProfiles)
            return
        }
        clearDiagnosticFailures(.apply, profileID: "")
        let profileIDs = Set(changes.keys.compactMap(LiveTVPortableRecordKey.parse).map(\.profileID))
        for profileID in profileIDs.sorted() where known.contains(profileID) && !removed.contains(profileID) {
            guard epoch == LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults) else { return }
            let adapter = adapter(profileID)
            guard adapter.isEnabled else {
                statuses[profileID] = .localOnly
                continue
            }
            guard mayApply(profileID, epoch: epoch) else { continue }
            var stage = trace(.apply, .prepareJournal)
            do {
                try await prepare(adapter, profileID: profileID, epoch: epoch, records: changes)
                stage = trace(.apply, .applyRecords)
                let pending = try await adapter.committingJournal {
                    guard mayApply(profileID, epoch: epoch) else { throw CancellationError() }
                    return try adapter.apply(
                        changes, sourceStore: sourceStore(profileID), includeLibrarySnapshots: false
                    )
                }
                guard mayApply(profileID, epoch: epoch) else { continue }
                stage = trace(.apply, .libraryState)
                if let definitions {
                    try await applyLibraryRevocations(pending, profileID: profileID, store: definitions(profileID))
                }
                let report = await libraryPreparation.resolve(pending)
                guard mayApply(profileID, epoch: epoch) else { continue }
                stage = trace(.apply, .identities)
                try await applyDeferredIdentities(adapter, profileID: profileID, epoch: epoch)
                stage = trace(.apply, .guideMappings)
                try await applyDeferredMappings(adapter, profileID: profileID, epoch: epoch)
                stage = trace(.apply, .libraryState)
                try await applyLibrary(report, profileID: profileID, epoch: epoch)
                guard mayApply(profileID, epoch: epoch) else { continue }
                stage = trace(.apply, .validateRecords)
                try await updateStatus(report, profileID: profileID, epoch: epoch, operation: .apply)
                finishDiagnostic(.apply, profileID: profileID)
            } catch {
                if error is CancellationError { continue }
                if mayApply(profileID, epoch: epoch) {
                    statuses[profileID] = Self.libraryStatus(for: error)
                    recordFailure(error, operation: .apply, stage: stage, profileID: profileID)
                }
            }
        }
    }

    /// Wire to the existing profile removal lifecycle, not to a transient missing
    /// profile roster during cloud hydration.
    public func removeProfile(_ profileID: String) throws {
        if followsMainSync { try sourceSync.removeProfile(profileID) }
        var removed = try removedProfiles()
        removed.insert(profileID)
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(removed.sorted()).write(
            to: metadataDirectory.appendingPathComponent("removed-profiles.json"), options: .atomic
        )
        try adapter(profileID).resetForAccountChange()
        statuses.removeValue(forKey: profileID)
        clearDiagnosticFailures(.capture, profileID: profileID)
        clearDiagnosticFailures(.apply, profileID: profileID)
    }

    public func accountDidChange() {
        LiveTVPortableSyncPreferenceStore.accountDidChange(defaults: defaults)
        if followsMainSync { sourceSync.accountDidChange() }
        Task { await libraryPreparation.discardExport() }
        statuses = [:]
        diagnosticFailures = [:]
        for profile in profiles.profiles {
            statuses[profile.id] = .localOnly
        }
    }

    public func sourceSetupStore(profileID: String) -> (any LiveTVSourcesStoring)? {
        guard profiles.profiles.contains(where: { $0.id == profileID }),
              (try? removedProfiles().contains(profileID)) == false else { return nil }
        return sourceStore(profileID)
    }

    public var stateDirectory: URL { directory }

    private func pendingLibraryState(
        _ adapter: LiveTVPortableSyncAdapter, profileID: String, epoch: String
    ) async throws -> LiveTVPortableImport {
        try await prepare(adapter, profileID: profileID, epoch: epoch)
        var pending = try adapter.pending(
            sourceStore: sourceStore(profileID), includeLibrarySnapshots: false
        )
        if let definitions {
            try await applyLibraryRevocations(pending, profileID: profileID, store: definitions(profileID))
            guard mayApply(profileID, epoch: epoch) else { throw CancellationError() }
            if pending.journalRevision.map(adapter.isCurrentJournalRevision) != true {
                pending = try adapter.pending(
                    sourceStore: sourceStore(profileID), includeLibrarySnapshots: false
                )
            }
        }
        return await libraryPreparation.resolve(pending)
    }

    private func captureLibraryState(profileID: String, epoch: String) async throws -> LiveTVPortableLibraryExport? {
        guard let definitions else { return nil }
        let store = definitions(profileID)
        let original = try store.load()
        let required = Set(original.flatMap(\.revisions).map(\.snapshotID))
        guard original.count <= LibraryChannelPortableState.maximumDefinitions,
              required.count <= LibraryChannelPortableState.maximumDefinitions * 32 else {
            throw LibraryChannelError.catalogTooLarge
        }
        var values: [LibraryChannelSnapshot] = []
        var itemCount = 0
        for id in required.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let snapshot = try await snapshots?.snapshot(id: id, profileID: profileID) else {
                throw LibraryChannelError.snapshotUnavailable
            }
            guard mayApply(profileID, epoch: epoch) else { throw CancellationError() }
            itemCount += snapshot.items.count
            guard itemCount <= LibraryChannelPortableState.maximumItems else { throw LibraryChannelError.catalogTooLarge }
            values.append(snapshot)
        }
        guard mayApply(profileID, epoch: epoch) else { throw CancellationError() }
        guard try store.load() == original else { throw LibraryChannelError.publicationConflict }
        let prepared = try await libraryPreparation.prepare(definitions: original, snapshots: values)
        guard mayApply(profileID, epoch: epoch) else { throw CancellationError() }
        guard try store.load() == original else { throw LibraryChannelError.publicationConflict }
        return prepared
    }

    private func applyLibrary(_ report: LiveTVPortableImport, profileID: String, epoch: String) async throws {
        let adapter = adapter(profileID)
        try await prepare(adapter, profileID: profileID, epoch: epoch)
        var applicable = report.journalRevision.map(adapter.isCurrentJournalRevision) == true
            ? report : try await pendingLibraryState(adapter, profileID: profileID, epoch: epoch)
        guard let revision = applicable.journalRevision else {
            throw LiveTVPortableSyncAdapter.PreparationError.preparationRequired
        }
        let reviewIDs = applicable.libraryReviewIDs
        applicable.libraryDefinitions.removeAll { reviewIDs.contains($0.id) }
        do {
            try await applyLibraryChanges(applicable, profileID: profileID, epoch: epoch)
        } catch {
            if error as? LibraryChannelError == .publicationConflict, mayApply(profileID, epoch: epoch) {
                try await prepare(adapter, profileID: profileID, epoch: epoch)
                _ = try await adapter.committingJournal {
                    guard mayApply(profileID, epoch: epoch) else { throw CancellationError() }
                    return try adapter.markLibrariesForReview(
                        Set(applicable.libraryDefinitions.map(\.id)), ifCurrent: revision
                    )
                }
            }
            throw error
        }
    }

    private func applyLibraryChanges(_ report: LiveTVPortableImport, profileID: String, epoch: String) async throws {
        guard let definitions, mayApply(profileID, epoch: epoch) else { return }
        guard !report.libraryDefinitions.isEmpty || !report.deletedLibraryIDs.isEmpty
            || !report.disabledLibraryIDs.isEmpty else { return }
        try await prepare(adapter(profileID), profileID: profileID, epoch: epoch)
        guard let revision = report.journalRevision,
              adapter(profileID).isCurrentJournalRevision(revision) else { return }
        let store = definitions(profileID)
        try await applyLibraryRevocations(report, profileID: profileID, store: store)
        guard mayApply(profileID, epoch: epoch) else { return }
        guard !report.libraryDefinitions.isEmpty else { return }
        guard let staging = snapshots as? any LibraryChannelSnapshotStaging else {
            throw LibraryChannelError.storageFailed
        }
        let original = try store.load()
        let incomingIDs = Set(report.libraryDefinitions.flatMap(\.revisions).map(\.snapshotID))
        let incoming = report.snapshots.filter { incomingIDs.contains($0.id) }
        try await libraryPreparation.validate(definitions: report.libraryDefinitions, snapshots: incoming)
        guard mayApply(profileID, epoch: epoch) else { return }
        let required = Set(original.flatMap(\.revisions).map(\.snapshotID)).union(incomingIDs)
        guard required.count <= LibraryChannelPortableState.maximumDefinitions * 32 else {
            throw LibraryChannelError.catalogTooLarge
        }
        let supplied = report.snapshots.filter { required.contains($0.id) }
        var indexed = Dictionary(uniqueKeysWithValues: supplied.map { ($0.id, $0) })
        var itemCount = supplied.reduce(0) { $0 + $1.items.count }
        guard itemCount <= LibraryChannelPortableState.maximumItems else { throw LibraryChannelError.catalogTooLarge }
        for id in required.sorted(by: { $0.uuidString < $1.uuidString }) {
            let stored = try await staging.snapshot(id: id, profileID: profileID)
            guard mayApply(profileID, epoch: epoch) else { return }
            if let stored {
                if let received = indexed[id] {
                    guard received == stored else { throw LibraryChannelError.invalidSnapshot }
                } else {
                    itemCount += stored.items.count
                    guard itemCount <= LibraryChannelPortableState.maximumItems else { throw LibraryChannelError.catalogTooLarge }
                    indexed[id] = stored
                }
            }
            guard indexed[id] != nil else { throw LibraryChannelError.snapshotUnavailable }
        }
        guard try store.load() == original else { throw LibraryChannelError.publicationConflict }
        let lease = try await staging.stage(
            indexed.values.sorted { $0.id.uuidString < $1.id.uuidString }, profileID: profileID
        )
        do {
            if mayApply(profileID, epoch: epoch), !Task.isCancelled {
                try await commitLibrary(
                    report, profileID: profileID, epoch: epoch,
                    store: store, original: original, snapshots: indexed
                )
            }
        } catch {
            await staging.release(lease)
            throw error
        }
        await staging.release(lease)
    }

    /// Denial does not depend on downloading new revision inputs. Retain the
    /// currently valid schedule while pausing it; never install a partial recipe.
    private func applyLibraryRevocations(
        _ report: LiveTVPortableImport, profileID: String, store: any LibraryChannelDefinitionStoring
    ) async throws {
        guard !report.deletedLibraryIDs.isEmpty || !report.disabledLibraryIDs.isEmpty else { return }
        guard let revision = report.journalRevision,
              adapter(profileID).isCurrentJournalRevision(revision) else { return }
        let previous = try store.load()
        guard previous.allSatisfy({ $0.profileID == profileID }) else {
            throw LibraryChannelError.authorizationChanged
        }
        var current = previous.filter { !report.deletedLibraryIDs.contains($0.id) }
        for index in current.indices where report.disabledLibraryIDs.contains(current[index].id) {
            current[index].isEnabled = false
        }
        if current != previous { try saveLibrary(current, replacing: previous, store: store) }
        if !report.deletedLibraryIDs.isEmpty {
            let adapter = adapter(profileID)
            _ = try await adapter.committingJournal {
                try adapter.acknowledgeLibraries(report.deletedLibraryIDs, ifCurrent: revision)
            }
        }
        if current != previous {
            NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidApply, object: profileID)
        }
    }

    private func commitLibrary(
        _ report: LiveTVPortableImport, profileID: String, epoch: String,
        store: any LibraryChannelDefinitionStoring,
        original: [LibraryChannelDefinition], snapshots: [UUID: LibraryChannelSnapshot]
    ) async throws {
        let latest = try store.load()
        guard latest == original else { throw LibraryChannelError.publicationConflict }
        let current = try await libraryPreparation.merge(
            profileID: profileID, current: latest, incoming: report.libraryDefinitions,
            deletedIDs: report.deletedLibraryIDs, snapshots: snapshots
        )
        guard mayApply(profileID, epoch: epoch) else { return }
        guard try store.load() == latest else { throw LibraryChannelError.publicationConflict }
        try await prepare(adapter(profileID), profileID: profileID, epoch: epoch)
        guard try store.load() == latest else { throw LibraryChannelError.publicationConflict }
        guard let revision = report.journalRevision,
              adapter(profileID).isCurrentJournalRevision(revision) else { return }
        if current != latest {
            try saveLibrary(current, replacing: latest, store: store)
        }
        let adapter = adapter(profileID)
        _ = try await adapter.committingJournal {
            guard mayApply(profileID, epoch: epoch) else { throw CancellationError() }
            return try adapter.acknowledgeLibraries(
                Set(report.libraryDefinitions.map(\.id)).union(report.deletedLibraryIDs),
                ifCurrent: revision
            )
        }
        if current != latest || !report.snapshots.isEmpty || !report.deletedLibraryIDs.isEmpty {
            NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidApply, object: profileID)
        }
    }

    private func saveLibrary(
        _ values: [LibraryChannelDefinition], replacing expected: [LibraryChannelDefinition],
        store: any LibraryChannelDefinitionStoring
    ) throws {
        guard let atomicStore = store as? any LibraryChannelDefinitionCompareAndSwapping else {
            throw LibraryChannelError.storageFailed
        }
        try atomicStore.save(values, ifUnchangedFrom: expected)
    }

    private func applyDeferredMappings(_ adapter: LiveTVPortableSyncAdapter, profileID: String, epoch: String) async throws {
        guard mayApply(profileID, epoch: epoch),
              !LiveTVPlaybackIdentityHold.isHeld(profileID: profileID),
              let cache = guideCache(profileID) else { return }
        try await prepare(adapter, profileID: profileID, epoch: epoch)
        guard !LiveTVPlaybackIdentityHold.isHeld(profileID: profileID) else { return }
        let mappings = try adapter.deferredGuideMappings()
        guard !mappings.isEmpty else { return }
        let authority = try guideAuthority(profileID)
        let applied = try await cache.applyPortableGuideMappings(mappings, configuration: authority.configuration)
        guard !applied.isEmpty, mayApply(profileID, epoch: epoch),
              !LiveTVPlaybackIdentityHold.isHeld(profileID: profileID),
              try guideAuthority(profileID) == authority else { return }
        try await prepare(adapter, profileID: profileID, epoch: epoch)
        guard !LiveTVPlaybackIdentityHold.isHeld(profileID: profileID),
              try guideAuthority(profileID) == authority else { return }
        let currentMappings = try adapter.deferredGuideMappings()
        guard applied.allSatisfy({ currentMappings[$0] == mappings[$0] }) else { return }
        try await adapter.committingJournal {
            guard mayApply(profileID, epoch: epoch) else { throw CancellationError() }
            try adapter.acknowledgeMappings(applied)
        }
        NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidApply, object: profileID)
    }

    private struct GuideAuthority: Equatable {
        let configuration: LiveTVSourcesConfiguration
        let authorization: LiveTVSourceAuthorization
    }

    private func guideAuthority(_ profileID: String) throws -> GuideAuthority {
        guard let profile = profiles.profiles.first(where: { $0.id == profileID }) else {
            throw LiveTVSourceApprovalError.staleAuthority
        }
        let configuration = try sourceStore(profileID).load()
        let context = LiveTVSourceApprovalContext(
            profile: profile, parentalPIN: profiles.parentalPIN,
            activeAccountIDs: profiles.activeAccountIDs(for: profileID, fallback: [])
        )
        let authorization = try LiveTVSourceApprovalStore(
            defaults: defaults, profileID: profileID,
            namespace: profileID == profiles.rootNamespaceOwnerID ? nil : profileID
        ).authorization(context: context, configuration: configuration)
        return GuideAuthority(configuration: authorization.filtering(configuration), authorization: authorization)
    }

    private func applyDeferredIdentities(_ adapter: LiveTVPortableSyncAdapter, profileID: String, epoch: String) async throws {
        guard mayApply(profileID, epoch: epoch),
              !LiveTVPlaybackIdentityHold.isHeld(profileID: profileID) else { return }
        try await prepare(adapter, profileID: profileID, epoch: epoch)
        guard !LiveTVPlaybackIdentityHold.isHeld(profileID: profileID) else { return }
        let hints = try adapter.deferredIdentityHints()
        guard !hints.isEmpty else { return }
        if try await applyIdentityHints(profileID, hints), mayApply(profileID, epoch: epoch) {
            try await prepare(adapter, profileID: profileID, epoch: epoch)
            guard !LiveTVPlaybackIdentityHold.isHeld(profileID: profileID) else { return }
            guard try adapter.deferredIdentityHints() == hints else { return }
            try await adapter.committingJournal {
                guard mayApply(profileID, epoch: epoch) else { throw CancellationError() }
                try adapter.acknowledgeIdentityHints(Set(hints.keys))
            }
            NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidApply, object: profileID)
        }
    }

    private func mayApply(_ profileID: String, epoch: String) -> Bool {
        !Task.isCancelled
            && (!followsMainSync || SyncSetupFeatureFlag(defaults: defaults).isEnabled)
            && epoch == LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults)
            && profiles.profiles.contains { $0.id == profileID }
            && adapter(profileID).isEnabled
            && operationAuthority[profileID] != nil
            && operationAuthority[profileID] == authority(profileID)
            && ((try? removedProfiles().contains(profileID)) == false)
    }

    private func authority(_ profileID: String) -> ProfileAuthority? {
        let namespace = profileID == profiles.rootNamespaceOwnerID ? nil : profileID
        guard let revision = LiveTVPortableSyncPreferenceStore(
            defaults: defaults, profileID: profileID, namespace: namespace
        ).consentRevision else { return nil }
        return ProfileAuthority(namespace: namespace, consentRevision: revision)
    }

    private func currentAuthority() -> [String: ProfileAuthority] {
        refreshParticipation()
        var result: [String: ProfileAuthority] = [:]
        for profile in profiles.profiles { result[profile.id] = authority(profile.id) }
        return result
    }

    public func refreshParticipation() {
        guard followsMainSync else { return }
        let enabled = SyncSetupFeatureFlag(defaults: defaults).isEnabled
        for profile in profiles.profiles {
            let preference = LiveTVPortableSyncPreferenceStore(
                defaults: defaults, profileID: profile.id,
                namespace: profile.id == profiles.rootNamespaceOwnerID ? nil : profile.id
            )
            if preference.isEnabled != enabled { preference.isEnabled = enabled }
        }
    }

    private func adapter(_ profileID: String) -> LiveTVPortableSyncAdapter {
        if let existing = operationAdapters[profileID] { return existing }
        let adapter = LiveTVPortableSyncAdapter(
            directory: directory, profileID: profileID, defaults: defaults,
            namespace: profileID == profiles.rootNamespaceOwnerID ? nil : profileID,
            requiresPreparedJournal: true, includesPlaylistSources: !followsMainSync
        )
        if operationInProgress { operationAdapters[profileID] = adapter }
        return adapter
    }

    private func prepare(
        _ adapter: LiveTVPortableSyncAdapter, profileID: String, epoch: String,
        records: [SyncRecordID: Data?] = [:],
        preparedLibrary: LiveTVPortableLibraryExport? = nil
    ) async throws {
        guard mayApply(profileID, epoch: epoch) else { throw CancellationError() }
        try await adapter.prepareForOperation(records: records, preparedLibrary: preparedLibrary)
        guard mayApply(profileID, epoch: epoch) else { throw CancellationError() }
    }

    /// Main-actor methods can still interleave across cache/snapshot awaits.
    /// Serialize channel transactions so an older acknowledgement cannot erase
    /// a newer pending update for the same channel.
    private func beginOperation() async {
        if !operationInProgress {
            operationInProgress = true
            return
        }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func endOperation() {
        for adapter in operationAdapters.values { adapter.discardPreparedJournal() }
        operationAdapters = [:]
        operationAuthority = [:]
        if operationWaiters.isEmpty { operationInProgress = false }
        else { operationWaiters.removeFirst().resume() }
    }

    public func statusSummary(profileID: String) -> LocalizedStringResource {
        if followsMainSync {
            switch sourceSync.statuses[profileID] {
            case .unavailable: return "Some Live TV sources could not be synced."
            case .pendingFiles(let count): return "Waiting for \(count) imported playlists to finish syncing."
            default: break
            }
        }
        guard let status = statuses[profileID] else { return "Waiting to sync Live TV." }
        switch status {
        case .localOnly: return "Live TV settings stay on this device."
        case .ready: return "Live TV settings are ready to sync."
        case .unavailable: return "Some Live TV settings could not be synced."
        case .pendingLibraryInputs: return "Waiting for complete library schedule inputs."
        case .pendingLibraryReview: return "Some library schedule changes need review before they can be applied."
        case .pendingSetup(let count): return "\(count) Live TV sources need local setup."
        case .pendingSchedules(let count): return "Waiting for \(count) library schedule snapshots."
        case .pendingChannelMatches(let count): return "Waiting to apply settings for \(count) channels."
        }
    }

    private static func libraryStatus(for error: Error) -> Status {
        if let error = error as? LibraryChannelError {
            switch error {
            case .publicationConflict: return .pendingLibraryReview
            case .snapshotUnavailable: return .pendingLibraryInputs
            default: break
            }
        }
        if error as? LiveTVPortableStateError == .incompleteSnapshot { return .pendingLibraryInputs }
        return .unavailable
    }

    private func updateStatus(
        _ report: LiveTVPortableImport, profileID: String, epoch: String,
        operation: LiveTVSyncDiagnostic.Operation
    ) async throws {
        let adapter = adapter(profileID)
        try await prepare(adapter, profileID: profileID, epoch: epoch)
        let pendingIdentities = try adapter.deferredIdentityHints()
        let pendingMappings = try adapter.deferredGuideMappings()
        let pendingChannels = Set(pendingIdentities.keys).union(pendingMappings.keys)
        if report.rejectedCount > 0 {
            statuses[profileID] = .unavailable
            recordFailure(LiveTVPortableStateError.invalidRecord, operation: operation,
                          stage: .validateRecords, profileID: profileID)
        }
        else if !report.libraryReviewIDs.isEmpty { statuses[profileID] = .pendingLibraryReview }
        else if (!report.libraryDefinitions.isEmpty && (definitions == nil || snapshots == nil))
            || ((!report.deletedLibraryIDs.isEmpty || !report.disabledLibraryIDs.isEmpty) && definitions == nil) {
            statuses[profileID] = .unavailable
            recordFailure(LibraryChannelError.storageFailed, operation: operation,
                          stage: .libraryState, profileID: profileID)
        }
        else if !report.incompleteSnapshotIDs.isEmpty {
            statuses[profileID] = .pendingSchedules(report.incompleteSnapshotIDs.count)
        } else if !report.pendingPlaylists.isEmpty || !report.localFileSources.isEmpty {
            statuses[profileID] = .pendingSetup(report.pendingPlaylists.count + report.localFileSources.count)
        } else if !pendingChannels.isEmpty {
            statuses[profileID] = .pendingChannelMatches(pendingChannels.count)
        } else {
            statuses[profileID] = .ready
        }
    }

    private func removedProfiles() throws -> Set<String> {
        let url = metadataDirectory.appendingPathComponent("removed-profiles.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_024 * 1_024 else { throw LiveTVPortableStateError.tooLarge }
        return Set(try JSONDecoder().decode([String].self, from: data))
    }

    private var metadataDirectory: URL {
        directory.appendingPathComponent(
            LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults), isDirectory: true
        )
    }

    private func trace(
        _ operation: LiveTVSyncDiagnostic.Operation, _ stage: LiveTVSyncDiagnostic.Stage
    ) -> LiveTVSyncDiagnostic.Stage {
        LiveTVSyncDiagnostic(operation: operation, stage: stage, outcome: .started).publish()
        return stage
    }

    private func finishDiagnostic(_ operation: LiveTVSyncDiagnostic.Operation, profileID: String) {
        guard statuses[profileID] != .unavailable else { return }
        clearDiagnosticFailures(operation, profileID: profileID)
        LiveTVSyncDiagnostic(operation: operation, stage: .finish, outcome: .succeeded).publish()
    }

    private func clearDiagnosticFailures(_ operation: LiveTVSyncDiagnostic.Operation, profileID: String) {
        let prefix = "\(operation.rawValue):\(profileID):"
        diagnosticFailures = diagnosticFailures.filter { !$0.key.hasPrefix(prefix) }
    }

    private func recordFailure(
        _ error: Error, operation: LiveTVSyncDiagnostic.Operation,
        stage: LiveTVSyncDiagnostic.Stage, profileID: String = ""
    ) {
        guard !(error is CancellationError), !Task.isCancelled else { return }
        if !profileID.isEmpty {
            guard mayApply(
                profileID, epoch: LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults)
            ) else { return }
        }
        if Self.libraryStatus(for: error) != .unavailable {
            LiveTVSyncDiagnostic(operation: operation, stage: stage, outcome: .deferred).publish()
            return
        }
        let failure = Self.diagnosticFailure(error)
        let diagnostic = LiveTVSyncDiagnostic(
            operation: operation, stage: stage, outcome: .failed,
            failure: failure
        )
        let key = "\(operation.rawValue):\(profileID):\(stage.rawValue)"
        guard diagnosticFailures[key] != diagnostic else { return }
        diagnosticFailures[key] = diagnostic
        PlozzLog.sync.error(
            "PLZLTVSYNC \(operation.rawValue).\(stage.rawValue) failed " +
            "reason=\(failure.reason.rawValue) code=\(failure.code.map(String.init) ?? "none")"
        )
        diagnostic.publish()
    }

    static func diagnosticFailure(_ error: Error) -> LiveTVSyncDiagnostic.Failure {
        if let error = error as? LiveTVPortableStateError {
            switch error {
            case .invalidRecord: return .init(reason: .invalidRecord)
            case .unsupportedVersion: return .init(reason: .unsupportedVersion)
            case .tooLarge: return .init(reason: .tooLarge)
            case .wrongProfile: return .init(reason: .wrongProfile)
            case .incompleteSnapshot: return .init(reason: .incompleteSnapshot)
            }
        }
        if let error = error as? KeychainError {
            switch error {
            case .unexpectedStatus(let code): return .init(reason: .keychain, code: Int(code))
            case .encodingFailed: return .init(reason: .serialization)
            }
        }
        if let error = error as? LiveTVPortableSyncAdapter.PreparationError {
            switch error {
            case .preparationRequired: return .init(reason: .journalPreparation)
            case .preparationSuperseded, .journalChanged: return .init(reason: .journalChanged)
            case .accountChanged: return .init(reason: .authorizationChanged)
            }
        }
        if let error = error as? LibraryChannelError {
            switch error {
            case .storageFailed: return .init(reason: .storage)
            case .invalidSnapshot: return .init(reason: .invalidRecord)
            case .catalogTooLarge: return .init(reason: .tooLarge)
            case .authorizationChanged: return .init(reason: .authorizationChanged)
            case .snapshotUnavailable: return .init(reason: .snapshotUnavailable)
            default: return .init(reason: .library)
            }
        }
        if error is DecodingError || error is EncodingError { return .init(reason: .serialization) }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSPOSIXErrorDomain {
            return .init(reason: .storage, code: nsError.code)
        }
        return .init(reason: .other)
    }
}

/// Only immutable inputs cross this boundary. Consent checks, source changes
/// and compare-and-swap publication stay on the main actor; journal I/O is awaited.
actor LiveTVPortableLibraryPreparation {
    private var cachedExport: LiveTVPortableLibraryExport?
    private let makeExport: @Sendable (
        [LibraryChannelDefinition], [LibraryChannelSnapshot]
    ) throws -> LiveTVPortableLibraryExport

    init(
        makeExport: @escaping @Sendable (
            [LibraryChannelDefinition], [LibraryChannelSnapshot]
        ) throws -> LiveTVPortableLibraryExport = {
            try LiveTVPortableLibraryExport(definitions: $0, snapshots: $1)
        }
    ) {
        self.makeExport = makeExport
    }

    func prepare(
        definitions: [LibraryChannelDefinition], snapshots: [LibraryChannelSnapshot]
    ) throws -> LiveTVPortableLibraryExport {
        try Task.checkCancellation()
        if let cachedExport, cachedExport.state.definitions == definitions,
           cachedExport.state.snapshots == snapshots {
            return cachedExport
        }
        let export = try makeExport(definitions, snapshots)
        cachedExport = export
        return export
    }

    func discardExport() {
        cachedExport = nil
    }

    func resolve(_ pending: LiveTVPortableImport) -> LiveTVPortableImport {
        pending.resolvingLibrarySnapshots()
    }

    func validate(
        definitions: [LibraryChannelDefinition], snapshots: [LibraryChannelSnapshot]
    ) throws {
        try Task.checkCancellation()
        _ = try LibraryChannelPortableState(definitions: definitions, snapshots: snapshots)
    }

    func merge(
        profileID: String, current: [LibraryChannelDefinition], incoming: [LibraryChannelDefinition],
        deletedIDs: Set<UUID>, snapshots: [UUID: LibraryChannelSnapshot]
    ) throws -> [LibraryChannelDefinition] {
        try Task.checkCancellation()
        return try LibraryChannelImportMerger.merge(
            profileID: profileID, current: current, incoming: incoming,
            deletedIDs: deletedIDs, snapshots: snapshots
        )
    }
}
