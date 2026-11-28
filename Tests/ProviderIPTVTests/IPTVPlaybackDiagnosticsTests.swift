import CoreModels
import Foundation
import XCTest
@testable import ProviderIPTV

final class IPTVPlaybackDiagnosticsTests: XCTestCase {
    override func tearDown() {
        IPTVFixture.state.reset()
        super.tearDown()
    }

    func testEncryptedProxyPreservesOnlyVerifiedMediaSuffixes() async throws {
        IPTVFixture.state.handler = { _ in (200, [:], Data("fixture".utf8)) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for suffix in ["ts", "M2TS", "mts", "m3u8", "mp4", ""] {
            let origin = try XCTUnwrap(URL(string: "https://provider.test/private/channel" + (suffix.isEmpty ? "" : "." + suffix)))
            let proxy = try IPTVPlaybackProxy(origin: origin, headers: [:], configuration: IPTVFixture.configuration())
            addTeardownBlock { await proxy.stop() }
            let address = try await proxy.start()
            let expected = ["ts", "m2ts", "mts", "m3u8"].contains(suffix.lowercased()) ? suffix.lowercased() : ""
            XCTAssertEqual(address.pathExtension, expected)
            XCTAssertFalse(address.absoluteString.contains("private"))
            let (body, response) = try await session.data(from: address)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(body, Data("fixture".utf8))
            let tampered = address.deletingPathExtension().appendingPathExtension(expected == "ts" ? "m3u8" : "ts")
            let (_, rejected) = try await session.data(from: tampered)
            XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 502)
            if !expected.isEmpty {
                let (_, stripped) = try await session.data(from: address.deletingPathExtension())
                XCTAssertEqual((stripped as? HTTPURLResponse)?.statusCode, 502)
            }
            await proxy.stop()
        }
    }

