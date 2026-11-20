import Observation

/// Cached metadata is usable before the live artwork source is resolved.
@MainActor @Observable
final class DetailPresentationReadiness {
    var artworkSourceIsReady = false
    var hasRestoredMetadata = false

    var metadataIsReady: Bool { artworkSourceIsReady || hasRestoredMetadata }
}
