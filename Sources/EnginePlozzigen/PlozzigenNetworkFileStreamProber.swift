import Foundation
import CoreModels
import AetherEngine
import MediaTransportCore

/// Probes a network file's headers through the same transport resolver and
/// representation-bound source used by playback.
///
/// Uses AetherEngine's combined bounded detail probe. This remains detail-only in
/// production; browse scans never decode media.
public struct PlozzigenNetworkFileStreamProber: NetworkFileStreamProbing {
    private let resolver: any MediaTransportNetworkFileResolving

    public init(resolver: any MediaTransportNetworkFileResolving) {
        self.resolver = resolver
    }

    public func probe(locator: NetworkFileLocator) async -> ProbedStreamFacts? {
        await probe(locator: locator, requirements: [.streamDetails, .atmos, .hdr10Plus])
    }

    public func probe(
        locator: NetworkFileLocator,
        requirements: SupplementalStreamProbeRequirements
    ) async -> ProbedStreamFacts? {
        guard !Task.isCancelled else { return nil }
        guard let resolved = try? await resolver.resolve(locator) else {
            HandoffDiagnostics.emit("shareProbe FAILED stage=resolve")
            return nil
        }
        let reader = TransportIOReader(resolvedSource: resolved)
        return await Self.probe(
            reader: reader, relativePath: locator.relativePath, requirements: requirements
        )
    }

    static func probe(
        reader: TransportIOReader,
        relativePath: String,
        requirements: SupplementalStreamProbeRequirements,
        operation: @escaping PlozzigenStreamProbeExecutor.Operation = PlozzigenStreamProbeExecutor.probe
    ) async -> ProbedStreamFacts? {
        let started = Date()
        let probe = await PlozzigenStreamProbeExecutor.runDetailProbe(
            reader: reader,
            formatHint: Self.formatHint(for: relativePath),
            requirements: requirements,
            // This reader belongs only to the probe. Closing latches cancellation,
            // including cancellation racing the start of its next async read.
            interrupt: { reader.close() },
            finalShutdown: { await reader.waitForFinalShutdown() },
            operation: operation
        )
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1_000)

        guard let probe, !Task.isCancelled else {
            HandoffDiagnostics.emit("shareProbe FAILED stage=probe elapsed=\(elapsedMs)ms")
            return nil
        }
        let facts = Self.facts(from: probe)
        HandoffDiagnostics.emit(
            "shareProbe elapsed=\(elapsedMs)ms range=\(facts.videoRangeType ?? "-") "
                + "codec=\(facts.audioCodec ?? "-") atmos=\(facts.audioIsAtmos)"
        )
        return facts
    }

    static func facts(from probe: SourceProbe) -> ProbedStreamFacts {
        let range: String? = switch probe.videoFormat {
        case .sdr: "SDR"
        case .hdr10: "HDR10"
        case .hdr10Plus: "HDR10Plus"
        case .hlg: "HLG"
        case .dolbyVision: "DOVI"
        }
        let audio = probe.audioTracks.first { $0.isDefault } ?? probe.audioTracks.first
        let w = Int(probe.videoWidth)
        let h = Int(probe.videoHeight)
        var facts = ProbedStreamFacts(
            videoWidth: w > 0 ? w : nil,
            videoHeight: h > 0 ? h : nil,
            videoRangeType: range,
            videoCodec: probe.videoCodecName,
            audioTrackID: audio?.id,
            audioCodec: audio?.codec,
            audioChannels: audio.map(\.channels).flatMap { $0 > 0 ? $0 : nil },
            audioIsAtmos: audio?.isAtmos ?? false,
            durationSeconds: probe.durationSeconds > 0 ? probe.durationSeconds : nil
        )
        facts.carriesHDR10PlusMetadata = probe.carriesHDR10PlusMetadata ? true : nil
        if probe.isDolbyVision || probe.videoFormat == .dolbyVision {
            facts.videoRangeType = "DOVI"
        } else if probe.carriesHDR10PlusMetadata {
            facts.videoRangeType = "HDR10Plus"
        }
        return facts
    }

    static func formatHint(for path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "mkv":               return "matroska"
        case "webm":              return "webm"
        case "mp4", "m4v", "mov": return "mp4"
        case "ts", "m2ts", "mts": return "mpegts"
        case "avi":               return "avi"
        default:                  return nil
        }
    }
}
