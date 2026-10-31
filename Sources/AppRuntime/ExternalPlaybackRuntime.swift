import CoreModels
import CoreNetworking
import CryptoKit
import FeaturePlayback
import Foundation
import Observation
import os
import UIKit

public struct ExternalPlaybackCompletion: Sendable {
    public let id: UUID
    public let item: MediaItem
    public let position: TimeInterval
    public let watchedPercent: Double
    public let reportedAt: Date

    public func enqueue(_ mutation: WatchMutation, using reconciler: WatchStateReconciler) async throws -> Bool {
        let persisted = OSAllocatedUnfairLock(initialState: false)
        let accepted = await reconciler.enqueue(mutation) {
            persisted.withLock { $0 = true }
        }
        guard !accepted || persisted.withLock({ $0 }) else { throw ExternalPlayerError.persistence }
        if accepted { Task { await reconciler.drain() } }
        return accepted
    }
}

@MainActor
public struct ExternalPlaybackContext {
    public let profileID: String
    public let authorizationID: String
    public let accounts: [ResolvedAccount]
    public let isAuthorized: Bool
    public let resolver: any AuthenticatedHTTPResourceResolving
    public let offlineResolver: (any OfflinePlaybackResolving)?

    public init(
        profileID: String, authorizationID: String, accounts: [ResolvedAccount],
        isAuthorized: Bool, resolver: any AuthenticatedHTTPResourceResolving,
        offlineResolver: (any OfflinePlaybackResolving)? = nil
    ) {
        self.profileID = profileID
        self.authorizationID = authorizationID
        self.accounts = accounts
        self.isAuthorized = isAuthorized
        self.resolver = resolver
        self.offlineResolver = offlineResolver
    }

    public var identity: String {
        ([profileID, authorizationID, String(isAuthorized)] + accounts.map {
            "\($0.account.connectionScopeKey):\($0.provider.session.userID):\($0.credentialRevision.rawValue)"
        }).joined(separator: "|")
    }
}

@MainActor
@Observable
public final class ExternalPlaybackRuntime {
    public static let shared = ExternalPlaybackRuntime()

    struct Owner: Codable, Equatable {
        let profileID: String
        let accountID: String
        let userID: String
        let credentialRevision: CredentialRevision

        init(profileID: String, account: ResolvedAccount) {
            self.profileID = profileID
            accountID = account.account.id
            userID = account.provider.session.userID
            credentialRevision = account.credentialRevision
        }
    }

    /// Only correlation and non-secret identity survive suspension or termination.
    /// Media URLs, tokens, subtitle URLs and provider metadata never enter this record.
    struct Receipt: Codable {
        let id: UUID
        let owner: Owner
        let itemID: String
        let player: ExternalPlayer
        let mediaURLDigest: String
        let duration: TimeInterval?
        let createdAt: Date
        var position: TimeInterval?
        var progress: Double?
        var returnedAt: Date?
        var failed = false
    }

    public var error: ExternalPlayerError?
    private(set) var receipt: Receipt?
    private let defaults: UserDefaults
    private let storageKey = "com.plozz.externalPlaybackReceipt"
    private let callbackScheme: String
    private let canOpen: @MainActor (URL) -> Bool
    private let open: @MainActor (URL) async -> Bool
    private var processingTask: Task<Void, Never>?
    private var launchID = UUID()
    @ObservationIgnored private var foregroundDepartureProfileID: String?

    /// Only the next scene departure belongs to this handoff, not a later browsing session.
    public func consumeForegroundDeparture(forProfile profileID: String) -> Bool {
        defer { foregroundDepartureProfileID = nil }
        return foregroundDepartureProfileID == profileID
    }

    public var returnID: UUID? {
        guard let receipt, receipt.position != nil || receipt.failed else { return nil }
        return receipt.id
    }

    public init(
        defaults: UserDefaults = .standard,
        callbackScheme: String = (Bundle.main.bundleIdentifier ?? "com.thatcube.Plozz") + ".external-player",
        canOpen: @escaping @MainActor (URL) -> Bool = { UIApplication.shared.canOpenURL($0) },
        open: @escaping @MainActor (URL) async -> Bool = { await UIApplication.shared.open($0) }
    ) {
        self.defaults = defaults
        self.callbackScheme = callbackScheme
        self.canOpen = canOpen
        self.open = open
        if let data = defaults.data(forKey: storageKey) {
            do {
                receipt = try JSONDecoder().decode(Receipt.self, from: data)
            } catch {
                PlozzLog.playback.error("Unable to restore external playback receipt.")
                self.error = .persistence
            }
        }
    }

