import CoreModels
import Foundation

public protocol MediaTransportNetworkFileResolving: Sendable {
    func resolve(_ locator: NetworkFileLocator) async throws -> MediaTransportResolvedSource
    /// Optional, single-use preparation without playback admission. Retain the
    /// handle until Play claims it, or cancel it when its browsing context ends.
    func prepare(_ locator: NetworkFileLocator) async throws -> MediaTransportPreparation
    func prepare(
        _ locator: NetworkFileLocator, startPosition: Double
    ) async throws -> MediaTransportPreparation
    /// Opt-in pending ticket. Only this lane permits intentional interruption
    /// of optional warming; opening and final playback validation still finish.
    func beginPreparation(
        _ locator: NetworkFileLocator, startPosition: Double
    ) throws -> MediaTransportPreparation

    /// The same resolver, but WITHOUT playback admission.
    ///
    /// Acquiring a playback lease deliberately drains any running library scan —
    /// correct when a movie starts, wrong for the lightweight reads that share the
    /// playback resolver: a codec/Atmos probe, a trickplay thumbnail. Those fire
    /// from ordinary browsing, so on a share they cancelled the in-flight scan on
    /// every detail page open. A cancelled scan never stamps `last_full_scan_at`,
    /// so `scanIfStale` saw it as stale and restarted a FULL walk — forever. That
    /// loop, not the scan interval, was the app's battery drain.
    ///
    /// Defaulted to `self` so test doubles and resolvers with no admission concept
    /// need not implement it.
    func withoutPlaybackAdmission() -> any MediaTransportNetworkFileResolving
}

public extension MediaTransportNetworkFileResolving {
    func withoutPlaybackAdmission() -> any MediaTransportNetworkFileResolving { self }

    func prepare(_ locator: NetworkFileLocator) async throws -> MediaTransportPreparation {
        throw MediaTransportError.unsupportedCapability("network-file preparation")
    }

    func beginPreparation(_ locator: NetworkFileLocator) throws -> MediaTransportPreparation {
        try beginPreparation(locator, startPosition: 0)
    }

    func beginPreparation(
        _ locator: NetworkFileLocator, startPosition: Double
    ) throws -> MediaTransportPreparation {
        guard startPosition.isFinite, startPosition >= 0 else {
            throw MediaTransportError.invalidInput(reason: "invalid preparation start position")
        }
        throw MediaTransportError.unsupportedCapability("interruptible network-file preparation")
    }

    /// Preserve existing zero-position implementations without claiming they
    /// support position-aware preparation.
    func prepare(
        _ locator: NetworkFileLocator, startPosition: Double
    ) async throws -> MediaTransportPreparation {
        guard startPosition.isFinite, startPosition >= 0 else {
            throw MediaTransportError.invalidInput(reason: "invalid preparation start position")
        }
        guard startPosition == 0 else {
            throw MediaTransportError.unsupportedCapability("position-aware network-file preparation")
        }
        return try await prepare(locator)
    }
}

/// Owns both an opened source and the resolver session that created it. The
/// session remains pinned to the locator's credential revision until the final
/// independent source cursor drains.
public final class MediaTransportResolvedSource: @unchecked Sendable {
    public let sourceLease: MediaTransportSourceLease
    /// Keep prepared and cold startup evidence separate.
    public let wasPrepared: Bool

    /// The transport pinned by this resolved source's exact session.
    public var transportIdentifier: String { sessionLease.key.endpoint.transportIdentifier }

    private let sessionLease: MediaTransportResolverLease
    private let playbackLease: MediaIOPlaybackLease?
    private let lock = NSLock()
    private var releaseTask: Task<Void, Never>?

    init(
        sourceLease: MediaTransportSourceLease,
        sessionLease: MediaTransportResolverLease,
        playbackLease: MediaIOPlaybackLease?,
        wasPrepared: Bool = false
    ) {
        self.sourceLease = sourceLease
        self.sessionLease = sessionLease
        self.playbackLease = playbackLease
        self.wasPrepared = wasPrepared
    }

    deinit {
        startRelease()
    }

    public func waitForFinalShutdown() async {
        await startRelease().value
    }

    @discardableResult
    private func startRelease() -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let releaseTask {
            return releaseTask
        }

        let sourceLease = sourceLease
        let sessionLease = sessionLease
        let playbackLease = playbackLease
        let task = Task.detached {
            sourceLease.close()
            await sourceLease.waitForFinalShutdown()
            sessionLease.release()
            await playbackLease?.releaseAndWait()
        }
        releaseTask = task
        return task
    }
}

