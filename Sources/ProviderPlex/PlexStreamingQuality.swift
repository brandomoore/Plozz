import CoreModels
import CoreNetworking

extension PlexProvider: StreamingQualityProviding {
    public func playbackInfo(
        for itemID: String, mediaSourceID: String?, forceTranscode: Bool,
        streaming: StreamingPlaybackOptions
    ) async throws -> PlaybackRequest {
        try await resolvePlayback(
            for: itemID, mediaSourceID: mediaSourceID,
            forceTranscode: forceTranscode, streaming: streaming
        )
    }

    public func releaseStreamingSession(_ request: PlaybackRequest) async {
        guard let id = request.streamingSessionID else { return }
        do { try await client.stopStreamingTranscode(sessionID: id) }
        catch { PlozzLog.playback.error("Unable to release the previous Plex streaming rendition.") }
    }
}
