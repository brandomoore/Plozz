import CoreModels
import CoreNetworking
import Foundation
@testable import ProviderIPTV
import XCTest

final class IPTVGuideDiagnosticsTests: XCTestCase {
    override func tearDown() {
        IPTVFixture.state.reset()
        super.tearDown()
    }

    func testMissingGuideRetainsAPIAndXMLTVResponsesWithoutSecretsOrExtraRequests() async throws {
        for (status, body, fallback) in [
            (404, "", "Unavailable"), (405, "", "Unavailable"), (501, "", "Unavailable"),
            (200, "<html>private-login-body</html>", "Malformed"),
            (200, #"{"epg_listings":[]}"#, "Empty")
        ] {
            let provider = try await provider()
            IPTVFixture.state.reset()
            IPTVFixture.state.handler = { request in
                let xml = request.url?.path.hasSuffix("xmltv.php") == true
                return (xml ? 404 : status, ["Content-Type": "text/html; private-header"], Data(body.utf8))
            }
            let since = Date()
            do {
                _ = try await load(provider)
                XCTFail("Failed XMLTV must remain an error")
            } catch { XCTAssertEqual(error as? AppError, .notFound) }
            let log = report(since: since)
            XCTAssertTrue(log.contains("endpoint=get_simple_data_table"))
            XCTAssertTrue(log.contains("http=\(status)"))
            XCTAssertTrue(log.contains("endpoint=xmltv"))
            XCTAssertTrue(log.contains("http=404 response=html"))
            XCTAssertTrue(log.contains("fallback\(fallback)=1"))
            XCTAssertTrue(log.contains("outcome=failed operations=2"))
            XCTAssertTrue(log.contains("rows=unknown reason=notFound"))
            for secret in ["provider.test", "private-user", "private-password", "private-login-body",
                           "private-header", "Private channel", "live:10", "stream_id", "https://"] {
                XCTAssertFalse(log.contains(secret), secret)
            }
            XCTAssertEqual(IPTVFixture.state.requests.count, 2)
            await provider.teardown()
        }
    }

    func testTransientAuthenticationAndCancellationFailuresDoNotTriggerFallback() async throws {
        for (status, reason) in [(401, "authentication"), (403, "authentication"), (429, "rateLimited"),
                                 (503, "invalidResponse"), (-1001, "timeout"), (-999, "cancelled")] {
            let provider = try await provider()
            IPTVFixture.state.reset()
            IPTVFixture.state.handler = { _ in
                if status < 0 {
                    throw NSError(domain: NSURLErrorDomain, code: status, userInfo: [
                        NSLocalizedDescriptionKey: "private-error-description",
                        NSURLErrorFailingURLStringErrorKey: "https://private-host/private-password"
                    ])
                }
                return (status, ["Content-Type": "text/html"], Data())
            }
            let since = Date()
            do {
                _ = try await load(provider)
                XCTFail("Failure must not become empty success")
            } catch {
                if status < 0 { XCTAssertEqual((error as NSError).code, status) }
                else if status == 401 || status == 403 { XCTAssertEqual(error as? IPTVError, .authentication) }
                else if status == 503 { XCTAssertEqual(error as? IPTVError, .httpStatus(503)) }
                else if case AppError.rateLimited = error {} else { XCTFail("Expected rate limit") }
            }
            let log = report(since: since)
            XCTAssertTrue(log.contains("reason=\(reason)"))
            XCTAssertTrue(log.contains("http=\(status > 0 ? String(status) : "unknown")"))
            if status == -1001 { XCTAssertTrue(log.contains("networkCode=-1001")) }
            if status == -999 {
                XCTAssertTrue(log.contains("outcome=cancelled"))
                XCTAssertFalse(log.contains("outcome=failed"))
            }
            XCTAssertFalse(log.contains("endpoint=xmltv"))
            XCTAssertFalse(log.contains("private-error-description"))
            XCTAssertFalse(log.contains("private-host"))
            XCTAssertEqual(IPTVFixture.state.requests.count, 1)
            await provider.teardown()
        }
    }

    func testSuccessfulFallbackAndCachedXMLTVReportActualRowsAndNoInventedHTTPResponse() async throws {
        let provider = try await provider { _, _, channels, from, to in
            [.init(id: "private-program", channelID: channels[0].id, title: "Private program",
                   startDate: from, endDate: to)]
        }
        IPTVFixture.state.reset()
        IPTVFixture.state.handler = { request in
            let xml = request.url?.path.hasSuffix("xmltv.php") == true
            return (200, ["Content-Type": xml ? "application/xml" : "application/json"],
                    Data((xml ? "<tv/>" : #"{"epg_listings":[]}"#).utf8))
        }
        let first = Date()
        let programmes = try await load(provider)
        XCTAssertEqual(programmes.count, 1)
        let fresh = report(since: first)
        XCTAssertTrue(fresh.contains("stage=parse outcome=succeeded requests=1 http=200 response=xml bytes=5 cached=false rows=1"))
        XCTAssertTrue(fresh.contains("outcome=succeeded operations=2"))
        let second = Date()
        _ = try await load(provider)
        let cached = report(since: second)
        XCTAssertTrue(cached.contains("stage=parse outcome=succeeded requests=0 http=unknown response=unknown bytes=5 cached=true rows=1"))
        XCTAssertEqual(IPTVFixture.state.requests.count, 3)
        XCTAssertFalse(cached.contains("Private program"))
        await provider.teardown()
    }

    func testExplicitXMLTVParseFailureIdentifiesStageAndDoesNotTryNativeAPI() async throws {
        let provider = try await provider(explicit: true) { _, _, _, _, _ in
            throw LiveTVSourceImportError.invalidGuide
        }
        IPTVFixture.state.reset()
        IPTVFixture.state.handler = { _ in
            (200, ["Content-Type": "text/html"], Data("<html>private-login-body</html>".utf8))
        }
        let since = Date()
        do {
            _ = try await load(provider)
            XCTFail("Invalid XMLTV must fail")
        } catch { XCTAssertEqual(error as? LiveTVSourceImportError, .invalidGuide) }
        let log = report(since: since)
        XCTAssertTrue(log.contains("source=explicitXMLTV"))
        XCTAssertTrue(log.contains("endpoint=xmltv stage=parse outcome=failed requests=1 http=200 response=html"))
        XCTAssertTrue(log.contains("reason=malformed"))
        XCTAssertFalse(log.contains("get_simple_data_table"))
        XCTAssertFalse(log.contains("private-login-body"))
        XCTAssertEqual(IPTVFixture.state.requests.count, 1)
        await provider.teardown()
    }

    func testLargeBatchRetainsFirstFailureAndLastRequestWithBoundedLogVolume() throws {
        let since = Date()
        let diagnostics = IPTVGuideDiagnostics(credential: try credential(), channels: 2_000)
        for index in 1...2_000 {
            let request = IPTVGuideDiagnostics.Request()
            request.parsing()
            diagnostics.record(request, endpoint: .xtream, rows: index == 100 ? nil : 0,
                               error: index == 100 ? IPTVError.malformed : nil)
            diagnostics.fallback(.empty)
        }
        XCTAssertEqual(lines(since: since).count, 1, "No per-channel logging while collecting the batch")
        diagnostics.finish(rows: 0)
        let entries = lines(since: since)
        XCTAssertEqual(entries.count, 8, "Begin + four initial requests + first failure + last request + completion")
        XCTAssertTrue(entries.contains { $0.contains("index=100 ") && $0.contains("reason=malformed") })
        XCTAssertTrue(entries.contains { $0.contains("index=2000 ") })
        XCTAssertTrue(entries.contains { $0.contains("operations=2000 omitted=1994 fallbackEmpty=2000") })
    }

    func testRejectedGuideIsNotReusedOnTheNextRefresh() async throws {
        let provider = try await provider(explicit: true) { data, _, _, _, _ in
            guard data == Data("<tv/>".utf8) else { throw LiveTVSourceImportError.invalidGuide }
            return []
        }
        IPTVFixture.state.reset()
        IPTVFixture.state.handler = { _ in
            let body = IPTVFixture.state.requests.count == 1 ? "<html>login</html>" : "<tv/>"
            return (200, ["Cache-Control": "max-age=60"], Data(body.utf8))
        }
        do {
            _ = try await load(provider)
            XCTFail("Malformed guides must fail, not become an empty guide")
        } catch { XCTAssertEqual(error as? LiveTVSourceImportError, .invalidGuide) }
        _ = try await load(provider)
        _ = try await load(provider)
        XCTAssertEqual(IPTVFixture.state.requests.count, 2, "Discard rejected bytes, but retain the valid replacement")
    }

    func testRepeatedMissingExplicitGuideReportsReusedFailureWithoutInventingRequests() async throws {
        let provider = try await provider(explicit: true)
        IPTVFixture.state.reset()
        IPTVFixture.state.handler = { _ in (404, ["Content-Type": "text/html"], Data()) }
        let since = Date()
        await ServerLiveTVGuideRefreshScope.$current.withValue(.init()) {
            for _ in 0..<2 {
                do {
                    _ = try await load(provider)
                    XCTFail("Missing override and missing fallback must stay failed")
                } catch { XCTAssertEqual(error as? AppError, .notFound) }
            }
        }
        let log = report(since: since)
        XCTAssertEqual(IPTVFixture.state.requests.count, 2)
        XCTAssertTrue(log.contains("requests=0 http=unknown response=unknown bytes=0"))
        XCTAssertTrue(log.contains("reusedFailure=true"))
        XCTAssertTrue(log.contains("fallbackUnavailable=1"))
        XCTAssertFalse(log.contains("get_simple_data_table"))
        for secret in ["provider.test", "private-user", "private-password", "private-token"] {
            XCTAssertFalse(log.contains(secret), secret)
        }
        IPTVFixture.state.handler = { _ in (200, [:], Data("<tv/>".utf8)) }
        _ = try await ServerLiveTVGuideRefreshScope.$current.withValue(.init()) { try await load(provider) }
        XCTAssertEqual(IPTVFixture.state.requests.count, 3, "The next refresh retries the preferred override immediately")
        await provider.teardown()
    }

    private func load(_ provider: IPTVProvider) async throws -> [ServerLiveTVProgramme] {
        try await provider.liveTVGuide(channelIDs: ["live:10"],
            from: Date(timeIntervalSince1970: 100), to: Date(timeIntervalSince1970: 500))
    }

    private func lines(since: Date) -> [String] {
        PlozzLog.recentEntries(limit: 500).filter {
            $0.date >= since && $0.message.hasPrefix("IPTV_GUIDE ")
        }.map(\.message)
    }

    private func report(since: Date) -> String { lines(since: since).joined(separator: "\n") }

    private func credential(explicit: Bool = false) throws -> IPTVCredential {
        try IPTVCredential(
            mode: .xtream, address: XCTUnwrap(URL(string: "https://provider.test")),
            username: "private-user", password: "private-password",
            guideURL: explicit ? URL(string: "https://provider.test/guide?token=private-token") : nil
        )
    }

    private func provider(
        explicit: Bool = false,
        guideLoader: @escaping IPTVProvider.IPTVGuideLoader = { _, _, _, _, _ in [] }
    ) async throws -> IPTVProvider {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        IPTVFixture.state.handler = { request in
            let action = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first { $0.name == "action" }?.value
            let body: String
            if action == nil { body = #"{"user_info":{"auth":1,"status":"Active"}}"# }
            else if action == "get_live_streams" { body = #"[{"stream_id":10,"name":"Private channel"}]"# }
            else { body = "[]" }
            return (200, ["Content-Type": "application/json"], Data(body.utf8))
        }
        let session = try await IPTVProvider.signIn(
            credential: credential(explicit: explicit), name: "Private source", deviceID: "Private device",
            cacheDirectory: root, configuration: IPTVFixture.configuration()
        )
        let provider = try IPTVProvider(
            context: .init(session: session, accountID: "private-account", credentialRevision: .init(),
                           localMediaContext: .init(accountID: "private-account", profileID: "profile", profileNamespace: nil)),
            cacheDirectory: root, configuration: IPTVFixture.configuration(), guideLoader: guideLoader
        )
        addTeardownBlock { await provider.teardown() }
        return provider
    }
}
