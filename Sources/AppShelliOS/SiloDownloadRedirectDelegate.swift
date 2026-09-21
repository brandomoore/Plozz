#if os(iOS)
import Foundation
import CoreModels

final class SiloDownloadRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: URL
    init(origin: URL) { self.origin = origin }

    static func sameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs, lhs.user == nil, lhs.password == nil,
              rhs.user == nil, rhs.password == nil,
              let leftScheme = lhs.scheme, let leftHost = lhs.host,
              let rightScheme = rhs.scheme, let rightHost = rhs.host,
              let left = try? NetworkOrigin(scheme: leftScheme, host: leftHost, port: lhs.port),
              let right = try? NetworkOrigin(scheme: rightScheme, host: rightHost, port: rhs.port) else { return false }
        return left == right
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.sameOrigin(origin, request.url) ? request : nil)
    }
}
#endif
