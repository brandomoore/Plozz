import Foundation

/// Bounded, uncached subtitle delivery. Credentials belong only to the resolved request.
public struct SubtitleFileLoader: Sendable {
    private let session: URLSession
    private let requestTimeout: TimeInterval

    public init(allowsExtractionDelay: Bool = false) {
        self.init(
            session: allowsExtractionDelay ? Self.extractionSession : Self.subtitleSession,
            allowsExtractionDelay: allowsExtractionDelay
        )
    }

    init(session: URLSession, allowsExtractionDelay: Bool = false) {
        self.session = session
        requestTimeout = allowsExtractionDelay ? 120 : 30
    }

    public func load(
        _ url: URL, maximumBytes: Int, allowsCellular: Bool, allowsConstrained: Bool,
        onChunk: @escaping @Sendable (Int) async throws -> Void = { _ in }
    ) async throws -> Data {
        try Task.checkCancellation()
        if url.isFileURL {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= maximumBytes else {
                throw CocoaError(.fileReadTooLarge)
            }
            return try Data(contentsOf: url)
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw URLError(.unsupportedURL)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        request.allowsCellularAccess = allowsCellular
        request.allowsExpensiveNetworkAccess = allowsCellular
        request.allowsConstrainedNetworkAccess = allowsConstrained
        request.httpShouldHandleCookies = false
        let (bytes, response) = try await session.bytes(for: request, delegate: SubtitleRequestDelegate())
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard response.expectedContentLength <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
            if data.count.isMultiple(of: 65_536) {
                try Task.checkCancellation()
                try await onChunk(65_536)
            }
        }
        try await onChunk(data.count % 65_536)
        try Task.checkCancellation()
        return data
    }

    private static let subtitleSession = makeSession(resourceTimeout: 60)
    private static let extractionSession = makeSession(resourceTimeout: 120)

    private static func makeSession(resourceTimeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = resourceTimeout
        return OfflineNetworkSession.make(configuration: configuration)
    }
}

private final class SubtitleRequestDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Never forward a token-bearing server subtitle URL to another location.
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
