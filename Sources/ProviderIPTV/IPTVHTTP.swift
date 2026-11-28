import CoreModels
import CoreNetworking
import Foundation
import os

final class IPTVHTTP: Sendable {
    @TaskLocal static var performanceMetrics: IPTVPerformanceMetrics?

    /// One guide operation's latest response policy, without changing thrown error kinds.
    final class ResponseMetadata: Sendable {
        private let state = OSAllocatedUnfairLock<(status: Int, retryAfter: TimeInterval?)?>(initialState: nil)

        func received(_ response: HTTPURLResponse) {
            let retryAfter = HTTPDate.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))
            state.withLock { $0 = (response.statusCode, retryAfter) }
        }

        func retryAfter(for error: any Error) -> TimeInterval? {
            let status: Int
            switch error {
            case AppError.rateLimited: status = 429
            case IPTVError.httpStatus(let code): status = code
            default: return nil
            }
            return state.withLock { $0?.status == status ? $0?.retryAfter : nil }
        }
    }

    private let session: URLSession
    private let redirects: IPTVRedirects
    private typealias RequestTask = Task<(URLSession.AsyncBytes, URLResponse), Error>
    private struct Lifecycle {
        var closed = false
        var starting: [UUID: RequestTask] = [:]
        var activeStreams: [UUID: IPTVHTTPChunkStream] = [:]
        var warmups: [UUID: Task<Void, Never>] = [:]
    }
    private let lifecycle = OSAllocatedUnfairLock(initialState: Lifecycle())

    init(
        configuration: URLSessionConfiguration? = nil, resourceTimeout: TimeInterval = 1_800,
        sensitiveValues: [String] = [], redirectScope: IPTVRedirectPolicy.Scope = .account
    ) {
        let configuration = configuration ?? .ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = resourceTimeout
        redirects = IPTVRedirects(sensitiveValues: sensitiveValues, scope: redirectScope)
        session = OfflineNetworkSession.make(configuration: configuration, delegate: redirects, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }
    func cancel() {
        let shutdown = lifecycle.withLock { state -> (
            tasks: [RequestTask], streams: [IPTVHTTPChunkStream], warmups: [Task<Void, Never>], invalidate: Bool
        ) in
            guard !state.closed else { return ([], [], [], false) }
            state.closed = true
            let streams = Array(state.activeStreams.values)
            state.activeStreams.removeAll()
            let warmups = Array(state.warmups.values)
            return (
                Array(state.starting.values), streams, warmups,
                state.starting.isEmpty && streams.isEmpty && warmups.isEmpty
            )
        }
        for task in shutdown.tasks { task.cancel() }
        for stream in shutdown.streams { stream.cancel() }
        for warmup in shutdown.warmups { warmup.cancel() }
        if shutdown.invalidate { session.invalidateAndCancel() }
    }

    private func finishStarting(_ id: UUID) {
        let invalidate = lifecycle.withLock { state in
            state.starting.removeValue(forKey: id)
            return state.closed && state.starting.isEmpty && state.activeStreams.isEmpty && state.warmups.isEmpty
        }
        if invalidate { session.invalidateAndCancel() }
    }

    private func finishStream(_ id: UUID) {
        let invalidate = lifecycle.withLock { state in
            state.activeStreams.removeValue(forKey: id)
            return state.closed && state.starting.isEmpty && state.activeStreams.isEmpty && state.warmups.isEmpty
        }
        if invalidate { session.invalidateAndCancel() }
    }

    private func finishWarmup(_ id: UUID) {
        let invalidate = lifecycle.withLock { state in
            state.warmups.removeValue(forKey: id)
            return state.closed && state.starting.isEmpty && state.activeStreams.isEmpty && state.warmups.isEmpty
        }
        if invalidate { session.invalidateAndCancel() }
    }

    /// Establishes a warm DNS/TCP/TLS keep-alive socket to `url`'s bare origin without
    /// sending credentials, query parameters, custom headers, or following redirects.
    func warmOrigin(_ url: URL) async {
        guard !Task.isCancelled,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let originRoot = components.url,
              LiveTVPlaylistSource.isSupportedURL(originRoot) else { return }
        var request = URLRequest(url: originRoot)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let id = UUID()
        let noRedirects = IPTVNoRedirectDelegate()
        let task: Task<Void, Never>? = lifecycle.withLock { state in
            guard !state.closed else { return nil }
            let task = Task<Void, Never> { [session] in
                guard !Task.isCancelled else { return }
                _ = try? await session.data(for: request, delegate: noRedirects)
            }
            state.warmups[id] = task
            return task
        }
        guard let task else { return }
        defer { finishWarmup(id) }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Streams raw `Data` chunks directly from `URLSessionDataDelegate` with bounded backpressure,
    /// avoiding per-byte `URLSession.AsyncBytes` iterator overhead on multi-Mbps live transport streams.
    func chunks(
        url: URL, headers: [String: String], method: String = "GET",
        timeout: TimeInterval? = nil,
        receivedResponse: (@Sendable (HTTPURLResponse) -> Void)? = nil
    ) async throws -> (IPTVHTTPChunkStream, HTTPURLResponse) {
        try Task.checkCancellation()
        guard LiveTVPlaylistSource.isSupportedURL(url) else { throw IPTVError.invalidAddress }
        try IPTVCredential.validate(headers: headers)
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let diagnostic = IPTVSetupDiagnostics.current
        diagnostic?.willRequest()
        let id = UUID()
        let delegate = IPTVChunkStreamDelegate(
            sensitiveValues: redirects.sensitiveValues,
            scope: redirects.scope,
            method: method,
            receivedResponse: { response in
                diagnostic?.received(status: response.statusCode, response: .init(mimeType: response.mimeType))
                receivedResponse?(response)
            },
            onFinish: { [weak self] in self?.finishStream(id) }
        )
        let stream = IPTVHTTPChunkStream(delegate: delegate)
        let dataTask: URLSessionDataTask = try lifecycle.withLock { state in
            guard !state.closed else { throw CancellationError() }
            Self.performanceMetrics?.requested()
            let task = session.dataTask(with: request)
            task.delegate = delegate
            delegate.attach(task: task, stream: stream)
            state.activeStreams[id] = stream
            return task
        }
        return try await withTaskCancellationHandler {
            let response = try await delegate.awaitResponse(starting: dataTask)
            if Task.isCancelled {
                stream.cancel()
                throw CancellationError()
            }
            return (stream, response)
        } onCancel: {
            stream.cancel()
        }
    }

    func bytes(
        url: URL, headers: [String: String], method: String = "GET",
        timeout: TimeInterval? = nil,
        guideRequest: Bool = false,
        guideCache: XMLTVGuideCacheMetadata? = nil,
        receivedResponse: (@Sendable (HTTPURLResponse) -> Void)? = nil
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        try Task.checkCancellation()
        guard LiveTVPlaylistSource.isSupportedURL(url) else { throw IPTVError.invalidAddress }
        try IPTVCredential.validate(headers: headers)
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let guideCache { request = guideCache.applying(to: request) }
        let diagnostic = IPTVSetupDiagnostics.current
        diagnostic?.willRequest()
        let guideDiagnostic = IPTVGuideDiagnostics.request
        guideDiagnostic?.requesting()
        let guideDelegate = guideRequest ? IPTVRedirects(
            sensitiveValues: redirects.sensitiveValues, scope: .guide, diagnostic: guideDiagnostic,
            guideCache: guideCache
        ) : nil
        let id = UUID()
        // URLSession.bytes creates its native task asynchronously. Fence that
        // entire startup, not just a cancellation check before calling it.
        let task = try lifecycle.withLock { state in
            guard !state.closed else { throw CancellationError() }
            let task = RequestTask { [session, request, guideDelegate] in
                try Task.checkCancellation()
                Self.performanceMetrics?.requested()
                let result = try await session.bytes(for: request, delegate: guideDelegate)
                if Task.isCancelled {
                    result.0.task.cancel()
                    throw CancellationError()
                }
                return result
            }
            state.starting[id] = task
            return task
        }
        defer { finishStarting(id) }
        let (bytes, response) = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        if Task.isCancelled {
            bytes.task.cancel()
            throw CancellationError()
        }
        guard let response = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw IPTVError.malformed
        }
        diagnostic?.received(status: response.statusCode, response: .init(mimeType: response.mimeType))
        guideDiagnostic?.received(response)
        receivedResponse?(response)
        if response.statusCode == 304, guideRequest, let guideCache,
           guideCache.permitsPersistence, guideCache.hasValidator, guideCache.responseURL == response.url {
            return (bytes, response)
        }
        guard (200...299).contains(response.statusCode) else {
            defer { bytes.task.cancel() }
            if redirects.scope == .playback, method == "GET", response.statusCode == 503,
               response.mimeType?.lowercased() == "application/json",
               try await Self.isConnectionLimit(bytes: bytes, response: response) {
                throw AppError.conflict
            }
            if response.statusCode == 401 || response.statusCode == 403 { throw IPTVError.authentication }
            if (300...399).contains(response.statusCode) { throw LiveTVSourceImportError.redirectBlocked }
            if response.statusCode == 404 { throw AppError.notFound }
            if response.statusCode == 405 || response.statusCode == 501 { throw IPTVError.unsupported }
            if response.statusCode == 429 || (response.statusCode == 509 && redirects.scope == .playback) {
                throw AppError.rateLimited(retryAfter: HTTPDate.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
            }
            throw IPTVError.httpStatus(response.statusCode)
        }
        return (bytes, response)
    }

    private static func isConnectionLimit(bytes: URLSession.AsyncBytes, response: HTTPURLResponse) async throws -> Bool {
        guard response.expectedContentLength <= 4_096 else { return false }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    var data = Data()
                    do {
                        for try await byte in bytes {
                            guard data.count < 4_096 else { return false }
                            data.append(byte)
                        }
                    } catch {
                        try Task.checkCancellation()
                        // The known HTTP refusal remains authoritative if its optional body is unavailable.
                        return false
                    }
                    struct Refusal: Decodable { let error: String }
                    do {
                        let refusal = try JSONDecoder().decode(Refusal.self, from: data)
                        return refusal.error.localizedCaseInsensitiveContains("maximum connection limits")
                    } catch is DecodingError {
                        return false
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(1))
                    return false
                }
                defer { group.cancelAll(); bytes.task.cancel() }
                let limited = try await group.next() ?? false
                try Task.checkCancellation()
                return limited
            }
        } onCancel: {
            bytes.task.cancel()
        }
    }
}

