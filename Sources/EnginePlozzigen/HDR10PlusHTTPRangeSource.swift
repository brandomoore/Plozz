import Foundation

protocol HDR10PlusRangeSource: AnyObject, Sendable {
    var size: Int64? { get }
    func read(at offset: Int64, count: Int) -> Data?
    func close()
}

/// Synchronous only at the AVIO boundary; URLSession delegate callbacks run on
/// their own queue. Never use data(for:) here: a server ignoring Range could
/// otherwise buffer an entire movie before the response is inspected.
final class HDR10PlusHTTPRangeSource: NSObject, HDR10PlusRangeSource, URLSessionDataDelegate,
    @unchecked Sendable {
    private let url: URL
    private let budget: HDR10PlusProbeBudget
    private let condition = NSCondition()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var closed = false
    private var completed = false
    private var accepted = false
    private var failed = false
    private var start: Int64 = 0
    private var requestedCount = 0
    private var expectedCount = 0
    private var redirects = 0
    private var bytes = Data()
    private var knownSize: Int64?

    init(
        url: URL,
        budget: HDR10PlusProbeBudget,
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        self.url = url
        self.budget = budget
        super.init()
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = budget.limits.requestTimeout
        configuration.timeoutIntervalForResource = budget.limits.wallTimeout
        configuration.httpMaximumConnectionsPerHost = 1
        let callbacks = OperationQueue()
        callbacks.maxConcurrentOperationCount = 1
        callbacks.qualityOfService = .utility
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: callbacks)
        budget.onCancellation { [weak self] in self?.close() }
    }

    var size: Int64? {
        condition.lock()
        defer { condition.unlock() }
        return knownSize
    }

    func read(at offset: Int64, count: Int) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        guard !closed, task == nil, budget.isActive, offset >= 0, count > 0,
              Self.isHTTPURL(url), let session
        else { return nil }
        if let knownSize, offset >= knownSize { return Data() }
        let remaining = knownSize.map { Int(min(Int64(count), $0 - offset)) } ?? count
        let allowed = budget.reserve(upTo: min(remaining, budget.limits.rangeBytes))
        guard allowed > 0, offset <= Int64.max - Int64(allowed) else { return nil }

        start = offset
        requestedCount = allowed
        expectedCount = 0
        redirects = 0
        bytes.removeAll(keepingCapacity: true)
        accepted = false
        failed = false
        completed = false
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = min(budget.remainingTime, budget.limits.requestTimeout)
        request.setValue("bytes=\(offset)-\(offset + Int64(allowed) - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let current = session.dataTask(with: request)
        task = current
        current.resume()

        let deadline = ProcessInfo.processInfo.systemUptime
            + min(budget.remainingTime, budget.limits.requestTimeout)
        while !completed, !closed, budget.isActive {
            let left = min(deadline - ProcessInfo.processInfo.systemUptime, budget.remainingTime)
            guard left > 0 else { break }
            _ = condition.wait(until: Date(timeIntervalSinceNow: min(left, 0.05)))
        }
        let result: Data?
        if completed, !closed, !failed, accepted, bytes.count == expectedCount, budget.isActive {
            result = bytes
        } else {
            result = nil
            // One failed request ends this source; an old callback cannot
            // become the response for a later AVIO request.
            failed = true
            current.cancel()
        }
        task = nil
        bytes.removeAll(keepingCapacity: false)
        if result == nil {
            closed = true
            session.invalidateAndCancel()
            self.session = nil
        }
        return result
    }

    func close() {
        condition.lock()
        closed = true
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        bytes.removeAll(keepingCapacity: false)
        condition.broadcast()
        condition.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        condition.lock()
        let range: (count: Int, size: Int64)?
        if !closed, task === dataTask, budget.isActive,
           let response = response as? HTTPURLResponse,
           let responseURL = response.url, Self.sameOrigin(url, responseURL) {
            range = Self.validatedRange(response, start: start, count: requestedCount, size: knownSize)
        } else {
            range = nil
        }
        if let range {
            accepted = true
            expectedCount = range.count
            knownSize = range.size
        } else {
            failed = true
            completed = true
            condition.broadcast()
        }
        condition.unlock()
        // Reject 200/redirect errors at the header boundary, before body delivery.
        completionHandler(range == nil ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        condition.lock()
        guard !closed, task === dataTask, accepted, !failed, budget.isActive,
              data.count <= expectedCount - bytes.count
        else {
            failed = true
            completed = true
            condition.broadcast()
            condition.unlock()
            dataTask.cancel()
            return
        }
        bytes.append(data)
        condition.unlock()
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        condition.lock()
        if self.task === task {
            failed = failed || error != nil
            completed = true
            condition.broadcast()
        }
        condition.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        condition.lock()
        let follow = !closed && self.task === task && budget.isActive && redirects < 3
            && request.url.map { Self.sameOrigin(url, $0) } == true
        var redirected: URLRequest?
        if follow {
            redirects += 1
            // Retain only this probe's headers. No cookies, shared credentials,
            // Referer or arbitrary redirect-supplied headers are forwarded.
            var safe = URLRequest(url: request.url!)
            safe.cachePolicy = .reloadIgnoringLocalCacheData
            safe.timeoutInterval = min(budget.remainingTime, budget.limits.requestTimeout)
            safe.setValue("bytes=\(start)-\(start + Int64(requestedCount) - 1)", forHTTPHeaderField: "Range")
            safe.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            redirected = safe
        } else {
            failed = true
            completed = true
            condition.broadcast()
        }
        condition.unlock()
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                ? .performDefaultHandling : .cancelAuthenticationChallenge,
            nil
        )
    }

    static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        guard isHTTPURL(first), isHTTPURL(second) else { return false }
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return first.scheme?.lowercased() == second.scheme?.lowercased()
            && first.host?.lowercased() == second.host?.lowercased()
            && port(first) == port(second)
    }

    private static func isHTTPURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && url.host != nil && url.user == nil && url.password == nil
    }

    static func validatedRange(
        _ response: HTTPURLResponse, start: Int64, count: Int, size: Int64?
    ) -> (count: Int, size: Int64)? {
        guard response.statusCode == 206, start >= 0, count > 0,
              response.value(forHTTPHeaderField: "Content-Encoding").map({
                  $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "identity"
              }) ?? true,
              let header = response.value(forHTTPHeaderField: "Content-Range"),
              header.hasPrefix("bytes ")
        else { return nil }
        let parts = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let total = Int64(parts[1]), total > 0 else { return nil }
        let endpoints = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard endpoints.count == 2,
              let lower = Int64(endpoints[0]), let upper = Int64(endpoints[1]),
              lower == start, upper >= lower, upper < total,
              upper - lower < Int64(count), size == nil || size == total
        else { return nil }
        let length = upper - lower + 1
        guard response.expectedContentLength < 0 || response.expectedContentLength == length else { return nil }
        return (Int(length), total)
    }
}
