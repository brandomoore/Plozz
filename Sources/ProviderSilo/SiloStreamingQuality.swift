import CoreModels
import CoreNetworking
import Foundation

extension SiloProvider: StreamingSessionReleasing, ExternalPlaybackProviding {
    public var streamingQualitySupport: StreamingQualitySupport { .silo }

    public func externalPlaybackInfo(
        for itemID: String, mediaSourceID: String?, player: ExternalPlayer,
        streaming: StreamingPlaybackOptions?
    ) async throws -> PlaybackRequest {
        if let streaming {
            try streaming.quality.validate()
            if let message = streamingQualitySupport.validationMessage(for: streaming.quality) {
                throw StreamingQualityError.serverRefusal(message)
            }
        }
        var options = streaming
        options?.startPosition = 0
        return try await resolvePlayback(
            for: itemID, mediaSourceID: mediaSourceID,
            forceTranscode: options?.forceTranscoding ?? false,
            streaming: options, externalPlayer: true
        )
    }

    public func playbackInfo(
        for itemID: String, mediaSourceID: String?, forceTranscode: Bool,
        streaming: StreamingPlaybackOptions
    ) async throws -> PlaybackRequest {
        if let message = streamingQualitySupport.validationMessage(for: streaming.quality) {
            throw StreamingQualityError.serverRefusal(message)
        }
        if let position = streaming.startPosition,
           !position.isFinite || !(0...31_536_000).contains(position) {
            throw StreamingQualityError.malformedResponse
        }
        do {
            return try await resolvePlayback(
                for: itemID, mediaSourceID: mediaSourceID,
                forceTranscode: forceTranscode, streaming: streaming
            )
        } catch AppError.invalidResponse {
            throw StreamingQualityError.malformedResponse
        } catch AppError.decoding {
            throw StreamingQualityError.malformedResponse
        }
    }

    public func releaseStreamingSession(_ request: PlaybackRequest) async {
        guard let id = request.streamingSessionID, id == request.playSessionID,
              let context = await playback.releaseContext(id: id, itemID: request.item.id) else { return }
        do {
            try await stopStreamingSession(id: id, installationID: context.installationID, stopID: context.stopID)
        } catch {
            PlozzLog.playback.error("Unable to release the previous Silo playback session.")
        }
    }

    public func releaseStreamingSession(id: String) async {
        do {
            _ = try SiloAPI.pathComponent(id)
            // A restored external receipt has no in-memory grant. The authenticated
            // server still enforces the current installation, account and profile.
            let capability: SiloPlaybackCapabilities = try await client.request("/playback/capabilities")
            guard let installationID = capability.installation_id, !installationID.isEmpty else {
                throw AppError.invalidResponse
            }
            try await stopStreamingSession(
                id: id, installationID: installationID, stopID: UUID().uuidString.lowercased()
            )
        } catch {
            PlozzLog.playback.error("Unable to release the restored Silo playback session.")
        }
    }

    private func stopStreamingSession(id: String, installationID: String, stopID: String) async throws {
        struct Body: Encodable { let installation_id: String; let stop_id: String }
        struct Receipt: Decodable, Sendable { let outcome: String }
        let receipt: Receipt = try await client.request(
            "/playback/\(try SiloAPI.pathComponent(id))", method: .delete,
            body: JSONEncoder().encode(Body(installation_id: installationID, stop_id: stopID))
        )
        guard ["stopped", "replayed"].contains(receipt.outcome) else { throw AppError.invalidResponse }
        await playback.remove(id)
    }
}

struct SiloStreamingSelection {
    static let audioBudgetKbps = 192
    let options: StreamingPlaybackOptions
    let source: SiloFileVersion
    let qualityPreference: String
    let videoBudgetKbps: Int?
    let requiresEncoding: Bool

    init(options: StreamingPlaybackOptions, source: SiloFileVersion, forceTranscode: Bool) throws {
        self.options = options
        self.source = source
        let force = forceTranscode || options.forceTranscoding
        requiresEncoding = force || !Self.originalFits(source, quality: options.quality)
        guard requiresEncoding else {
            qualityPreference = "original"
            videoBudgetKbps = nil
            return
        }
        if options.codec == .preferHEVC {
            throw StreamingQualityError.codecUnavailable(.hevc)
        }
        let sourceClass = Self.sourceHeightClass(source)
        let height = min(options.quality.maximumHeight ?? sourceClass ?? 0,
                         sourceClass ?? options.quality.maximumHeight ?? 0)
        guard StreamingQualitySupport.silo.heights.contains(height) else {
            throw StreamingQualityError.serverRefusal(
                "Silo can’t convert this file at the selected resolution."
            )
        }
        var budget = options.quality.maximumBitrate.map { $0 / 1_000 - Self.audioBudgetKbps }
        if force && Self.originalFits(source, quality: options.quality) {
            guard source.bitrate >= StreamingQualitySupport.silo.minimumBitrateKbps else {
                throw StreamingQualityError.serverRefusal(
                    "Silo can’t force conversion of this file at original quality. Choose a supported quality limit."
                )
            }
            budget = min(budget ?? 1_000_000, source.bitrate - Self.audioBudgetKbps)
        }
        guard let budget, (100...1_000_000).contains(budget) else {
            throw StreamingQualityError.serverRefusal(
                "Silo can’t honor the selected bitrate limit."
            )
        }
        videoBudgetKbps = budget
        // Compound preferences keep height independent of the bandwidth cap.
        qualityPreference = height == 480 ? "480p" : "\(height)p-high"
    }

