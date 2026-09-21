#if canImport(AVFoundation)
import AVFoundation
import CoreModels
import Foundation

enum NativePlaybackFailure {
    struct VideoFormat: Sendable {
        let codec: FourCharCode
        let transfer: String?

        init(_ description: CMFormatDescription) {
            codec = CMFormatDescriptionGetMediaSubType(description)
            transfer = CMFormatDescriptionGetExtension(
                description, extensionKey: kCMFormatDescriptionExtension_TransferFunction
            ) as? String
        }

        var isHDRH264: Bool {
            codec == kCMVideoCodecType_H264 && [
                kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String,
                kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
            ].contains(transfer ?? "")
        }
    }

    @MainActor
    static func probeConvertedFormat(
        read: @MainActor () async throws -> VideoFormat?,
        isCurrent: @MainActor () -> Bool,
        pause: @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }
    ) async throws -> VideoFormat? {
        // HLS assets can initially report zero tracks while their init segment loads.
        for _ in 0..<50 {
            try Task.checkCancellation()
            guard isCurrent() else { return nil }
            if let format = try await read() {
                try Task.checkCancellation()
                return isCurrent() ? format : nil
            }
            try await pause()
        }
        return nil
    }

    static func classify(
        _ error: NSError?, httpStatus: Int? = nil, convertedFormat: VideoFormat? = nil,
        provider: ProviderKind? = nil
    ) -> StreamingPlaybackFailure {
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
        var kind: StreamingPlaybackFailure.Kind
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
        if http == nil, (kind == .unsupportedFormat || (kind == .unknown && media?.code == -12927)),
           convertedFormat?.isHDRH264 == true {
            kind = .hdrConversion
        }
        return .init(
            kind: kind, domain: domain, code: evidence?.code, httpStatus: http,
            provider: kind == .hdrConversion ? provider : nil
        )
    }
}
#endif