    /// Every new ordinary play intent supersedes an older external return.
    public func beginPlaybackIntent() {
        foregroundDepartureProfileID = nil
        processingTask?.cancel()
        launchID = UUID()
        clearReceipt()
    }

    public func launch(
        item: MediaItem, startPosition: TimeInterval?, settings: PlaybackSettings,
        selection: ExternalPlayerSettings,
        streamingOptions: StreamingPlaybackOptions? = nil,
        context: @escaping @MainActor () -> ExternalPlaybackContext,
        isPresented: @escaping @MainActor () -> Bool
    ) async throws -> Bool {
        let initial = context()
        let generation = launchID
        do {
            return try await launchIfSupported(
                item: item, startPosition: startPosition, settings: settings, selection: selection,
                streamingOptions: streamingOptions, context: context, isPresented: isPresented
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard initial.isAuthorized, isPresented(), generation == launchID,
                  context().identity == initial.identity else { throw CancellationError() }
            if let failure = error as? ExternalPlayerError,
               failure == .unsupportedSource || failure == .unavailable {
                PlozzLog.playback.info("External player unavailable for this source; using Plozz.")
            } else {
                PlozzLog.playback.error("External player preparation failed; retrying playback in Plozz.")
            }
            return false
        }
    }

    private func launchIfSupported(
        item: MediaItem, startPosition: TimeInterval?, settings: PlaybackSettings,
        selection: ExternalPlayerSettings, streamingOptions: StreamingPlaybackOptions?,
        context: @escaping @MainActor () -> ExternalPlaybackContext,
        isPresented: @escaping @MainActor () -> Bool
    ) async throws -> Bool {
        guard selection.player != .builtIn else { return false }
        // Trailer, live-channel and music sessions remain owned by their existing runtimes.
        guard item.kind == .movie || item.kind == .episode else { return false }
        let generation = launchID
        let initial = context()
        guard initial.isAuthorized,
              let account = initial.accounts.first(where: { $0.account.id == item.sourceAccountID })
                ?? (item.sourceAccountID == nil ? initial.accounts.first : nil)
        else { throw CancellationError() }
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard isPresented(), generation == launchID, context().identity == initial.identity else {
                throw CancellationError()
            }
        }
        try checkCurrent()
        switch account.provider.kind {
        case .iptv, .mediaShare, .silo:
            // These sources need Plozz's transport or session lifecycle. Do not
            // negotiate an external stream or expose credentials speculatively.
            PlozzLog.playback.info("Source requires Plozz playback; skipping external player.")
            return false
        case .jellyfin, .emby, .plex:
            break
        }
        guard selection.player == .custom || ExternalPlayer.supported.contains(selection.player) else {
            throw ExternalPlayerError.unavailable
        }
        if let scheme = selection.player.scheme, let url = URL(string: scheme + "://"), !canOpen(url) {
            throw ExternalPlayerError.unavailable
        }
        if selection.player == .custom {
            try ExternalPlayerURL.validateCustomTemplate(selection.customURLTemplate)
        }
        guard streamingOptions?.requiresConversionPolicy != true else {
            throw ExternalPlayerError.unsupportedSource
        }
        if let offlineResolver = initial.offlineResolver,
           await offlineResolver.localPlaybackURL(for: item, versionID: item.selectedVersionID) != nil {
            throw ExternalPlayerError.unsupportedSource
        }
        try checkCurrent()
        let provider = account.provider
        let request = try await provider.playbackInfo(
            for: item.id, mediaSourceID: item.selectedVersionID, forceTranscode: false
        )
        do {
            try checkCurrent()
            guard request.externalAudioURL == nil, !request.isTranscoding,
                  request.deliveryMode == .directPlay, request.streamingSessionID == nil,
                  !request.suppressOrdinaryWatchReporting else {
                throw ExternalPlayerError.unsupportedSource
            }
            let mediaURL = try await resolveURL(
                source: request.playbackSource, fallback: request.streamURL, resolver: initial.resolver
            )
            try checkCurrent()
            var subtitles: [URL] = []
            if selection.player != .custom {
                for track in request.subtitleTracks where !track.isBitmapSubtitle
                    && ["srt", "subrip"].contains(track.codec?.lowercased() ?? "") {
                    guard case .authenticatedHTTP(let locator) = track.deliverySource else { continue }
                    let url = try await initial.resolver.resolve(locator)
                    try checkCurrent()
                    if ExternalPlayerURL.isSupportedMediaURL(url) { subtitles.append(url) }
                    if subtitles.count == 8 { break }
                }
            }
            let nonce = UUID()
            let link = try ExternalPlayerURL.make(
                settings: selection, mediaURL: mediaURL,
                title: request.sourceFileName ?? request.item.title,
                position: settings.resumeRewindInterval.applied(to: startPosition ?? request.startPosition),
                subtitles: subtitles, callbackScheme: callbackScheme, nonce: nonce
            )
            try checkCurrent()
            if selection.player.returnsProgress {
                try save(Receipt(
                    id: nonce, owner: Owner(profileID: initial.profileID, account: account),
                    itemID: item.id, player: selection.player, mediaURLDigest: Self.digest(mediaURL),
                    duration: request.item.runtime.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                    createdAt: Date()
                ))
            }
            foregroundDepartureProfileID = initial.profileID
            guard await open(link) else {
                foregroundDepartureProfileID = nil
                if receipt?.id == nonce { clearReceipt() }
                throw ExternalPlayerError.unavailable
            }
            try checkCurrent()
            PlozzLog.playback.info("Opened external player.")
            return true
        } catch {
            foregroundDepartureProfileID = nil
            if let streaming = provider as? any StreamingQualityProviding {
                var cleanupRequest = request
                if cleanupRequest.streamingSessionID == nil,
                   request.isTranscoding || request.deliveryMode != .directPlay {
                    cleanupRequest.streamingSessionID = request.playSessionID
                }
                if cleanupRequest.streamingSessionID != nil {
                    await streaming.releaseStreamingSession(cleanupRequest)
                }
            }
            throw error
        }
    }

