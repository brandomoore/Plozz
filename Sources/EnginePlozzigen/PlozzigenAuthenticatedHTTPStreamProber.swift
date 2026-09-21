import Foundation
import AetherEngine
import CoreModels

/// Positive-only source enrichment off the UI/playback critical path.
public struct PlozzigenAuthenticatedHTTPStreamProber: AuthenticatedHTTPStreamProbing {
    private let resolver: any AuthenticatedHTTPResourceResolving
    private let operation: PlozzigenStreamProbeExecutor.Operation

    public init(resolver: any AuthenticatedHTTPResourceResolving) {
        self.resolver = resolver
        self.operation = PlozzigenStreamProbeExecutor.probe
    }

    init(
        resolver: any AuthenticatedHTTPResourceResolving,
        operation: @escaping PlozzigenStreamProbeExecutor.Operation
    ) {
        self.resolver = resolver
        self.operation = operation
    }

    public func probe(
        locator: AuthenticatedHTTPPlaybackLocator
    ) async -> ProbedStreamFacts? {
        await probe(locator: locator, requirements: .atmos)
    }

    public func probe(
        locator: AuthenticatedHTTPPlaybackLocator,
        requirements: SupplementalStreamProbeRequirements
    ) async -> ProbedStreamFacts? {
        guard !requirements.isEmpty, !Task.isCancelled else { return nil }
        guard locator.deliveryMode == .directFile else {
            HandoffDiagnostics.emit(
                "atmosProbe SKIP item=\(locator.itemID) reason=notDirectFile"
            )
            return nil
        }
        guard let url = try? await resolver.resolve(locator) else {
            HandoffDiagnostics.emit(
                "atmosProbe FAILED item=\(locator.itemID) stage=resolve"
            )
            return nil
        }

        guard !Task.isCancelled else { return nil }
        let started = Date()
        let limits = HDR10PlusProbeLimits()
        let budget = HDR10PlusProbeBudget(limits: limits)
        let source = HDR10PlusHTTPRangeSource(url: url, budget: budget)
        let probe = await PlozzigenStreamProbeExecutor.runDetailProbe(
            reader: HDR10PlusAVIOReader(source: source, budget: budget),
            requirements: requirements,
            limits: limits,
            budget: budget,
            operation: operation
        )
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1_000)
        guard let probe, !Task.isCancelled else {
            HandoffDiagnostics.emit(
                "sourceProbe FAILED item=\(locator.itemID) stage=probe elapsed=\(elapsedMs)ms"
            )
            return nil
        }
        let facts = Self.facts(from: probe, requirements: requirements)
        HandoffDiagnostics.emit(
            "sourceProbe item=\(locator.itemID) elapsed=\(elapsedMs)ms "
                + "hdr10plus=\(facts.carriesHDR10PlusMetadata == true) atmos=\(facts.audioIsAtmos)"
        )
        return facts.audioIsAtmos || facts.carriesHDR10PlusMetadata == true ? facts : nil
    }

    static func facts(
        from probe: SourceProbe, requirements: SupplementalStreamProbeRequirements
    ) -> ProbedStreamFacts {
        var facts = ProbedStreamFacts()
        if requirements.contains(.hdr10Plus), probe.carriesHDR10PlusMetadata {
            facts.carriesHDR10PlusMetadata = true
            facts.videoRangeType = probe.isDolbyVision || probe.videoFormat == .dolbyVision
                ? "DOVI" : "HDR10Plus"
        }
        if requirements.contains(.atmos) {
            let audio = probe.audioTracks.first { $0.isDefault } ?? probe.audioTracks.first
            facts.audioIsAtmos = audio?.isAtmos ?? false
            if facts.audioIsAtmos { facts.audioTrackID = audio?.id }
        }
        // Base `.sdr` and unresolved detail flags never replace server metadata.
        return facts
    }
}
