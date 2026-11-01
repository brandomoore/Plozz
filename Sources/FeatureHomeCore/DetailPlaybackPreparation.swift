import CoreModels
import CoreNetworking
import Foundation

/// One already-resolved file, never an instruction to discover versions or episodes.
public struct DetailPlaybackPreparationCandidate: Hashable, Sendable {
    public let accountID: String
    public let itemID: String
    public let kind: MediaItemKind
    public let mediaSourceID: String
    public let sourceRevision: String?
    public let startPosition: Double
    private let physicalFileRelativePath: String?

    public init?(
        _ item: MediaItem, allowsMultipleVersions: Bool = false,
        exactFileRelativePath: String? = nil
    ) {
        guard [.movie, .episode].contains(item.kind),
              item.locallyValidatedPlayableSource,
              !item.isYouTubeTrailer,
              let accountID = item.sourceAccountID else { return nil }
        let startPosition = item.resumePosition ?? 0
        guard startPosition.isFinite, startPosition >= 0 else { return nil }
        self.startPosition = startPosition
        let sources = item.sources.filter { !item.rejectedSourceIDs.contains($0.id) }
        let currentSource = MediaSourceRef(accountID: accountID, itemID: item.id).id
        guard item.explicitSourceSelection || Set(sources.map(\.id) + [currentSource]).count == 1
        else { return nil }
        let versions = item.versions
        if versions.isEmpty || (versions.count == 1 && versions[0].playbackMediaSourceID == nil) {
            guard let path = exactFileRelativePath, !path.isEmpty,
                  item.selectedVersionID == nil || item.selectedVersionID == path else { return nil }
            if let version = versions.first {
                guard version.sourceAccountID == nil || version.sourceAccountID == accountID,
                      version.sourceItemID == nil || version.sourceItemID == item.id else { return nil }
            }
            self.accountID = accountID
            self.itemID = item.id
            self.kind = item.kind
            self.mediaSourceID = path
            self.sourceRevision = item.mediaInfo?.sourceRevision
            self.physicalFileRelativePath = path
            return
        }
        let selected: MediaVersion
        if versions.count == 1 {
            selected = versions[0]
            if let id = item.selectedVersionID,
               id != selected.id, id != selected.playbackMediaSourceID { return nil }
        } else {
            guard allowsMultipleVersions, item.explicitSourceSelection,
                  let id = item.selectedVersionID else { return nil }
            let matches = versions.filter { $0.id == id || $0.playbackMediaSourceID == id }
            guard matches.count == 1, let match = matches.first else { return nil }
            selected = match
        }
        guard selected.sourceAccountID == nil || selected.sourceAccountID == accountID,
              selected.sourceItemID == nil || selected.sourceItemID == item.id,
              let mediaSourceID = selected.playbackMediaSourceID else { return nil }
        self.accountID = accountID
        self.itemID = item.id
        self.kind = item.kind
        self.mediaSourceID = mediaSourceID
        self.sourceRevision = selected.sourceMetadata?.sourceRevision ?? item.mediaInfo?.sourceRevision
        self.physicalFileRelativePath = nil
    }

    func matchesHandoff(_ item: MediaItem) -> Bool {
        let position = item.resumePosition ?? 0
        guard position.isFinite, position >= 0 else { return false }
        // Start Over may choose a different time without invalidating the file cache.
        // Ordinary candidate equality still includes time and supersedes stale work.
        var handoffItem = item
        handoffItem.resumePosition = startPosition
        return Self(
            handoffItem, allowsMultipleVersions: true,
            exactFileRelativePath: physicalFileRelativePath
        ) == self
    }
}

public struct DetailPlaybackPreparationScope: Hashable, Sendable {
    public let profileID: String
    public let authorizationID: String
    public let accountID: String
    public let serverUserID: String
    public let credentialRevision: CredentialRevision

    public init(
        profileID: String, authorizationID: String, accountID: String,
        serverUserID: String, credentialRevision: CredentialRevision
    ) {
        self.profileID = profileID
        self.authorizationID = authorizationID
        self.accountID = accountID
        self.serverUserID = serverUserID
        self.credentialRevision = credentialRevision
    }

    public init?(
        webDAVAccount account: Account, profileID: String, authorizationID: String,
        credentialRevision: CredentialRevision, isAuthorized: Bool
    ) {
        guard isAuthorized, account.server.provider == .mediaShare,
              ["http", "https"].contains(account.server.baseURL.scheme?.lowercased() ?? "") else { return nil }
        self.init(
            profileID: profileID, authorizationID: authorizationID, accountID: account.id,
            serverUserID: account.userID, credentialRevision: credentialRevision
        )
    }
}

