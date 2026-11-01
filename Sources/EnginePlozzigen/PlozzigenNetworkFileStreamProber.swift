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

    public static func preparePlaybackSource(
        locator: NetworkFileLocator, startPosition: Double, source: any MediaTransportByteSource
    ) async throws {
        let isDisc = (locator.relativePath as NSString).pathExtension.lowercased() == "iso"
        guard isDisc || startPosition > 0 else { return }
        let reader = TransportIOReader(
            source: source, readAheadWindow: 4 * 1024 * 1024,
            maximumReadAheadSize: 4 * 1024 * 1024, discImageProbeEnabled: isDisc
        )
        var limits = HDR10PlusProbeLimits()
        limits.networkBytes = (isDisc ? 48 : 28) * 1024 * 1024
        limits.packets = 4_096
        limits.packetBytes = 4 * 1024 * 1024
        limits.wallTimeout = isDisc ? 30 : 20
        let report = await PlozzigenStreamProbeExecutor.runBoundedProbe(
            reader: reader, formatHint: formatHint(for: locator.relativePath), limits: limits,
            interrupt: { reader.close() }, finalShutdown: { await reader.waitForFinalShutdown() }
        ) { source, limits, cancellation in
            try AetherEngine.prepareSource(
                source: source, presentationTime: startPosition, duration: isDisc ? 4 : 2, preroll: 0,
                limits: limits, cancellation: cancellation
            )
        }
        guard let report else {
            try Task.checkCancellation()
            throw MediaTransportError.protocolViolation(reason: "source preparation did not complete")
        }
        let outcome: String = switch report.outcome {
        case .complete: "complete"
        case .endOfSource: "endOfSource"
        case .seekFailed: "seekFailed"
        case .budgetExhausted: "budgetExhausted"
        }
        HandoffDiagnostics.emit(
            "sourcePreparation outcome=\(outcome) inputBytes=\(report.inputBytesRead)"
                + " packets=\(report.demuxedPackets) start=\(startPosition)"
                + " origin=\(report.sourceOrigin) range=\(report.requestedSourceRange)"
        )
        for (kind, stream) in [("video", report.video), ("audio", report.audio)] {
            guard let stream else { continue }
            HandoffDiagnostics.emit(
                "sourcePreparation stream=\(kind) packets=\(stream.packetCount) bytes=\(stream.packetBytes)"
                    + " first=\(String(describing: stream.firstSourceTime))"
                    + " range=\(String(describing: stream.observedSourceRange))"
                    + " randomAccess=\(String(describing: stream.randomAccessSourceTime))"
                    + " untimed=\(stream.untimedPacketCount)"
            )
        }
        try requireCompletePreparation(report.outcome)
    }

    static func requireCompletePreparation(_ outcome: SourcePreparationOutcome) throws {
        switch outcome {
        case .complete:
            break
        case .endOfSource:
            throw MediaTransportPreparationIncomplete.endOfSource
        case .seekFailed:
            throw MediaTransportPreparationIncomplete.seekUnavailable
        case .budgetExhausted(let reason):
            switch reason {
            case .inputLimit:
                throw MediaTransportPreparationIncomplete.inputBudget
            case .packetLimit:
                throw MediaTransportPreparationIncomplete.packetBudget
            case .packetSizeLimit:
                throw MediaTransportPreparationIncomplete.packetSizeBudget
            case .timedOut:
                // This is the native optional-work budget report, never a
                // transport timeout or the resolver's preparation deadline.
                throw MediaTransportPreparationIncomplete.timeBudget
            case .invalidLimits, .invalidReaderResult, .unsupportedURL, .sourceBusy:
                throw reason
            }
        }
        // Do not turn an already observed incomplete/failure report into a
        // successful partial-cache handoff when Play cancels at this boundary.
        try Task.checkCancellation()
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
        let reader = TransportIOReader(
            resolvedSource: resolved,
            discImageProbeEnabled: Self.formatHint(for: locator.relativePath) == nil
        )
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
