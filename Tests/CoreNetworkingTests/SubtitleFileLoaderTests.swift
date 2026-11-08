import Foundation
import XCTest
@testable import CoreNetworking

final class SubtitleFileLoaderTests: XCTestCase {
    func testBoundedHTTPDeliveryRejectsFailedAndOversizedResponses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubtitleFileProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let loader = SubtitleFileLoader(session: session)
        for (host, code) in [
            ("missing.invalid", URLError.Code.badServerResponse),
            ("declared-large.invalid", .dataLengthExceedsMaximum),
            ("streamed-large.invalid", .dataLengthExceedsMaximum)
        ] {
            do {
                _ = try await loader.load(
                    XCTUnwrap(URL(string: "https://\(host)/subtitle.srt")), maximumBytes: 16,
                    allowsCellular: false, allowsConstrained: false
                )
                XCTFail("Must reject \(host)")
            } catch let error as URLError { XCTAssertEqual(error.code, code) }
        }
        let data = try await loader.load(
            XCTUnwrap(URL(string: "https://valid.invalid/subtitle.srt")), maximumBytes: 16,
            allowsCellular: false, allowsConstrained: false
        )
        XCTAssertEqual(data, Data("subtitle".utf8))
    }

    func testLocalFileSizeLimitAndCancellation() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-\(UUID()).srt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 65, count: 32).write(to: file)
        let loader = SubtitleFileLoader()
        do {
            _ = try await loader.load(file, maximumBytes: 16, allowsCellular: false, allowsConstrained: false)
            XCTFail("Large local sidecars must be rejected before reading")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileReadTooLarge) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await loader.load(file, maximumBytes: 64, allowsCellular: false, allowsConstrained: false)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled sidecar load must throw")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}

private final class SubtitleFileProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        XCTAssertFalse(request.allowsCellularAccess)
        XCTAssertFalse(request.httpShouldHandleCookies)
        let data = url.host?.contains("large") == true ? Data(repeating: 65, count: 17) : Data("subtitle".utf8)
        let headers = url.host == "declared-large.invalid" ? ["Content-Length": "17"] : [:]
        guard let response = HTTPURLResponse(url: url, statusCode: url.host == "missing.invalid" ? 404 : 200,
                                            httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
