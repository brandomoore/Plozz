#if os(iOS)
import AppRuntime
import CoreModels
import CoreNetworking
import CoreUI
import FeatureHomeCore
import SwiftUI

extension View {
    func plozziOSPreparedPlayerCover<PlayerContent: View>(
        item: Binding<PlozziOSPlaybackRequest?>,
        orientation: PlaybackOrientation,
        provider: @escaping (MediaItem) -> (any MediaProvider)?,
        @ViewBuilder content: @escaping (PlozziOSPlaybackRequest, PlozziOSPlayerOrientation) -> PlayerContent
    ) -> some View {
        modifier(PlozziOSPlaybackPreparation(
            request: item, preference: orientation, provider: provider, player: content
        ))
    }
}

private struct PlozziOSPlaybackPreparation<PlayerContent: View>: ViewModifier {
    @Environment(PlozziOSAppModel.self) private var model
    @Environment(HeroTrailerController.self) private var hero
    @Binding var request: PlozziOSPlaybackRequest?
    let preference: PlaybackOrientation
    let provider: (MediaItem) -> (any MediaProvider)?
    let player: (PlozziOSPlaybackRequest, PlozziOSPlayerOrientation) -> PlayerContent
    @State private var choice = PlaybackVersionChoiceModel()
    @State private var pending: PlozziOSPlaybackRequest?
    @State private var presented: PlozziOSPlaybackRequest?
    @State private var promptIsPresented = false
    @State private var preparationOwner: UUID?
    @State private var failure: LocalizedStringResource?

    func body(content: Content) -> some View {
        content
            .overlay {
                if request != nil, presented == nil, choice.prompt == nil, failure == nil {
                    HStack(spacing: 16) {
                        ProgressView()
                        Button("Cancel") { cancel() }
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("playback-preparation")
                }
            }
            .playbackVersionChoice(choice, onDismiss: {
                promptIsPresented = choice.prompt != nil
                presentPreparedRequest()
            })
            .onChange(of: choice.prompt?.id) { _, id in
                if id != nil { promptIsPresented = true }
            }
            .alert("Couldn't load versions", isPresented: Binding(
                get: { failure != nil }, set: { if !$0 { cancel() } }
            )) {
                Button("Close player") { cancel() }
            } message: {
                if let failure { Text(failure) }
            }
            .plozziOSPlayerCover(item: Binding(
                get: { presented },
                set: { value in
                    presented = value
                    if value == nil { cancel() }
                }
            ), orientation: preference, content: player)
            .task(id: request?.id) {
                guard let request else { cancel(); return }
                await prepare(request)
            }
            .onChange(of: model.profiles.activeProfileID) { _, _ in cancel() }
            .onChange(of: model.accountsProviders.liveTVAuthorizationID) { _, _ in cancel() }
            .onChange(of: model.accountsProviders.watchMutationServerScope) { _, _ in cancel() }
            .onDisappear {
                releaseHero()
                if presented == nil { cancel() }
            }
    }

    private func prepare(_ opened: PlozziOSPlaybackRequest) async {
        choice.cancel()
        pending = nil
        failure = nil
        releaseHero()
        preparationOwner = opened.id
        hero.suspendForPlayback(owner: opened.id)
        ExternalPlaybackRuntime.shared.beginPlaybackIntent()
        let session = model.makePlaybackSession()
        do {
            guard let provider = provider(opened.item) else {
                // The caller's existing unavailable-server view owns this error.
                pending = opened
                presentPreparedRequest()
                return
            }
            let item = try await model.preparePlaybackVersion(
                opened.item, provider: provider, choice: choice, session: session,
                isPresented: { request?.id == opened.id }
            )
            if try await openExternalPlayer(item, opened: opened, provider: provider, session: session) {
                if request?.id == opened.id { cancel() }
                return
            }
            try Task.checkCancellation()
            guard request?.id == opened.id, model.isCurrentPlaybackSession(session) else {
                throw CancellationError()
            }
            pending = opened.prepared(item: item, session: session)
            presentPreparedRequest()
        } catch is CancellationError {
            if request?.id == opened.id { cancel() }
        } catch {
            guard request?.id == opened.id else { return }
            failure = PlaybackVersionChoiceModel.reportFailure(error)
        }
    }

    private func presentPreparedRequest() {
        guard !promptIsPresented, choice.prompt == nil,
              let pending, request?.id == pending.id else { return }
        if let session = pending.preparedSession, !model.isCurrentPlaybackSession(session) {
            cancel()
            return
        }
        presented = pending
        self.pending = nil
    }

    private func openExternalPlayer(
        _ item: MediaItem, opened: PlozziOSPlaybackRequest, provider: any MediaProvider,
        session: PlozziOSAppModel.PlaybackSession
    ) async throws -> Bool {
        let selection = ExternalPlayerSettingsModel.shared
        selection.migrateIfNeeded(from: model.settings.playback.settings.externalPlayer)
        guard selection.settings.player != .builtIn else { return false }
        var options: StreamingPlaybackOptions?
        if provider is any StreamingQualityProviding, [.movie, .episode].contains(item.kind) {
            var updates = PlozziOSStreamingNetwork.updates().makeAsyncIterator()
            guard let network = await updates.next() else { throw CancellationError() }
            let connection = StreamingConnection.resolve(
                network: network, locality: provider.connectionLocality, previousConnection: nil
            )
            options = model.settings.playback.settings.streaming.options(for: connection)
        }
        try Task.checkCancellation()
        do {
            return try await ExternalPlaybackRuntime.shared.launch(
                item: item, startPosition: opened.startPosition,
                settings: model.settings.playback.settings, selection: selection.settings,
                streamingOptions: options, context: { model.externalPlaybackContext() },
                isPresented: { request?.id == opened.id && model.isCurrentPlaybackSession(session) }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            PlozzLog.playback.error("External player handoff failed; using Plozz.")
            return false
        }
    }

    private func releaseHero() {
        if let preparationOwner { hero.resumeAfterPlayback(owner: preparationOwner) }
        preparationOwner = nil
    }

    private func cancel() {
        choice.cancel()
        pending = nil
        presented = nil
        failure = nil
        request = nil
        releaseHero()
    }
}

extension PlozziOSAppModel {
    func preparePlaybackVersion(
        _ item: MediaItem, provider: any MediaProvider, choice: PlaybackVersionChoiceModel,
        session: PlaybackSession, isPresented: @escaping () -> Bool
    ) async throws -> MediaItem {
        let snapshot = identityIndex.identitySnapshotStore.current
        let selected = try await choice.prepare(
            item, provider: provider, settings: settings.playback,
            preferences: versionPreferences, offlineResolver: downloads.offlineResolver,
            sourceResolver: crossServerSourceResolver(
                in: accountsProviders.resolvedActiveAccounts,
                identitySources: { snapshot.sourceRefs(for: $0) }
            ),
            isCurrent: { isPresented() && self.isCurrentPlaybackSession(session) }
        )
        try Task.checkCancellation()
        guard isPresented(), isCurrentPlaybackSession(session) else { throw CancellationError() }
        return selected
    }
}
#endif
