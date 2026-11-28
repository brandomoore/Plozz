import Foundation

/// A local, user-shared report. Only closed-vocabulary facts are exported.
public enum PlaybackDiagnosticReport: Equatable, Sendable {
    public enum Stage: String, Codable, Sendable { case preparation, opening, playback }

    case setup(IPTVSetupDiagnostic)
    case playback(LiveChannelFailureReport)
    case library(LibraryLoadDiagnostic)
    case homeSection(HomeSectionIssue.Reason, provider: ProviderKind?)
    case onDemand(
        error: StreamingQualityError, provider: ProviderKind, engine: PlaybackEngineKind?,
        stage: Stage, negotiatedCodec: DirectPlayVideoCodec? = nil,
        retryCodec: DirectPlayVideoCodec? = nil
    )

    public var message: LocalizedStringResource? {
        switch self {
        case .library: return nil
        case .homeSection(let reason, _): return reason.explanation
        case .onDemand(let error, _, _, _, _, _): return error.userMessage
        case .playback(let report): return report.message
        case .setup(let diagnostic):
            guard diagnostic.outcome == .failed, let failure = diagnostic.failure else { return nil }
            if [.storage, .invalidInput, .sourceChanged, .fileUnavailable].contains(failure.reason) { return nil }
            if let message = Self.providerMessage(httpStatus: diagnostic.httpStatus, networkCode: failure.networkCode) {
                return message
            }
            if diagnostic.response == .html, [.malformed, .invalidResponse, .empty].contains(failure.reason) {
                return "The provider returned HTML instead of a playlist or channel list. Check the address; it may lead to a login or error page."
            }
            return nil
        }
    }

