import Observation

/// Artwork readiness is independent of playback, children and optional metadata.
@MainActor @Observable
final class DetailArtworkReadiness {
    var isReady = false
}
