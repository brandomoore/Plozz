import CoreModels
import CoreNetworking
import Foundation
import Observation

/// A presentation-owned gate, shared by initial play and episode/playlist advance.
/// No stream or engine is opened while a choice is pending.
@MainActor
@Observable
public final class PlaybackVersionChoiceModel {
    public struct Prompt: Equatable {
        public let id: UUID
        public let item: MediaItem
        public let versions: [MediaVersion]
        public let selectedVersionID: String?
        public var needsIntroduction: Bool
    }

    public private(set) var prompt: Prompt?
    @ObservationIgnored private var continuation: CheckedContinuation<MediaItem, Error>?
    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var settings: PlaybackSettingsModel?
    @ObservationIgnored private var preferences: (any VersionPreferenceStoring)?
    @ObservationIgnored private var isCurrent: () -> Bool = { false }
    @ObservationIgnored private var capabilities: MediaCapabilities = .default

    public init() {}

    public var isPreparing: Bool { owner != nil }

    public static func prepareWithFailover(
        _ opened: MediaItem,
        triedAccountIDs: Set<String>,
        prepare: (MediaItem) async throws -> MediaItem,
        nextSource: (MediaItem, Set<String>) -> MediaItem?,
        isCurrent: () -> Bool
    ) async throws -> (item: MediaItem, triedAccountIDs: Set<String>) {
        var item = opened
        var tried = triedAccountIDs
        while true {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            do {
                let prepared = try await prepare(item)
                try Task.checkCancellation()
                guard isCurrent() else { throw CancellationError() }
                return (prepared, tried)
            } catch {
                try Task.checkCancellation()
                guard isCurrent(), !(error is CancellationError), (error as? AppError) != .cancelled else {
                    throw CancellationError()
                }
                guard !item.explicitSourceSelection,
                      let failedAccount = item.selectedSourceAccountID ?? item.sourceAccountID,
                      tried.insert(failedAccount).inserted,
                      let next = nextSource(item, tried),
                      let nextAccount = next.selectedSourceAccountID ?? next.sourceAccountID,
                      !tried.contains(nextAccount) else { throw error }
                _ = reportFailure(error, stage: "inventory-failover")
                item = next
            }
        }
    }

