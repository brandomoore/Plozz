import CoreModels
import Foundation

public extension IPTVSetupDiagnostic.Failure {
    static func sanitized(_ error: any Error) -> Self {
        if error is CancellationError { return .init(.cancelled) }
        if error is DecodingError { return .init(.malformed) }
        if let failure = error as? LiveTVSourceImportError {
            switch failure {
            case .cancelled: return .init(.cancelled)
            case .downloadFailed: return .init(.network)
            case .invalidResponse, .temporarilyUnavailable: return .init(.invalidResponse)
            case .responseTooLarge, .guideTooLarge, .guideSourceLimitReached: return .init(.tooLarge)
            case .invalidPlaylist, .invalidGuide: return .init(.malformed)
            case .streamManifest: return .init(.unsupported)
            case .cacheFailed: return .init(.storage)
            case .unsafeGuideOrigin, .redirectBlocked: return .init(.redirectBlocked)
            case .guideWithoutPlaylist: return .init(.guideInsteadOfPlaylist)
            case .authenticationRequired: return .init(.authentication)
            case .tooManyRequests: return .init(.rateLimited)
            }
        }
        let system = error as NSError
        if system.domain == NSCocoaErrorDomain {
            if system.code == NSUserCancelledError { return .init(.cancelled) }
            if [NSFileReadNoSuchFileError, NSFileReadNoPermissionError].contains(system.code) {
                return .init(.fileUnavailable)
            }
            if [NSFileWriteOutOfSpaceError, NSFileWriteNoPermissionError, NSFileWriteUnknownError].contains(system.code) {
                return .init(.storage)
            }
        }
        if system.domain == NSURLErrorDomain {
            switch system.code {
            case NSURLErrorCancelled: return .init(.cancelled)
            case NSURLErrorTimedOut: return .init(.timeout, networkCode: system.code)
            case NSURLErrorNotConnectedToInternet: return .init(.offline, networkCode: system.code)
            default: return .init(.network, networkCode: system.code)
            }
        }
        if let error = error as? AppError {
            switch error {
            case .unauthorized, .invalidCredentials: return .init(.authentication)
            case .cancelled: return .init(.cancelled)
            case .serverUnreachable: return .init(.network)
            case .decoding: return .init(.malformed)
            case .notFound: return .init(.notFound)
            case .rateLimited: return .init(.rateLimited)
            case .invalidResponse: return .init(.invalidResponse)
            default: return .init(.other)
            }
        }
        return .init(.other)
    }
}
