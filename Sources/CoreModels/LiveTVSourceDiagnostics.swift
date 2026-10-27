import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Local, bounded evidence for source loss. Only explicit diagnostic submission exports it.
public final class LiveTVSourceDiagnostics: @unchecked Sendable {
    public enum Event: String, Codable, Sendable {
        case sourceRead, sourceMissing, sourceReadFailed, sourceSave, sourceSaveFailed
        case localMutation, syncMutation, suppressionChanged, syncSourceRecord
        case accountsReloaded, accountSnapshot, reportSnapshot, reportRequested
        case sourcesActivate, sourcesInvalidate, sourcesRestore, sourcesRestored, sourcesRejected
        case authorityChanged, sourceNotification, guideReload, guideReloaded, guideState, sheetChanged
        case enrollmentStarted, enrollmentDecision, enrollmentFinished
        case providerCreated, catalogRefreshStarted, catalogRefreshFinished, catalogProgress, catalogRead
        case syncFinished, syncFailed
        case syncLocalIntentPreserved
        case keychainRead, keychainWrite, keychainRemove, sourceErase, sourcesScreen
        case profileRemoved, profileDeletionDeferred
    }

    public enum Identity: String, Codable, Sendable {
        case profile, activeProfile, namespace, storageNamespace, storageKey, account, source, catalog, request, authority, rootNamespaceOwner
    }

    public enum Count: String, Codable, Sendable {
        case playlists, servers, enabledPlaylists, enabledServers, channels, accounts, activeAccounts
        case iptvAccounts, selectedAccounts, suppressedAccounts, choices, added, generation
        case entries, bytes, requests, elapsedMilliseconds, waiters, sourceRecords, omittedSources
        case profiles
    }

    public enum Flag: String, Codable, Sendable {
        case present, enabled, active, authorized, current, cancelled, loading, failed, suppressed
        case profileMatches, namespaceMatches, storageNamespaceMatches, identityPending, actionableIdentityPending
        case selectionUnavailable, explicitSelection, defaultNamespace, deleted, background, committed
        case sameAuthority, sameConfiguration, hasSnapshot, hasChannels, guide, refresh, sheet, sceneActive
        case iptv, plex, jellyfin, emby, localFile, xtream, defaultNamespaceMatches, capture
        case sharedPartition
    }

    public enum Stage: String, Codable, Sendable { case initial, configuration, prepared, completed, error }

    public enum Reason: String, Codable, Sendable {
        case suppressed, disabled, accountUnavailable, authorizationChanged, generationChanged
        case alreadyConfigured, unavailable, noChannels, saved, cancelled, timeout, storage
        case invalidConfiguration, other
    }

    struct Source: Codable, Equatable, Sendable {
        let id: String
        let account: String?
        let enabled: Bool
    }

    struct Payload: Codable, Equatable, Sendable {
        let event: Event
        let identities: [Identity: String]
        let counts: [Count: Int]
        let flags: [Flag: Bool]
        let reason: Reason?
        let stage: Stage?
        let errorCode: Int?
        let sources: [Source]

        var isValid: Bool {
            identities.values.allSatisfy(Self.isDigest)
                && sources.count <= 64
                && sources.allSatisfy { Self.isDigest($0.id) && ($0.account.map(Self.isDigest) ?? true) }
                && counts.values.allSatisfy { (0...1_000_000_000_000).contains($0) }
                && errorCode.map { (Int(Int32.min)...Int(Int32.max)).contains($0) } != false
        }

        private static func isDigest(_ value: String) -> Bool {
            value.utf8.count == 16 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }

    struct Entry: Codable, Sendable {
        let timestamp: Date
        let launch: UUID
        let sequence: Int
        let build: String
        let payload: Payload
    }

    struct Journal: Codable {
        var schema = 1
        var discarded = 0
        var entries: [Entry] = []
    }

    enum StorageIssue: String, Encodable, Sendable {
        case locationUnavailable, oversized, invalidJournal, readFailed, writeFailed, encodeFailed
    }

    public static let shared = LiveTVSourceDiagnostics(
        url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Plozz/Diagnostics/live-tv-sources.json")
    )
    public static let snapshotRequested = Notification.Name("com.plozz.liveTV.diagnosticSnapshotRequested")
    static let maximumBytes = 256 * 1_024
    static let maximumEntries = 512
    static let retention: TimeInterval = 48 * 3_600