    public func prepare(
        _ opened: MediaItem,
        provider: any MediaProvider,
        settings: PlaybackSettingsModel,
        preferences: any VersionPreferenceStoring,
        offlineResolver: (any OfflinePlaybackResolving)? = nil,
        sourceResolver: (@Sendable (MediaItem) async -> CrossServerSourceResolution)? = nil,
        capabilities: MediaCapabilities = .detected(),
        isCurrent: @escaping () -> Bool = { true }
    ) async throws -> MediaItem {
        guard owner == nil else {
            PlozzLog.playback.error("A version choice is already pending.")
            throw AppError.invalidResponse
        }
        guard [.movie, .episode].contains(opened.kind), opened.youTubeTrailerVideoID == nil else {
            return opened
        }
        let id = UUID()
        owner = id
        defer { clear(owner: id) }
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        var item = opened
        let local = await offlineResolver?.localPlaybackURL(for: opened, versionID: opened.selectedVersionID)
        try Task.checkCancellation()
        guard owner == id, isCurrent() else { throw CancellationError() }
        if local == nil {
            let resolved = try await PlaybackPreparationDiagnostics.capture(provider: provider.kind, operation: .versions) {
                try await provider.playbackItem(id: opened.id)
            }
            try Task.checkCancellation()
            guard owner == id, isCurrent() else { throw CancellationError() }
            guard resolved.id == opened.id, resolved.kind == opened.kind,
                  resolved.sourceAccountID == nil || resolved.sourceAccountID == opened.sourceAccountID else {
                PlaybackPreparationDiagnostics.identityFailure(
                    provider: provider.kind, operation: .versions, expectedID: opened.id,
                    expectedKind: opened.kind, expectedAccountID: opened.sourceAccountID, resolved: resolved
                )
                PlozzLog.playback.error("Version details did not match the requested title.")
                throw AppError.invalidResponse
            }
            item = PlayerVersionSelection.item(opened: opened, resolved: resolved, authoritativeVersions: true)
            if item.seriesID == nil { item.seriesID = resolved.seriesID }
            if let sourceResolver {
                var discoveryItem = resolved
                discoveryItem.sourceAccountID = item.sourceAccountID
                discoveryItem.sources = item.sources
                discoveryItem.rejectedSourceIDs.formUnion(item.rejectedSourceIDs)
                let discovery = await sourceResolver(discoveryItem)
                try Task.checkCancellation()
                guard owner == id, isCurrent() else { throw CancellationError() }
                item.rejectedSourceIDs.formUnion(discovery.rejectedSourceIDs)
                let rejected = item.rejectedSourceIDs
                item.sources.removeAll { rejected.contains($0.id) }
                var known = Set(item.sources.map(\.id))
                for source in discovery.sources
                where !item.rejectedSourceIDs.contains(source.id) && known.insert(source.id).inserted {
                    item.sources.append(source)
                }
            }
            item = try await Self.resolvingAlternateInventories(in: item, provider: provider) {
                self.owner == id && isCurrent()
            }
            if !item.explicitSourceSelection {
                item.selectedVersionID = nil
            }
        } else {
            return opened
        }
        try Task.checkCancellation()
        guard owner == id, isCurrent() else { throw CancellationError() }
        let versions = PlayerVersionSelection.versions(for: item)
        guard versions.count > 1 else { return item }
        let selectedID = DetailPlaybackSelection.preferredVersionID(
            for: item, versions: versions, versionOverride: nil,
            preferences: preferences, capabilities: capabilities
        )
        if settings.settings.versionSelectionMode == .automatic {
            guard let selectedID,
                  let selected = PlayerVersionSelection.selecting(
                    selectedID, in: item, explicit: item.explicitSourceSelection
                  ) else {
                PlozzLog.playback.error("Could not resolve an automatic playback version.")
                throw AppError.invalidResponse
            }
            return selected
        }
        self.settings = settings
        self.preferences = preferences
        self.isCurrent = isCurrent
        self.capabilities = capabilities
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                prompt = Prompt(
                    id: id, item: item, versions: versions, selectedVersionID: selectedID,
                    needsIntroduction: settings.settings.versionSelectionMode == nil
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(owner: id) }
        }
    }

    static func resolvingAlternateInventories(
        in opened: MediaItem, provider: any MediaProvider, isCurrent: () -> Bool
    ) async throws -> MediaItem {
        var item = opened
        for index in item.sources.indices
        where item.sources[index].accountID == item.sourceAccountID
            && item.sources[index].itemID == item.id
            && (item.sources[index].kind == nil || item.sources[index].kind == item.kind) {
            item.sources[index].versions = item.versions.isEmpty
                ? [MediaVersion.synthesized(from: item)] : item.versions
        }
        var unavailableAlternates = Set<String>()
        for index in item.sources.indices
        where item.sources[index].accountID == item.sourceAccountID
            && item.sources[index].itemID != item.id
            && (item.sources[index].kind == nil || item.sources[index].kind == item.kind) {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            let source = item.sources[index]
            do {
                let alternate = try await PlaybackPreparationDiagnostics.capture(
                    provider: provider.kind, operation: .alternateVersions
                ) {
                    try await provider.playbackItem(id: source.itemID)
                }
                try Task.checkCancellation()
                guard isCurrent() else { throw CancellationError() }
                guard alternate.id == source.itemID, alternate.kind == item.kind,
                      alternate.sourceAccountID == nil || alternate.sourceAccountID == source.accountID else {
                    PlaybackPreparationDiagnostics.identityFailure(
                        provider: provider.kind, operation: .alternateVersions, expectedID: source.itemID,
                        expectedKind: item.kind, expectedAccountID: source.accountID, resolved: alternate
                    )
                    PlozzLog.playback.error("Version details did not match the alternate source.")
                    throw AppError.invalidResponse
                }
                item.sources[index].versions = alternate.versions.isEmpty
                    ? [MediaVersion.synthesized(from: alternate)] : alternate.versions
                item.sources[index].edition = alternate.edition ?? source.edition
            } catch {
                try Task.checkCancellation()
                guard isCurrent(), !(error is CancellationError),
                      (error as? AppError) != .cancelled else { throw CancellationError() }
                _ = reportFailure(error, stage: "alternate-inventory")
                unavailableAlternates.insert(source.id)
            }
        }
        item.sources.removeAll { unavailableAlternates.contains($0.id) }
        return item
    }

    public func chooseMode(_ mode: PlaybackVersionSelectionMode, promptID: UUID) {
        guard let prompt, prompt.id == promptID, prompt.needsIntroduction else { return }
        guard isCurrent() else { cancel(); return }
        settings?.settings.versionSelectionMode = mode
        if mode == .askEveryTime {
            self.prompt?.needsIntroduction = false
        } else {
            guard let preferences,
                  let id = DetailPlaybackSelection.preferredVersionID(
                    for: prompt.item, versions: prompt.versions, versionOverride: nil,
                    preferences: preferences, capabilities: capabilities
                  ),
                  let item = PlayerVersionSelection.selecting(
                    id, in: prompt.item, explicit: prompt.item.explicitSourceSelection
                  ) else {
                PlozzLog.playback.error("Could not resolve the first automatic playback version.")
                finish(.failure(AppError.invalidResponse), owner: prompt.id)
                return
            }
            finish(.success(item), owner: prompt.id)
        }
    }

    public func chooseVersion(_ versionID: String, promptID: UUID) {
        guard let prompt, prompt.id == promptID, !prompt.needsIntroduction else { return }
        guard isCurrent() else { cancel(); return }
        guard let version = prompt.versions.first(where: { $0.id == versionID }),
              let item = PlayerVersionSelection.selecting(versionID, in: prompt.item) else {
            PlozzLog.playback.error("The requested playback version is no longer available.")
            return
        }
        if let preferences, preferences.shouldRememberVersion(for: prompt.item) {
            preferences.rememberVersion(version, forTitle: DetailPlaybackSelection.versionPreferenceKey(for: prompt.item))
            if DetailPlaybackSelection.versionPreferenceKey(for: item)
                != DetailPlaybackSelection.versionPreferenceKey(for: prompt.item) {
                preferences.rememberVersion(version, forTitle: DetailPlaybackSelection.versionPreferenceKey(for: item))
            }
        }
        finish(.success(item), owner: prompt.id)
    }

    public func cancel() {
        guard let owner else { return }
        cancel(owner: owner)
    }

    public static func reportFailure(_ error: Error, stage: String = "preparation") -> LocalizedStringResource {
        let code: String
        let message: LocalizedStringResource
        if let streaming = error as? StreamingQualityError {
            code = streaming.diagnosticCode ?? "unspecified"
            message = streaming.userMessage
        } else if let app = error as? AppError {
            code = HandoffDiagnostics.errorCode(app)
            message = app.userMessage
        } else {
            code = "unknown"
            message = StreamingQualityError.negotiationFailed.userMessage
        }
        PlozzLog.playback.error("Could not prepare playback versions: \(code)")
        HandoffDiagnostics.emit("versions FAILED stage=\(stage) code=\(code)")
        return message
    }

    private func cancel(owner id: UUID) {
        finish(.failure(CancellationError()), owner: id)
    }

    private func finish(_ result: Result<MediaItem, Error>, owner id: UUID) {
        guard owner == id else { return }
        let continuation = self.continuation
        clear(owner: id)
        continuation?.resume(with: result)
    }

    private func clear(owner id: UUID) {
        guard owner == id else { return }
        prompt = nil
        continuation = nil
        settings = nil
        preferences = nil
        isCurrent = { false }
        owner = nil
    }

}
