import Foundation
import AetherEngine
import CoreModels

/// Positive-only source enrichment off the UI/playback critical path.
public struct PlozzigenAuthenticatedHTTPStreamProber: AuthenticatedHTTPStreamProbing {
    private let resolver: any AuthenticatedHTTPResourceResolving

    public init(resolver: any AuthenticatedHTTPResourceResolving) {
        self.resolver = resolver
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
        var facts = ProbedStreamFacts()
        let started = Date()
        if requirements.contains(.hdr10Plus),
           await PlozzigenHDR10PlusProbe.probe(url: url) == true {
            facts.videoRangeType = "HDR10Plus"
        }
        guard !Task.isCancelled else { return nil }
        if requirements.contains(.atmos) {
            let probe = await PlozzigenStreamProbeExecutor.runAtmosProbe {
                try? AetherEngine.probeDetectingAtmos(url: url)
            }
            if let probe {
                let audio = PlozzigenNetworkFileStreamProber.facts(from: probe)
                facts.audioIsAtmos = audio.audioIsAtmos
                if audio.audioIsAtmos { facts.audioTrackID = audio.audioTrackID }
            }
        }
        guard !Task.isCancelled else { return nil }
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1_000)
        HandoffDiagnostics.emit(
            "sourceProbe item=\(locator.itemID) elapsed=\(elapsedMs)ms "
                + "hdr10plus=\(facts.videoRangeType == "HDR10Plus") atmos=\(facts.audioIsAtmos)"
        )
        return facts.audioIsAtmos || facts.videoRangeType != nil ? facts : nil
    }
}
