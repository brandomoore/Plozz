import Foundation
import XCTest
import AetherEngine
@testable import EnginePlozzigen

final class HDR10PlusHTTPRangeSourceTests: XCTestCase {
    func testCombinedPublicEngineProbeUsesStrictHTTPReader() async {
        let fixture = HDR10PlusHTTPStub.Scenario(payload: HDR10PlusTestFixture.positive)
        let (source, budget) = makeSource(fixture, bytes: 8 * 1024 * 1024)
        let result = await PlozzigenStreamProbeExecutor.runDetailProbe(
            reader: HDR10PlusAVIOReader(source: source, budget: budget),
            formatHint: "mp4",
            requirements: [.hdr10Plus, .atmos],
            limits: budget.limits,
            budget: budget
        )
        XCTAssertEqual(result?.carriesHDR10PlusMetadata, true)
        XCTAssertEqual(result?.videoFormat, .hdr10Plus)
        XCTAssertGreaterThan(fixture.snapshot.requests, 0)
        XCTAssertLessThanOrEqual(fixture.snapshot.delivered, budget.limits.networkBytes)
        XCTAssertNil(source.read(at: 0, count: 1), "Native return must close the caller-owned HTTP source")
    }

    func testCombinedProbeRejectsIgnoredRangeEvenForPositiveMedia() async {
        let fixture = HDR10PlusHTTPStub.Scenario(status: 200, payload: HDR10PlusTestFixture.positive)
        let (source, budget) = makeSource(fixture, bytes: 8 * 1024 * 1024)
        let result = await PlozzigenStreamProbeExecutor.runDetailProbe(
            reader: HDR10PlusAVIOReader(source: source, budget: budget),
            requirements: [.hdr10Plus, .atmos],
            limits: budget.limits,
            budget: budget
        )
        XCTAssertNil(result)
        XCTAssertEqual(fixture.snapshot.requests, 1)
        XCTAssertFalse(budget.isActive)
        XCTAssertNil(source.read(at: 0, count: 1))
    }

    func testCombinedProbeCancellationClosesStalledHTTPSource() async {
        let fixture = HDR10PlusHTTPStub.Scenario(stall: true)
        let (source, budget) = makeSource(fixture)
        let task = Task {
            await PlozzigenStreamProbeExecutor.runDetailProbe(
                reader: HDR10PlusAVIOReader(source: source, budget: budget),
                requirements: [.hdr10Plus, .atmos],
                limits: budget.limits,
                budget: budget
            )
        }
        await waitForRequest(fixture)
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertFalse(budget.isActive)
        XCTAssertNil(source.read(at: 0, count: 1))
    }

