#if canImport(AVFoundation)
import AVFoundation
import CoreModels
import Foundation

enum NativePlaybackFailure {
    static func classify(_ error: NSError?, httpStatus: Int? = nil) -> StreamingPlaybackFailure {
        var errors: [NSError] = []
        var current = error
        var visited = Set<ObjectIdentifier>()
        while let value = current, errors.count < 8, visited.insert(ObjectIdentifier(value)).inserted {
            errors.append(value)
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let network = errors.first { $0.domain == NSURLErrorDomain }
        let av = errors.first { $0.domain == AVFoundationErrorDomain }
        let media = errors.first { $0.domain == "CoreMediaErrorDomain" }
        let evidence = network ?? av ?? media
        let domain: StreamingPlaybackFailure.Domain? = network != nil ? .url : av != nil ? .avFoundation : media != nil ? .coreMedia : nil
        let http = httpStatus.flatMap { (400...599).contains($0) ? $0 : nil }
        let kind: StreamingPlaybackFailure.Kind
        if http == 401 || http == 403 { kind = .accessDenied }
        else if http == 404 || http == 410 { kind = .unavailable }
        else if http == 408 || http == 504 { kind = .timedOut }
        else if let http, http >= 500 { kind = .server }
        else if let network {
            switch URLError.Code(rawValue: network.code) {
            case .timedOut: kind = .timedOut
            case .userAuthenticationRequired, .userCancelledAuthentication: kind = .accessDenied
            case .fileDoesNotExist, .resourceUnavailable: kind = .unavailable
            case .cannotDecodeContentData, .cannotDecodeRawData: kind = .unsupportedFormat
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .secureConnectionFailed: kind = .network
            default: kind = .unknown
            }
        } else if let av, [AVError.Code.decoderNotFound.rawValue,
                          AVError.Code.fileFormatNotRecognized.rawValue, AVError.Code.decodeFailed.rawValue].contains(av.code) {
            kind = .unsupportedFormat
        } else {
            kind = .unknown
        }
        return .init(kind: kind, domain: domain, code: evidence?.code, httpStatus: http)
    }
}
#endif
