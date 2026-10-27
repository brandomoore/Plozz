#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureHomeCore
import FeaturePlayback
import FeatureHome
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

/// A fully-resolved request to present the player for an item at an explicit
/// start position (seconds). `startPosition` of `0` means "start over".
struct PlayRequest: Identifiable, Equatable {
    let item: MediaItem
    let startPosition: TimeInterval
    let traceID: UUID
    let requestedAt: Date
    let playlist: VideoPlaylistPlaybackContext?

    /// Resolves the show's remembered version HERE, so no play path can skip it.
    ///
    /// Every tvOS playback starts by building one of these, so applying the
    /// preference in the initializer makes it structural rather than something
    /// each caller must remember — which is exactly what four separate paths
    /// forgot (see `DetailPlaybackSelection.playbackReady`).
    init(
        item: MediaItem,
        startPosition: TimeInterval,
        traceID: UUID = UUID(),
        requestedAt: Date = Date(),
        versionPreferences: any VersionPreferenceStoring = VersionPreferenceStore(),
        capabilities: MediaCapabilities = .detected(),
        playlist: VideoPlaylistPlaybackContext? = nil
    ) {
        self.item = DetailPlaybackSelection.playbackReady(
            item,
            preferences: versionPreferences,
            capabilities: capabilities
        )
        self.startPosition = startPosition
        self.traceID = traceID
        self.requestedAt = requestedAt
        self.playlist = playlist
    }

    var id: String { item.id }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.traceID == rhs.traceID && lhs.item == rhs.item
            && lhs.startPosition == rhs.startPosition
    }
}
#endif
