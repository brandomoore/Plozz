import CoreModels
import CoreNetworking
import Foundation
import os
import XCTest
@testable import ProviderIPTV

final class IPTVGuideCacheTests: XCTestCase {
    private let guide = URL(string: "https://cdn.test/guide.xml")!

    override func tearDown() {
        IPTVFixture.state.reset()
        super.tearDown()
    }

    private func client() throws -> IPTVClient {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let client = try IPTVClient(
            credential: IPTVCredential(
                mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.test/list.m3u")),
                headers: ["X-Playlist-Key": "playlist-only"], guideURL: guide,
                guideHeaders: ["X-Guide-Key": "guide-only"]
            ),
            directory: root, configuration: IPTVFixture.configuration()
        )
        addTeardownBlock { await client.cancel() }
        return client
    }

    func testLargeGuideIsReusedAndHeldBytesSurviveCacheCancellation() async throws {
        let body = Data(repeating: 0x61, count: 17 * 1_024 * 1_024)
        IPTVFixture.state.handler = { _ in (200, ["Cache-Control": "max-age=60"], body) }
        let client = try client()
        let first = try await client.guideData(from: guide)
        let second = try await client.guideData(from: guide)
        XCTAssertEqual(first, body)
        XCTAssertEqual(second, body)
        XCTAssertEqual(IPTVFixture.state.requests.count, 1)
        XCTAssertEqual(IPTVFixture.state.requests[0].value(forHTTPHeaderField: "X-Guide-Key"), "guide-only")
        XCTAssertNil(IPTVFixture.state.requests[0].value(forHTTPHeaderField: "X-Playlist-Key"))
        let retained = await client.cachedGuideByteCount
        XCTAssertEqual(retained, body.count)
        await client.cancel()
        let cleared = await client.cachedGuideByteCount
        XCTAssertEqual(cleared, 0)
        XCTAssertEqual(second, body)
    }

    func testLargeGuideRespectsNoStoreNoCacheAndZeroMaxAge() async throws {
        let body = Data(repeating: 0x62, count: 17 * 1_024 * 1_024)
        for directive in ["no-store", "no-cache", "max-age=0"] {
            IPTVFixture.state.reset()
            IPTVFixture.state.handler = { _ in (200, ["Cache-Control": directive], body) }
            let client = try client()
            for _ in 0..<2 {
                let value = try await client.guideData(from: guide)
                XCTAssertEqual(value, body)
            }
            let retained = await client.cachedGuideByteCount
            XCTAssertEqual(retained, 0)
            XCTAssertEqual(IPTVFixture.state.requests.count, 2)
            await client.cancel()
        }
    }

    func testExpiredCacheReleasesBackingWithoutAnotherRequest() async throws {
        IPTVFixture.state.handler = { _ in (200, ["Cache-Control": "max-age=0.05"], Data("<tv/>".utf8)) }
        let client = try client()
        _ = try await client.guideData(from: guide)
        let deadline = ContinuousClock.now + .seconds(2)
        while await client.cachedGuideByteCount != 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let retained = await client.cachedGuideByteCount
        XCTAssertEqual(retained, 0)
        XCTAssertEqual(IPTVFixture.state.requests.count, 1)
        _ = try await client.guideData(from: guide)
        XCTAssertEqual(IPTVFixture.state.requests.count, 2)
    }

    func testOldExpiryDoesNotClearReplacementAndClientsNeverShareCachedGuides() async throws {
        IPTVFixture.state.handler = { request in
            (200, ["Cache-Control": request.url?.lastPathComponent == "guide.xml" ? "max-age=0.05" : "max-age=60"],
             Data("<tv/>".utf8))
        }
        let first = try client()
        let second = try client()
        _ = try await first.guideData(from: guide)
        let replacement = guide.deletingLastPathComponent().appendingPathComponent("replacement.xml")
        _ = try await first.guideData(from: replacement)
        _ = try await second.guideData(from: replacement)
        try await Task.sleep(for: .milliseconds(100))
        _ = try await first.guideData(from: replacement)
        let retained = await first.cachedGuideByteCount
        XCTAssertEqual(retained, 5)
        XCTAssertEqual(IPTVFixture.state.requests.count, 3)
    }

    func testTransientGuideFailuresRetryButCacheOnlyTheCompleteResponse() async throws {
        for failure in [503, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost] {
            IPTVFixture.state.reset()
            IPTVFixture.state.handler = { _ in
                if IPTVFixture.state.requests.count == 1 {
                    if failure < 0 { throw URLError(URLError.Code(rawValue: failure)) }
                    return (failure, ["Retry-After": "0"], Data())
                }
                return (200, [:], Data("<tv/>".utf8))
            }
            let client = try client()
            let data = try await client.guideData(from: guide)
            XCTAssertEqual(data, Data("<tv/>".utf8))
            _ = try await client.guideData(from: guide)
            XCTAssertEqual(IPTVFixture.state.requests.count, 2)
            await client.cancel()
        }
    }

