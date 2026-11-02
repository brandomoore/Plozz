import CoreModels
import CoreNetworking
import Foundation

/// One bounded report per guide batch; never retain addresses, identities, payloads or error descriptions.
final class IPTVGuideDiagnostics {
    @TaskLocal static var request: Request?

    enum Endpoint: String { case xtream = "get_simple_data_table", xmltv }
    enum Fallback: String { case empty, malformed, unavailable }
    enum Stage: String { case lookup, request, download, parse }
    enum RedirectFailure: String { case invalidDestination, downgrade, credentials }

    final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private let started = ProcessInfo.processInfo.systemUptime
        private var stage = Stage.lookup
        private var requests = 0
        private var status: Int?
        private var response: IPTVSetupDiagnostic.Response?
        private var bytes = 0
        private var cached = false
        private var reusedFailure = false
        private var redirects = 0
        private var redirectFailure: RedirectFailure?

        func requesting() {
            lock.withLock {
                stage = .request
                requests += 1
                status = nil
                response = nil
            }
        }

        func received(_ response: HTTPURLResponse) {
            lock.withLock {
                status = response.statusCode
                self.response = .init(mimeType: response.mimeType)
                stage = .download
            }
        }

        func consumed(_ count: Int) { lock.withLock { bytes += count } }
        func parsing() { lock.withLock { stage = .parse } }
        func redirected() { lock.withLock { redirects += 1 } }
        func blockedRedirect(_ reason: RedirectFailure) { lock.withLock { redirectFailure = reason } }
        func reuseGuideFailure() { lock.withLock { reusedFailure = true } }
        func cacheHit(bytes: Int) {
            lock.withLock {
                cached = true
                self.bytes = bytes
                stage = .download
            }
        }

        func summary(rows: Int?, error: (any Error)?) -> String {
            lock.withLock {
                let failure = error.map(IPTVGuideDiagnostics.failure)
                let outcome = failure?.reason == .cancelled ? "cancelled" : error == nil ? "succeeded" : "failed"
                return "stage=\(stage.rawValue) outcome=\(outcome)"
                    + " requests=\(requests) http=\(status.map(String.init) ?? "unknown")"
                    + " response=\(response?.rawValue ?? "unknown") bytes=\(bytes) cached=\(cached)"
                    + " rows=\(rows.map(String.init) ?? "unknown") reason=\(failure?.reason.rawValue ?? "none")"
                    + " networkCode=\(failure?.networkCode.map(String.init) ?? "unknown")"
                    + " reusedFailure=\(reusedFailure)"
                    + " redirects=\(redirects) redirectBlocked=\(redirectFailure?.rawValue ?? "none")"
                    + " elapsedMs=\(IPTVGuideDiagnostics.milliseconds(since: started))"
            }
        }
    }

    private let id = UUID().uuidString
    private let started = ProcessInfo.processInfo.systemUptime
    private var samples: [(index: Int, text: String)] = []
    private var firstFailure: (index: Int, text: String)?
    private var last: (index: Int, text: String)?
    private var operations = 0
    private var fallbackCounts: [Fallback: Int] = [:]
    private let source: String
    private let channels: Int

    init(credential: IPTVCredential, channels: Int) {
        self.channels = channels
        source = !credential.explicitGuideURLs.isEmpty ? "explicitXMLTV"
            : credential.mode == .xtream ? "xtream" : "playlistXMLTV"
        PlozzLog.networking.info("IPTV_GUIDE batch=\(id) event=begin source=\(source) channels=\(channels)")
    }

    func record(_ request: Request, endpoint: Endpoint, rows: Int? = nil, error: (any Error)? = nil) {
        operations += 1
        let sample = (index: operations, text: "IPTV_GUIDE batch=\(id) event=request index=\(operations)"
            + " endpoint=\(endpoint.rawValue) " + request.summary(rows: rows, error: error))
        if samples.count < 4 { samples.append(sample) }
        if error != nil, firstFailure == nil { firstFailure = sample }
        last = sample
    }

    func fallback(_ reason: Fallback, channels: Int = 1) {
        fallbackCounts[reason, default: 0] += channels
    }

    func finish(rows: Int? = nil, error: (any Error)? = nil) {
        var retained = samples
        for sample in [firstFailure, last].compactMap({ $0 }) {
            if !retained.contains(where: { $0.index == sample.index }) { retained.append(sample) }
        }
        for sample in retained.sorted(by: { $0.index < $1.index }) { PlozzLog.networking.info(sample.text) }
        let failure = error.map(Self.failure)
        let outcome = failure?.reason == .cancelled ? "cancelled" : error == nil ? "succeeded" : "failed"
        let summary = "IPTV_GUIDE batch=\(id) event=complete source=\(source) channels=\(channels)"
            + " outcome=\(outcome) operations=\(operations) omitted=\(operations - retained.count)"
            + " fallbackEmpty=\(fallbackCounts[.empty, default: 0])"
            + " fallbackMalformed=\(fallbackCounts[.malformed, default: 0])"
            + " fallbackUnavailable=\(fallbackCounts[.unavailable, default: 0])"
            + " rows=\(rows.map(String.init) ?? "unknown") reason=\(failure?.reason.rawValue ?? "none")"
            + " elapsedMs=\(Self.milliseconds(since: started))"
        if error != nil, failure?.reason != .cancelled { PlozzLog.networking.error(summary) }
        else { PlozzLog.networking.info(summary) }
    }

    private static func failure(_ error: any Error) -> IPTVSetupDiagnostic.Failure {
        if let error = error as? IPTVError { return error.setupFailure }
        if let error = error as? ServerLiveTVError, error == .unsupportedAPI { return .init(.unsupported) }
        return .sanitized(error)
    }

    private static func milliseconds(since start: TimeInterval) -> Int {
        Int(min(86_400_000, max(0, (ProcessInfo.processInfo.systemUptime - start) * 1_000)))
    }
}
