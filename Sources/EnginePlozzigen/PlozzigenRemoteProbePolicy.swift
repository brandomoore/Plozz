import AetherEngine
import CoreModels
import Foundation

enum PlozzigenRemoteProbePolicy {
    static func apply(to options: inout LoadOptions, request: PlaybackRequest, url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              !request.isTranscoding, !request.isManifestStream,
              let metadata = request.localRemuxSource?.sourceMetadata ?? request.sourceMetadata,
              ["mkv", "matroska", "webm"].contains(metadata.container?.lowercased() ?? ""),
              let video = metadata.video, video.codec?.lowercased() == "av1",
              (video.width ?? 0) > 0, (video.height ?? 0) > 0 else { return false }
        // Bound the AV1/Matroska metadata scan. The ordinary 50 MB / 60 s scan
        // can outlast the player's watchdog while chasing unresolvable font attachments.
        options.probesize = 2 * 1024 * 1024
        options.maxAnalyzeDuration = 2 * 1_000_000
        return true
    }

    static func isComplete(_ probe: SourceProbe?, for request: PlaybackRequest) -> Bool {
        guard let probe, probe.videoCodecID != 0, probe.videoWidth > 0, probe.videoHeight > 0,
              let metadata = request.localRemuxSource?.sourceMetadata ?? request.sourceMetadata,
              let video = metadata.video,
              probe.videoCodecName?.lowercased() == video.codec?.lowercased(),
              Int(probe.videoWidth) == video.width, Int(probe.videoHeight) == video.height else {
            return false
        }
        if metadata.audio != nil && probe.audioTracks.isEmpty { return false }
        if let selected = request.preferredAudioTrackID,
           !probe.audioTracks.contains(where: { $0.id == selected }) { return false }
        guard probe.audioTracks.allSatisfy({
            !$0.codec.isEmpty && $0.channels > 0 && $0.sampleRate > 0
        }) else { return false }
        let expectedAudio = request.audioTracks.filter { !$0.isExternal }
        let expectedSubtitles = request.subtitleTracks.filter { !$0.isExternal }
        return expectedAudio.allSatisfy { expected in
            probe.audioTracks.contains { $0.id == expected.id }
        } && expectedSubtitles.allSatisfy { expected in
            probe.subtitleTracks.contains {
                $0.id == expected.id && !$0.codec.isEmpty
                    && (!["ass", "ssa"].contains($0.codec) || $0.assHeader?.isEmpty == false)
            }
        }
    }
}