    static func originalFits(_ source: SiloFileVersion, quality: StreamingQuality) -> Bool {
        guard let bitrate = quality.maximumBitrate, let height = quality.maximumHeight else {
            return quality.validationError == nil
        }
        guard let sourceHeight = source.video_tracks?.first?.height, sourceHeight > 0,
              source.bitrate > 0 else { return false }
        return sourceHeight <= height && source.bitrate <= bitrate / 1_000
    }

    private static func sourceHeightClass(_ source: SiloFileVersion) -> Int? {
        let video = source.video_tracks?.first
        guard (video?.width ?? 0) > 0 || (video?.height ?? 0) > 0 else { return nil }
        if (video?.width ?? 0) >= 3840 || (video?.height ?? 0) >= 2160 { return 2160 }
        if (video?.width ?? 0) >= 1920 || (video?.height ?? 0) >= 1080 { return 1080 }
        if (video?.width ?? 0) >= 1280 || (video?.height ?? 0) >= 720 { return 720 }
        return 480
    }

    func validate(_ plan: SiloPlaybackPlan) throws -> DirectPlayVideoCodec? {
        let invalid = StreamingQualityError.serverRefusal(
            "Silo returned a stream outside the selected quality limits. Playback was stopped rather than removing the limit."
        )
        if plan.degradation_warnings?.contains(where: {
            ["quality_preference_normalized", "quality_reduction_unavailable"].contains($0.code)
        }) == true { throw invalid }
        if options.quality == .original, !requiresEncoding {
            return plan.effective_recipe?.video_codec.flatMap(DirectPlayVideoCodec.init(rawValue:))
        }
        guard plan.delivery == "server_transcode_hls" else {
            guard !requiresEncoding, Self.originalFits(source, quality: options.quality) else { throw invalid }
            return nil
        }

        guard let recipe = plan.effective_recipe else { throw invalid }
        if options.codec == .preferHEVC, recipe.video_codec == "h264" {
            throw StreamingQualityError.codecUnavailable(.hevc)
        }
        guard recipe.video_codec == "h264", recipe.audio_codec == "aac",
              let height = recipe.height, height > 0,
              let width = recipe.width, width > 0,
              let bitrate = recipe.bitrate_kbps, bitrate > 0,
              let channels = recipe.audio_channels, (1...2).contains(channels) else { throw invalid }
        if let maximum = options.quality.maximumHeight, height > maximum { throw invalid }
        if let sourceHeight = source.video_tracks?.first?.height, sourceHeight > 0, height > sourceHeight { throw invalid }
        if let sourceWidth = source.video_tracks?.first?.width, sourceWidth > 0, width > sourceWidth { throw invalid }
        if let budget = videoBudgetKbps, bitrate > budget { throw invalid }
        if let maximum = options.quality.maximumBitrate,
           bitrate > maximum / 1_000 - (channels == 1 ? 128 : Self.audioBudgetKbps) { throw invalid }
        return .h264
    }

    static func refusal(_ reason: String?) -> StreamingQualityError {
        switch reason {
        case "session_expired":
            .playback(.init(kind: .unavailable, provider: .silo, providerReason: .sessionExpired))
        case "transcoding_disabled":
            .serverRefusal("Silo reported that transcoding is disabled.", reason: .transcodingDisabled)
        case "conversion_tool_unavailable":
            .serverRefusal("Silo reported that its conversion tool is unavailable.", reason: .conversionToolUnavailable)
        case "hdr_transcode_unsupported":
            .serverRefusal("Silo reported that HDR conversion is unsupported for this file.", reason: .hdrTranscodeUnsupported)
        default:
            .serverRefusal("Silo did not return a playable stream. No recognized reason was supplied.", reason: .unspecified)
        }
    }
}

extension SiloFileVersion {
    var playbackAudioTracks: [MediaTrack] {
        (audio_tracks ?? []).enumerated().map { index, track in
            MediaTrack(
                id: index, kind: .audio,
                displayTitle: track.title ?? track.language ?? track.codec ?? String(index),
                language: track.language, codec: track.codec,
                isDefault: track.default, channels: track.channels
            )
        }
    }

    var playbackSubtitleTracks: [MediaTrack] {
        (subtitle_tracks ?? []).enumerated().map { index, track in
            MediaTrack(
                id: index, kind: .subtitle,
                displayTitle: track.title ?? track.language ?? track.codec ?? String(index),
                language: track.language, codec: track.codec,
                isDefault: track.default, isForced: track.forced, isExternal: track.external
            )
        }
    }
}
