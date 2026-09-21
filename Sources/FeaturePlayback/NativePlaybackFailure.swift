#if canImport(AVFoundation)
import AVFoundation
import CoreModels
import Foundation

enum NativePlaybackFailure {
    struct VideoFormat: Sendable {
        let codec: FourCharCode
        let transfer: String?
        let primaries: String?
        let matrix: String?

        init(_ description: CMFormatDescription) {
            codec = CMFormatDescriptionGetMediaSubType(description)
            transfer = CMFormatDescriptionGetExtension(
                description, extensionKey: kCMFormatDescriptionExtension_TransferFunction
            ) as? String
            primaries = CMFormatDescriptionGetExtension(
                description, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries
            ) as? String
            matrix = CMFormatDescriptionGetExtension(
                description, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix
            ) as? String
        }

        var isHDRH264: Bool {
            codec == kCMVideoCodecType_H264 && dynamicRange?.isHDR == true
        }

        var dynamicRange: SourceDynamicRange? {
            if transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String { return .hdr10 }
            if transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String { return .hlg }
            if transfer == kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String { return .sdr }
            if transfer == nil,
               primaries == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String,
               matrix == kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String { return .sdr }
            return nil
        }
    }

    @MainActor
    static func probeConvertedFormat(
        read: @MainActor () async throws -> VideoFormat?,
        isCurrent: @MainActor () -> Bool,
        pause: @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }
    ) async throws -> VideoFormat? {
        // HLS assets can initially report zero tracks while their init segment loads.
        var latest: VideoFormat?
        for _ in 0..<50 {
            try Task.checkCancellation()
            guard isCurrent() else { return nil }
            if let format = try await read() {
                try Task.checkCancellation()
                guard isCurrent() else { return nil }
                latest = format
                if format.dynamicRange != nil { return format }
            }
            try await pause()
        }
        return isCurrent() ? latest : nil
    }

    static func classify(
        _ error: NSError?, httpStatus: Int? = nil, convertedFormat: VideoFormat? = nil,
        provider: ProviderKind? = nil, convertingHDRSource: Bool = false
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
        } else if http == nil, kind == .unknown, media?.code == -12927,
                  convertingHDRSource, convertedFormat?.dynamicRange == nil {
            kind = .hdrConversionUnconfirmed
        }
        return .init(
            kind: kind, domain: domain, code: evidence?.code, httpStatus: http,
            provider: kind == .hdrConversion || kind == .hdrConversionUnconfirmed ? provider : nil
        )
    }
}
#endif
