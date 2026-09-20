import Foundation
@testable import MetadataKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor TMDbTVDBDiscoveryFixture {
    struct Reply: Sendable {
        var json: String
        var status: Int = 200
        var headers: [String: String] = [:]
    }

    private var requests: [URLRequest] = []
    private let reply: @Sendable (URLRequest, Int) throws -> Reply

    init(reply: @escaping @Sendable (URLRequest, Int) throws -> Reply) {
        self.reply = reply
    }

    nonisolated var http: MetadataDiscoveryHTTPClient {
        MetadataDiscoveryHTTPClient(send: { try await self.send($0) })
    }

    func recorded() -> [URLRequest] { requests }

    private func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let response = try reply(request, requests.count)
        return (
            Data(response.json.utf8),
            HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil,
                            headerFields: response.headers)!
        )
    }

    static func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.reduce(into: [:]) { $0[$1.name] = $1.value }
    }

    static func tvdbReply(_ request: URLRequest) -> Reply {
        switch request.url!.lastPathComponent {
        case "login":
            return Reply(json: #"{"status":"success","data":{"token":"fixture-jwt"}}"#)
        case "countries":
            return Reply(json: #"{"data":[{"id":"usa","shortCode":"US"},{"id":"can","shortCode":"CA"},{"id":"fra","shortCode":"FR"},{"id":"jpn","shortCode":"JP"}]}"#)
        case "languages":
            return Reply(json: #"{"data":[{"id":"eng","shortCode":"en"},{"id":"fra","shortCode":"fr"},{"id":"jpn","shortCode":"ja"}]}"#)
        default:
            return Reply(json: #"{"status":"success","data":[]}"#)
        }
    }
}