/// One aggregate per import or guide batch, never a record per channel or byte.
final class IPTVPerformanceMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    private var items = 0
    private var bytes = 0

    func requested() {
        lock.withLock { requests += 1 }
    }

    func record(items: Int = 0, bytes: Int = 0) {
        lock.withLock {
            self.items += items
            self.bytes += bytes
        }
    }

    var snapshot: PerformanceDiagnostics.Metrics {
        lock.withLock { .init(items: items, bytes: bytes, requests: requests) }
    }

    static func outcome(for error: any Error) -> PerformanceDiagnostics.Outcome {
        let errorCode = error as NSError
        return error is CancellationError || error as? LiveTVSourceImportError == .cancelled
            || (errorCode.domain == NSURLErrorDomain && errorCode.code == NSURLErrorCancelled)
            ? .cancelled : .failed
    }
}

private final class IPTVNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private final class IPTVRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    let sensitiveValues: [String]
    let scope: IPTVRedirectPolicy.Scope
    let diagnostic: IPTVGuideDiagnostics.Request?
    let guideCache: XMLTVGuideCacheMetadata?

    init(
        sensitiveValues: [String], scope: IPTVRedirectPolicy.Scope,
        diagnostic: IPTVGuideDiagnostics.Request? = nil, guideCache: XMLTVGuideCacheMetadata? = nil
    ) {
        self.sensitiveValues = sensitiveValues
        self.scope = scope
        self.diagnostic = diagnostic
        self.guideCache = guideCache
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let redirected = IPTVRedirectPolicy.request(
            request, previous: response.url, original: task.originalRequest, sensitiveValues: sensitiveValues,
            scope: scope, diagnostic: diagnostic
        )
        completionHandler(redirected.map { guideCache?.applying(to: $0) ?? $0 })
    }
}

