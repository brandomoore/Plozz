#if canImport(SwiftUI)
import SwiftUI
import AppRuntime
import CoreModels
import CoreNetworking
import CoreUI
import FeatureHome
import FeatureHomeCore
import FeatureMusic
import FeaturePlayback
import MediaTransportCore
import MetadataKit
import FeatureSearch
import FeatureSettings
import FeatureProfiles
import RatingsService
import TraktService
import SeerService
import SimklService
import AniListService
import MALService
import LastFmService

/// Hosts the full-screen player and builds its ``PlayerViewModel`` exactly once,
/// off the render path.
///
/// Constructing the view model inline inside a `.fullScreenCover` content closure
/// is a trap: SwiftUI re-invokes that closure on every parent render, and because
/// ``PlayerView`` keeps the model in `@State` (the first value wins), every extra
/// invocation builds a throwaway `PlayerViewModel` — and a throwaway
/// `NativeVideoEngine` at its `init` — that is discarded immediately. Under the
/// player's own `@Observable` mutation churn this becomes self-reinforcing: each
/// render spawns engines that storm `AttributeGraph`, which drives more renders.
/// On device this showed up as the live VM/Native instance counters racing
/// upward (Native far ahead of VM, since every model makes a native engine before
/// it ever routes to an engine), thermal throttling, and growing lag the longer the
/// player stayed up.
///
/// Building the model in `.task`, gated by this view's identity, fires the factory
/// once per presentation instead of once per render.
///
/// **Episode advance**: when a `PlayerViewModel` sets its `pendingNextEpisode`,
/// this view swaps the VM in-place — the `Color.black` ZStack stays up so the
/// full-screen cover never dismisses and the series page never flashes through.
@MainActor
struct PlayerPresentation: View {
    let make: (PlayRequest, PlayerViewModel.PrefetchedPlayback?, PlaybackContinuation?) throws -> PlayerViewModel
    /// Re-selects the next-best source after the current target fails to start,
    /// excluding every account already attempted; `nil` means no untried source
    /// remains, so the player's own error state stays on screen (r8-play-failover).
    let makeFailover: (_ failedItem: MediaItem, _ tried: Set<String>) -> MediaItem?
    let showDiagnostics: Bool
    let themePalette: ThemePalette
    let versionPreferences: any VersionPreferenceStoring
    let prepareVersion: (PlaybackVersionChoiceModel, MediaItem) async throws -> MediaItem
    let versionAuthorizationScope: [String]
    let playbackSettings: PlaybackSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.externalPlaybackContext) private var externalContext
    @State private var versionChoice = PlaybackVersionChoiceModel()
    @State private var versionChoiceFailed = false
    @State private var sourceUnavailable = false
    @State private var versionChoiceFailureMessage: LocalizedStringResource = "Please try playing this video again."

    /// The currently-active play request; changes when auto-advancing episodes.
    @State private var activeRequest: PlayRequest
    @State private var viewModel: PlayerViewModel?
    /// Source account IDs already attempted for the active title, so failover never
    /// re-tries a server that already failed and can detect true exhaustion. Reset
    /// whenever the title changes (episode auto-advance).
    @State private var triedAccountIDs: Set<String> = []
    @State private var handoffTask: Task<Void, Never>?
    @State private var isPresented = true

    init(
        request: PlayRequest,
        make: @escaping (PlayRequest, PlayerViewModel.PrefetchedPlayback?, PlaybackContinuation?) throws -> PlayerViewModel,
        makeFailover: @escaping (_ failedItem: MediaItem, _ tried: Set<String>) -> MediaItem?,
        showDiagnostics: Bool,
        themePalette: ThemePalette,
        versionPreferences: any VersionPreferenceStoring,
        prepareVersion: @escaping (PlaybackVersionChoiceModel, MediaItem) async throws -> MediaItem,
        versionAuthorizationScope: [String],
        playbackSettings: PlaybackSettings = .default
    ) {
        self.make = make
        self.makeFailover = makeFailover
        self.showDiagnostics = showDiagnostics
        self.themePalette = themePalette
        self.versionPreferences = versionPreferences
        self.prepareVersion = prepareVersion
        self.versionAuthorizationScope = versionAuthorizationScope
        self.playbackSettings = playbackSettings
        self._activeRequest = State(initialValue: request)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let viewModel {
                PlayerView(
                    viewModel: viewModel,
                    showDiagnostics: showDiagnostics,
                    themePalette: themePalette
                )
                .id(activeRequest.traceID)
            } else if versionChoice.prompt == nil, !versionChoiceFailed {
                ProgressView()
                    .tint(.white)
            }
        }
        .task {
            if viewModel == nil {
                ExternalPlaybackRuntime.shared.beginPlaybackIntent()
                HandoffDiagnostics.emit(
                    "presentation READY trace=\(activeRequest.traceID.uuidString.prefix(8)) "
                        + "item=\(activeRequest.item.id) "
                        + "tapToPresentation=\(HandoffDiagnostics.ms(activeRequest.requestedAt))"
                )
                do {
                    activeRequest = try await preparedRequest(activeRequest)
                    guard !Task.isCancelled, isPresented else { return }
                    if await openExternalPlayer() { return }
                    guard !Task.isCancelled, isPresented else { return }
                    viewModel = try make(activeRequest, nil, nil)
                } catch is CancellationError {
                    if isPresented { dismiss() }
                    return
                } catch {
                    showVersionChoiceFailure(error)
                    return
                }
                updateVersionMenu()
                ScreenshotSeed.holdPlayerControlsIfRequested(viewModel)
                HandoffDiagnostics.emit(
                    "viewModel CREATED trace=\(activeRequest.traceID.uuidString.prefix(8)) "
                        + "item=\(activeRequest.item.id) "
                        + "tapToModel=\(HandoffDiagnostics.ms(activeRequest.requestedAt))"
                )
            }
        }
        .onAppear { isPresented = true }
        .onDisappear {
            isPresented = false
            versionChoice.cancel()
            handoffTask?.cancel()
            viewModel?.controls.versions.onSelect = nil
        }
        .playbackVersionChoice(versionChoice)
        .environment(\.themePalette, themePalette)
        .onChange(of: versionChoice.prompt?.id) { _, id in
            if id != nil { viewModel?.setPaused(true) }
        }
        .onChange(of: versionAuthorizationScope) { _, _ in
            guard versionChoice.isPreparing || viewModel == nil else { return }
            versionChoice.cancel()
            handoffTask?.cancel()
            dismiss()
        }
        .onChange(of: externalContext?().identity) { _, _ in
            if viewModel == nil { dismiss() }
        }
        // Even a no-op handler consumes Back; loaded playback owns the command.
        .onExitCommand(perform: viewModel == nil ? {
            versionChoice.cancel()
            dismiss()
        } : nil)
        .alert(sourceUnavailable ? "Source Unavailable" : "Couldn't load versions", isPresented: $versionChoiceFailed) {
            Button("Close player") { dismiss() }
        } message: {
            if sourceUnavailable {
                Text("Connect or enable this source in Settings, then try again.")
            } else {
                Text(versionChoiceFailureMessage)
            }
        }
        .onChange(of: versionItem) { _, _ in updateVersionMenu() }
        .onChange(of: viewModel?.currentMediaSourceID) { _, _ in updateVersionMenu() }
        .onChange(of: viewModel?.pendingNextEpisode?.id) { _, nextID in
            guard handoffTask == nil, nextID != nil,
                  let next = viewModel?.pendingNextEpisode else { return }
            triedAccountIDs = []
            replacePlayback(
                with: PlayRequest(item: next, startPosition: 0, versionPreferences: versionPreferences),
                preparesEpisodeHandoff: true
            )
        }
        .onChange(of: viewModel?.pendingPlaylistSelection?.index) { _, index in
            guard handoffTask == nil, let index,
                  let outgoing = viewModel,
                  let next = outgoing.pendingPlaylistSelection?.item,
                  let playlist = activeRequest.playlist else { return }
            triedAccountIDs = []
            replacePlayback(
                with: PlayRequest(
                    item: next, startPosition: 0,
                    versionPreferences: versionPreferences, playlist: playlist
                ),
                playlistIndex: index
            )
        }
        .onChange(of: viewModel?.phase) { _, phase in
            // Playback failed to start on the routed server. Silently retarget to
            // the next-best untried source (a dead/unreachable copy falls through to
            // another server's copy) and re-present at the same resume point. When
            // no untried source remains, the player's `.failed` error stays visible.
            guard handoffTask == nil, !activeRequest.item.explicitSourceSelection,
                  case .failed = phase else { return }
            let failedAccountID = activeRequest.item.selectedSourceAccountID
                ?? activeRequest.item.sourceAccountID
            var attempted = triedAccountIDs
            if let failedAccountID { attempted.insert(failedAccountID) }
            guard let nextItem = makeFailover(activeRequest.item, attempted) else {
                triedAccountIDs = attempted
                return
            }
            triedAccountIDs = attempted
            replacePlayback(with: PlayRequest(
                item: nextItem, startPosition: activeRequest.startPosition,
                versionPreferences: versionPreferences
            ))
        }
    }

    private func openExternalPlayer() async -> Bool {
        let deviceSettings = ExternalPlayerSettingsModel.shared
        deviceSettings.migrateIfNeeded(from: playbackSettings.externalPlayer)
        guard deviceSettings.settings.player != .builtIn else { return false }
        do {
            guard let externalContext else { throw ExternalPlayerError.unavailable }
            let opened = try await ExternalPlaybackRuntime.shared.launch(
                item: activeRequest.item, startPosition: activeRequest.startPosition,
                settings: playbackSettings, selection: deviceSettings.settings,
                context: externalContext, isPresented: { isPresented }
            )
            if opened { dismiss() }
            return opened
        } catch is CancellationError {
            if isPresented { dismiss() }
            return true
        } catch {
            PlozzLog.playback.error("External player context unavailable; using Plozz.")
            return false
        }
    }

    private var versionItem: MediaItem {
        PlayerVersionSelection.item(opened: activeRequest.item, resolved: viewModel?.currentPlaybackItem)
    }

    private func updateVersionMenu() {
        guard let model = viewModel, handoffTask == nil else { return }
        let item = versionItem
        model.controls.versions.onSelect = { [weak model] id in
            guard let model, viewModel === model else { return }
            switchVersion(id)
        }
        model.controls.versions.options = PlayerVersionSelection.versions(for: item).map {
            .init(version: $0, isSelected: PlayerVersionSelection.isSelected(
                $0, item: item, mediaSourceID: model.currentMediaSourceID
            ))
        }
    }

    private func switchVersion(_ id: String) {
        guard let outgoing = viewModel, handoffTask == nil, isPresented else { return }
        let item = versionItem
        guard let incoming = PlayerVersionSelection.selecting(id, in: item),
              let version = PlayerVersionSelection.versions(for: item).first(where: { $0.id == id }) else {
            PlozzLog.playback.error("The requested player version is no longer available.")
            return
        }
        let continuation = outgoing.continuationForVersionChange()
        if versionPreferences.shouldRememberVersion(for: item) {
            versionPreferences.rememberVersion(
                version, forTitle: DetailPlaybackSelection.versionPreferenceKey(for: item)
            )
        }
        triedAccountIDs = []
        replacePlayback(
            with: PlayRequest(
                item: incoming, startPosition: continuation.position,
                versionPreferences: versionPreferences,
                playlist: incoming.sourceAccountID == activeRequest.playlist?.accountID
                    ? activeRequest.playlist : nil
            ),
            continuation: continuation
        )
    }

    private func replacePlayback(
        with request: PlayRequest,
        preparesEpisodeHandoff: Bool = false,
        continuation: PlaybackContinuation? = nil,
        playlistIndex: Int? = nil
    ) {
        guard let outgoing = viewModel, handoffTask == nil, isPresented else { return }
        outgoing.controls.versions.options = []
        outgoing.controls.versions.onSelect = nil
        let incomingRequest = request
        handoffTask = Task { @MainActor in
            let request: PlayRequest
            do {
                // An in-player version change or source failover is already a
                // concrete selection, not another Play/Next action.
                request = preparesEpisodeHandoff || playlistIndex != nil
                    ? try await preparedRequest(incomingRequest) : incomingRequest
            } catch is CancellationError {
                handoffTask = nil
                if isPresented { dismiss() }
                return
            } catch {
                handoffTask = nil
                showVersionChoiceFailure(error)
                return
            }
            let prepared = preparesEpisodeHandoff
                ? await outgoing.prepareEpisodeHandoff(to: request.item) : nil
            guard !Task.isCancelled, isPresented, viewModel === outgoing else {
                await outgoing.discardEpisodeHandoff(prepared)
                handoffTask = nil
                return
            }
            let preserveDisplayMode = preparesEpisodeHandoff
                && outgoing.shouldPreserveDisplayMode(forNext: prepared)
            let prefetched = prepared?.inheritingPreservedDisplayMode(preserveDisplayMode)
            await outgoing.stop(preserveDisplayMode: preserveDisplayMode)
            guard !Task.isCancelled, isPresented, viewModel === outgoing else {
                await outgoing.discardEpisodeHandoff(prefetched)
                handoffTask = nil
                return
            }
            if let playlistIndex { request.playlist?.advance(to: playlistIndex) }
            let incoming: PlayerViewModel
            do {
                incoming = try make(request, prefetched, continuation)
            } catch {
                await outgoing.discardEpisodeHandoff(prefetched)
                handoffTask = nil
                showVersionChoiceFailure(error)
                return
            }
            activeRequest = request
            viewModel = incoming
            handoffTask = nil
            updateVersionMenu()
        }
    }

    private func preparedRequest(_ request: PlayRequest) async throws -> PlayRequest {
        guard !request.item.isYouTubeTrailer else { throw AppError.invalidResponse }
        let prepared = try await PlaybackVersionChoiceModel.prepareWithFailover(
            request.item, triedAccountIDs: triedAccountIDs,
            prepare: { try await prepareVersion(versionChoice, $0) },
            nextSource: makeFailover, isCurrent: { isPresented }
        )
        triedAccountIDs = prepared.triedAccountIDs
        let item = prepared.item
        try Task.checkCancellation()
        guard isPresented else { throw CancellationError() }
        return PlayRequest(
            item: item, startPosition: request.startPosition, traceID: request.traceID,
            requestedAt: request.requestedAt, versionPreferences: versionPreferences,
            playlist: item.sourceAccountID == request.playlist?.accountID ? request.playlist : nil
        )
    }

    private func showVersionChoiceFailure(_ error: Error) {
        guard isPresented else { return }
        viewModel?.setPaused(true)
        sourceUnavailable = error as? AppError == .unauthorized
        versionChoiceFailureMessage = PlaybackVersionChoiceModel.reportFailure(error)
        versionChoiceFailed = true
    }
}
#endif
