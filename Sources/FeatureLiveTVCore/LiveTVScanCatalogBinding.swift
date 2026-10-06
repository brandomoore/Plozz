import CoreModels
import Foundation
import Observation

@MainActor
@Observable
public final class LiveTVScanCatalogBinding {
    private static var activeBindings: [String: WeakBinding] = [:]
    public let coordinator: LiveTVChannelScanCoordinator
    public private(set) var issue: LiveTVChannelScanError?
    @ObservationIgnored private let profileID: String
    @ObservationIgnored private let ownershipID = UUID()
    @ObservationIgnored private weak var model: LiveTVPrototypeModel?
    @ObservationIgnored private let authorization:
        @MainActor (LiveTVSourcesConfiguration) throws -> LiveTVSourceAuthorization
    @ObservationIgnored private var configuration = LiveTVSourcesConfiguration.empty
    @ObservationIgnored private var channels: [LiveTVPrototypeChannel] = []
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var ownsScan = false
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var preparationID = UUID()
    @ObservationIgnored private var preparedInput: (
        authority: LiveTVSourceAuthorization, playlists: [LiveTVPlaylistSource], channels: [LiveTVPrototypeChannel]
    )?

    public init(
        profileID: String, model: LiveTVPrototypeModel,
        coordinator: LiveTVChannelScanCoordinator,
        authorization: @escaping @MainActor (LiveTVSourcesConfiguration) throws -> LiveTVSourceAuthorization
    ) {
        self.profileID = profileID
        self.model = model
        self.coordinator = coordinator
        self.authorization = authorization
    }

    deinit {
        preparation?.cancel()
        // Avoid the isolated-deinit back-deployment thunk on older Swift
        // runtimes while keeping cleanup on the main actor.
        let cleanup: @MainActor @Sendable () -> Void = {
            [coordinator, weak model, profileID, ownershipID] in
            if Self.activeBindings[profileID]?.ownershipID == ownershipID {
                Self.activeBindings.removeValue(forKey: profileID)
            }
            coordinator.deactivate()
            model?.setScanHiddenChannelIDs([])
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { cleanup() }
        } else {
            Task { @MainActor in cleanup() }
        }
    }

    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            let previous = Self.activeBindings[profileID]?.value
            previous?.revokeScan()
            Self.activeBindings[profileID] = WeakBinding(self)
            ownsScan = true
            bind()
        } else {
            releaseScan()
        }
    }

    public func updateCatalog(_ configuration: LiveTVSourcesConfiguration, channels: [LiveTVPrototypeChannel]) {
        self.configuration = configuration
        self.channels = channels
        if isActive && ownsScan { bind() }
    }

    public func invalidate(_ sourceIDs: Set<String>) {
        cancelPreparation()
        if coordinator.isPreparingCatalog { coordinator.deactivate() }
        for id in sourceIDs { coordinator.invalidate(sourceID: id) }
        synchronizeVisibility()
    }

    public func deactivate() {
        isActive = false
        releaseScan()
    }

    public func retry() {
        guard isActive && ownsScan else { return }
        bind()
    }

    public func waitUntilPrepared() async {
        await preparation?.value
    }

    public func synchronizeVisibility() {
        model?.setScanHiddenChannelIDs(coordinator.scanHiddenChannelIDs)
    }

    private func clearRuntime() {
        cancelPreparation()
        coordinator.deactivate()
        model?.setScanHiddenChannelIDs([])
    }

    private func revokeScan() {
        // Keep the active request latched: background catalog updates must not
        // steal ownership back from the newly presented destination.
        ownsScan = false
        clearRuntime()
    }

    private func releaseScan() {
        if Self.activeBindings[profileID]?.value === self {
            Self.activeBindings.removeValue(forKey: profileID)
        }
        revokeScan()
    }

    private final class WeakBinding {
        let ownershipID: UUID
        weak var value: LiveTVScanCatalogBinding?
        init(_ value: LiveTVScanCatalogBinding) {
            self.value = value
            ownershipID = value.ownershipID
        }
    }

    private func bind() {
        do {
            let authority = try authorization(configuration)
            guard authority.profileID == profileID else { throw LiveTVChannelScanError.sourceUnavailable }
            let playlists = authority.filtering(configuration).playlists.filter(\.isEnabled)
            if let input = preparedInput,
               input.authority == authority, input.playlists == playlists, input.channels == channels {
                return
            }
            clearRuntime()
            coordinator.beginCatalogPreparation()
            issue = nil
            preparedInput = (authority, playlists, channels)
            let channels = channels
            let profileID = profileID
            let request = preparationID
            let worker = Task.detached(priority: .utility) {
                let sources = try playlists.map {
                    try Task.checkCancellation()
                    return try LiveTVChannelScanSource(source: $0, channels: channels)
                }
                return try LiveTVChannelScanCoordinator.prepareCatalog(profileID: profileID, sources: sources)
            }
            preparation = Task { [weak self] in
                do {
                    let catalog = try await withTaskCancellationHandler {
                        try await worker.value
                    } onCancel: {
                        worker.cancel()
                    }
                    try Task.checkCancellation()
                    guard let self, self.preparationID == request, self.isActive, self.ownsScan else { return }
                    guard try self.authorization(self.configuration) == authority else {
                        throw LiveTVChannelScanError.sourceUnavailable
                    }
                    try self.coordinator.bind(catalog)
                    self.preparation = nil
                    self.synchronizeVisibility()
                } catch {
                    guard !Task.isCancelled, let self, self.preparationID == request else { return }
                    self.fail(error)
                }
            }
        } catch {
            fail(error)
        }
    }

    private func cancelPreparation() {
        preparation?.cancel()
        preparation = nil
        preparationID = UUID()
        preparedInput = nil
    }

    private func fail(_ error: Error) {
        issue = (error as? LiveTVChannelScanError) ?? .sourceUnavailable
        clearRuntime()
        HandoffDiagnostics.emit("LIVE_TV event=scanCatalogUnavailable")
    }
}
