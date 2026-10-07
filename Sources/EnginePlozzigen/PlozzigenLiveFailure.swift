#if canImport(AVFoundation)
import Foundation
import CoreModels
import AetherEngine

enum PlozzigenLiveFailure {
    static func appError(_ info: PlaybackErrorInfo?) -> AppError {
        guard let info else { return .unknown("live playback failed") }
        if info.kind == .sourceRateLimited { return .rateLimited(retryAfter: nil) }
        if info.kind == .sourceRefused, info.underlyingDomain == nil {
            switch info.underlyingCode {
            case 401, 403: return .unauthorized
            case 404, 410: return .notFound
            case 429, 503, 509: return .rateLimited(retryAfter: nil)
            default: return .invalidResponse
            }
        }
        if info.underlyingDomain == NSURLErrorDomain {
            switch info.underlyingCode {
            case NSURLErrorCancelled: return .cancelled
            case NSURLErrorFileDoesNotExist: return .notFound
            case NSURLErrorUserAuthenticationRequired: return .unauthorized
            case NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed,
                 NSURLErrorNotConnectedToInternet, NSURLErrorSecureConnectionFailed:
                return .serverUnreachable
            default: break
            }
        }
        switch info.kind {
        case .sourceOpenFailed, .nativeItemFailed, .noPlayableTrackWithinBudget,
             .masterPlaylistRejected, .vodSourceFailed, .reloadFailed, .liveReloadNeverReady:
            return .invalidResponse
        case .liveSourceUnavailable:
            return .serverUnreachable
        case .softwarePipelineFailed, .audioBridgeProducedNoOutput,
             .dolbyVisionRequiresHardware, .demuxedAudioLiveUnsupported:
            return .decoding
        default:
            return .unknown("live playback failed")
        }
    }

    static func diagnostic(_ info: PlaybackErrorInfo?) -> String {
        guard let info else { return "kind=unknown domain=none code=none" }
        let kind: String
        switch info.kind {
        case .sourceOpenFailed, .sourceRefused, .customSourceProbeFailed,
             .liveSourceUnavailable, .hlsPlaylistOnRawLivePath, .dolbyVisionRequiresHardware,
             .demuxedAudioLiveUnsupported, .nativeItemFailed, .noPlayableTrackWithinBudget,
             .masterPlaylistRejected, .vodSourceFailed, .sourceRateLimited,
             .softwarePipelineFailed, .audioSessionFailed, .reloadFailed,
             .liveReloadNeverReady, .audioTrackSwitchFailed, .audioBridgeProducedNoOutput:
            kind = info.kind.rawValue
        default:
            kind = "unknown"
        }
        let domain: String
        switch info.underlyingDomain {
        case nil: domain = "none"
        case NSURLErrorDomain: domain = "url"
        case "AVFoundationErrorDomain": domain = "avfoundation"
        case "CoreMediaErrorDomain": domain = "coremedia"
        case NSPOSIXErrorDomain: domain = "posix"
        default: domain = "other"
        }
        return "kind=\(kind) domain=\(domain) code=\(info.underlyingCode.map(String.init) ?? "none")"
    }

    static func record(
        _ info: PlaybackErrorInfo?, attempt: PlaybackFailureAttempt?, stage: PlaybackFailureDiagnostic.Stage,
        fallbackError: Error? = nil
    ) {
        let error = fallbackError.map { $0 as NSError }
        guard appError(info) != .cancelled, !(fallbackError is CancellationError),
              !(error?.domain == NSURLErrorDomain && error?.code == NSURLErrorCancelled) else { return }
        attempt?.fail(
            stage: stage,
            engineFailure: info.flatMap { .init(rawValue: $0.kind.rawValue) }
                ?? (stage == .audioSession ? .audioSessionFailed : .unknown),
            domain: .init(info == nil ? error?.domain : info?.underlyingDomain),
            code: info == nil ? error?.code : info?.underlyingCode,
            httpStatus: info?.kind == .sourceRefused && info?.underlyingDomain == nil ? info?.underlyingCode : nil
        )
    }
}
#endif