    private let url: URL?
    private let clock: @Sendable () -> Date
    private let launch = UUID()
    private static let build: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return isBuild(value) ? value : "unknown"
    }()
    private let queue = DispatchQueue(label: "com.plozz.liveTV.sourceDiagnostics", qos: .utility)
    private let lock = NSLock()
    private var sequence = 0
    private var deduplicated: [String: Payload] = [:]
    private var pending: [Entry] = []
    private var pendingDiscarded = 0
    private var drainScheduled = false
    private var journal = Journal()
    private var writeScheduled = false
    private var storageIssue: StorageIssue?
    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "com.plozz.app", category: "sourceDiagnostics")
    #endif

    init(url: URL?, clock: @escaping @Sendable () -> Date = Date.init) {
        self.url = url
        self.clock = clock
        queue.async { self.restore() }
    }

    public func record(
        _ event: Event, identities: [Identity: String] = [:], counts: [Count: Int] = [:],
        flags: [Flag: Bool] = [:], reason: Reason? = nil, stage: Stage? = nil, error: (any Error)? = nil,
        deduplicate: Bool = false
    ) {
        append(Payload(
            event: event, identities: identities.mapValues(Self.digest),
            counts: counts.mapValues { min(1_000_000_000_000, max(0, $0)) },
            flags: flags, reason: reason ?? error.map(Self.reason), stage: stage,
            errorCode: error.flatMap { Int32(exactly: ($0 as NSError).code).map(Int.init) },
            sources: []
        ), deduplicate: deduplicate)
    }

    public func configuration(
        _ configuration: LiveTVSourcesConfiguration, namespace: String?, event: Event = .sourceRead
    ) {
        var sources = configuration.playlists.prefix(64).map { Source(
            id: Self.digest($0.id), account: nil, enabled: $0.isEnabled
        ) }
        sources += configuration.servers.prefix(64 - sources.count).map { Source(
            id: Self.digest($0.id), account: Self.digest($0.accountID), enabled: $0.isEnabled
        ) }
        append(Payload(
            event: event, identities: [
                .namespace: Self.digest(namespace ?? "default"),
                .storageKey: Self.digest(SettingsKey.scoped(LiveTVSourcesStore.baseKey, namespace: namespace))
            ],
            counts: [
                .playlists: configuration.playlists.count, .servers: configuration.servers.count,
                .enabledPlaylists: configuration.playlists.filter(\.isEnabled).count,
                .enabledServers: configuration.servers.filter(\.isEnabled).count,
                .omittedSources: max(0, configuration.playlists.count + configuration.servers.count - 64)
            ],
            flags: [.defaultNamespace: namespace == nil], reason: nil, stage: nil, errorCode: nil,
            sources: sources
        ), deduplicate: event == .sourceRead)
    }

    @MainActor
    public static func captureReport() -> String {
        shared.record(.reportRequested)
        NotificationCenter.default.post(name: snapshotRequested, object: nil)
        return shared.report()
    }

    public func report() -> String {
        queue.sync {
            trim()
            writeScheduled = false
            persist()
            do {
                let data = try encodedJournal()
                return "storage=\(storageIssue?.rawValue ?? "ok")\n" + String(decoding: data, as: UTF8.self)
            } catch {
                storageFailed(.encodeFailed)
                return "storage=encodeFailed"
            }
        }
    }

    public struct Export: Encodable, Sendable {
        private let schema = 2
        private let storageAvailable: Bool
        private let storageIssue: StorageIssue?
        private let discarded: Int
        private let entries: [ExportEntry]

        fileprivate init(journal: Journal, storage: StorageIssue?, scope: DiagnosticExportScope) {
            storageAvailable = storage == nil
            storageIssue = storage
            discarded = journal.discarded
            entries = journal.entries.map { ExportEntry($0, scope: scope) }
        }
    }

    private struct ExportEntry: Encodable, Sendable {
        let ageMilliseconds: Int?
        let launch: String
        let sequence: Int
        let build: String
        let event: Event
        let identities: [String: String]
        let counts: [String: Int]
        let flags: [String: Bool]
        let reason: Reason?
        let stage: Stage?
        let errorCode: Int?
        let sources: [ExportSource]

        init(_ entry: Entry, scope: DiagnosticExportScope) {
            ageMilliseconds = scope.ageMilliseconds(for: entry.timestamp)
            launch = scope.alias(for: entry.launch.uuidString)
            sequence = entry.sequence
            build = entry.build
            event = entry.payload.event
            identities = Dictionary(uniqueKeysWithValues: entry.payload.identities.map {
                ($0.key.rawValue, scope.alias(forDigest: $0.value))
            })
            counts = Dictionary(uniqueKeysWithValues: entry.payload.counts.map { ($0.key.rawValue, $0.value) })
            flags = Dictionary(uniqueKeysWithValues: entry.payload.flags.map { ($0.key.rawValue, $0.value) })
            reason = entry.payload.reason
            stage = entry.payload.stage
            errorCode = entry.payload.errorCode
            sources = entry.payload.sources.map {
                ExportSource(id: scope.alias(forDigest: $0.id), account: $0.account.map { scope.alias(forDigest: $0) },
                             enabled: $0.enabled)
            }
        }
    }

    private struct ExportSource: Encodable, Sendable {
        let id: String
        let account: String?
        let enabled: Bool
    }

    @MainActor
    public static func captureExport(scope: DiagnosticExportScope) -> Export {
        shared.record(.reportRequested)
        NotificationCenter.default.post(name: snapshotRequested, object: nil)
        return shared.export(scope: scope)
    }

    public func export(scope: DiagnosticExportScope) -> Export {
        queue.sync {
            trim()
            writeScheduled = false
            persist()
            return Export(journal: journal, storage: storageIssue, scope: scope)
        }
    }

    private static func digest(_ value: String) -> String {
        HandoffDiagnostics.correlationID(value.isEmpty ? "empty" : value)
    }

    private static func reason(_ error: any Error) -> Reason {
        if error is CancellationError || (error as? AppError) == .cancelled { return .cancelled }
        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            if error.code == NSURLErrorTimedOut { return .timeout }
            if error.code == NSURLErrorCancelled { return .cancelled }
        }
        if error.domain == NSCocoaErrorDomain || error.domain == NSPOSIXErrorDomain { return .storage }
        return .other
    }

    private func append(_ payload: Payload, deduplicate: Bool) {
        lock.withLock {
            if payload.event == .sourceSave {
                deduplicated["sourceReading" + (payload.identities[.namespace] ?? "")] = nil
            }
            if deduplicate {
                let readEvents: Set<Event> = [.sourceRead, .sourceMissing, .sourceReadFailed]
                let category = readEvents.contains(payload.event) ? "sourceReading" : payload.event.rawValue
                var key = category
                key += payload.identities[.namespace] ?? ""
                key += payload.identities[.profile] ?? ""
                key += payload.identities[.account] ?? ""
                key += payload.identities[.catalog] ?? ""
                key += payload.identities[.source] ?? ""
                if let sharedPartition = payload.flags[.sharedPartition] {
                    key += String(sharedPartition)
                }
                if payload.event == .keychainRead {
                    key += payload.identities[.storageKey] ?? ""
                }
                guard deduplicated[key] != payload else { return }
                if deduplicated.count >= 128 { deduplicated.removeAll(keepingCapacity: true) }
                deduplicated[key] = payload
            }
            sequence &+= 1
            let entry = Entry(timestamp: clock(), launch: launch, sequence: sequence, build: Self.build, payload: payload)
            if pending.count == Self.maximumEntries {
                pending.removeFirst()
                pendingDiscarded += 1
            }
            pending.append(entry)
            guard !drainScheduled else { return }
            drainScheduled = true
            queue.async { self.drain() }
        }
    }

    private func drain() {
        let batch = lock.withLock {
            let batch = (pending, pendingDiscarded)
            pending = []
            pendingDiscarded = 0
            drainScheduled = false
            return batch
        }
        journal.entries.append(contentsOf: batch.0)
        journal.discarded += batch.1
        trim()
        guard !writeScheduled else { return }
        writeScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(250)) {
            guard self.writeScheduled else { return }
            self.writeScheduled = false
            self.persist()
        }
    }

    private func trim() {
        let cutoff = clock().addingTimeInterval(-Self.retention)
        let before = journal.entries.count
        journal.entries.removeAll { $0.timestamp < cutoff }
        if journal.entries.count > Self.maximumEntries {
            journal.entries.removeFirst(journal.entries.count - Self.maximumEntries)
        }
        journal.discarded += before - journal.entries.count
    }

    private func restore() {
        guard let url else { storageFailed(.locationUnavailable); return }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            let data: Data
            do {
                data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            guard data.count <= Self.maximumBytes else { storageFailed(.oversized); return }
            let decoded = try JSONDecoder().decode(Journal.self, from: data)
            guard decoded.schema == 1, (0...1_000_000_000_000).contains(decoded.discarded),
                  decoded.entries.count <= Self.maximumEntries,
                  decoded.entries.allSatisfy({
                      $0.payload.isValid && $0.sequence > 0
                          && Self.isBuild($0.build)
                          && $0.timestamp <= clock().addingTimeInterval(300)
                  }) else { storageFailed(.invalidJournal); return }
            journal = decoded
            trim()
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch {
            storageFailed(.readFailed)
        }
    }

    private func persist() {
        do {
            let data = try encodedJournal()
            guard let url else { storageFailed(.locationUnavailable); return }
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            try data.write(to: url, options: .atomic)
        } catch {
            storageFailed(.writeFailed)
        }
    }

    private func encodedJournal() throws -> Data {
        var data = try Self.encoder().encode(journal)
        while data.count > Self.maximumBytes, !journal.entries.isEmpty {
            let excess = max(1, journal.entries.count * (data.count - Self.maximumBytes) / data.count)
            journal.entries.removeFirst(excess)
            journal.discarded += excess
            data = try Self.encoder().encode(journal)
        }
        return data
    }

    private static func isBuild(_ value: String) -> Bool {
        value == "unknown" || (!value.isEmpty && value.utf8.count <= 32
            && value.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 })
    }

    private func storageFailed(_ code: StorageIssue) {
        storageIssue = code
        #if canImport(OSLog)
        Self.logger.error("Live TV diagnostic journal unavailable reason=\(code.rawValue, privacy: .public)")
        #endif
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