/// Chunked upstream HTTP body reader backed by `URLSessionDataDelegate` with bounded backpressure.
final class IPTVHTTPChunkStream: Sendable {
    private let delegate: IPTVChunkStreamDelegate

    fileprivate init(delegate: IPTVChunkStreamDelegate) {
        self.delegate = delegate
    }

    func nextChunk() async throws -> Data? {
        try await delegate.nextChunk()
    }

    func cancel() {
        delegate.cancel()
    }
}

private final class IPTVChunkStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let highWaterBytes = 2 * 1024 * 1024
    private static let lowWaterBytes = 512 * 1024

    private struct State {
        weak var task: URLSessionDataTask?
        var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?
        var responseOutcome: Result<HTTPURLResponse, Error>?
        var checking503Limit = false
        var errorBody = Data()
        var error503Timer: Task<Void, Never>?
        var chunks: [Data] = []
        var headIndex = 0
        var queuedBytes = 0
        var isSuspended = false
        var completed = false
        var completionError: Error?
        var chunkContinuation: CheckedContinuation<Data?, Error>?
        var cancelled = false
        var onFinish: (@Sendable () -> Void)?
    }

    private let sensitiveValues: [String]
    private let scope: IPTVRedirectPolicy.Scope
    private let method: String
    private let receivedResponse: (@Sendable (HTTPURLResponse) -> Void)?
    private let state: OSAllocatedUnfairLock<State>

    init(
        sensitiveValues: [String],
        scope: IPTVRedirectPolicy.Scope,
        method: String,
        receivedResponse: (@Sendable (HTTPURLResponse) -> Void)?,
        onFinish: @escaping @Sendable () -> Void
    ) {
        self.sensitiveValues = sensitiveValues
        self.scope = scope
        self.method = method
        self.receivedResponse = receivedResponse
        var initial = State()
        initial.onFinish = onFinish
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    func attach(task: URLSessionDataTask, stream _: IPTVHTTPChunkStream) {
        state.withLock { $0.task = task }
    }

    func awaitResponse(starting task: URLSessionDataTask) async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { continuation in
            let immediate: Result<HTTPURLResponse, Error>? = state.withLock { s in
                if s.cancelled { return .failure(CancellationError()) }
                if let outcome = s.responseOutcome { return outcome }
                s.responseContinuation = continuation
                return nil
            }
            if let immediate {
                continuation.resume(with: immediate)
            } else {
                task.resume()
            }
        }
    }

    func nextChunk() async throws -> Data? {
        try await withTaskCancellationHandler {
            enum Pop {
                case chunk(Data, URLSessionDataTask?)
                case eof
                case failure(Error)
                case wait
            }
            let fast: Pop = state.withLock { s in
                if s.cancelled { return .failure(CancellationError()) }
                if s.headIndex < s.chunks.count {
                    let data = s.chunks[s.headIndex]
                    s.chunks[s.headIndex] = Data()
                    s.headIndex += 1
                    if s.headIndex > 32 && s.headIndex * 2 >= s.chunks.count {
                        s.chunks.removeFirst(s.headIndex)
                        s.headIndex = 0
                    }
                    s.queuedBytes -= data.count
                    var toResume: URLSessionDataTask?
                    if s.isSuspended && s.queuedBytes <= Self.lowWaterBytes {
                        s.isSuspended = false
                        toResume = s.task
                    }
                    return .chunk(data, toResume)
                }
                if s.completed {
                    return s.completionError.map(Pop.failure) ?? .eof
                }
                return .wait
            }
            switch fast {
            case .chunk(let data, let toResume):
                toResume?.resume()
                return data
            case .eof:
                return nil
            case .failure(let error):
                throw error
            case .wait:
                break
            }
            return try await withCheckedThrowingContinuation { continuation in
                enum WaitPop {
                    case chunk(Data, URLSessionDataTask?)
                    case eof
                    case failure(Error)
                    case parked
                }
                let result: WaitPop = state.withLock { s in
                    if s.cancelled { return .failure(CancellationError()) }
                    if s.headIndex < s.chunks.count {
                        let data = s.chunks[s.headIndex]
                        s.chunks[s.headIndex] = Data()
                        s.headIndex += 1
                        if s.headIndex > 32 && s.headIndex * 2 >= s.chunks.count {
                            s.chunks.removeFirst(s.headIndex)
                            s.headIndex = 0
                        }
                        s.queuedBytes -= data.count
                        var toResume: URLSessionDataTask?
                        if s.isSuspended && s.queuedBytes <= Self.lowWaterBytes {
                            s.isSuspended = false
                            toResume = s.task
                        }
                        return .chunk(data, toResume)
                    }
                    if s.completed {
                        return s.completionError.map(WaitPop.failure) ?? .eof
                    }
                    s.chunkContinuation = continuation
                    return .parked
                }
                switch result {
                case .chunk(let data, let toResume):
                    toResume?.resume()
                    continuation.resume(returning: data)
                case .eof:
                    continuation.resume(returning: nil)
                case .failure(let error):
                    continuation.resume(throwing: error)
                case .parked:
                    break
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        let cleanup = state.withLock { s -> (
            URLSessionDataTask?, Bool, Task<Void, Never>?,
            CheckedContinuation<HTTPURLResponse, Error>?,
            CheckedContinuation<Data?, Error>?,
            (@Sendable () -> Void)?
        ) in
            guard !s.cancelled else { return (nil, false, nil, nil, nil, nil) }
            s.cancelled = true
            s.completed = true
            s.chunks.removeAll()
            s.headIndex = 0
            s.queuedBytes = 0
            let task = s.task
            let wasSuspended = s.isSuspended
            s.isSuspended = false
            let timer = s.error503Timer
            s.error503Timer = nil
            let respCont = s.responseContinuation
            s.responseContinuation = nil
            let chunkCont = s.chunkContinuation
            s.chunkContinuation = nil
            let finish = s.onFinish
            s.onFinish = nil
            return (task, wasSuspended, timer, respCont, chunkCont, finish)
        }
        cleanup.2?.cancel()
        if cleanup.1 { cleanup.0?.resume() }
        cleanup.0?.cancel()
        cleanup.3?.resume(throwing: CancellationError())
        cleanup.4?.resume(throwing: CancellationError())
        cleanup.5?()
    }

    private func settleResponse(_ outcome: Result<HTTPURLResponse, Error>) {
        let (cont, timer) = state.withLock { s -> (CheckedContinuation<HTTPURLResponse, Error>?, Task<Void, Never>?) in
            guard s.responseOutcome == nil else { return (nil, nil) }
            s.responseOutcome = outcome
            s.checking503Limit = false
            let timer = s.error503Timer
            s.error503Timer = nil
            let c = s.responseContinuation
            s.responseContinuation = nil
            return (c, timer)
        }
        timer?.cancel()
        cont?.resume(with: outcome)
    }

    private static func mapStatusError(_ response: HTTPURLResponse, scope: IPTVRedirectPolicy.Scope) -> Error {
        if response.statusCode == 401 || response.statusCode == 403 { return IPTVError.authentication }
        if (300...399).contains(response.statusCode) { return LiveTVSourceImportError.redirectBlocked }
        if response.statusCode == 404 { return AppError.notFound }
        if response.statusCode == 405 || response.statusCode == 501 { return IPTVError.unsupported }
        if response.statusCode == 429 || (response.statusCode == 509 && scope == .playback) {
            return AppError.rateLimited(retryAfter: HTTPDate.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        }
        return IPTVError.httpStatus(response.statusCode)
    }

    private static func isConnectionLimitJSON(_ data: Data) -> Bool {
        struct Refusal: Decodable { let error: String }
        guard let refusal = try? JSONDecoder().decode(Refusal.self, from: data) else { return false }
        return refusal.error.localizedCaseInsensitiveContains("maximum connection limits")
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let redirected = IPTVRedirectPolicy.request(
            request, previous: response.url, original: task.originalRequest,
            sensitiveValues: sensitiveValues, scope: scope
        )
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            settleResponse(.failure(IPTVError.malformed))
            return
        }
        receivedResponse?(http)
        if (200...299).contains(http.statusCode) {
            completionHandler(.allow)
            settleResponse(.success(http))
            return
        }
        if scope == .playback, method == "GET", http.statusCode == 503,
           http.mimeType?.lowercased() == "application/json",
           http.expectedContentLength <= 4_096 {
            let timer = Task { [weak self, weak dataTask] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                dataTask?.cancel()
                self.settleResponse(.failure(IPTVError.httpStatus(503)))
            }
            let allow = state.withLock { s -> Bool in
                guard !s.cancelled else { return false }
                s.checking503Limit = true
                s.error503Timer = timer
                return true
            }
            if allow {
                completionHandler(.allow)
            } else {
                timer.cancel()
                completionHandler(.cancel)
            }
            return
        }
        completionHandler(.cancel)
        settleResponse(.failure(Self.mapStatusError(http, scope: scope)))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        enum Action {
            case ignore
            case overflow503
            case deliver(CheckedContinuation<Data?, Error>, Data)
            case suspend
            case buffered
        }
        let action: Action = state.withLock { s in
            guard !s.cancelled else { return .ignore }
            if s.checking503Limit {
                if s.errorBody.count + data.count > 4_096 {
                    s.checking503Limit = false
                    return .overflow503
                }
                s.errorBody.append(data)
                return .ignore
            }
            if let cont = s.chunkContinuation {
                s.chunkContinuation = nil
                return .deliver(cont, data)
            }
            s.chunks.append(data)
            s.queuedBytes += data.count
            if s.queuedBytes >= Self.highWaterBytes && !s.isSuspended {
                s.isSuspended = true
                return .suspend
            }
            return .buffered
        }
        switch action {
        case .ignore, .buffered:
            break
        case .overflow503:
            dataTask.cancel()
            settleResponse(.failure(IPTVError.httpStatus(503)))
        case .deliver(let cont, let chunk):
            cont.resume(returning: chunk)
        case .suspend:
            dataTask.suspend()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (was503, body503, chunkCont, finish) = state.withLock { s -> (
            Bool, Data, CheckedContinuation<Data?, Error>?, (@Sendable () -> Void)?
        ) in
            let was503 = s.checking503Limit
            let body503 = was503 ? s.errorBody : Data()
            s.checking503Limit = false
            s.completed = true
            if !s.cancelled, let error {
                s.completionError = error
            }
            let c = s.chunkContinuation
            s.chunkContinuation = nil
            let finish = s.onFinish
            s.onFinish = nil
            return (was503, body503, c, finish)
        }
        if was503 {
            let err: Error = Self.isConnectionLimitJSON(body503) ? AppError.conflict : IPTVError.httpStatus(503)
            settleResponse(.failure(err))
        } else if let error {
            settleResponse(.failure(error))
        } else {
            settleResponse(.failure(IPTVError.malformed))
        }
        if let chunkCont {
            if let error {
                chunkCont.resume(throwing: error)
            } else {
                chunkCont.resume(returning: nil)
            }
        }
        finish?()
    }
}

enum IPTVRedirectPolicy {
    enum Scope: Sendable { case account, playback, guide }

    static func request(
        _ request: URLRequest, previous: URL?, original: URLRequest?, sensitiveValues: [String] = [],
        scope: Scope = .account, diagnostic: IPTVGuideDiagnostics.Request? = nil
    ) -> URLRequest? {
        diagnostic?.redirected()
        guard let next = request.url, let previous,
              LiveTVPlaylistSource.isSupportedURL(next) else {
            diagnostic?.blockedRedirect(.invalidDestination)
            return nil
        }
        guard scope == .playback
            || !(previous.scheme?.lowercased() == "https" && next.scheme?.lowercased() != "https") else {
            diagnostic?.blockedRedirect(.downgrade)
            return nil
        }
        if IPTVCredential.sameOrigin(previous, next),
           IPTVCredential.sameOrigin(original?.url ?? previous, next) {
            return request
        }
        // Providers route media through changing delivery servers, sometimes
        // over HTTP with credentials in the URL. This grant is playback-only;
        // account requests retain their strict origin and downgrade checks.
        let secrets = sensitiveValues + protectedValues(
            url: original?.url ?? previous, headers: original?.allHTTPHeaderFields ?? [:]
        )
        let destination = next.absoluteString.removingPercentEncoding ?? next.absoluteString
        let source = original?.url ?? previous
        let secureGuideUpgrade = scope == .guide
            && source.scheme?.lowercased() == "http" && (source.port ?? 80) == 80
            && next.scheme?.lowercased() == "https" && (next.port ?? 443) == 443
            && source.host?.lowercased() == next.host?.lowercased()
            && (IPTVCredential.sameOrigin(source, previous) || IPTVCredential.sameOrigin(previous, next))
        // A standard-port HTTPS upgrade on the same host can retain URL credentials.
        // It still strips headers, and never authorizes another host or a downgrade.
        guard scope == .playback || secureGuideUpgrade
            || !secrets.contains(where: { !$0.isEmpty && destination.contains($0) }) else {
            diagnostic?.blockedRedirect(.credentials)
            return nil
        }
        var clean = URLRequest(url: next)
        clean.timeoutInterval = request.timeoutInterval
        clean.httpMethod = request.httpMethod
        clean.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for header in ["Range", "If-Range"] {
            clean.setValue(request.value(forHTTPHeaderField: header), forHTTPHeaderField: header)
        }
        return clean
    }

    static func protectedValues(url: URL, headers: [String: String]) -> [String] {
        var secrets = (URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.filter { SensitiveQueryPolicy.isSensitive($0.name) }.compactMap(\.value) ?? []
        )
        for (name, value) in headers {
            if name.lowercased() == "authorization", value.lowercased().hasPrefix("bearer ") {
                secrets.append(String(value.dropFirst(7)))
            } else if name.lowercased() == "authorization", value.lowercased().hasPrefix("basic "),
                      let bytes = Data(base64Encoded: String(value.dropFirst(6))),
                      let pair = String(data: bytes, encoding: .utf8), let colon = pair.firstIndex(of: ":") {
                secrets.append(String(pair[pair.index(after: colon)...]))
            } else if name.lowercased() == "cookie" {
                secrets += value.split(separator: ";").compactMap { field in
                    guard let equals = field.firstIndex(of: "=") else { return nil }
                    return field[field.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                }
            } else if !["accept", "accept-encoding", "user-agent", "range", "if-range"].contains(name.lowercased()) {
                secrets.append(value)
            }
        }
        return secrets.filter { !$0.isEmpty }
    }
}

enum IPTVValue: Decodable, Sendable {
    case text(String), number(Double), boolean(Bool), object([String: IPTVValue]), array([IPTVValue]), null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let text = try? value.decode(String.self) { self = .text(text) }
        else if let flag = try? value.decode(Bool.self) { self = .boolean(flag) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let array = try? value.decode([IPTVValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: IPTVValue].self)) }
    }

    var text: String? {
        switch self {
        case .text(let value): value
        case .number(let value) where value.isFinite:
            value.rounded() == value && abs(value) < Double(Int64.max) ? String(Int64(value)) : String(value)
        case .boolean(let value): value ? "1" : "0"
        default: nil
        }
    }
    var object: [String: IPTVValue] { if case .object(let value) = self { value } else { [:] } }
    var array: [IPTVValue] { if case .array(let value) = self { value } else { [] } }
}

typealias IPTVObject = [String: IPTVValue]

extension IPTVObject {
    func text(_ key: String) -> String? { self[key]?.text.flatMap { $0.isEmpty ? nil : $0 } }
    func number(_ key: String) -> Double? { text(key).flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } }
    func integer(_ key: String) -> Int? { text(key).flatMap(Int.init) }
    func object(_ key: String) -> IPTVObject { self[key]?.object ?? [:] }
    func array(_ key: String) -> [IPTVValue] { self[key]?.array ?? [] }
}
