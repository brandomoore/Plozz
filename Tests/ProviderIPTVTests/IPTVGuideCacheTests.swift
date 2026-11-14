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

    func testLastModifiedOnlyGuideCanRevalidateWithoutETag() async throws {
        let modified = "Wed, 21 Oct 2015 07:28:00 GMT"
        IPTVFixture.state.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
            if let value = request.value(forHTTPHeaderField: "If-Modified-Since") {
                XCTAssertEqual(value, modified)
                return (304, [:], Data())
            }
            return (200, ["Last-Modified": modified], Data("<tv/>".utf8))
        }
        let client = try client()
        let original = try await client.guideDocument(from: guide)
        let saved = try XCTUnwrap(original.cacheMetadata)
        let result = try await client.guideResponse(from: guide, previous: saved)
        guard case .notModified(let metadata) = result else { return XCTFail("Expected Last-Modified revalidation") }
        XCTAssertEqual(metadata.lastModified, modified)
        XCTAssertNil(metadata.etag)
        XCTAssertEqual(IPTVFixture.state.requests.count, 2)
    }

    func test304NoStoreAlsoRevokesLegacyRawResponse() async throws {
        IPTVFixture.state.handler = { request in
            if request.value(forHTTPHeaderField: "If-None-Match") != nil {
                return (304, ["Cache-Control": "no-store"], Data())
            }
            return (200, ["ETag": "\"v1\""], Data("<tv/>".utf8))
        }
        let client = try client()
        let original = try await client.guideDocument(from: guide, retainsRawResponse: true)
        let before = await client.cachedGuideByteCount
        XCTAssertEqual(before, 5)
        let saved = try XCTUnwrap(original.cacheMetadata)
        let result = try await client.guideResponse(from: guide, previous: saved)
        guard case .notModified(let metadata) = result else { return XCTFail("Expected revalidation") }
        XCTAssertFalse(metadata.permitsPersistence)
        let after = await client.cachedGuideByteCount
        XCTAssertEqual(after, 0)
        _ = try await client.guideData(from: guide)
        XCTAssertEqual(IPTVFixture.state.requests.count, 3)
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

    func testRejectedConditionalRequestsFallBackToOneOrdinaryDownload() async throws {
        for status in [400, 405, 412, 431, 501] {
            IPTVFixture.state.reset()
            IPTVFixture.state.handler = { request in
                if request.value(forHTTPHeaderField: "If-None-Match") != nil {
                    return (status, [:], Data())
                }
                XCTAssertNil(request.value(forHTTPHeaderField: "If-Modified-Since"))
                return (200, ["ETag": "\"v1\"", "Last-Modified": "Wed, 21 Oct 2015 07:28:00 GMT"], Data("<tv/>".utf8))
            }
            let client = try client()
            let first = try await client.guideDocument(from: guide)
            let metadata = try XCTUnwrap(first.cacheMetadata)
            let response = try await client.guideResponse(from: guide, previous: metadata)
            guard case .document(let document) = response else { return XCTFail("Expected full fallback for \(status)") }
            XCTAssertEqual(document.data, first.data)
            XCTAssertEqual(IPTVFixture.state.requests.count, 3, "Seed, conditional request, ordinary fallback")
            await client.cancel()
        }
    }

    func testConditionalFallbackDoesNotBypassAuthorizationMissingFeedsOrRetryAfter() async throws {
        for (status, headers) in [
            (401, [String: String]()), (403, [:]), (404, [:]),
            (429, ["Retry-After": "120"]), (503, ["Retry-After": "120"]), (400, ["Retry-After": "120"])
        ] {
            IPTVFixture.state.reset()
            IPTVFixture.state.handler = { _ in (200, ["ETag": "\"v1\""], Data("<tv/>".utf8)) }
            let client = try client()
            let first = try await client.guideDocument(from: guide)
            let metadata = try XCTUnwrap(first.cacheMetadata)
            IPTVFixture.state.handler = { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
                return (status, headers, Data())
            }
            do {
                _ = try await client.guideResponse(from: guide, previous: metadata)
                XCTFail("Refusal must remain an error: \(status)")
            } catch {
                switch status {
                case 401, 403: XCTAssertEqual(error as? IPTVError, .authentication)
                case 404: XCTAssertEqual(error as? AppError, .notFound)
                case 429: XCTAssertEqual(error as? AppError, .rateLimited(retryAfter: 120))
                default: XCTAssertEqual(error as? IPTVError, .httpStatus(status))
                }
            }
            XCTAssertEqual(IPTVFixture.state.requests.count, 2)
            await client.cancel()
        }
    }

    func testFailedOrdinaryFallbackIsNotRetriedOrReportedAsSuccess() async throws {
        IPTVFixture.state.handler = { _ in (200, ["ETag": "\"v1\""], Data("<tv/>".utf8)) }
        let client = try client()
        let first = try await client.guideDocument(from: guide)
        let metadata = try XCTUnwrap(first.cacheMetadata)
        IPTVFixture.state.handler = { request in
            (request.value(forHTTPHeaderField: "If-None-Match") == nil ? 500 : 412, [:], Data())
        }
        do {
            _ = try await client.guideResponse(from: guide, previous: metadata)
            XCTFail("Failed fallback must stay visible")
        } catch { XCTAssertEqual(error as? IPTVError, .httpStatus(500)) }
        XCTAssertEqual(IPTVFixture.state.requests.count, 3)
    }

    func testOrdinaryRequestsCannotTriggerConditionalFallback() async throws {
        for (owner, headers) in [
            (guide, [String: String]()),
            (guide.appendingPathComponent("different"), ["ETag": "\"v1\""])
        ] {
            IPTVFixture.state.reset()
            IPTVFixture.state.handler = { request in
                XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
                XCTAssertNil(request.value(forHTTPHeaderField: "If-Modified-Since"))
                return (412, [:], Data())
            }
            let metadata = try XMLTVGuideCacheMetadata(response: XCTUnwrap(HTTPURLResponse(
                url: owner, statusCode: 200, httpVersion: nil, headerFields: headers
            )))
            let client = try client()
            do {
                _ = try await client.guideResponse(from: guide, previous: metadata)
                XCTFail("No conditional headers were sent; an ordinary retry cannot help")
            } catch { XCTAssertEqual(error as? IPTVError, .httpStatus(412)) }
            XCTAssertEqual(IPTVFixture.state.requests.count, 1)
            await client.cancel()
        }
    }

    func testOversizedCacheHeadersCannotRejectValidXMLTVOrPermitUnsafePersistence() async throws {
        let oversized = String(repeating: "x", count: 8_193)
        for header in ["ETag", "Last-Modified", "Cache-Control", "Expires", "Date", "Age"] {
            IPTVFixture.state.reset()
            IPTVFixture.state.handler = { _ in
                (200, [header: header == "Cache-Control" ? oversized + ", no-store" : oversized], Data("<tv/>".utf8))
            }
            let client = try client()
            let document = try await client.guideDocument(from: guide)
            XCTAssertEqual(document.data, Data("<tv/>".utf8))
            let metadata = try XCTUnwrap(document.cacheMetadata)
            XCTAssertNil(metadata.etag)
            XCTAssertNil(metadata.lastModified)
            if header != "ETag", header != "Last-Modified" {
                XCTAssertFalse(document.permitsPersistence, header)
                XCTAssertFalse(metadata.isFresh(at: metadata.checkedAt), header)
            } else {
                XCTAssertTrue(document.permitsPersistence)
            }
            await client.cancel()
        }
    }

    func testInvalid304ValidatorDoesNotResurrectTheOldValidator() throws {
        let first = try XMLTVGuideCacheMetadata(response: XCTUnwrap(HTTPURLResponse(
            url: guide, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"v1\""]
        )))
        let updated = try XMLTVGuideCacheMetadata(response: XCTUnwrap(HTTPURLResponse(
            url: guide, statusCode: 304, httpVersion: nil,
            headerFields: ["ETag": String(repeating: "x", count: 8_193)]
        )), previous: first)
        XCTAssertNil(updated.etag)
        XCTAssertNil(updated.applying(to: URLRequest(url: guide)).value(forHTTPHeaderField: "If-None-Match"))
    }

    func testConditionalGuideResponsePreservesValidatorsAndHonorsUpdatedPolicy() async throws {
        let modified = "Wed, 21 Oct 2015 07:28:00 GMT"
        IPTVFixture.state.handler = { request in
            if request.value(forHTTPHeaderField: "If-None-Match") != nil {
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"guide-v1\"")
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-Modified-Since"), modified)
                return (304, ["Cache-Control": "no-cache", "ETag": "\"guide-v2\""], Data())
            }
            return (200, ["ETag": "\"guide-v1\"", "Last-Modified": modified], Data("<tv/>".utf8))
        }
        let client = try client()
        let original = try await client.guideDocument(from: guide)
        let saved = try XCTUnwrap(original.cacheMetadata)
        XCTAssertEqual(saved.expiresAt.timeIntervalSince(saved.checkedAt), 43_200, accuracy: 0.01)
        let result = try await client.guideResponse(from: guide, previous: saved)
        guard case .notModified(let metadata) = result else { return XCTFail("Expected bodyless revalidation") }
        XCTAssertEqual(metadata.etag, "\"guide-v2\"")
        XCTAssertEqual(metadata.lastModified, modified)
        XCTAssertEqual(metadata.expiresAt, metadata.checkedAt)
        XCTAssertEqual(IPTVFixture.state.requests.count, 2)
        let retained = await client.cachedGuideByteCount
        XCTAssertEqual(retained, 0)
    }

    func testUnsolicited304NeverSucceedsForGuideOrAccountRequests() async throws {
        IPTVFixture.state.handler = { _ in (304, [:], Data()) }
        let client = try client()
        do {
            _ = try await client.guideDocument(from: guide)
            XCTFail("A guide without a saved representation cannot accept 304")
        } catch {
            XCTAssertEqual(error as? LiveTVSourceImportError, .redirectBlocked)
        }
        let http = IPTVHTTP(configuration: IPTVFixture.configuration())
        do {
            _ = try await http.bytes(url: guide, headers: [:])
            XCTFail("Account status semantics must not change")
        } catch {
            XCTAssertEqual(error as? LiveTVSourceImportError, .redirectBlocked)
        }
    }

    func testGuideFreshnessRespectsHTTPAgeExpiresAndNoCache() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [([String: String], TimeInterval)] = [
            ([:], 43_200),
            (["Cache-Control": "max-age=86400"], 43_200),
            (["Cache-Control": "max-age=300", "Age": "100"], 200),
            (["Cache-Control": "max-age=300", "Date": HTTPDate.string(from: now.addingTimeInterval(-200))], 100),
            (["Expires": HTTPDate.string(from: now.addingTimeInterval(90))], 90),
            (["Cache-Control": "no-cache=\"ETag\", max-age=300"], 0),
            (["Cache-Control": "NO-CACHE = \"ETag\", max-age=300"], 0),
            (["Cache-Control": "max-age=invalid"], 0),
            (["Cache-Control": "max-age=300, max-age=0"], 0),
            (["Age": "invalid"], 0)
        ]
        for (headers, lifetime) in cases {
            let response = try XCTUnwrap(HTTPURLResponse(url: guide, statusCode: 200, httpVersion: nil, headerFields: headers))
            let metadata = try XMLTVGuideCacheMetadata(response: response, now: now)
            XCTAssertEqual(metadata.expiresAt.timeIntervalSince(now), lifetime, accuracy: 0.01)
            XCTAssertFalse(metadata.isFresh(at: now.addingTimeInterval(lifetime)))
            XCTAssertFalse(metadata.isFresh(at: now.addingTimeInterval(-1)))
        }
    }

    func test304InheritsCachePolicyButChanged200DoesNotInheritOldValidators() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try XCTUnwrap(HTTPURLResponse(url: guide, statusCode: 200, httpVersion: nil, headerFields: [
            "ETag": "\"v1\"", "Last-Modified": HTTPDate.string(from: now), "Cache-Control": "max-age=300"
        ]))
        let saved = try XMLTVGuideCacheMetadata(response: first, now: now)
        for status in [200, 304] {
            let http = try XCTUnwrap(HTTPURLResponse(url: guide, statusCode: status, httpVersion: nil, headerFields: [:]))
            let result = try XMLTVGuideCacheMetadata(response: http, previous: saved, now: now)
            XCTAssertEqual(result.etag, status == 304 ? saved.etag : nil)
            XCTAssertEqual(result.lastModified, status == 304 ? saved.lastModified : nil)
            XCTAssertEqual(result.expiresAt.timeIntervalSince(now), status == 304 ? 300 : 43_200)
        }
    }

    func testRealRedirectOnlySendsValidatorsToTheirExactResource() async throws {
        let body = Data("<tv/>".utf8)
        let target = try IPTVTestHTTPServer { request in
            let conditional = request.lowercased().contains("if-none-match: \"v1\"")
            XCTAssertFalse(request.lowercased().contains("x-guide-key:"))
            return .init(data: conditional ? Data() : body, status: conditional ? 304 : 200,
                         headers: ["ETag": "\"v1\""])
        }
        let targetURL = try await target.start().appendingPathComponent("guide.xml")
        addTeardownBlock { await target.stop() }
        let source = try IPTVTestHTTPServer { request in
            XCTAssertFalse(request.lowercased().contains("if-none-match:"))
            XCTAssertFalse(request.lowercased().contains("if-modified-since:"))
            return .init(status: 302, headers: ["Location": targetURL.absoluteString])
        }
        let sourceURL = try await source.start().appendingPathComponent("guide.xml")
        addTeardownBlock { await source.stop() }
        let client = try client()
        let first = try await client.guideDocument(from: sourceURL)
        let saved = try XCTUnwrap(first.cacheMetadata)
        XCTAssertEqual(saved.responseURL, targetURL)
        let second = try await client.guideResponse(from: sourceURL, previous: saved)
        guard case .notModified = second else { return XCTFail("Redirected guide should revalidate") }
        let requests = await target.requestCount
        XCTAssertEqual(requests, 2)
        let differentPath = targetURL.deletingLastPathComponent().appendingPathComponent("other.xml")
        XCTAssertNil(saved.applying(to: URLRequest(url: differentPath)).value(forHTTPHeaderField: "If-None-Match"))
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
