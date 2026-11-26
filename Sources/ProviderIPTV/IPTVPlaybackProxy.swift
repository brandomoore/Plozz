import CoreModels
import CoreNetworking
import CryptoKit
import Foundation
import Network

/// AVFoundation forwards custom headers to every HLS host. Keep credentials
/// behind a per-playback, loopback-only endpoint and authorize each upstream
/// request against the original stream origin instead.
actor IPTVPlaybackProxy {
    private let listener: NWListener
    private let origin: URL
    private let originPortal: URL?
    private let alternateOrigins: [IPTVStreamDelivery.AlternateOrigin]
    private let portalPool: IPTVPortalPool?
    private var activeOrigin: URL
    private let headers: [String: String]
    private let formatHint: MediaFormatHint
    private let http: IPTVHTTP
    private let ownsHTTP: Bool
    private let isLive: Bool
    private let uptime: @Sendable () -> TimeInterval
    private let diagnostic: PlaybackFailureAttempt?
    private let key = SymmetricKey(size: .bits256)
    /// Derives each address's nonce from its URL, so a segment keeps one
    /// loopback address across playlist refreshes. A random nonce gave every
    /// refresh new URLs for the same MEDIA-SEQUENCE, which AVPlayer rejects
    /// (CoreMedia -12312) and stops following the live playlist.
    private let nonceKey = SymmetricKey(size: .bits256)
    private let token = UUID().uuidString
    private var port: UInt16?
    private var requests: [UUID: (NWConnection, Task<Void, Never>)] = [:]
    private var stopped = false
    private var didStart = false
    private var shutdown: Task<Void, Never>?
    private var liveRootRequest: UUID?
    private var rootWaiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    private var refusal: (status: Int, expiresAt: TimeInterval?)?
    private var playbackURL: URL?
    private var deliveryFailure: PlaybackDeliveryFailure?
    private var livePlaylistURL: URL?
    private var diagnosticSequence = 0
    private let diagnosticStarted = ProcessInfo.processInfo.systemUptime

    init(
        origin: URL, headers: [String: String], formatHint: MediaFormatHint = .init(),
        configuration: URLSessionConfiguration? = nil,
        sharedHTTP: IPTVHTTP? = nil,
        originPortal: URL? = nil,
        alternateOrigins: [IPTVStreamDelivery.AlternateOrigin] = [],
        portalPool: IPTVPortalPool? = nil,
        sensitiveValues: [String] = [], content: PlaybackFailureDiagnostic.Content = .live,
        diagnostics: PlaybackFailureDiagnostics = .shared,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) throws {
        self.origin = origin
        self.originPortal = originPortal
        self.alternateOrigins = alternateOrigins
        self.portalPool = portalPool
        self.activeOrigin = origin
        self.headers = headers
        self.formatHint = formatHint
        isLive = content == .live
        self.uptime = uptime
        if let sharedHTTP {
            http = sharedHTTP
            ownsHTTP = false
        } else {
            http = IPTVHTTP(
                configuration: configuration, resourceTimeout: 86_400,
                sensitiveValues: sensitiveValues, redirectScope: .playback
            )
            ownsHTTP = true
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        diagnostic = diagnostics.begin(layer: .iptvProxy, content: content, captureForPresentation: true)
    }

    func start() async throws -> URL {
        guard !stopped else { throw CancellationError() }
        guard !didStart else { throw AppError.invalidResponse }
        didStart = true
        let listener = listener
        let ready = IPTVListenerReady()
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                guard let self else { connection.cancel(); return }
                await self.accept(connection)
            }
        }
        let value: UInt16 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready.install(continuation)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if let port = listener.port?.rawValue { ready.finish(.success(port)) }
                        else { ready.finish(.failure(IPTVError.storage)) }
                    case .failed: ready.finish(.failure(IPTVError.storage))
                    case .cancelled: ready.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                listener.start(queue: DispatchQueue.global(qos: .userInitiated))
            }
        } onCancel: {
            ready.finish(.failure(CancellationError()))
            listener.cancel()
        }
        guard !stopped, !Task.isCancelled else { listener.cancel(); throw CancellationError() }
        port = value
        let url = try address(for: origin)
        playbackURL = url
        deliveryFailure = PlaybackDeliveryFailure.register(loopbackURL: url)
        return url
    }

    func stop() async {
        if let shutdown { await shutdown.value; return }
        stopped = true
        livePlaylistURL = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        if ownsHTTP { http.cancel() }
        if let playbackURL { PlaybackDeliveryFailure.unregister(loopbackURL: playbackURL) }
        let waiting = rootWaiters
        rootWaiters.removeAll()
        for (_, continuation) in waiting { continuation.resume(throwing: CancellationError()) }
        let pending = requests.values.map(\.1)
        for (connection, task) in requests.values { task.cancel(); connection.cancel() }
        requests.removeAll()
        let completion = Task { for task in pending { await task.value } }
        shutdown = completion
        await completion.value
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, requests.count < 16 else { connection.cancel(); return }
        let id = UUID()
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        let task = Task { [weak self] in
            guard let self else { connection.cancel(); return }
            await self.serve(connection, id: id)
            await self.finished(id)
        }
        requests[id] = (connection, task)
    }

    private func finished(_ id: UUID) {
        requests.removeValue(forKey: id)?.0.cancel()
    }

    private func cancelRequest(_ id: UUID) {
        guard let (connection, task) = requests[id] else { return }
        task.cancel()
        connection.cancel()
        cancelRootWaiter(id)
    }

    private func acquireLiveRoot(_ id: UUID) async throws {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        if liveRootRequest == nil { liveRootRequest = id; return }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                rootWaiters.append((id, continuation))
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancelRootWaiter(id) }
        }
    }

    private func cancelRootWaiter(_ id: UUID) {
        guard let index = rootWaiters.firstIndex(where: { $0.0 == id }) else { return }
        rootWaiters.remove(at: index).1.resume(throwing: CancellationError())
    }

    private func releaseLiveRoot(_ id: UUID) {
        guard liveRootRequest == id else { return }
        liveRootRequest = nil
        guard !stopped, !rootWaiters.isEmpty else { return }
        let next = rootWaiters.removeFirst()
        liveRootRequest = next.0
        next.1.resume()
    }

    private func address(for url: URL) throws -> URL {
        guard let port, LiveTVPlaylistSource.isSupportedURL(url),
              let encrypted = try AES.GCM.seal(
                  Data(url.absoluteString.utf8), using: key, nonce: Self.nonce(for: url, key: nonceKey)
              ).combined else {
            throw IPTVError.invalidAddress
        }
        let payload = encrypted.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let suffix = mediaSuffix(for: url)
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(token)/\(payload)\(suffix)") else {
            throw IPTVError.invalidAddress
        }
        return url
    }

    /// Deterministic per URL: reveals only that two addresses name the same
    /// upstream URL, which the playlist already says.
    static func nonce(for url: URL, key: SymmetricKey) throws -> AES.GCM.Nonce {
        let code = HMAC<SHA256>.authenticationCode(for: Data(url.absoluteString.utf8), using: key)
        return try AES.GCM.Nonce(data: Data(code).prefix(12))
    }

    private func upstream(for path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0] == token, parts[1].utf8.count <= 24_000 else {
            throw IPTVError.authentication
        }
        let resource = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(resource.count) else { throw IPTVError.authentication }
        var text = resource[0].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: text),
              let raw = String(data: try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key), encoding: .utf8),
              let url = URL(string: raw), LiveTVPlaylistSource.isSupportedURL(url),
              (resource.count == 2 ? "." + resource[1] : "") == mediaSuffix(for: url) else {
            throw IPTVError.authentication
        }
        return url
    }

    private func mediaSuffix(for url: URL) -> String {
        let suffix = url.pathExtension.lowercased()
        // Some playlists declare output=ts but omit the extension from every channel URL.
        if suffix.isEmpty, url == origin, let container = formatHint.container,
           ["ts", "m3u8"].contains(container) {
            return "." + container
        }
        return ["m3u8", "ts", "m2ts", "mts"].contains(suffix) ? "." + suffix : ""
    }

    private func serve(_ connection: NWConnection, id: UUID) async {
        defer { releaseLiveRoot(id) }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(15)); connection.cancel() }
            catch is CancellationError {}
            catch { connection.cancel() }
        }
        defer { deadline.cancel() }
        var sentResponse = false
        var diagnosticStage: PlaybackFailureDiagnostic.Stage?
        var rejectedBody = false
        let responseEvidence = IPTVPlaybackResponseEvidence()
        var receivedBytes = 0
        do {
            var head = Data()
            while head.range(of: Data("\r\n\r\n".utf8)) == nil {
                let bytes = try await Self.receive(connection, maximum: 32_768 - head.count)
                guard !bytes.isEmpty, head.count + bytes.count < 32_768 else { throw IPTVError.malformed }
                head.append(bytes)
            }
            deadline.cancel()
            guard let text = String(data: head, encoding: .utf8), let line = text.components(separatedBy: "\r\n").first else {
                throw IPTVError.malformed
            }
            let request = line.split(separator: " ")
            guard request.count == 3, request[0] == "GET" || request[0] == "HEAD" else { throw IPTVError.unsupported }
            let url = try upstream(for: String(request[1]))
            // No request body/pipelining is supported. Observe EOF while the
            // upstream is stalled, rather than waiting for our next socket write.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
                Task { await self?.cancelRequest(id) }
            }
            if isLive, url == origin { try await acquireLiveRoot(id) }
            if let refusal {
                if let expiresAt = refusal.expiresAt, uptime() >= expiresAt {
                    self.refusal = nil
                    deliveryFailure?.clearRateLimit()
                } else {
                    try await Self.send(connection, data: Self.failureHead(
                        refusal.status, retryAfter: refusal.expiresAt.map { max(0, $0 - uptime()) }
                    ))
                    return
                }
            }
            var outgoing: [String: String] = [:]
            for field in text.components(separatedBy: "\r\n").dropFirst() {
                guard let colon = field.firstIndex(of: ":") else { continue }
                let name = field[..<colon].lowercased()
                if name == "range" || name == "if-range" {
                    outgoing[String(field[..<colon])] = field[field.index(after: colon)...]
                        .trimmingCharacters(in: .whitespaces)
                }
            }
            diagnosticStage = .response
            let (bytes, response) = try await openUpstream(
                url: url, forwardedHeaders: outgoing, method: String(request[0]), evidence: responseEvidence
            )
            defer { bytes.task.cancel() }
            let upstreamTask = bytes.task
            try await withTaskCancellationHandler {
                if request[0] == "HEAD" {
                    responseEvidence.finish(outcome: .complete, receivedBytes: 0)
                    diagnosticStage = nil
                    try await Self.send(connection, data: responseHead(response, chunked: false))
                    return
                }
                diagnosticStage = .body
                var iterator = bytes.makeAsyncIterator()
                var prefix = Data()
                while prefix.count < 16, let byte = try await iterator.next() {
                    prefix.append(byte)
                    receivedBytes += 1
                }
                responseEvidence.received(receivedBytes)
                // Keys, encrypted segments and byte ranges are opaque bytes, not documents.
                if isLive, url == origin, !outgoing.keys.contains(where: { $0.lowercased() == "range" }),
                   response.statusCode != 206, response.value(forHTTPHeaderField: "Content-Range") == nil,
                   let format = Self.nonVideoBodyFormat(prefix) {
                    responseEvidence.detect(format)
                    rejectedBody = true
                    throw AppError.invalidResponse
                }
                let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                let prefixText = String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let hasManifestHeader = prefixText.hasPrefix("#EXTM3U")
                    || prefixText.hasPrefix("\u{FEFF}#EXTM3U")
                let manifest = contentType.contains("mpegurl") || hasManifestHeader
                if manifest {
                    responseEvidence.detect(.hls)
                    var body = prefix
                    while let byte = try await iterator.next() {
                        guard body.count < 8 * 1_024 * 1_024 else { throw IPTVError.oversizedRecord }
                        body.append(byte)
                        receivedBytes += 1
                        if body.count.isMultiple(of: 65_536) {
                            responseEvidence.received(receivedBytes)
                            try Task.checkCancellation()
                        }
                    }
                    guard let text = String(data: body, encoding: .utf8) else { throw IPTVError.malformed }
                    responseEvidence.playlist(Self.playlistEvidence(text))
                    diagnosticStage = .manifest
                    let rewritten = try rewrite(text, baseURL: response.url ?? url)
                    try Task.checkCancellation()
                    if isLive, url == origin, hasManifestHeader {
                        // Reopening an Xtream entrypoint can mint new session URLs
                        // for the same HLS media sequence. Refresh its delivery URL.
                        livePlaylistURL = response.url
                    }
                    let data = Data(rewritten.utf8)
                    responseEvidence.finish(outcome: .complete, receivedBytes: receivedBytes)
                    diagnosticStage = nil
                    try await Self.send(connection, data: Data(
                        "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8
                    ))
                    sentResponse = true
                    try await Self.send(connection, data: data)
                } else {
                    diagnosticStage = nil
                    try await Self.send(connection, data: responseHead(response, chunked: true))
                    sentResponse = true
                    var chunk = prefix
                    diagnosticStage = .body
                    while let byte = try await iterator.next() {
                        chunk.append(byte)
                        receivedBytes += 1
                        if chunk.count == 65_536 {
                            responseEvidence.received(receivedBytes)
                            try Task.checkCancellation()
                            diagnosticStage = nil
                            try await Self.sendChunk(connection, data: chunk)
                            chunk.removeAll(keepingCapacity: true)
                            diagnosticStage = .body
                        }
                    }
                    responseEvidence.finish(outcome: .complete, receivedBytes: receivedBytes)
                    diagnosticStage = nil
                    if !chunk.isEmpty { try await Self.sendChunk(connection, data: chunk) }
                    try await Self.send(connection, data: Data("0\r\n\r\n".utf8))
                }
            } onCancel: { upstreamTask.cancel() }
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
                || (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled
            responseEvidence.finish(
                outcome: cancelled || diagnosticStage == nil ? .consumerClosed : .upstreamFailure,
                receivedBytes: receivedBytes,
                networkCode: (error as NSError).domain == NSURLErrorDomain ? (error as NSError).code : nil
            )
            if !Task.isCancelled, !(error is CancellationError), let diagnosticStage {
                let failure = (error as? IPTVError)?.setupFailure ?? .sanitized(error)
                let evidence = responseEvidence.snapshot
                let failureDiagnostic = diagnostic?.fail(
                    stage: diagnosticStage, reason: failure.reason,
                    domain: failure.networkCode == nil ? .none : .url, code: failure.networkCode,
                    httpStatus: evidence.status, format: evidence.format,
                    evidence: .init(delivery: deliveryFailure?.evidence)
                )
                if rejectedBody {
                    deliveryFailure?.clearRateLimit()
                    deliveryFailure?.record(.invalidResponse, diagnostic: failureDiagnostic)
                    if refusal == nil || refusal.map({ [429, 509].contains($0.status) }) == true {
                        refusal = (502, nil)
                    }
                } else if let status = evidence.status,
                   [401, 403, 429, 451, 509].contains(status) || error as? AppError == .conflict {
                    let retryAfter: TimeInterval?
                    if case AppError.rateLimited(let delay) = error { retryAfter = delay }
                    else { retryAfter = nil }
                    let appError: AppError
                    switch status {
                    case 401, 403: appError = .unauthorized
                    case 429, 509: appError = .rateLimited(retryAfter: retryAfter)
                    case 451: appError = .accessRestricted
                    case 503: appError = .conflict
                    default: appError = .invalidResponse
                    }
                    if ![429, 509].contains(status) { deliveryFailure?.clearRateLimit() }
                    deliveryFailure?.record(appError, diagnostic: failureDiagnostic)
                    if refusal == nil || refusal.map({ [429, 509].contains($0.status) }) == true {
                        var expiresAt = retryAfter.map { uptime() + $0 }.flatMap { $0.isFinite ? $0 : nil }
                        if let previous = refusal, [429, 509].contains(status) {
                            // Overlapping HLS requests may extend, but never shorten, a cooldown.
                            expiresAt = previous.expiresAt.flatMap { previousExpiry in
                                expiresAt.map { max(previousExpiry, $0) }
                            }
                        }
                        refusal = (status, expiresAt)
                    }
                }
            }
            if !Task.isCancelled { PlozzLog.playback.error("Authenticated IPTV delivery failed") }
            if !sentResponse {
                do {
                    let status = responseEvidence.snapshot.status
                    try await Self.send(connection, data: Self.failureHead(
                        status.flatMap { (400...599).contains($0) ? $0 : nil } ?? 502,
                        retryAfter: refusal?.expiresAt.map { max(0, $0 - uptime()) }
                    ))
                } catch { connection.cancel() }
            }
        }
    }

    private func openUpstream(
        url: URL, forwardedHeaders: [String: String], method: String,
        evidence: IPTVPlaybackResponseEvidence
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let failoverTimeout: TimeInterval = 8
        func scopedHeaders(for target: URL) -> [String: String] {
            if IPTVCredential.sameOrigin(activeOrigin, target)
                || IPTVCredential.sameOrigin(origin, target)
                || alternateOrigins.contains(where: { IPTVCredential.sameOrigin($0.url, target) }) {
                return headers
            }
            return [:]
        }
        func fetch(_ target: URL, timeout: TimeInterval? = nil) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
            let scoped = scopedHeaders(for: target)
            diagnosticSequence = min(1_000_000, diagnosticSequence + 1)
            var request = PlaybackDeliveryEvidence.Request(
                sequence: diagnosticSequence, resource: url == origin ? .root : .child,
                method: method == "HEAD" ? .head : .get,
                startedMilliseconds: min(86_400_000, max(0, Int(
                    (ProcessInfo.processInfo.systemUptime - diagnosticStarted) * 1_000
                )))
            )
            request.rangeRequested = forwardedHeaders.keys.contains { $0.lowercased() == "range" }
            evidence.begin(request, delivery: deliveryFailure)
            let currentOrigin = activeOrigin
            return try await http.bytes(
                url: target, headers: scoped.merging(forwardedHeaders) { _, forwarded in forwarded },
                method: method, timeout: timeout,
                receivedResponse: { response in
                    evidence.record(response: response, target: target, origin: currentOrigin)
                }
            )
        }
        if url == origin, !alternateOrigins.isEmpty {
            let redirectedLive = isLive ? livePlaylistURL : nil
            struct Attempt {
                let portal: URL?
                let url: URL
                let isRedirectedLive: Bool
            }
            var attempts: [Attempt] = []
            var seenURLs = Set<URL>()
            if let redirectedLive {
                attempts.append(.init(portal: originPortal, url: redirectedLive, isRedirectedLive: true))
                seenURLs.insert(redirectedLive)
            }
            if seenURLs.insert(activeOrigin).inserted {
                let activePortal = activeOrigin == origin
                    ? originPortal
                    : alternateOrigins.first(where: { $0.url == activeOrigin })?.portal
                attempts.append(.init(portal: activePortal, url: activeOrigin, isRedirectedLive: false))
            }
            for alternate in alternateOrigins where seenURLs.insert(alternate.url).inserted {
                attempts.append(.init(portal: alternate.portal, url: alternate.url, isRedirectedLive: false))
            }
            var didFailOver = false
            for (index, attempt) in attempts.enumerated() {
                let isLast = index == attempts.count - 1
                let timeout: TimeInterval? = isLast ? nil : failoverTimeout
                do {
                    let result = try await fetch(attempt.url, timeout: timeout)
                    if !attempt.isRedirectedLive {
                        if attempt.url != activeOrigin {
                            activeOrigin = attempt.url
                            livePlaylistURL = nil
                        }
                    }
                    if didFailOver, let portal = attempt.portal {
                        await portalPool?.recordSuccess(portal)
                        PlozzLog.playback.info("IPTV_PORTAL event=streamFailoverSucceeded")
                        HandoffDiagnostics.emit("IPTV_PORTAL event=streamFailoverSucceeded")
                    }
                    return result
                } catch {
                    if attempt.isRedirectedLive, !Task.isCancelled, !(error is CancellationError),
                       let status = evidence.snapshot.status, [401, 403, 404, 410].contains(status) {
                        evidence.finish(outcome: .upstreamFailure, receivedBytes: 0)
                        livePlaylistURL = nil
                        evidence.reset()
                        PlozzLog.playback.debug("Renewing expired IPTV live delivery")
                        continue
                    }
                    guard !isLast, !Task.isCancelled, !(error is CancellationError),
                          IPTVPortalPool.shouldFailOver(after: error, httpStatus: evidence.snapshot.status) else {
                        throw error
                    }
                    if let portal = attempt.portal {
                        await portalPool?.recordFailure(portal)
                    }
                    didFailOver = true
                    evidence.finish(outcome: .upstreamFailure, receivedBytes: 0)
                    evidence.reset()
                    PlozzLog.playback.info("IPTV_PORTAL event=streamFailoverRetrying")
                }
            }
        }
        let target = isLive && url == origin ? livePlaylistURL ?? url : url
        do {
            return try await fetch(target)
        } catch {
            guard target != url, !Task.isCancelled, !(error is CancellationError),
                  let status = evidence.snapshot.status, [401, 403, 404, 410].contains(status) else { throw error }
            evidence.finish(outcome: .upstreamFailure, receivedBytes: 0)
            // Renew only an expired redirected session, once. A refusal from
            // the original entrypoint still follows the terminal failure path.
            livePlaylistURL = nil
            evidence.reset()
            PlozzLog.playback.debug("Renewing expired IPTV live delivery")
            return try await fetch(url)
        }
    }

    private static func failureHead(_ status: Int, retryAfter: TimeInterval? = nil) -> Data {
        let retry = retryAfter.flatMap {
            $0.isFinite && $0 >= 0 ? "Retry-After: \(String(format: "%.0f", ceil($0)))\r\n" : nil
        } ?? ""
        return Data("HTTP/1.1 \(status) Upstream Failure\r\n\(retry)Content-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }

    private final class IPTVPlaybackResponseEvidence: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int?
        private var format: PlaybackFailureDiagnostic.Format = .unknown
        private var request: PlaybackDeliveryEvidence.Request?
        private var delivery: PlaybackDeliveryFailure?
        private var started = ProcessInfo.processInfo.systemUptime

        var snapshot: (status: Int?, format: PlaybackFailureDiagnostic.Format) {
            lock.withLock { (status, format) }
        }

        func begin(_ request: PlaybackDeliveryEvidence.Request, delivery: PlaybackDeliveryFailure?) {
            lock.withLock {
                self.request = request
                self.delivery = delivery
                started = ProcessInfo.processInfo.systemUptime
                delivery?.recordRequest(request)
            }
        }

        private func update(_ change: (inout PlaybackDeliveryEvidence.Request) -> Void) {
            lock.withLock {
                guard var request else { return }
                change(&request)
                request.elapsedMilliseconds = min(86_400_000, max(0, Int(
                    (ProcessInfo.processInfo.systemUptime - started) * 1_000
                )))
                self.request = request
                delivery?.recordRequest(request)
            }
        }

        func record(response: HTTPURLResponse, target: URL, origin: URL) {
            lock.withLock {
                status = response.statusCode
                format = .init(mimeType: response.mimeType)
            }
            update {
                $0.status = response.statusCode
                $0.format = .init(mimeType: response.mimeType)
                $0.outcome = .receiving
                $0.redirected = response.url.map { $0 != target }
                $0.crossOrigin = response.url.map { !IPTVCredential.sameOrigin(origin, $0) }
                let length = response.expectedContentLength
                $0.expectedBytes = (0...9_007_199_254_740_991).contains(length) ? Int(length) : nil
                $0.rangeResponse = IPTVPlaybackProxy.rangeEvidence(response.value(forHTTPHeaderField: "Content-Range"))
            }
        }

        func received(_ count: Int) { update { $0.receivedBytes = min(9_007_199_254_740_991, count) } }
        func playlist(_ value: PlaybackDeliveryEvidence.Playlist) { update { $0.playlist = value } }
        func finish(outcome: PlaybackDeliveryEvidence.Outcome, receivedBytes: Int, networkCode: Int? = nil) {
            update {
                // A failed loopback write cannot undo a completely received upstream response.
                if $0.outcome != .complete { $0.outcome = outcome }
                $0.receivedBytes = min(9_007_199_254_740_991, receivedBytes)
                $0.networkCode = networkCode
            }
        }
        func detect(_ detected: PlaybackFailureDiagnostic.Format) {
            lock.withLock { format = detected }
            update { $0.format = detected }
        }
        func reset() { lock.withLock { status = nil; format = .unknown } }
    }

    nonisolated static func nonVideoBodyFormat(_ prefix: Data) -> PlaybackFailureDiagnostic.Format? {
        guard !prefix.isEmpty else { return .empty }
        let text = String(decoding: prefix.prefix(16), as: UTF8.self)
            .drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
        let lower = text.lowercased()
        func tag(_ name: String) -> Bool {
            guard lower.hasPrefix(name), let next = lower.dropFirst(name.count).first else { return false }
            return next == ">" || next == "/" || next.isWhitespace
        }
        if tag("<!doctype html") || tag("<html") { return .html }
        if tag("<?xml") || tag("<mediacontainer") { return .xml }
        guard text.utf8.allSatisfy({ (32...126).contains($0) || [9, 10, 13].contains($0) }),
              let first = text.first else { return nil }
        let tail = text.dropFirst().drop(while: \.isWhitespace)
        if first == "{", tail.first == "\"" || tail.first == "}" { return .json }
        if first == "[", let next = tail.first,
           "\"{[]-".contains(next) || next.isNumber
            || ["true", "false", "null"].contains(where: { tail.hasPrefix($0) }) {
            return .json
        }
        return nil
    }

    nonisolated static func rangeEvidence(_ value: String?) -> PlaybackDeliveryEvidence.RangeResponse {
        guard let value else { return .absent }
        let fields = value.split(separator: " ")
        guard fields.count == 2, fields[0].lowercased() == "bytes" else { return .invalid }
        let parts = fields[1].split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .invalid }
        if parts[0] == "*", Int(parts[1]).map({ $0 >= 0 }) == true { return .valid }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int(bounds[0]), let end = Int(bounds[1]),
              start >= 0, end >= start else { return .invalid }
        if parts[1] != "*", Int(parts[1]).map({ $0 > end }) != true { return .invalid }
        return .valid
    }

    nonisolated static func playlistEvidence(_ text: String) -> PlaybackDeliveryEvidence.Playlist {
        var value = PlaybackDeliveryEvidence.Playlist(
            hasHeader: false, isMaster: false, targetDurationMilliseconds: nil,
            maximumSegmentMilliseconds: nil, mediaSequence: nil, segments: 0,
            hasEndList: false, hasByteRanges: false, hasMap: false, hasEncryption: false
        )
        func milliseconds(_ raw: Substring) -> Int? {
            guard let seconds = Double(raw), seconds.isFinite, (0...86_400).contains(seconds) else { return nil }
            return Int((seconds * 1_000).rounded())
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "#EXTM3U" || line == "\u{FEFF}#EXTM3U" { value.hasHeader = true }
            if line.hasPrefix("#EXT-X-STREAM-INF:") { value.isMaster = true }
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                value.targetDurationMilliseconds = milliseconds(line.dropFirst(22))
            }
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:"),
               let sequence = Int(line.dropFirst(22)), (0...9_007_199_254_740_991).contains(sequence) {
                value.mediaSequence = sequence
            }
            if line.hasPrefix("#EXTINF:") {
                value.segments = min(1_000_000, value.segments + 1)
                if let duration = milliseconds(line.dropFirst(8).split(separator: ",").first ?? "") {
                    value.maximumSegmentMilliseconds = max(value.maximumSegmentMilliseconds ?? 0, duration)
                }
            }
            if line == "#EXT-X-ENDLIST" { value.hasEndList = true }
            if line.hasPrefix("#EXT-X-BYTERANGE:") { value.hasByteRanges = true }
            if line.hasPrefix("#EXT-X-MAP:") { value.hasMap = true }
            if line.hasPrefix("#EXT-X-KEY:") {
                // Quoted URI text is not an encryption-method attribute.
                let method = line.dropFirst(11).split(separator: "\"", omittingEmptySubsequences: false)
                    .enumerated().filter { $0.offset.isMultiple(of: 2) }
                    .flatMap { $0.element.split(separator: ",") }
                    .first { $0.hasPrefix("METHOD=") }?.dropFirst(7)
                if let method, !method.isEmpty, method != "NONE" { value.hasEncryption = true }
            }
        }
        return value
    }

    func rewrite(_ manifest: String, baseURL: URL) throws -> String {
        let expression = try NSRegularExpression(pattern: #"\bURI="([^"]+)""#)
        let normalized = manifest.hasPrefix("\u{FEFF}") ? String(manifest.dropFirst()) : manifest
        return try normalized.components(separatedBy: .newlines).map { line in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            if !line.hasPrefix("#") {
                guard let url = URL(string: line.trimmingCharacters(in: .whitespaces), relativeTo: baseURL)?.absoluteURL else {
                    throw IPTVError.malformed
                }
                return try address(for: url).absoluteString
            }
            var result = line
            for match in expression.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                guard let range = Range(match.range(at: 1), in: result),
                      let url = URL(string: String(result[range]), relativeTo: baseURL)?.absoluteURL else {
                    throw IPTVError.malformed
                }
                result.replaceSubrange(range, with: try address(for: url).absoluteString)
            }
            return result
        }.joined(separator: "\n")
    }

    private func responseHead(_ response: HTTPURLResponse, chunked: Bool) -> Data {
        var fields = ["HTTP/1.1 \(response.statusCode) OK", "Connection: close"]
        for name in ["Content-Type", "Content-Range", "Accept-Ranges"] {
            if let value = response.value(forHTTPHeaderField: name),
               !value.contains("\r"), !value.contains("\n") { fields.append(name + ": " + value) }
        }
        if chunked { fields.append("Transfer-Encoding: chunked") }
        else if response.expectedContentLength >= 0 { fields.append("Content-Length: \(response.expectedContentLength)") }
        return Data((fields.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private nonisolated static func receive(_ connection: NWConnection, maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, maximum)) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }

    private nonisolated static func send(_ connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private nonisolated static func sendChunk(_ connection: NWConnection, data: Data) async throws {
        var output = Data((String(data.count, radix: 16) + "\r\n").utf8)
        output.append(data)
        output.append(Data("\r\n".utf8))
        try await send(connection, data: output)
    }
}

private final class IPTVListenerReady: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    private var result: Result<UInt16, Error>?

    func install(_ continuation: CheckedContinuation<UInt16, Error>) {
        let completed: Result<UInt16, Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let completed { continuation.resume(with: completed) }
    }

    func finish(_ result: Result<UInt16, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let callback = continuation
        continuation = nil
        lock.unlock()
        callback?.resume(with: result)
    }
}