    func testProxyPreservesHTTPRefusalsWithoutTheirPrivateResponseBody() async throws {
        for status in [401, 403, 404, 429, 451, 503] {
            IPTVFixture.state.reset()
            IPTVFixture.state.handler = { _ in (status, ["Content-Type": "text/html"], Data("private".utf8)) }
            let buffer = ProxyDiagnosticBuffer()
            let diagnostics = PlaybackFailureDiagnostics()
            diagnostics.start { buffer.append($0) }
            let proxy = try IPTVPlaybackProxy(
                origin: XCTUnwrap(URL(string: "https://provider.test/private")),
                headers: ["Authorization": "Bearer private"], configuration: IPTVFixture.configuration(),
                diagnostics: diagnostics
            )
            addTeardownBlock { await proxy.stop() }
            let url = try await proxy.start()
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            for _ in 0..<2 {
                let (body, response) = try await session.data(from: url)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, status)
                XCTAssertTrue(body.isEmpty)
            }
            if [401, 403, 429, 451].contains(status) {
                XCTAssertEqual(IPTVFixture.state.requests.count, 1, "Native fallback must not retry a provider refusal.")
            }

            let failure = try XCTUnwrap(buffer.values.first)
            XCTAssertEqual(buffer.values.count, 1)
            XCTAssertEqual(failure.httpStatus, status)
            XCTAssertEqual(failure.stage, .response)
            XCTAssertEqual(failure.format, .html)
            XCTAssertNil(failure.code)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(failure), as: UTF8.self).contains("private"))
            let state = try XCTUnwrap(PlaybackDeliveryFailure.state(for: url))
            if status == 451 { XCTAssertEqual(state.error, .accessRestricted) }
            await proxy.stop()
            XCTAssertNil(PlaybackDeliveryFailure.state(for: url))
            if [401, 403, 429, 451].contains(status) {
                XCTAssertNotNil(state.error, "The active player retains evidence through proxy cleanup.")
                XCTAssertEqual(state.diagnostic?.httpStatus, status)
            } else {
                XCTAssertNil(state.error, "Recoverable failures must not poison a successful native fallback.")
                XCTAssertNil(state.diagnostic)
            }
        }
    }

    func testDeclaredFormatLabelsOnlyTheExtensionlessOriginWithoutChangingUpstream() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for (path, hint, expected) in [
            ("channel", "ts", "ts"), ("channel", "m3u8", "m3u8"),
            ("channel.m3u8", "ts", "m3u8"), ("channel.ts", "m3u8", "ts"),
            ("channel.mp4", "ts", ""), ("channel", "mp4", "")
        ] {
            let origin = try XCTUnwrap(URL(string: "https://provider.test/private/" + path))
            IPTVFixture.state.handler = { request in
                XCTAssertEqual(request.url, origin)
                return (200, [:], Data("fixture".utf8))
            }
            let proxy = try IPTVPlaybackProxy(
                origin: origin, headers: [:], formatHint: .init(container: hint),
                configuration: IPTVFixture.configuration()
            )
            addTeardownBlock { await proxy.stop() }
            let address = try await proxy.start()
            XCTAssertEqual(address.pathExtension, expected)
            let (_, response) = try await session.data(from: address)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let tampered = address.deletingPathExtension().appendingPathExtension(expected == "ts" ? "m3u8" : "ts")
            let (_, rejected) = try await session.data(from: tampered)
            XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 502)
            await proxy.stop()
        }
    }

    func testExpiredRateLimitCanRecoverOnTheSameProxyWithoutRetainingItsFailure() async throws {
        IPTVFixture.state.handler = { _ in
            if IPTVFixture.state.requests.count == 1 {
                return (429, ["Retry-After": "0"], Data())
            }
            return (200, ["Content-Type": "video/mp2t"], Data(repeating: 0x47, count: 188))
        }
        let proxy = try IPTVPlaybackProxy(
            origin: XCTUnwrap(URL(string: "https://provider.test/channel.ts")),
            headers: [:], configuration: IPTVFixture.configuration()
        )
        addTeardownBlock { await proxy.stop() }
        let url = try await proxy.start()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, refused) = try await session.data(from: url)
        XCTAssertEqual((refused as? HTTPURLResponse)?.statusCode, 429)
        XCTAssertEqual(PlaybackDeliveryFailure.state(for: url)?.error, .rateLimited(retryAfter: 0))
        let (body, recovered) = try await session.data(from: url)
        XCTAssertEqual((recovered as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(body.count, 188)
        XCTAssertEqual(IPTVFixture.state.requests.count, 2)
        XCTAssertNil(PlaybackDeliveryFailure.state(for: url)?.error)
        XCTAssertNil(PlaybackDeliveryFailure.state(for: url)?.diagnostic)
    }

    func testConnectionLimitUsesOriginalResponseWithoutOpeningADiagnosticStream() async throws {
        IPTVFixture.state.handler = { _ in
            (503, ["Content-Type": "application/json"], Data("""
            {"error":"All active M3U profiles have reached maximum connection limits","private":"fixture-secret"}
            """.utf8))
        }
        let proxy = try IPTVPlaybackProxy(
            origin: XCTUnwrap(URL(string: "https://provider.test/channel.ts")),
            headers: [:], configuration: IPTVFixture.configuration()
        )
        addTeardownBlock { await proxy.stop() }
        let url = try await proxy.start()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (body, response) = try await session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        XCTAssertTrue(body.isEmpty)
        XCTAssertEqual(PlaybackDeliveryFailure.state(for: url)?.error, .conflict)
        XCTAssertEqual(IPTVFixture.state.requests.count, 1)
        let evidence = try XCTUnwrap(PlaybackDeliveryFailure.state(for: url)?.evidence)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self).contains("fixture-secret"))
    }

    func testProxyNetworkFailurePreservesCodeWithoutInventingHTTPResponse() async throws {
        IPTVFixture.state.handler = { _ in throw URLError(.timedOut) }
        let diagnostics = PlaybackFailureDiagnostics()
        let buffer = ProxyDiagnosticBuffer()
        diagnostics.start { buffer.append($0) }
        let proxy = try IPTVPlaybackProxy(
            origin: XCTUnwrap(URL(string: "https://provider.test/live")),
            headers: [:], configuration: IPTVFixture.configuration(), diagnostics: diagnostics
        )
        addTeardownBlock { await proxy.stop() }
        let url = try await proxy.start()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        _ = try await session.data(from: url)
        let failure = try XCTUnwrap(buffer.values.first)
        XCTAssertEqual(failure.reason, .timeout)
        XCTAssertEqual(failure.domain, .url)
        XCTAssertEqual(failure.code, -1001)
        XCTAssertNil(failure.httpStatus)
        XCTAssertEqual(failure.evidence?.delivery?.firstFailure?.networkCode, -1001)
        XCTAssertNil(failure.evidence?.delivery?.firstFailure?.status)
    }

    func testSuccessfulNonVideoRootResponsesRetainTheirCauseWithoutAnotherRequest() async throws {
        for (text, format) in [
            ("<!DOCTYPE html><html>fixture-secret</html>", "html"),
            (" \u{FEFF}<HtMl><body>fixture-secret</body></HtMl>", "html"),
            (#"{"error":"fixture-secret"}"#, "json"),
            ("<?xml version=\"1.0\"?><error>fixture-secret</error>", "xml"),
            ("", "empty")
        ] {
            IPTVFixture.state.reset()
            IPTVFixture.state.handler = { _ in
                (200, ["Content-Type": "video/mp2t"], Data(text.utf8))
            }
            let diagnostics = PlaybackFailureDiagnostics()
            let buffer = ProxyDiagnosticBuffer()
            diagnostics.start { buffer.append($0) }
            let proxy = try IPTVPlaybackProxy(
                origin: XCTUnwrap(URL(string: "https://provider.test/private/channel.ts")),
                headers: [:], configuration: IPTVFixture.configuration(), diagnostics: diagnostics
            )
            addTeardownBlock { await proxy.stop() }
            let url = try await proxy.start()
            let state = try XCTUnwrap(PlaybackDeliveryFailure.state(for: url))
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            for _ in 0..<2 {
                let (body, response) = try await session.data(from: url)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502, format)
                XCTAssertTrue(body.isEmpty, format)
            }
            XCTAssertEqual(IPTVFixture.state.requests.count, 1, format)
            XCTAssertEqual(state.error, .invalidResponse, format)
            XCTAssertEqual(state.diagnostic?.httpStatus, 200, "Keep the actual upstream status.")
            XCTAssertEqual(state.diagnostic?.format.rawValue, format)
            XCTAssertEqual(state.evidence.firstFailure?.format.rawValue, format)
            XCTAssertEqual(state.evidence.firstFailure?.outcome, .upstreamFailure)
            XCTAssertLessThanOrEqual(state.evidence.firstFailure?.receivedBytes ?? Int.max, 16)
            XCTAssertEqual(buffer.values.count, 1)
            let encoded = String(decoding: try JSONEncoder().encode(state.evidence), as: UTF8.self)
            XCTAssertFalse(encoded.contains("fixture-secret"))
            XCTAssertFalse(encoded.contains("private"))
            await proxy.stop()
        }
    }

    func testBodyRecognitionLeavesUnknownAndMediaPrefixesAlone() {
        for text in ["#EXTM3U\n", "<htmlish>", "<?xmlish>", "{broken}", "[not-json]", "fixture"] {
            XCTAssertNil(IPTVPlaybackProxy.nonVideoBodyFormat(Data(text.utf8)), text)
        }
        for bytes in [
            Data([0, 0, 0, 24]) + Data("ftypisom".utf8),
            Data([0x1a, 0x45, 0xdf, 0xa3, 0x01, 0xff]),
            Data([0x47, 0x40, 0x00, 0x10]) + Data(repeating: 0xff, count: 12)
        ] {
            XCTAssertNil(IPTVPlaybackProxy.nonVideoBodyFormat(bytes))
        }
        XCTAssertEqual(IPTVPlaybackProxy.nonVideoBodyFormat(Data("[]".utf8)), .json)
        XCTAssertEqual(IPTVPlaybackProxy.nonVideoBodyFormat(Data("<MediaContainer>".utf8)), .xml)
    }

    func testNonVideoResponseAfterThrottleRetainsTheNewCauseAndOldRequestHistory() async throws {
        IPTVFixture.state.handler = { _ in
            IPTVFixture.state.requests.count == 1
                ? (429, ["Retry-After": "0"], Data())
                : (200, [:], Data(#"{"error":"private"}"#.utf8))
        }
        let proxy = try IPTVPlaybackProxy(
            origin: XCTUnwrap(URL(string: "https://provider.test/live.ts")),
            headers: [:], configuration: IPTVFixture.configuration()
        )
        addTeardownBlock { await proxy.stop() }
        let url = try await proxy.start()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for _ in 0..<3 { _ = try await session.data(from: url) }
        let state = try XCTUnwrap(PlaybackDeliveryFailure.state(for: url))
        XCTAssertEqual(state.error, .invalidResponse)
        XCTAssertEqual(state.diagnostic?.httpStatus, 200)
        XCTAssertEqual(state.diagnostic?.format, .json)
        XCTAssertEqual(state.evidence.firstFailure?.status, 429)
        XCTAssertEqual(state.evidence.recent.last?.format, .json)
        XCTAssertEqual(IPTVFixture.state.requests.count, 2)
    }

    func testEncryptedChildrenRangesHeadsAndOnDemandBodiesStayOpaque() async throws {
        let opaque = Data("<!DOCTYPE html>!".utf8)
        let manifest = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="key"
        #EXTINF:6,
        segment.ts
        """
        IPTVFixture.state.handler = { request in
            if request.httpMethod == "HEAD" { return (200, ["Content-Length": "16"], Data()) }
            if request.value(forHTTPHeaderField: "Range") != nil || request.url?.path == "/partial" {
                return (206, ["Content-Range": "bytes 64-79/128"], opaque)
            }
            if request.url?.path == "/live.m3u8" {
                return (200, ["Content-Type": "text/html"], Data(manifest.utf8))
            }
            return (200, ["Content-Type": "application/octet-stream"], opaque)
        }
        let proxy = try IPTVPlaybackProxy(
            origin: XCTUnwrap(URL(string: "https://provider.test/live.m3u8")),
            headers: [:], configuration: IPTVFixture.configuration()
        )
        addTeardownBlock { await proxy.stop() }
        let url = try await proxy.start()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (body, response) = try await session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let text = String(decoding: body, as: UTF8.self)
        let key = try XCTUnwrap(text.components(separatedBy: "\"").first(where: { $0.hasPrefix("http://") }))
        let segment = try XCTUnwrap(text.split(separator: "\n").first(where: { $0.hasPrefix("http://") }))
        for child in [key, String(segment)] {
            let (received, response) = try await session.data(from: XCTUnwrap(URL(string: child)))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(received, opaque)
        }
        var range = URLRequest(url: url)
        range.setValue("bytes=64-79", forHTTPHeaderField: "Range")
        let (ranged, rangeResponse) = try await session.data(for: range)
        XCTAssertEqual((rangeResponse as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(ranged, opaque)
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        let (_, headResponse) = try await session.data(for: head)
        XCTAssertEqual((headResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertNil(PlaybackDeliveryFailure.state(for: url)?.error)

        for (path, content, status) in [
            ("movie", PlaybackFailureDiagnostic.Content.onDemand, 200), ("partial", .live, 206)
        ] {
            let relay = try IPTVPlaybackProxy(
                origin: XCTUnwrap(URL(string: "https://provider.test/" + path)),
                headers: [:], configuration: IPTVFixture.configuration(), content: content
            )
            addTeardownBlock { await relay.stop() }
            let address = try await relay.start()
            let (received, response) = try await session.data(from: address)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, status)
            XCTAssertEqual(received, opaque)
            XCTAssertNil(PlaybackDeliveryFailure.state(for: address)?.error)
        }
    }

    func testSuccessfulManifestAndFailedChildBothReachTheRetainedPlaybackEvidence() async throws {
        let manifest = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:123
        #EXTINF:6.5,private channel title
        private-segment.ts?token=secret
        #EXT-X-ENDLIST
        """
        IPTVFixture.state.handler = { request in
            if request.url?.pathExtension == "ts" {
                return (404, ["Content-Type": "text/html"], Data("private provider error".utf8))
            }
            return (200, ["Content-Type": "application/octet-stream"], Data(manifest.utf8))
        }
        let proxy = try IPTVPlaybackProxy(
            origin: XCTUnwrap(URL(string: "https://provider.test/private/live?token=secret")),
            headers: [:], configuration: IPTVFixture.configuration()
        )
        addTeardownBlock { await proxy.stop() }
        let url = try await proxy.start()
        let state = try XCTUnwrap(PlaybackDeliveryFailure.state(for: url))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (body, response) = try await session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let child = try XCTUnwrap(String(decoding: body, as: UTF8.self).split(separator: "\n")
            .first { $0.hasPrefix("http://") }.flatMap { URL(string: String($0)) })
        _ = try await session.data(from: child)
        let evidence = state.evidence
        XCTAssertEqual(evidence.root?.format, .hls, "Use sniffed response facts, not the opaque proxy URL.")
        XCTAssertEqual(evidence.root?.playlist?.targetDurationMilliseconds, 6_000)
        XCTAssertEqual(evidence.root?.playlist?.maximumSegmentMilliseconds, 6_500)
        XCTAssertEqual(evidence.root?.playlist?.mediaSequence, 123)
        XCTAssertEqual(evidence.root?.receivedBytes, manifest.utf8.count)
        XCTAssertEqual(evidence.firstFailure?.resource, .child)
        XCTAssertEqual(evidence.firstFailure?.status, 404)
        XCTAssertEqual(evidence.firstFailure?.format, .html)
        XCTAssertNil(state.error, "Do not alter the existing fallback policy.")
        let text = String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
        for secret in ["private", "token", "secret", "127.0.0.1"] { XCTAssertFalse(text.contains(secret)) }
        await proxy.stop()
        XCTAssertEqual(state.evidence.firstFailure?.status, 404)
    }

    func testRangeAndPlaylistFactsDoNotRetainArbitraryHeaderOrManifestText() {
        XCTAssertEqual(IPTVPlaybackProxy.rangeEvidence(nil), .absent)
        XCTAssertEqual(IPTVPlaybackProxy.rangeEvidence("bytes 10-19/20"), .valid)
        XCTAssertEqual(IPTVPlaybackProxy.rangeEvidence("bytes */20"), .valid)
        for value in ["bytes 20-10/30", "bytes 10-20/15", "bytes secret", "https://private.test"] {
            XCTAssertEqual(IPTVPlaybackProxy.rangeEvidence(value), .invalid)
        }
        let value = IPTVPlaybackProxy.playlistEvidence("""
        #EXTM3U
        #EXT-X-TARGETDURATION:secret
        #EXT-X-MEDIA-SEQUENCE:99999999999999999999999999
        #EXT-X-KEY:METHOD=AES-128,URI="https://private.test/key"
        #EXT-X-MAP:URI="private-init"
        #EXT-X-BYTERANGE:16
        #EXTINF:nan,private
        private.ts
        """)
        XCTAssertNil(value.targetDurationMilliseconds)
        XCTAssertNil(value.maximumSegmentMilliseconds)
        XCTAssertNil(value.mediaSequence)
        XCTAssertTrue(value.hasEncryption)
        XCTAssertTrue(value.hasMap)
        XCTAssertTrue(value.hasByteRanges)
        XCTAssertTrue(value.isValid)
        XCTAssertTrue(IPTVPlaybackProxy.playlistEvidence(
            "#EXT-X-KEY:URI=\"https://private.test/key,METHOD=NONE\",METHOD=AES-128"
        ).hasEncryption)
        XCTAssertFalse(IPTVPlaybackProxy.playlistEvidence(
            "#EXT-X-KEY:METHOD=NONE,URI=\"https://private.test/key,METHOD=AES-128\""
        ).hasEncryption)
    }

    func testPreconnectRefusalsAndNonVideoBodiesRecordDiagnosticsWithoutSecondUpstreamRequest() async throws {
        struct Case {
            let label: String
            let status: Int
            let headers: [String: String]
            let body: Data
            let expectedLoopbackStatus: Int
            let expectedError: AppError?
        }
        let cases: [Case] = [
            Case(
                label: "401", status: 401, headers: ["Content-Type": "text/html"],
                body: Data("private-401".utf8), expectedLoopbackStatus: 401, expectedError: .unauthorized
            ),
            Case(
                label: "429", status: 429, headers: ["Retry-After": "30"],
                body: Data("private-429".utf8), expectedLoopbackStatus: 429,
                expectedError: .rateLimited(retryAfter: 30)
            ),
            Case(
                label: "451", status: 451, headers: [:],
                body: Data("private-451".utf8), expectedLoopbackStatus: 451,
                expectedError: .accessRestricted
            ),
            Case(
                label: "503-limit", status: 503, headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"All active M3U profiles have reached maximum connection limits","secret":"private"}"#.utf8),
                expectedLoopbackStatus: 503, expectedError: .conflict
            ),
            Case(
                label: "200-html", status: 200, headers: ["Content-Type": "video/mp2t"],
                body: Data("<!DOCTYPE html><html>private-login</html>".utf8),
                expectedLoopbackStatus: 502, expectedError: .invalidResponse
            ),
            Case(
                label: "200-empty", status: 200, headers: ["Content-Type": "video/mp2t"],
                body: Data(), expectedLoopbackStatus: 502, expectedError: .invalidResponse
            ),
            Case(
                label: "404-recoverable", status: 404, headers: ["Content-Type": "text/plain"],
                body: Data("private-404".utf8), expectedLoopbackStatus: 404, expectedError: nil
            )
        ]
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for item in cases {
            IPTVFixture.state.reset()
            IPTVFixture.state.handler = { _ in (item.status, item.headers, item.body) }
            let buffer = ProxyDiagnosticBuffer()
            let diagnostics = PlaybackFailureDiagnostics()
            diagnostics.start { buffer.append($0) }
            let proxy = try IPTVPlaybackProxy(
                origin: XCTUnwrap(URL(string: "https://provider.test/private/live.ts")),
                headers: ["Authorization": "Bearer private-secret"],
                configuration: IPTVFixture.configuration(), diagnostics: diagnostics
            )
            addTeardownBlock { await proxy.stop() }
            let url = try await proxy.start()
            let state = try XCTUnwrap(PlaybackDeliveryFailure.state(for: url))

            await proxy.preconnectDirectLive()
            let (body, response) = try await session.data(from: url)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, item.expectedLoopbackStatus, item.label)
            XCTAssertTrue(body.isEmpty, item.label)
            if item.status == 429 {
                XCTAssertNotNil(http.value(forHTTPHeaderField: "Retry-After"), item.label)
            }
            XCTAssertEqual(
                IPTVFixture.state.requests.count, 1,
                "\(item.label): preconnect failure must not trigger a duplicate upstream request."
            )
            XCTAssertEqual(state.error, item.expectedError, item.label)
            XCTAssertEqual(buffer.values.count, 1, item.label)
            XCTAssertEqual(state.evidence.firstFailure?.outcome, .upstreamFailure, item.label)
            let encoded = String(decoding: try JSONEncoder().encode(state.evidence), as: UTF8.self)
            XCTAssertFalse(encoded.contains("private"), item.label)
            await proxy.stop()
        }
    }

    func testAdoptedPreconnectMidStreamTruncationFinalizesOriginalRequestEvidence() async throws {
        var payload = Data(repeating: 0x00, count: 4_096)
        for index in stride(from: 0, to: payload.count, by: 188) { payload[index] = 0x47 }
        let source = try IPTVTestHTTPServer { _ in
            .init(data: payload, headers: ["Content-Type": "video/mp2t"], cutoff: 1_024, chunkSize: 512)
        }
        let origin = try await source.start().appendingPathComponent("live.ts")
        addTeardownBlock { await source.stop() }
        let proxy = try IPTVPlaybackProxy(origin: origin, headers: [:])
        addTeardownBlock { await proxy.stop() }
        let url = try await proxy.start()
        let state = try XCTUnwrap(PlaybackDeliveryFailure.state(for: url))

        await proxy.preconnectDirectLive()
        let deadline = ContinuousClock.now + .seconds(5)
        while await source.requestCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        _ = try? await session.data(from: url)

        let requests = await source.requestCount
        XCTAssertEqual(requests, 1)
        let settleDeadline = ContinuousClock.now + .seconds(2)
        while state.evidence.recent.last?.outcome == .receiving, ContinuousClock.now < settleDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let recorded = try XCTUnwrap(state.evidence.recent.last)
        XCTAssertEqual(recorded.status, 200)
        XCTAssertEqual(recorded.outcome, .upstreamFailure)
        XCTAssertEqual(recorded.receivedBytes, 1_024)
    }
}

private final class ProxyDiagnosticBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PlaybackFailureDiagnostic] = []
    var values: [PlaybackFailureDiagnostic] { lock.withLock { storage } }
    func append(_ value: PlaybackFailureDiagnostic) { lock.withLock { storage.append(value) } }
}
