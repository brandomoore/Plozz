#if os(iOS)
import CoreModels
import CryptoKit
import Foundation
import MediaDownloads
import ProviderJellyfin

enum EmbyOfflineAudioDownload {
    typealias Engine = PlozziOSBackgroundHTTPDownloadEngine

    static func prepare(
        source: ManagedHTTPDownloadSource,
        authorize: @escaping @Sendable () async throws -> Void,
        provider: @escaping @Sendable () async throws -> JellyfinProvider,
        resolve: @escaping @Sendable (AuthenticatedHTTPPlaybackLocator) async throws -> URL,
        updateSource: @escaping Engine.SourceUpdater
    ) async throws -> Engine.Resolution {
        guard source.provider == .emby, let sourceID = source.mediaSourceID,
              case .constrained(let constraint) = source.quality else { throw AppError.invalidResponse }
        try await authorize()
        let current = try await provider()
        let initial = try await current.playbackInfo(
            for: source.itemID, mediaSourceID: sourceID, forceTranscode: true
        )
        try await authorize()
        let fingerprint = try fingerprint(source: source, playback: initial)
        let tracks = initial.audioTracks
        guard !tracks.isEmpty, tracks.count <= 64,
              Set(tracks.map(\.id)).count == tracks.count,
              tracks.allSatisfy({ $0.id >= 0 }) else { throw AppError.invalidResponse }
        let preferred = source.preferredAudioLanguages.lazy.compactMap { language in
            tracks.first { LanguageMatch.matches(language, $0.language) }
        }.first ?? tracks.first(where: \.isDefault) ?? tracks[0]
        let plan = OfflineAudioDownload.Plan(
            sourceFingerprint: fingerprint,
            tracks: tracks.map { .init(id: $0.id, language: $0.language) },
            primaryAudioID: preferred.id, audioFormat: .aac, duration: initial.item.runtime
        )
        let state = PreparationState(source: source, update: updateSource)
        return .init(audioPackage: .init(
            plan: plan, authorize: authorize,
            prepare: { audioID in
                try await authorize()
                let current = try await provider()
                let playback = try await current.playbackInfo(
                    for: source.itemID, mediaSourceID: sourceID, forceTranscode: true
                )
                try await authorize()
                guard try self.fingerprint(source: source, playback: playback) == fingerprint else {
                    throw OfflineAudioDownload.Failure.sourceChanged
                }
                let streamURL: URL
                if case .authenticatedHTTP(let locator) = playback.playbackSource {
                    streamURL = try await resolve(locator)
                } else if let url = playback.streamURL {
                    streamURL = url
                } else {
                    throw AppError.invalidResponse
                }
                try await authorize()
                let sessionID = try await state.session(for: audioID)
                let url = try EmbyOfflineDownloadURLBuilder.makeURL(
                    from: streamURL, itemID: source.itemID, mediaSourceID: sourceID,
                    audioStreamIndex: audioID ?? preferred.id, audioOnly: audioID != nil,
                    sessionID: sessionID,
                    maximumVideoBitrateBps: constraint.maximumVideoBitrateBps,
                    maximumHeight: constraint.maximumHeight
                )
                return .init(url: url, expectedDuration: playback.item.runtime,
                             cleanupURL: nil, singleFile: true)
            },
            finishPreparation: { audioID in
                try await authorize()
                guard let sessionID = await state.existingSession(for: audioID) else { return }
                let current = try await provider()
                try await current.finishOfflineAudioEncoding(sessionID: sessionID)
                try await authorize()
                try await state.clear(audioID)
            }
        ), expectedDuration: initial.item.runtime)
    }

    private struct Fingerprint: Encodable {
        let accountID: String
        let itemID: String
        let sourceID: String
        let revision: String
        let quality: DownloadQuality
        let audio: [OfflineAudioDownload.Track]
    }

    private static func fingerprint(source: ManagedHTTPDownloadSource, playback: PlaybackRequest) throws -> String {
        guard let sourceID = source.mediaSourceID,
              case .authenticatedHTTP(let original) = playback.downloadableOriginalSource,
              original.mediaSourceID == sourceID,
              let revision = playback.sourceMetadata?.sourceRevision, !revision.isEmpty else {
            throw AppError.invalidResponse
        }
        let identity = Fingerprint(
            accountID: source.accountID, itemID: source.itemID, sourceID: sourceID,
            revision: revision, quality: source.quality,
            audio: playback.audioTracks.map { .init(id: $0.id, language: $0.language) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(identity)).map { String(format: "%02x", $0) }.joined()
    }

    private actor PreparationState {
        private var source: ManagedHTTPDownloadSource
        private let update: Engine.SourceUpdater

        init(source: ManagedHTTPDownloadSource, update: @escaping Engine.SourceUpdater) {
            self.source = source
            self.update = update
        }

        func existingSession(for trackID: Int?) -> String? {
            reference(for: trackID)?.itemIdentifier
        }

        private func reference(for trackID: Int?) -> ManagedHTTPPreparationReference? {
            if let trackID { return source.audioPreparationReferences[trackID] }
            return source.preparationReference
        }

        func session(for trackID: Int?) async throws -> String {
            if let reference = reference(for: trackID) {
                guard reference.queueIdentifier == "emby-offline",
                      UUID(uuidString: reference.itemIdentifier) != nil else { throw AppError.invalidResponse }
                return reference.itemIdentifier
            }
            let id = UUID().uuidString
            let updated = source.replacingPreparationReference(
                .init(queueIdentifier: "emby-offline", itemIdentifier: id), audioTrackID: trackID
            )
            try await update(updated)
            source = updated
            return id
        }

        func clear(_ trackID: Int?) async throws {
            let updated = source.replacingPreparationReference(nil, audioTrackID: trackID)
            try await update(updated)
            source = updated
        }
    }
}
#endif