    func testTransportNeverUsesSharedCookiesCredentialsOrCache() {
        let configuration = URLSessionConfiguration.default
        let budget = HDR10PlusProbeBudget(limits: .init())
        let source = HDR10PlusHTTPRangeSource(
            url: URL(string: "https://example.invalid/video")!,
            budget: budget, configuration: configuration
        )
        defer { source.close() }
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 2)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 5)
    }

    func testValidRangesRespectCumulativeBudgetAcrossSeeks() async {
        let fixture = HDR10PlusHTTPStub.Scenario()
        let (source, budget) = makeSource(fixture, bytes: 27)
        defer { source.close() }
        let first = await Task.detached { source.read(at: 100, count: 20) }.value
        let second = await Task.detached { source.read(at: 0, count: 20) }.value
        let exhausted = await Task.detached { source.read(at: 500, count: 1) }.value
        XCTAssertEqual(first?.count, 20)
        XCTAssertEqual(second?.count, 7)
        XCTAssertNil(exhausted)
        XCTAssertEqual(fixture.snapshot.requests, 2)
        XCTAssertEqual(fixture.snapshot.delivered, 27)
        XCTAssertEqual(source.size, 1024)
        XCTAssertTrue(budget.isActive)
    }

    func testIgnoredRangeStopsStreamingBeforeWholeMovieDelivery() async {
        let fixture = HDR10PlusHTTPStub.Scenario(status: 200)
        let (source, _) = makeSource(fixture)
        defer { source.close() }
        let result = await Task.detached { source.read(at: 0, count: 16) }.value
        XCTAssertNil(result)
        try? await Task.sleep(for: .milliseconds(80))
        // URLProtocol/CFNetwork may enqueue one chunk before honoring the
        // response disposition. It must stop instead of draining the body.
        XCTAssertLessThanOrEqual(fixture.snapshot.delivered, 128 * 1024)
        XCTAssertEqual(fixture.snapshot.requests, 1)
        XCTAssertGreaterThan(fixture.snapshot.stops, 0)
    }

    func testOversizedAndTruncated206BodiesFailClosed() async {
        for delta in [-1, 1] {
            let fixture = HDR10PlusHTTPStub.Scenario(bodyDelta: delta)
            let (source, _) = makeSource(fixture)
            let result = await Task.detached { source.read(at: 0, count: 16) }.value
            XCTAssertNil(result)
            source.close()
        }
    }

    func testRequestTimeoutAndCancellationStopOutstandingIO() async {
        let timedOut = HDR10PlusHTTPStub.Scenario(stall: true)
        let (timedSource, _) = makeSource(timedOut, requestTimeout: 0.05)
        let started = ProcessInfo.processInfo.systemUptime
        let result = await Task.detached { timedSource.read(at: 0, count: 16) }.value
        XCTAssertNil(result)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5)
        timedSource.close()

        let cancelled = HDR10PlusHTTPStub.Scenario(stall: true)
        let (source, budget) = makeSource(cancelled)
        let task = Task.detached { source.read(at: 0, count: 16) }
        await waitForRequest(cancelled)
        let cancellationStart = ProcessInfo.processInfo.systemUptime
        budget.cancel()
        let cancelledResult = await task.value
        XCTAssertNil(cancelledResult)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - cancellationStart, 0.5)
        XCTAssertNil(source.read(at: 0, count: 16))
        source.close()
    }

    func testCrossOriginRedirectNeverIssuesDestinationRequest() async {
        let fixture = HDR10PlusHTTPStub.Scenario(redirect: URL(string: "https://other.invalid/private?api_key=fake")!)
        let (source, _) = makeSource(fixture)
        defer { source.close() }
        let result = await Task.detached { source.read(at: 0, count: 16) }.value
        XCTAssertNil(result)
        XCTAssertEqual(fixture.snapshot.requests, 1)
        XCTAssertEqual(fixture.snapshot.delivered, 0)
    }

    func testSameOriginRedirectRetainsBoundedRange() async {
        let fixture = HDR10PlusHTTPStub.Scenario(
            redirect: URL(string: "https://example.invalid/final?api_key=fake")!
        )
        let (source, _) = makeSource(fixture, bytes: 16)
        defer { source.close() }
        let result = await Task.detached { source.read(at: 0, count: 16) }.value
        XCTAssertEqual(result?.count, 16)
        XCTAssertEqual(fixture.snapshot.requests, 2)
        XCTAssertEqual(fixture.snapshot.delivered, 16)
    }

    func testOriginChecksIncludeSchemePortAndRejectUserInfo() {
        let origin = URL(string: "https://example.invalid/path?api_key=fake")!
        XCTAssertTrue(HDR10PlusHTTPRangeSource.sameOrigin(origin, URL(string: "https://EXAMPLE.invalid:443/next")!))
        for other in [
            "http://example.invalid/path", "https://example.invalid:444/path",
            "https://other.invalid/path", "https://name:password@example.invalid/path", "file:///movie"
        ] {
            XCTAssertFalse(HDR10PlusHTTPRangeSource.sameOrigin(origin, URL(string: other)!))
        }
    }

    func testResponseValidationRejectsMissingMismatchedAndEncodedRanges() {
        let url = URL(string: "https://example.invalid/video")!
        let valid = ["Content-Range": "bytes 10-19/100", "Content-Length": "10"]
        func validate(_ status: Int, _ headers: [String: String], size: Int64? = nil) -> Bool {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
            return HDR10PlusHTTPRangeSource.validatedRange(response, start: 10, count: 10, size: size) != nil
        }
        XCTAssertTrue(validate(206, valid))
        XCTAssertFalse(validate(200, valid))
        XCTAssertFalse(validate(404, valid))
        XCTAssertFalse(validate(206, [:]))
        XCTAssertFalse(validate(206, valid, size: 101))
        for range in ["bytes 0-9/100", "bytes 10-20/100", "bytes 10-19/*", "bytes 10-19/19",
                      "bytes 19-10/100", "bytes 10-9223372036854775807/100", "bytes 10-19/100/200"] {
            XCTAssertFalse(validate(206, ["Content-Range": range]))
        }
        XCTAssertFalse(validate(206, valid.merging(["Content-Encoding": "gzip"]) { _, new in new }))
        XCTAssertFalse(validate(206, valid.merging(["Content-Length": "9"]) { _, new in new }))
    }

    private func makeSource(
        _ fixture: HDR10PlusHTTPStub.Scenario, bytes: Int = 1024, requestTimeout: TimeInterval = 1
    ) -> (HDR10PlusHTTPRangeSource, HDR10PlusProbeBudget) {
        let url = HDR10PlusHTTPStub.register(fixture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HDR10PlusHTTPStub.self]
        var limits = HDR10PlusProbeLimits()
        limits.networkBytes = bytes
        limits.requestTimeout = requestTimeout
        let budget = HDR10PlusProbeBudget(limits: limits)
        return (HDR10PlusHTTPRangeSource(url: url, budget: budget, configuration: configuration), budget)
    }

    private func waitForRequest(_ fixture: HDR10PlusHTTPStub.Scenario) async {
        for _ in 0..<100 {
            if fixture.snapshot.requests > 0 { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected mock request to start")
    }
}

private final class HDR10PlusHTTPStub: URLProtocol, @unchecked Sendable {
    final class Scenario: @unchecked Sendable {
        let status: Int
        let bodyDelta: Int
        let stall: Bool
        let redirect: URL?
        let payload: Data?
        let lock = NSLock()
        var requests = 0
        var delivered = 0
        var stops = 0

        init(
            status: Int = 206, bodyDelta: Int = 0, stall: Bool = false,
            redirect: URL? = nil, payload: Data? = nil
        ) {
            self.status = status
            self.bodyDelta = bodyDelta
            self.stall = stall
            self.redirect = redirect
            self.payload = payload
        }

        var snapshot: (requests: Int, delivered: Int, stops: Int) {
            lock.withLock { (requests, delivered, stops) }
        }
    }

    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var scenarios: [String: Scenario] = [:]
    }
    private static let registry = Registry()
    private let lock = NSLock()
    private var stopped = false
    private var scenario: Scenario?

    static func register(_ scenario: Scenario) -> URL {
        let path = "/" + UUID().uuidString
        registry.lock.withLock {
            registry.scenarios[path] = scenario
            if let redirect = scenario.redirect { registry.scenarios[redirect.path] = scenario }
        }
        return URL(string: "https://example.invalid\(path)?api_key=fake")!
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let scenario = Self.registry.lock.withLock({ Self.registry.scenarios[url.path] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        self.scenario = scenario
        scenario.lock.withLock { scenario.requests += 1 }
        if scenario.stall { return }
        if let redirect = scenario.redirect, url != redirect {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil,
                                           headerFields: ["Location": redirect.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            return
        }
        let endpoints = request.value(forHTTPHeaderField: "Range")!
            .dropFirst(6).split(separator: "-").compactMap { Int($0) }
        let total = scenario.payload?.count ?? 1024
        let upper = min(endpoints[1], total - 1)
        let count = upper - endpoints[0] + 1
        let response = HTTPURLResponse(
            url: url, statusCode: scenario.status, httpVersion: nil,
            headerFields: [
                "Content-Range": "bytes \(endpoints[0])-\(upper)/\(total)",
                "Content-Length": scenario.status == 200 ? "3000000000" : "\(count)"
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.02) { [self] in
            guard !lock.withLock({ stopped }) else { return }
            if scenario.status == 200 {
                sendIgnoredRangeChunk(remaining: 256)
            } else {
                let body = scenario.payload.map { $0.subdata(in: endpoints[0]..<(upper + 1)) }
                    ?? Data(repeating: 7, count: max(0, count + scenario.bodyDelta))
                scenario.lock.withLock { scenario.delivered += body.count }
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    private func sendIgnoredRangeChunk(remaining: Int) {
        guard remaining > 0, !lock.withLock({ stopped }), let scenario else { return }
        let chunk = Data(repeating: 7, count: 32 * 1024)
        scenario.lock.withLock { scenario.delivered += chunk.count }
        client?.urlProtocol(self, didLoad: chunk)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.01) { [self] in
            sendIgnoredRangeChunk(remaining: remaining - 1)
        }
    }

    override func stopLoading() {
        lock.withLock { stopped = true }
        scenario?.lock.withLock { scenario?.stops += 1 }
    }
}
