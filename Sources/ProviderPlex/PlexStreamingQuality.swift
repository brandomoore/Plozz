import CoreModels
import CoreNetworking

struct PlexStreamingDecisionResponse: Decodable {
    let MediaContainer: PlexStreamingDecision
}

struct PlexStreamingDecision: Decodable {
    // Decision responses are not library-metadata responses: unrelated fields
    // such as librarySectionID may use different scalar types.
    struct Item: Decodable {
        let Media: [Output]?
    }

    struct Output: Decodable {
        let container: String?
        let videoCodec: String?
        let audioCodec: String?
        let Part: [OutputPart]?

        struct OutputPart: Decodable {
            let Stream: [OutputStream]?

            struct OutputStream: Decodable {
                @LenientInt var streamType: Int?
                let decision: String?
                let codec: String?
            }
        }

        var copiesVideo: Bool {
            let video = Part?.flatMap { $0.Stream ?? [] }.filter { $0.streamType == 1 } ?? []
            return !video.isEmpty && video.allSatisfy { $0.decision?.lowercased() == "copy" }
        }

        var copiesAudio: Bool {
            let audio = Part?.flatMap { $0.Stream ?? [] }.filter { $0.streamType == 2 } ?? []
            return !audio.isEmpty && audio.allSatisfy { $0.decision?.lowercased() == "copy" }
        }

        var hasUnsupportedCopiedAudio: Bool {
            Part?.flatMap { $0.Stream ?? [] }.contains {
                $0.streamType == 2 && $0.decision?.lowercased() == "copy"
                    && !PlexClient.canDirectStreamAudio(codec: $0.codec ?? audioCodec ?? "")
            } == true
        }
    }

    @LenientInt var generalDecisionCode: Int?
    @LenientInt var transcodeDecisionCode: Int?
    @LenientInt var mdeDecisionCode: Int?
    let Metadata: [Item]?

    @discardableResult
    func validate(
        options: StreamingPlaybackOptions, supportsHEVC: Bool, allowsStreamCopy: Bool = false,
        allowsAudioStreamCopy: Bool = false
    ) throws -> DirectPlayVideoCodec {
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
        let validContainer = container == "mp4"
        guard (!media.copiesVideo || allowsStreamCopy),
              (!media.copiesAudio || allowsAudioStreamCopy), !media.hasUnsupportedCopiedAudio else {
            HandoffDiagnostics.emit("plex STREAM_DECISION incompatible-stream-copy")
            throw StreamingQualityError.noCompatibleStream
        }
        let preference: StreamingCodecPreference = media.copiesVideo ? .automatic : options.codec
        let validCodec = preference.codecs(supportsHEVC: supportsHEVC).contains(codec ?? "")
        if !validCodec, options.codec == .preferHEVC, supportsHEVC, codec == "h264" {
            throw StreamingQualityError.codecUnavailable(.hevc)
        }
        guard validContainer, validCodec else {
            HandoffDiagnostics.emit("plex STREAM_DECISION incompatible-output")
            throw StreamingQualityError.noCompatibleStream
        }
        HandoffDiagnostics.emit("plex STREAM_DECISION accepted container=\(container ?? "") codec=\(codec ?? "")")
        return codec == "hevc" ? .hevc : .h264
    }

    var deliveryMode: PlaybackDiagnostics.PlaybackMode {
        guard let media = Metadata?.first?.Media?.first,
              media.copiesVideo, media.copiesAudio else { return .transcode }
        return .remux
    }
}

extension PlexProvider: StreamingSessionMaintaining {
    public func maintainStreamingSession(_ request: PlaybackRequest) async throws {
        guard request.isTranscoding, let id = request.streamingSessionID, !id.isEmpty else { return }
        try await client.pingStreamingTranscode(sessionID: id)
    }
}

extension PlexProvider: StreamingSessionReleasing {
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
        await releaseStreamingSession(id: id)
    }

    public func releaseStreamingSession(id: String) async {
        do { try await client.stopStreamingTranscode(sessionID: id) }
        catch { PlozzLog.playback.error("Unable to release the previous Plex streaming rendition.") }
    }
}