/// The transport owns its TTL and exact-key claim. Feature code only owns cancellation.
public struct DetailPlaybackPreparationReservation: Sendable {
    public let cancel: @Sendable () async -> Void
    public let requestPlaybackHandoff: @Sendable () async -> Void

    public init(cancel: @escaping @Sendable () async -> Void) {
        self.cancel = cancel
        self.requestPlaybackHandoff = {}
    }

    /// Opt-in pending tickets can stop warming while retaining source ownership.
    public init(
        cancel: @escaping @Sendable () async -> Void,
        requestPlaybackHandoff: @escaping @Sendable () async -> Void
    ) {
        self.cancel = cancel
        self.requestPlaybackHandoff = requestPlaybackHandoff
    }
}

public struct DetailPlaybackPreparationEnvironment {
    public var allowsMultipleVersions: Bool
    /// Must live-check authorization and return nil for non-WebDAV accounts.
    public let scope: @MainActor (String) -> DetailPlaybackPreparationScope?
    /// Provider-owned decoding of an already-known physical file ID, never a title default.
    private let exactFileRelativePath: @MainActor (MediaItem) -> String?
    private let provider: @MainActor (String) -> (any MediaProvider)?
    private let reserve: @MainActor (NetworkFileLocator, Double) async throws -> DetailPlaybackPreparationReservation
    var ownership: DetailPlaybackPreparationOwnership?

    public init(
        allowsMultipleVersions: Bool = false,
        scope: @escaping @MainActor (String) -> DetailPlaybackPreparationScope?,
        exactFileRelativePath: @escaping @MainActor (MediaItem) -> String? = { _ in nil },
        provider: @escaping @MainActor (String) -> (any MediaProvider)?,
        reserve: @escaping @MainActor (NetworkFileLocator, Double) async throws -> DetailPlaybackPreparationReservation
    ) {
        self.allowsMultipleVersions = allowsMultipleVersions
        self.scope = scope
        self.exactFileRelativePath = exactFileRelativePath
        self.provider = provider
        self.reserve = reserve
    }

    public static let disabled = Self(
        scope: { _ in nil }, provider: { _ in nil }, reserve: { _, _ in throw CancellationError() }
    )

    @MainActor
    func candidate(for item: MediaItem) -> DetailPlaybackPreparationCandidate? {
        guard let accountID = item.sourceAccountID, scope(accountID) != nil else { return nil }
        return DetailPlaybackPreparationCandidate(
            item, allowsMultipleVersions: allowsMultipleVersions,
            exactFileRelativePath: exactFileRelativePath(item)
        )
    }

    @MainActor
    func prepare(
        _ candidate: DetailPlaybackPreparationCandidate,
        scope expected: DetailPlaybackPreparationScope
    ) async throws -> DetailPlaybackPreparationReservation? {
        try Task.checkCancellation()
        guard scope(candidate.accountID) == expected,
              let provider = provider(candidate.accountID),
              provider.kind == .mediaShare else { return nil }
        let locator = try await provider.playbackPreparationLocator(
            for: candidate.itemID, mediaSourceID: candidate.mediaSourceID
        )
        try Task.checkCancellation()
        guard scope(candidate.accountID) == expected else { throw CancellationError() }
        guard let locator else { return nil }
        guard locator.accountID == candidate.accountID,
              locator.relativePath == candidate.mediaSourceID,
              locator.credentialRevision == expected.credentialRevision else { throw AppError.invalidResponse }
        let reservation = try await reserve(locator, candidate.startPosition)
        guard !Task.isCancelled, scope(candidate.accountID) == expected else {
            await reservation.cancel()
            return nil
        }
        return ownership?.retain(reservation, scope: expected) ?? reservation
    }
}

/// Shell-owned lifetime survives dismissal of the detail during Play, but not a
/// profile/authorization/account change. The resolver independently bounds it by TTL.
@MainActor
final class DetailPlaybackPreparationOwnership {
    private var id = UUID()
    private var reservation: DetailPlaybackPreparationReservation?
    private var scope: DetailPlaybackPreparationScope?
    private var expiry: Task<Void, Never>?

