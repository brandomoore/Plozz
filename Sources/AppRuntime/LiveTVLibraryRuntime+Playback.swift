#if canImport(AVFoundation)
import CoreModels
import FeatureLiveTVCore
import FeaturePlayback
import Foundation

extension LiveTVLibraryRuntime {
    public func makeEngine(
        engine: any LiveChannelEngine,
        onCompleted: @escaping @MainActor @Sendable (MediaItem, UUID) throws -> Void
    ) -> LibraryLiveChannelEngine {
        // An authorized external player must retain its runtime after the guide leaves.
        LibraryLiveChannelEngine(engine: engine) { [self] id, expectedAuthorization, decoder in
            guard let runtimeAuthorization = authorizationID else {
                throw LibraryChannelError.authorizationChanged
            }
            let context = try service.playbackCandidate(catalogID: "library:\(id.uuidString)")
            guard context.channelID == id, context.profileID == profileID,
                  await context.validateAuthorization() == expectedAuthorization,
                  authorizationID == runtimeAuthorization else {
                throw LibraryChannelError.authorizationChanged
            }
            let currentAuthorization: @MainActor @Sendable () -> String? = { [self] in
                guard authorizationID == runtimeAuthorization,
                      context.eligibilityID == expectedAuthorization else { return nil }
                return expectedAuthorization
            }
            let session = LibraryChannelPlaybackSession(
                channelID: id,
                engine: decoder,
                schedule: { currentAuthorization() == nil ? nil : context.eligibleSchedule() },
                provider: { item in
                    guard currentAuthorization() != nil else { return nil }
                    return context.eligibleProvider(for: item)
                },
                authorization: currentAuthorization,
                validateAuthorization: {
                    guard currentAuthorization() != nil,
                          await context.validateAuthorization() == expectedAuthorization,
                          currentAuthorization() != nil else { return nil }
                    return expectedAuthorization
                },
                historyAuthorization: { [history] in
                    guard currentAuthorization() != nil else { return nil }
                    return history.authorizationID
                },
                historyReporting: .externalCompletion { [history] scheduled, item, token in
                    try Task.checkCancellation()
                    guard currentAuthorization() != nil,
                          await context.validateAuthorization() == expectedAuthorization,
                          currentAuthorization() != nil, history.authorizationID == token,
                          context.eligibleProvider(for: scheduled) != nil else {
                        throw LibraryChannelError.authorizationChanged
                    }
                    try onCompleted(Self.completedItem(item, scheduled: scheduled), token)
                }
            )
            session.setTrackPreferences(
                audioLanguages: trackPreferences.audioLanguage.map { [$0] } ?? [],
                subtitleLanguages: trackPreferences.subtitleMode == .off
                    ? [] : trackPreferences.subtitleLanguage.map { [$0] } ?? []
            )
            return session
        }
    }

    static func completedItem(_ item: MediaItem, scheduled: LibraryChannelItem) throws -> MediaItem {
        guard item.id == scheduled.itemID, item.kind == scheduled.kind,
              item.sourceAccountID == nil || item.sourceAccountID == scheduled.library.accountID else {
            throw LibraryChannelError.mediaChanged
        }
        var completed = item
        completed.sourceAccountID = scheduled.library.accountID
        return completed
    }
}
#endif