public struct MediaTransportNetworkFileResolver: MediaTransportNetworkFileResolving {
    public typealias SessionKeyProvider = @Sendable (
        _ locator: NetworkFileLocator
    ) async throws -> MediaTransportSessionKey
    public typealias PlaybackLeaseProvider = @Sendable (
        _ locator: NetworkFileLocator
    ) async throws -> MediaIOPlaybackLease?
    /// Optional header/disc probing within the default 30-second preparation
    /// budget, never playback or decoding. The
    /// source is borrowed only for this call; closing it does not consume the
    /// reservation. Retaining a reader does not extend its borrowed lifetime:
    /// all borrowed reads are closed and drained before publication.
    /// Throw MediaTransportPreparationIncomplete for expected optional coverage
    /// limits. That source is discarded before Play may resolve normally; actual
    /// transport, authorization and representation errors must not use that type.
    public typealias SourcePreparer = @Sendable (
        _ locator: NetworkFileLocator,
        _ startPosition: Double,
        _ source: any MediaTransportByteSource
    ) async throws -> Void

    private let registry: MediaTransportResolverRegistry
    private let sessionKeyProvider: SessionKeyProvider
    private let playbackLeaseProvider: PlaybackLeaseProvider
    private let sourcePreparer: SourcePreparer?
    private let preparation: MediaTransportPreparationCoordinator
    private var usesPlaybackAdmission = true

    public init(
        registry: MediaTransportResolverRegistry,
        playbackLeaseProvider: @escaping PlaybackLeaseProvider = { _ in nil },
        sourcePreparer: SourcePreparer? = nil,
        sessionKeyProvider: @escaping SessionKeyProvider
    ) {
        self.init(
            registry: registry,
            playbackLeaseProvider: playbackLeaseProvider,
            sourcePreparer: sourcePreparer,
            sessionKeyProvider: sessionKeyProvider,
            preparationTiming: MediaTransportPreparationTiming()
        )
    }

    init(
        registry: MediaTransportResolverRegistry,
        playbackLeaseProvider: @escaping PlaybackLeaseProvider = { _ in nil },
        sourcePreparer: SourcePreparer? = nil,
        sessionKeyProvider: @escaping SessionKeyProvider,
        preparationTiming: MediaTransportPreparationTiming
    ) {
        self.registry = registry
        self.playbackLeaseProvider = playbackLeaseProvider
        self.sourcePreparer = sourcePreparer
        self.sessionKeyProvider = sessionKeyProvider
        self.preparation = MediaTransportPreparationCoordinator(timing: preparationTiming)
    }

    /// Drops playback admission only. The session identity/credential checks in
    /// `resolve` are untouched, so a lightweight read is still bound to the same
    /// account + credential revision as playback.
    public func withoutPlaybackAdmission() -> any MediaTransportNetworkFileResolving {
        var copy = self
        copy.usesPlaybackAdmission = false
        return copy
    }

    public func prepare(_ locator: NetworkFileLocator) async throws -> MediaTransportPreparation {
        try await prepare(locator, startPosition: 0)
    }

    /// Position guides the bounded probe, not cache identity: every prepared
    /// byte remains bound to the exact locator and can serve any playback seek.
    public func prepare(
        _ locator: NetworkFileLocator, startPosition: Double = 0
    ) async throws -> MediaTransportPreparation {
        try validatePreparationPosition(startPosition)
        return try await preparation.prepare(
            locator, operation: preparationOperation(locator, startPosition: startPosition)
        )
    }

    public func beginPreparation(
        _ locator: NetworkFileLocator, startPosition: Double = 0
    ) throws -> MediaTransportPreparation {
        try validatePreparationPosition(startPosition)
        let warmup = MediaTransportPreparationWarmup()
        return try preparation.begin(
            locator, warmup: warmup,
            operation: preparationOperation(locator, startPosition: startPosition, warmup: warmup)
        )
    }

    private func validatePreparationPosition(_ startPosition: Double) throws {
        guard startPosition.isFinite, startPosition >= 0 else {
            throw MediaTransportError.invalidInput(reason: "invalid preparation start position")
        }
        guard usesPlaybackAdmission else {
            throw MediaTransportError.unsupportedCapability("preparation without playback admission")
        }
    }

