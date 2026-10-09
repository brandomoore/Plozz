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

    func testProxyRetainsOriginalHTTPFailureBeforeReturningGenericGatewayError() async throws {
        for status in [401, 403, 404, 429, 503] {
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
                let (_, response) = try await session.data(from: url)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502)
            }

            let failure = try XCTUnwrap(buffer.values.first)
            XCTAssertEqual(buffer.values.count, 1)
            XCTAssertEqual(failure.httpStatus, status)
            XCTAssertEqual(failure.stage, .response)
            XCTAssertEqual(failure.format, .html)
            XCTAssertNil(failure.code)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(failure), as: UTF8.self).contains("private"))
            await proxy.stop()
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
    }
}

private final class ProxyDiagnosticBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PlaybackFailureDiagnostic] = []
    var values: [PlaybackFailureDiagnostic] { lock.withLock { storage } }
    func append(_ value: PlaybackFailureDiagnostic) { lock.withLock { storage.append(value) } }
}