    private func resolveURL(
        source: PlaybackSource?, fallback: URL?, resolver: any AuthenticatedHTTPResourceResolving
    ) async throws -> URL {
        let url: URL
        switch source {
        case .authenticatedHTTP(let locator):
            guard locator.deliveryMode == .directFile else { throw ExternalPlayerError.unsupportedSource }
            url = try await resolver.resolve(locator)
        case .publicURL(let source): url = source.url
        case .networkFile, .dlnaResource: throw ExternalPlayerError.unsupportedSource
        case .none:
            guard let fallback else { throw ExternalPlayerError.unsupportedSource }
            url = fallback
        }
        guard ExternalPlayerURL.isSupportedMediaURL(url) else { throw ExternalPlayerError.unsupportedSource }
        return url
    }

    @discardableResult
    public func receive(_ url: URL, now: Date = Date()) -> Bool {
        guard url.scheme?.caseInsensitiveCompare(callbackScheme) == .orderedSame,
              url.host?.lowercased() == "external-player" else { return false }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let values = components.queryItems,
              values.filter({ $0.name == "session" }).count == 1,
              let token = values.first(where: { $0.name == "session" })?.value,
              var pending = receipt, UUID(uuidString: token) == pending.id,
              pending.position == nil, !pending.failed else {
            PlozzLog.playback.info("Ignored an unmatched external player callback.")
            return true
        }
        do {
            guard now.timeIntervalSince(pending.createdAt) >= 0,
                  now.timeIntervalSince(pending.createdAt) < 24 * 60 * 60 else {
                throw ExternalPlayerError.expiredCallback
            }
            if url.path == "/error" {
                pending.failed = true
            } else {
                guard url.path == "/success",
                      values.filter({ $0.name == "position" }).count == 1,
                      values.filter({ $0.name == "lastPlayedUrl" }).count == 1,
                      let position = values.first(where: { $0.name == "position" })?.value.flatMap(Double.init),
                      position.isFinite, position >= 0, position < 24 * 60 * 60 * 30,
                      let played = values.first(where: { $0.name == "lastPlayedUrl" })?.value.flatMap(URL.init(string:)),
                      Self.digest(played) == pending.mediaURLDigest else {
                    throw ExternalPlayerError.invalidCallback
                }
                if pending.player == .nativePlayer {
                    let progressValues = values.filter { $0.name == "progress" }
                    guard progressValues.count <= 1 else { throw ExternalPlayerError.invalidCallback }
                    if let reported = progressValues.first {
                        guard let progress = reported.value.flatMap(Double.init),
                              progress.isFinite, (0...1).contains(progress) else {
                            throw ExternalPlayerError.invalidCallback
                        }
                        pending.progress = progress
                    }
                }
                if pending.progress == nil, let duration = pending.duration, position > duration + 5 {
                    throw ExternalPlayerError.invalidCallback
                }
                pending.position = position
            }
            pending.returnedAt = now
            try save(pending)
        } catch let failure as ExternalPlayerError {
            clearReceipt()
            error = failure
            PlozzLog.playback.error("Rejected external playback result.")
        } catch {
            self.error = .persistence
            PlozzLog.playback.error("Unable to save external playback result.")
        }
        return true
    }