    // l10n:content — stable, credential-free support protocol fields, not UI labels
    public var supportText: String {
        if case .library(let diagnostic) = self { return diagnostic.supportText }
        var fields = ["format=plozz-live-tv-1"]
        func field(_ key: String, _ value: String?) {
            if let value { fields.append("\(key)=\(value)") }
        }
        func number(_ key: String, _ value: Int?) { field(key, value.map(String.init)) }
        switch self {
        case .library: break
        case .homeSection(let reason, let provider):
            fields[0] = "format=plozz-home-section-1"
            field("operation", "homeSection")
            field("provider", provider?.rawValue)
            switch reason {
            case .failed(let error): field("reason", HandoffDiagnostics.errorCode(error))
            case .notReturned: field("reason", "notReturned")
            case .sourceUnavailable: field("reason", "sourceUnavailable")
            case .empty: field("reason", "empty")
            }
        case .onDemand(let error, let provider, let engine, let stage, let codec, let retryCodec):
            fields[0] = "format=plozz-playback-1"
            field("operation", "playback")
            field("content", "onDemand")
            field("provider", provider.rawValue)
            field("engine", engine?.rawValue)
            field("stage", stage.rawValue)
            field("failure", error.diagnosticCode)
            field("negotiated_codec", codec?.rawValue)
            field("retried_codec", retryCodec?.rawValue)
            if case .playback(let failure) = error {
                field("reason", failure.kind.rawValue)
                field("engine_failure", failure.engineFailure?.rawValue)
                field("provider_reason", failure.providerReason?.rawValue)
                field("domain", failure.domain?.rawValue)
                number("code", failure.code)
                number("http_status", failure.httpStatus)
                for (index, error) in failure.underlyingErrors.enumerated() {
                    field("underlying_error_\(index)", "\(error.domain.rawValue):\(error.code)")
                }
            }
        case .setup(let diagnostic):
            field("operation", "setup")
            field("source", diagnostic.source.rawValue)
            field("authentication", diagnostic.authentication.rawValue)
            field("entry", diagnostic.entry.rawValue)
            field("stage", diagnostic.stage.rawValue)
            field("outcome", diagnostic.outcome.rawValue)
            field("reason", diagnostic.failure?.reason.rawValue)
            field("response", diagnostic.response?.rawValue)
            number("http_status", diagnostic.httpStatus)
            number("network_code", diagnostic.failure?.networkCode)
            number("sqlite_code", diagnostic.failure?.sqliteCode)
            number("elapsed_ms", diagnostic.elapsedMilliseconds)
            number("stage_ms", diagnostic.stageMilliseconds)
            number("requests", diagnostic.requestCount)
            number("entries", diagnostic.entries)
            number("playlist_bytes", diagnostic.playlistBytes)
            number("skipped_entries", diagnostic.skippedEntries)
        case .playback(let report):
            fields[0] = "format=plozz-live-tv-2"
            field("operation", "playback")
            field("failure", report.failure.diagnosticCode)
            if let diagnostic = report.diagnostic {
                field("layer", diagnostic.layer.rawValue)
                field("stage", diagnostic.stage.rawValue)
                field("reason", diagnostic.reason.rawValue)
                field("engine_failure", diagnostic.engineFailure.rawValue)
                field("domain", diagnostic.domain.rawValue)
                field("stream_format", diagnostic.format.rawValue)
                number("code", diagnostic.code)
                number("http_status", diagnostic.httpStatus)
                number("elapsed_ms", diagnostic.elapsedMilliseconds)
                if let evidence = diagnostic.evidence {
                    field("route", evidence.route?.rawValue)
                    field("first_frame", evidence.firstFrameReady.map { $0 ? "true" : "false" })
                    field("native_capture", evidence.nativeCapture?.rawValue)
                    for (index, error) in evidence.nativeErrors.enumerated() {
                        field("native_error_\(index)", "\(error.domain.rawValue):\(error.code)")
                    }
                    for (index, error) in evidence.nativeLogErrors.enumerated() {
                        field("native_log_\(index)", "\(error.domain.rawValue):\(error.code)")
                    }
                    func request(_ prefix: String, _ value: PlaybackDeliveryEvidence.Request) {
                        number("\(prefix).sequence", value.sequence)
                        field("\(prefix).resource", value.resource.rawValue)
                        field("\(prefix).method", value.method.rawValue)
                        field("\(prefix).outcome", value.outcome.rawValue)
                        number("\(prefix).started_ms", value.startedMilliseconds)
                        number("\(prefix).elapsed_ms", value.elapsedMilliseconds)
                        number("\(prefix).http_status", value.status)
                        field("\(prefix).format", value.format.rawValue)
                        field("\(prefix).redirected", value.redirected.map { $0 ? "true" : "false" })
                        field("\(prefix).cross_origin", value.crossOrigin.map { $0 ? "true" : "false" })
                        field("\(prefix).range_requested", value.rangeRequested ? "true" : "false")
                        field("\(prefix).content_range", value.rangeResponse.rawValue)
                        number("\(prefix).expected_bytes", value.expectedBytes)
                        number("\(prefix).received_bytes", value.receivedBytes)
                        number("\(prefix).network_code", value.networkCode)
                        if let playlist = value.playlist {
                            field("\(prefix).hls_header", playlist.hasHeader ? "true" : "false")
                            field("\(prefix).hls_master", playlist.isMaster ? "true" : "false")
                            number("\(prefix).hls_target_ms", playlist.targetDurationMilliseconds)
                            number("\(prefix).hls_max_segment_ms", playlist.maximumSegmentMilliseconds)
                            number("\(prefix).hls_media_sequence", playlist.mediaSequence)
                            number("\(prefix).hls_segments", playlist.segments)
                            field("\(prefix).hls_endlist", playlist.hasEndList ? "true" : "false")
                            field("\(prefix).hls_byte_ranges", playlist.hasByteRanges ? "true" : "false")
                            field("\(prefix).hls_map", playlist.hasMap ? "true" : "false")
                            field("\(prefix).hls_encrypted", playlist.hasEncryption ? "true" : "false")
                        }
                    }
                    if let delivery = evidence.delivery {
                        if let root = delivery.root { request("upstream_root", root) }
                        if let failure = delivery.firstFailure { request("upstream_first_failure", failure) }
                        for (index, value) in delivery.recent.enumerated() {
                            request("upstream_\(index)", value)
                        }
                    }
                }
            }
        }
        return fields.joined(separator: "\n")
    }

    static func providerMessage(httpStatus: Int?, networkCode: Int?) -> LocalizedStringResource? {
        switch httpStatus {
        case 401:
            return "The provider did not accept authorization for this request (HTTP 401)."
        case 403:
            return "The provider refused access (HTTP 403)."
        case 404:
            return "The provider could not find the requested playlist or stream (HTTP 404)."
        case 410:
            return "The provider reported that this playlist or stream is no longer available (HTTP 410)."
        case 429, 509:
            return "The provider is limiting requests."
        case 451:
            return "The provider has restricted access to this stream (HTTP 451)."
        case .some(let status) where (500...599).contains(status):
            return "The provider returned a server error (HTTP \(String(status)))."
        default: break
        }
        switch networkCode {
        case URLError.timedOut.rawValue:
            return "The request to the provider did not respond in time."
        case URLError.notConnectedToInternet.rawValue:
            return "Your device is offline."
        case URLError.cannotFindHost.rawValue, URLError.dnsLookupFailed.rawValue:
            return "The provider’s address could not be resolved."
        case URLError.secureConnectionFailed.rawValue, URLError.serverCertificateHasBadDate.rawValue,
             URLError.serverCertificateUntrusted.rawValue, URLError.serverCertificateHasUnknownRoot.rawValue,
             URLError.serverCertificateNotYetValid.rawValue,
             URLError.clientCertificateRejected.rawValue, URLError.clientCertificateRequired.rawValue:
            return "A secure connection to the provider could not be established."
        default: return nil
        }
    }
}
