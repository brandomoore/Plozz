import AetherEngine
import CoreModels
import FeaturePlayback
import Foundation

enum PlozzigenPlaybackFailure {
    static func classify(
        _ info: PlaybackErrorInfo?, fallbackError: Error? = nil
    ) -> StreamingPlaybackFailure? {
        let httpStatus = info.flatMap {
            ($0.kind == .sourceRefused || $0.kind == .sourceRateLimited)
                && $0.underlyingDomain == nil ? $0.underlyingCode : nil
        }
        let underlying = info.flatMap { info -> NSError? in
            guard let domain = info.underlyingDomain, let code = info.underlyingCode else { return nil }
            return NSError(domain: domain, code: code)
        } ?? (fallbackError as NSError?)
        let classified = NativePlaybackFailure.classify(underlying, httpStatus: httpStatus)
        guard let info else {
            return classified.kind == .unknown && classified.domain == nil ? nil : classified
        }
        var kind = classified.kind
        if info.kind == .sourceRateLimited {
            kind = .rateLimited
        } else if kind == .unknown {
            switch info.kind {
            case .storageExhausted: kind = .storageExhausted
            case .audioSessionFailed: kind = .audioOutputFailed
            case .dolbyVisionRequiresHardware, .demuxedAudioLiveUnsupported:
                kind = .unsupportedFormat
            case .softwarePipelineFailed, .audioBridgeProducedNoOutput: kind = .processingFailed
            case .noPlayableTrackWithinBudget, .liveReloadNeverReady: kind = .readinessTimedOut
            case .sourceCertificateRejected, .liveSourceUnavailable: kind = .network
            default: kind = .unknown
            }
        }
        var underlyingErrors = classified.underlyingErrors
        if underlyingErrors.isEmpty, let code = info.underlyingCode, httpStatus == nil {
            underlyingErrors = [.init(domain: info.underlyingDomain, code: code)]
        }
        return .init(
            kind: kind, domain: classified.domain, code: classified.code, httpStatus: classified.httpStatus,
            engineFailure: .init(rawValue: info.kind.rawValue) ?? .unknown,
            underlyingErrors: underlyingErrors
        )
    }
}