    public func processReturn(
        context: @escaping @MainActor () -> ExternalPlaybackContext,
        onProgress: @escaping @MainActor (ExternalPlaybackCompletion) async throws -> Void
    ) async {
        while let task = processingTask {
            await task.value
            if Task.isCancelled { return }
        }
        guard !Task.isCancelled, returnID != nil else { return }
        let task = Task {
            await consumeReturn(context: context, onProgress: onProgress)
            processingTask = nil
        }
        processingTask = task
        await task.value
    }

    private func consumeReturn(
        context: @escaping @MainActor () -> ExternalPlaybackContext,
        onProgress: @escaping @MainActor (ExternalPlaybackCompletion) async throws -> Void
    ) async {
        guard let pending = receipt else { return }
        let initial = context()
        guard initial.isAuthorized,
              let account = initial.accounts.first(where: {
                  Owner(profileID: initial.profileID, account: $0) == pending.owner
              }) else { return }
        func current() -> Bool {
            !Task.isCancelled && receipt?.id == pending.id && context().identity == initial.identity
        }
        if pending.failed {
            clearReceipt()
            error = .playbackFailed
            return
        }
        do {
            var item = try await account.provider.item(id: pending.itemID)
            guard current(), let position = pending.position else { return }
            guard item.id == pending.itemID, item.kind == .movie || item.kind == .episode,
                  item.sourceAccountID == nil || item.sourceAccountID == account.account.id else {
                throw ExternalPlayerError.invalidCallback
            }
            item = item.taggingSource(account.account.id)
            let duration = pending.duration ?? item.runtime.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            if pending.progress == nil, let duration, position > duration + 5 {
                throw ExternalPlayerError.invalidCallback
            }
            // Native Player measures the actual file; catalog runtimes can describe
            // a different edition. Infuse and older receipts retain the runtime fallback.
            let boundedPosition = pending.progress != nil
                ? position : duration.map { min(position, max(0, $0)) } ?? position
            let percent = pending.progress.map { $0 * 100 } ?? WatchProgressMath.watchedPercent(
                position: boundedPosition, engineDuration: duration ?? 0, itemRuntime: nil
            )
            // The durable outbox owns retries and cross-server/tracker convergence.
            try await onProgress(ExternalPlaybackCompletion(
                id: pending.id, item: item, position: boundedPosition, watchedPercent: percent,
                reportedAt: pending.returnedAt ?? pending.createdAt
            ))
            guard current() else { return }
            clearReceipt()
        } catch ExternalPlayerError.invalidCallback {
            if current() {
                clearReceipt()
                error = .invalidCallback
            }
        } catch is CancellationError {
            return
        } catch {
            PlozzLog.playback.error("Unable to reconcile external playback progress.")
            if current() { self.error = .progressSyncFailed }
        }
    }

    private func save(_ value: Receipt) throws {
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: storageKey)
            receipt = value
        } catch {
            PlozzLog.playback.error("Unable to encode external playback receipt.")
            throw ExternalPlayerError.persistence
        }
    }

    private func clearReceipt() {
        defaults.removeObject(forKey: storageKey)
        receipt = nil
    }

    static func digest(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
