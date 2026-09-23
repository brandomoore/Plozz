#if canImport(SwiftUI)
import SwiftUI
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
import ProviderTrailers
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
    let make: (PlayRequest, PlayerViewModel.PrefetchedPlayback?, PlaybackContinuation?) -> PlayerViewModel
    /// Re-selects the next-best source after the current target fails to start,
    /// excluding every account already attempted; `nil` means no untried source
    /// remains, so the player's own error state stays on screen (r8-play-failover).
    let makeFailover: (_ failedItem: MediaItem, _ tried: Set<String>) -> MediaItem?
    let showDiagnostics: Bool
    let themePalette: ThemePalette
    let versionPreferences: any VersionPreferenceStoring

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
        make: @escaping (PlayRequest, PlayerViewModel.PrefetchedPlayback?, PlaybackContinuation?) -> PlayerViewModel,
        makeFailover: @escaping (_ failedItem: MediaItem, _ tried: Set<String>) -> MediaItem?,
        showDiagnostics: Bool,
        themePalette: ThemePalette,
        versionPreferences: any VersionPreferenceStoring
    ) {
        self.make = make
        self.makeFailover = makeFailover
        self.showDiagnostics = showDiagnostics
        self.themePalette = themePalette
        self.versionPreferences = versionPreferences
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
            }
        }
        .task {
            if viewModel == nil {
                HandoffDiagnostics.emit(
                    "presentation READY trace=\(activeRequest.traceID.uuidString.prefix(8)) "
                        + "item=\(activeRequest.item.id) "
                        + "tapToPresentation=\(HandoffDiagnostics.ms(activeRequest.requestedAt))"
                )
                viewModel = make(activeRequest, nil, nil)
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
            handoffTask?.cancel()
            viewModel?.controls.versions.onSelect = nil
        }
        .onChange(of: versionItem) { _, _ in updateVersionMenu() }
        .onChange(of: viewModel?.currentMediaSourceID) { _, _ in updateVersionMenu() }
        .onChange(of: viewModel?.pendingNextEpisode?.id) { _, nextID in
            guard handoffTask == nil, nextID != nil,
                  let next = viewModel?.pendingNextEpisode else { return }
            // Adopt the next episode's prefetched resolution (if ready) BEFORE
            // stop() runs, so the incoming player skips the network resolve and
            // reuses the already-open session rather than the old player releasing
            // it. `nil` when the prefetch didn't finish → the new player resolves
            // normally (no regression).
            let consumed = viewModel?.consumePrefetchedNext(matching: next.id)
            // Keep the panel's HDR/DV mode across a same-range hand-off so the TV
            // doesn't flap DV→SDR→DV between episodes (needs the prefetched next's
            // source facts, so it's a no-op on a prefetch miss).
            let preserveDisplay = viewModel?.shouldPreserveDisplayMode(forNext: consumed) ?? false
            let prefetched = consumed?.inheritingPreservedDisplayMode(preserveDisplay)
            triedAccountIDs = []
            replacePlayback(
                with: PlayRequest(item: next, startPosition: 0, versionPreferences: versionPreferences),
                prefetched: prefetched, preserveDisplayMode: preserveDisplay
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
        versionPreferences.rememberVersion(
            version, forTitle: DetailPlaybackSelection.versionPreferenceKey(for: item)
        )
        triedAccountIDs = []
        replacePlayback(
            with: PlayRequest(
                item: incoming, startPosition: continuation.position,
                versionPreferences: versionPreferences
            ),
            continuation: continuation
        )
    }

    private func replacePlayback(
        with request: PlayRequest,
        prefetched: PlayerViewModel.PrefetchedPlayback? = nil,
        preserveDisplayMode: Bool = false,
        continuation: PlaybackContinuation? = nil
    ) {
        guard let outgoing = viewModel, handoffTask == nil, isPresented else { return }
        outgoing.controls.versions.options = []
        outgoing.controls.versions.onSelect = nil
        handoffTask = Task { @MainActor in
            await outgoing.stop(preserveDisplayMode: preserveDisplayMode)
            guard !Task.isCancelled, isPresented, viewModel === outgoing else {
                handoffTask = nil
                return
            }
            let incoming = make(request, prefetched, continuation)
            activeRequest = request
            viewModel = incoming
            handoffTask = nil
            updateVersionMenu()
        }
    }
}
#endif
