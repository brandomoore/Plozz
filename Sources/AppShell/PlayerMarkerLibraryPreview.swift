#if DEBUG && os(tvOS)
import AppRuntime
import CoreModels
import CoreNetworking
import EnginePlozzigen
import FeaturePlayback
import SwiftUI

@MainActor
struct PlayerMarkerLibraryPreview: View {
    let appState: AppState
    let onClose: () -> Void
    @State private var video: PlayerSkipMarkerVideo?

    var body: some View {
        let scope = MarkerPreviewLibrarySource.authorizationID(appState)
        PlayerSkipMarkerPreview(onClose: onClose, video: video)
            .task(id: scope) {
                video?.stop()
                let model = PlayerSkipMarkerVideo(
                    source: { [weak appState] in
                        guard let appState else { throw CancellationError() }
                        return try await MarkerPreviewLibrarySource.resolve(appState, expected: scope)
                    },
                    makeEngine: { [weak appState] in
                        guard let appState, MarkerPreviewLibrarySource.authorizationID(appState) == scope,
                              appState.isActiveProfileAuthorized else { throw CancellationError() }
                        let engine = try PlozzigenVideoEngine(
                            networkFileResolver: appState.mediaShare.networkFileResolver,
                            authenticatedHTTPResolver: appState.authenticatedHTTPResolver
                        )
                        engine.configureLiveOutput(.init(
                            isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true
                        ))
                        return engine
                    }
                )
                video = model
            }
            .onDisappear { video?.stop() }
    }
}

@MainActor
enum MarkerPreviewLibrarySource {
    static func authorizationID(_ app: AppState) -> String {
        let accounts = app.accountsProviders
        let revisions = accounts.accounts.filter { accounts.activeAccountIDs.contains($0.id) }
            .map { "\($0.id):\(accounts.credentialRevision($0).rawValue)" }.sorted()
        let disabled = app.profileSettings.homeLibraryVisibilityModel.visibility.disabledKeys.sorted()
        return "\(app.profilesModel.activeProfileID)|\(app.isActiveProfileAuthorized)|"
            + "\(app.plexHomeUsers.plexIdentityGeneration)|\(revisions)|\(disabled)"
    }

    static func resolve(_ app: AppState, expected: String) async throws -> PlayerSkipMarkerVideo.Source {
        func check() throws {
            try Task.checkCancellation()
            guard app.isActiveProfileAuthorized, authorizationID(app) == expected else {
                throw CancellationError()
            }
        }
        try check()
        let visibility = app.profileSettings.homeLibraryVisibilityModel.visibility
        let sources = app.accountsProviders.resolvedActiveAccounts.filter { source in
            guard source.account.server.provider == .plex,
                  app.profilesModel.activeProfile.homeUserBinding(forPlexAccount: source.account.id) != nil
            else { return true }
            // A mapped Home user must have its own server override before discovery.
            return app.plexHomeUsers.effectiveCredentialRevision(for: source.account) != source.account.credentialRevision
        }
        return try await resolve(sources: sources, visibility: visibility, authorize: check)
    }

    static func resolve(
        sources: [ResolvedAccount], visibility: HomeLibraryVisibility,
        authorize: () throws -> Void
    ) async throws -> PlayerSkipMarkerVideo.Source {
        var lastFailure: AppError?
        for source in sources {
            try authorize()
            let provider = source.provider
            do {
                let libraries = try await provider.libraries().filter {
                    visibility.isEnabled("\(source.account.id):\($0.id)") && !$0.isMusic
                }
                try authorize()
                guard !libraries.isEmpty else { continue }
                let ids = Set(libraries.map(\.id))
                let candidates = try await provider.continueWatching(limit: 12, inLibraries: Array(ids))
                try authorize()
                var episode = candidates.first {
                    $0.kind == .episode && $0.libraryID.map(ids.contains) == true
                }
                if episode == nil {
                    for library in libraries.filter({ $0.kind == .series }).prefix(3) {
                        let page = try await provider.items(
                            in: library.id, kind: .episode, page: PageRequest(startIndex: 0, limit: 5)
                        )
                        try authorize()
                        if var candidate = page.items.first(where: {
                            $0.kind == .episode && ($0.libraryID == nil || $0.libraryID == library.id)
                        }) {
                            candidate.libraryID = library.id
                            episode = candidate
                            break
                        }
                    }
                }
                guard let episode else { continue }
                var options = StreamingPlaybackOptions(quality: .original)
                options.subtitlesOff = true
                let request: PlaybackRequest
                let release: @Sendable (PlaybackRequest) async -> Void
                if let streaming = provider as? any StreamingQualityProviding {
                    request = try await streaming.playbackInfo(
                        for: episode.id, mediaSourceID: nil, forceTranscode: false, streaming: options
                    )
                    release = { await streaming.releaseStreamingSession($0) }
                } else if provider.kind.playbackInfoIsIdempotent {
                    request = try await provider.playbackInfo(for: episode.id)
                    release = { _ in }
                } else {
                    PlozzLog.playback.info("Marker preview source has no watch-neutral session release capability.")
                    continue
                }
                do { try authorize() }
                catch {
                    await release(request)
                    throw error
                }
                guard request.item.id == episode.id, request.item.kind == .episode else {
                    await release(request)
                    throw AppError.invalidResponse
                }
                let start: TimeInterval = (episode.runtime ?? 0) > 120 ? 60 : 0
                return .init(request: request, startPosition: start, release: { await release(request) })
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastFailure = (error as? AppError) ?? .serverUnreachable
                PlozzLog.playback.error("Could not resolve a library episode for the marker preview on \(provider.kind.rawValue).")
            }
        }
        PlozzLog.playback.error("No available episode was found in this profile's enabled libraries.")
        throw lastFailure ?? AppError.notFound
    }
}
#endif