    private func preparationOperation(
        _ locator: NetworkFileLocator, startPosition: Double,
        warmup: MediaTransportPreparationWarmup? = nil
    ) -> @Sendable () async throws -> MediaTransportPreparedResource {
        let registry = registry
        let provider = sessionKeyProvider
        let sourcePreparer = sourcePreparer
        return {
            let key = try await Self.validatedKey(for: locator, provider: provider)
            guard ["http", "https"].contains(key.endpoint.transportIdentifier) else {
                throw MediaTransportError.unsupportedCapability("network-file preparation transport")
            }
            try Task.checkCancellation()
            let session = try await registry.lease(for: key)
            var resource: MediaTransportPreparedResource?
            do {
                guard let fileSystem = session.session.fileSystem as? any MediaTransportPreparingFileSystem else {
                    throw MediaTransportError.unsupportedCapability("filesystem preparation")
                }
                try Task.checkCancellation()
                let incremental = warmup == nil ? nil
                    : fileSystem as? any MediaTransportPreparationWarmingFileSystem
                let source: MediaTransportSourceLease
                if let incremental {
                    source = try await incremental.openPreparationSource(for: locator)
                } else {
                    source = try await fileSystem.prepareSource(for: locator)
                }
                let prepared = MediaTransportPreparedResource(source: source, session: session)
                resource = prepared
                try Task.checkCancellation()
                if let warmup, incremental != nil || sourcePreparer != nil {
                    let borrowed = try source.makePreparationBorrow()
                    try await warmup.run(borrowed: borrowed) {
                        try await incremental?.warmPreparedSource(for: locator, source: borrowed)
                        try Task.checkCancellation()
                        try await sourcePreparer?(locator, startPosition, borrowed)
                    }
                } else if let sourcePreparer {
                    let borrowed = try source.makePreparationBorrow()
                    do {
                        try await withTaskCancellationHandler {
                            try Task.checkCancellation()
                            try await sourcePreparer(locator, startPosition, borrowed)
                        } onCancel: {
                            borrowed.close()
                        }
                    } catch {
                        await borrowed.shutdown()
                        throw borrowed.firstFailure ?? error
                    }
                    await borrowed.shutdown()
                    if let failure = borrowed.firstFailure { throw failure }
                    try Task.checkCancellation()
                }
                let fresh = try await Self.validatedKey(for: locator, provider: provider)
                guard fresh == key else {
                    throw MediaTransportError.sourceChanged(reason: "prepared session identity changed")
                }
                try await session.validateForPreparedPlayback()
                try Task.checkCancellation()
                source.finishPreparation()
                return prepared
            } catch {
                await Self.reportFailure(error, session: session)
                if let resource { await resource.discard().value } else { session.release() }
                throw error
            }
        }
    }

    private static func validatedKey(
        for locator: NetworkFileLocator,
        provider: SessionKeyProvider
    ) async throws -> MediaTransportSessionKey {
        try Task.checkCancellation()
        let key = try await provider(locator)
        guard key.accountID == locator.accountID,
              key.credentialRevision == locator.credentialRevision,
              key.role == .playback else {
            throw MediaTransportError.invalidInput(reason: "network-file session identity mismatch")
        }
        try Task.checkCancellation()
        return key
    }

    public func resolve(_ locator: NetworkFileLocator) async throws -> MediaTransportResolvedSource {
        let key: MediaTransportSessionKey
        let playbackLease: MediaIOPlaybackLease?
        do {
            key = try await Self.validatedKey(for: locator, provider: sessionKeyProvider)
            playbackLease = usesPlaybackAdmission ? try await playbackLeaseProvider(locator) : nil
        } catch {
            if usesPlaybackAdmission { preparation.cancel(locator: locator) }
            throw error
        }

        var prepared: MediaTransportPreparedResource?
        do {
            try Task.checkCancellation()
            if usesPlaybackAdmission { prepared = try await preparation.claim(locator) }
            if let prepared {
                let session = prepared.sessionLease
                let fresh = try await Self.validatedKey(for: locator, provider: sessionKeyProvider)
                guard fresh == key, fresh == session.key else {
                    throw MediaTransportError.sourceChanged(reason: "prepared session identity changed")
                }
                try await session.validateForPreparedPlayback()
                guard let fileSystem = session.session.fileSystem as? any MediaTransportPreparingFileSystem else {
                    throw MediaTransportError.unsupportedCapability("filesystem preparation")
                }
                try await fileSystem.revalidatePreparedSource(for: locator)
                let finalKey = try await Self.validatedKey(for: locator, provider: sessionKeyProvider)
                guard finalKey == fresh else {
                    throw MediaTransportError.sourceChanged(reason: "prepared session identity changed")
                }
                try await session.validateForPreparedPlayback()
                try Task.checkCancellation()
                return prepared.transfer(playbackLease: playbackLease)
            }
        } catch {
            if let prepared {
                await Self.reportFailure(error, session: prepared.sessionLease)
                await prepared.discard().value
            }
            await playbackLease?.releaseAndWait()
            throw error
        }

        let sessionLease: MediaTransportResolverLease
        do {
            // A cancelled preparation may have needed time to drain. Do not
            // open against an identity captured before that suspension.
            if usesPlaybackAdmission {
                let fresh = try await Self.validatedKey(for: locator, provider: sessionKeyProvider)
                guard fresh == key else {
                    throw MediaTransportError.sourceChanged(reason: "network-file session identity changed")
                }
            }
            sessionLease = try await registry.lease(for: key)
        } catch {
            await playbackLease?.releaseAndWait()
            throw error
        }
        do {
            let sourceLease = try await sessionLease.session.fileSystem.openSource(for: locator)
            if Task.isCancelled {
                await sourceLease.waitForFinalShutdown()
                throw CancellationError()
            }
            return MediaTransportResolvedSource(
                sourceLease: sourceLease,
                sessionLease: sessionLease,
                playbackLease: playbackLease
            )
        } catch {
            await Self.reportFailure(error, session: sessionLease)
            sessionLease.release()
            await playbackLease?.releaseAndWait()
            throw error
        }
    }

    private static func reportFailure(_ error: Error, session: MediaTransportResolverLease) async {
        if let transportError = error as? MediaTransportError,
           session.session.shouldRetireAfterOpenFailure(transportError) {
            await session.reportConnectionFailure()
        }
    }
}