    func testGuideRetryBudgetAndTerminalFailures() async throws {
        for (status, headers, expectedRequests) in [
            (503, ["Retry-After": "0"], 3),
            (503, ["Retry-After": "120"], 1),
            (429, ["Retry-After": "120"], 1),
            (401, [:], 1), (403, [:], 1), (404, [:], 1), (301, [:], 1),
            (NSURLErrorCancelled, [:], 1), (NSURLErrorServerCertificateUntrusted, [:], 1)
        ] {
            IPTVFixture.state.reset()
            IPTVFixture.state.handler = { _ in
                if status < 0 { throw URLError(URLError.Code(rawValue: status)) }
                return (status, headers, Data())
            }
            let client = try client()
            do {
                _ = try await client.guideData(from: guide)
                XCTFail("Exhausted or terminal failures must remain failures")
            } catch {
                if status < 0 { XCTAssertEqual((error as NSError).code, status) }
                if status == 503 { XCTAssertEqual(error as? IPTVError, .httpStatus(503)) }
                if status == 429 {
                    XCTAssertEqual(error as? AppError, .rateLimited(retryAfter: 120))
                }
            }
            XCTAssertEqual(IPTVFixture.state.requests.count, expectedRequests, "status \(status)")
            let retained = await client.cachedGuideByteCount
            XCTAssertEqual(retained, 0)
            await client.cancel()
        }
    }

    func testCancellationDuringGuideRetryBackoffStopsFurtherRequests() async throws {
        IPTVFixture.state.handler = { _ in (503, ["Retry-After": "10"], Data()) }
        let client = try client()
        let guide = guide
        let task = Task { try await client.guideData(from: guide) }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(2)
        while IPTVFixture.state.requests.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(IPTVFixture.state.requests.count, 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled retries must not succeed")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as NSError).code == NSURLErrorCancelled)
        }
        XCTAssertEqual(IPTVFixture.state.requests.count, 1)
    }

    func testGuideRetryDelayRespectsServerBackoffAndFiniteBudget() {
        XCTAssertEqual(IPTVClient.guideRetryDelay(after: URLError(.timedOut), attempt: 0, retryAfter: nil), 1)
        XCTAssertEqual(IPTVClient.guideRetryDelay(after: URLError(.timedOut), attempt: 1, retryAfter: nil), 2)
        XCTAssertNil(IPTVClient.guideRetryDelay(after: URLError(.timedOut), attempt: 2, retryAfter: nil))
        for delay in [11.0, .infinity, .nan] {
            XCTAssertNil(IPTVClient.guideRetryDelay(after: IPTVError.httpStatus(503), attempt: 0, retryAfter: delay))
        }
        XCTAssertEqual(IPTVClient.guideRetryDelay(after: IPTVError.httpStatus(503), attempt: 0, retryAfter: 8), 8)
    }

    func testInterruptedGuideBodyRetriesTheWholeDownload() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let body = Data(repeating: 0x61, count: 8_192)
        let server = try IPTVTestHTTPServer { _ in
            let first = calls.withLock { $0 += 1; return $0 == 1 }
            return .init(data: body, cutoff: first ? 1_024 : nil)
        }
        let url = try await server.start().appendingPathComponent("guide.xml")
        addTeardownBlock { await server.stop() }
        let client = try client()
        let data = try await client.guideData(from: url)
        XCTAssertEqual(data, body, "Never cache or append a partial first response")
        XCTAssertEqual(calls.withLock { $0 }, 2)
    }

    func testRealGuideRedirectStripsHeadersAndReportsBlockedCredentials() async throws {
        let target = try IPTVTestHTTPServer { request in
            for header in ["authorization:", "cookie:", "x-guide-key:"] {
                XCTAssertFalse(request.lowercased().contains(header))
            }
            return .init(data: Data("<tv/>".utf8))
        }
        let targetURL = try await target.start()
        addTeardownBlock { await target.stop() }
        for copiesSecret in [false, true] {
            let source = try IPTVTestHTTPServer { _ in
                .init(status: 301, headers: [
                    "Location": targetURL.appendingPathComponent(copiesSecret ? "fixture-secret.xml" : "guide.xml").absoluteString
                ])
            }
            let url = try await source.start().appendingPathComponent("guide.xml")
            addTeardownBlock { await source.stop() }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            addTeardownBlock { try FileManager.default.removeItem(at: root) }
            let client = try IPTVClient(
                credential: IPTVCredential(
                    mode: .playlist, address: url, guideURL: url,
                    guideHeaders: ["X-Guide-Key": "fixture-secret"]
                ), directory: root
            )
            addTeardownBlock { await client.cancel() }
            let diagnostic = IPTVGuideDiagnostics.Request()
            let before = await target.requestCount
            do {
                let data = try await IPTVGuideDiagnostics.$request.withValue(diagnostic) {
                    try await client.guideData(from: url)
                }
                XCTAssertFalse(copiesSecret)
                XCTAssertEqual(data, Data("<tv/>".utf8))
            } catch {
                XCTAssertTrue(copiesSecret)
                XCTAssertEqual(error as? LiveTVSourceImportError, .redirectBlocked)
            }
            let after = await target.requestCount
            XCTAssertEqual(after - before, copiesSecret ? 0 : 1)
            let summary = diagnostic.summary(rows: nil, error: nil)
            XCTAssertTrue(summary.contains("redirects=1 redirectBlocked=\(copiesSecret ? "credentials" : "none")"))
        }
    }
}
