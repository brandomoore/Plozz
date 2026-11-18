import Foundation

/// Optional website artwork never uses the media session's credentials or cookies.
public struct ProviderIconLoader: Sendable {
    public static let maximumBytes = 256 * 1_024
    private let session: URLSession

    public init() { session = Self.iconSession }
    init(session: URLSession) { self.session = session }

    public static func iconURL(for source: URL) -> URL? {
        guard let source = URLComponents(url: source, resolvingAgainstBaseURL: false),
              let scheme = source.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = source.host, !host.isEmpty else { return nil }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = source.port
        origin.path = "/favicon.ico"
        return origin.url
    }

    public func load(from source: URL) async throws -> Data {
        guard let url = Self.iconURL(for: source) else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let (bytes, response) = try await session.bytes(for: request, delegate: IconRequestDelegate())
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard response.expectedContentLength <= Self.maximumBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < Self.maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }

    private static let iconSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.urlCache = URLCache(memoryCapacity: 4 * 1_024 * 1_024, diskCapacity: 0)
        return OfflineNetworkSession.make(configuration: configuration)
    }()
}

private final class IconRequestDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
