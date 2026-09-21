import CoreModels
import CoreNetworking

struct PlexStreamingDecisionResponse: Decodable {
    let MediaContainer: PlexStreamingDecision
}

struct PlexStreamingDecision: Decodable {
    @LenientInt var generalDecisionCode: Int?
    @LenientInt var transcodeDecisionCode: Int?
    @LenientInt var mdeDecisionCode: Int?
    let Metadata: [PlexMetadata]?

    func validate(options: StreamingPlaybackOptions) throws {
        let codes = [generalDecisionCode, transcodeDecisionCode, mdeDecisionCode].compactMap { $0 }
        if let failure = codes.first(where: { $0 >= 2000 }) {
            HandoffDiagnostics.emit("plex STREAM_DECISION refused code=\(failure)")
            throw StreamingQualityError.plexDecision(failure)
        }
        guard (transcodeDecisionCode ?? generalDecisionCode) == 1001,
              let media = Metadata?.first?.Media?.first else {
            throw StreamingQualityError.noCompatibleStream
        }
        let container = media.container?.lowercased()
        let codec = media.videoCodec?.lowercased()
        let validContainer = options.codec == .preferH264
            ? ["mpegts", "mp4"].contains(container ?? "")
            : container == "mp4"
        let validCodec = options.codec == .preferH264 ? codec == "h264" : ["h264", "hevc"].contains(codec ?? "")
        guard validContainer, validCodec else {
            HandoffDiagnostics.emit("plex STREAM_DECISION incompatible-output")
            throw StreamingQualityError.noCompatibleStream
        }
        HandoffDiagnostics.emit("plex STREAM_DECISION accepted container=\(container ?? "") codec=\(codec ?? "")")
    }
}

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