    func retain(
        _ reservation: DetailPlaybackPreparationReservation,
        scope: DetailPlaybackPreparationScope
    ) -> DetailPlaybackPreparationReservation {
        cancel()
        let id = self.id
        self.reservation = reservation
        self.scope = scope
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.cancel(id: id)
        }
        return DetailPlaybackPreparationReservation(
            cancel: { [weak self] in await self?.cancel(id: id) },
            requestPlaybackHandoff: { [weak self] in await self?.requestPlaybackHandoff(id: id) }
        )
    }

    func validate(using environment: DetailPlaybackPreparationEnvironment) {
        guard let scope else { return }
        if environment.scope(scope.accountID) != scope { cancel() }
    }

    private func cancel(id: UUID) {
        if self.id == id { cancel() }
    }

    private func requestPlaybackHandoff(id: UUID) async {
        guard self.id == id else { return }
        await reservation?.requestPlaybackHandoff()
    }

    private func cancel() {
        id = UUID()
        expiry?.cancel()
        expiry = nil
        if let reservation { Task { await reservation.cancel() } }
        reservation = nil
        scope = nil
    }
}

/// Page-owned, one-candidate preparation. No player, inventory discovery or playback admission.
@MainActor
public final class DetailPlaybackPreparationCoordinator {
    private struct Key: Equatable {
        let candidate: DetailPlaybackPreparationCandidate
        let scope: DetailPlaybackPreparationScope
    }
    private var key: Key?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var reservation: DetailPlaybackPreparationReservation?
    private var handedOff = false
    private var handoffWasStopped = false
    private let dwell: @Sendable () async throws -> Void
    private let prepare: @MainActor (
        DetailPlaybackPreparationCandidate, DetailPlaybackPreparationScope,
        DetailPlaybackPreparationEnvironment
    ) async throws -> DetailPlaybackPreparationReservation?

    public init() {
        dwell = { try await Task.sleep(for: .milliseconds(750)) }
        prepare = { try await $2.prepare($0, scope: $1) }
    }

    init(
        dwell: @escaping @Sendable () async throws -> Void,
        prepare: @escaping @MainActor (
            DetailPlaybackPreparationCandidate, DetailPlaybackPreparationScope,
            DetailPlaybackPreparationEnvironment
        ) async throws -> DetailPlaybackPreparationReservation?
    ) {
        self.dwell = dwell
        self.prepare = prepare
    }

    public func update(
        candidate: DetailPlaybackPreparationCandidate?,
        environment: DetailPlaybackPreparationEnvironment,
        isActive: Bool
    ) {
        let next = candidate.flatMap { candidate in
            environment.scope(candidate.accountID).map { Key(candidate: candidate, scope: $0) }
        }
        if key != next || (isActive && handoffWasStopped) { invalidate() }
        guard isActive, let next else {
            stop()
            return
        }
        guard key != next else { return }
        key = next
        let generation = self.generation
        let dwell = self.dwell
        let prepare = self.prepare
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.generation == generation else { return }
            PlozzLog.playback.error("Detail preparation exceeded its deadline")
            self.invalidate()
        }
        task = Task(priority: .utility) { [weak self] in
            defer {
                if self?.generation == generation {
                    self?.deadline?.cancel()
                    self?.deadline = nil
                }
            }
            do {
                try await dwell()
                try Task.checkCancellation()
                guard environment.scope(next.candidate.accountID) == next.scope else { return }
                let result = try await prepare(next.candidate, next.scope, environment)
                guard let self, !Task.isCancelled, self.generation == generation,
                      environment.scope(next.candidate.accountID) == next.scope else {
                    await result?.cancel()
                    return
                }
                self.reservation = result
            } catch is CancellationError {
                // Leaving or changing the page is expected, not a playback failure.
            } catch {
                guard !Task.isCancelled, (error as? AppError) != .cancelled else { return }
                PlozzLog.playback.error(
                    "Detail preparation failed type=\(String(describing: type(of: error)))"
                )
            }
        }
    }

    /// Preserve an exact returned reservation across the cover/resume/version gate.
    /// Legacy in-flight calls are still cancelled. An opt-in pending ticket can
    /// stop warming; the player's ordinary resolver still admits and claims.
    public func handoff(_ item: MediaItem) {
        guard key?.candidate.matchesHandoff(item) == true, let reservation else {
            invalidate()
            return
        }
        guard !handedOff else { return }
        handedOff = true
        Task { await reservation.requestPlaybackHandoff() }
        task?.cancel()
        task = nil
        deadline?.cancel()
        deadline = nil
    }

    public func stop() {
        if handedOff {
            handoffWasStopped = true
        } else {
            invalidate()
        }
    }

    /// Source/version changes and revoked identity must never preserve a handoff.
    public func invalidate() {
        generation = UUID()
        task?.cancel()
        task = nil
        deadline?.cancel()
        deadline = nil
        key = nil
        handedOff = false
        handoffWasStopped = false
        if let reservation {
            Task { await reservation.cancel() }
        }
        reservation = nil
    }
}
