import CoreModels
import Foundation
import XCTest
@testable import ProviderIPTV

final class IPTVPlaybackLifecycleTests: XCTestCase {
    func testClientDisconnectCancelsAnUpstreamStalledBeforeHeadersOrBody() async throws {
        for beforeHeaders in [true, false] {
            let source = try IPTVTestHTTPServer { _ in
                .init(
                    data: Data(repeating: 0x47, count: 131_072),
                    headerDelay: beforeHeaders ? .seconds(30) : .zero,
                    delay: beforeHeaders ? .zero : .seconds(30)
                )
            }
            let origin = try await source.start()
            addTeardownBlock { await source.stop() }
            let proxy = try IPTVPlaybackProxy(origin: origin.appendingPathComponent("live.ts"), headers: [:])
            addTeardownBlock { await proxy.stop() }
            let url = try await proxy.start()
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let request = Task { try await session.data(from: url) }
            try await waitUntil { await source.activeRequestCount == 1 }

            request.cancel()
            _ = await request.result
            try await waitUntil { await source.activeRequestCount == 0 }
            await proxy.stop()
        }
    }

    func testLiveRootProbesNeverOpenTwoUpstreamStreamsAtOnce() async throws {
        let source = try IPTVTestHTTPServer { _ in
            .init(data: Data(repeating: 0x47, count: 131_072), delay: .seconds(30))
        }
        let origin = try await source.start()
        addTeardownBlock { await source.stop() }
        let proxy = try IPTVPlaybackProxy(origin: origin.appendingPathComponent("live.ts"), headers: [:])
        addTeardownBlock { await proxy.stop() }
        let url = try await proxy.start()
        let firstSession = URLSession(configuration: .ephemeral)
        let secondSession = URLSession(configuration: .ephemeral)
        defer { firstSession.invalidateAndCancel(); secondSession.invalidateAndCancel() }
        let first = Task { try await firstSession.data(from: url) }
        try await waitUntil { await source.requestCount == 1 }
        let second = Task { try await secondSession.data(from: url) }
        try await Task.sleep(for: .milliseconds(200))
        let beforeCancellation = await source.requestCount
        XCTAssertEqual(beforeCancellation, 1)

        first.cancel()
        _ = await first.result
        try await waitUntil { await source.requestCount == 2 }
        let peak = await source.peakActiveRequestCount
        XCTAssertEqual(peak, 1)
        second.cancel()
        _ = await second.result
        await proxy.stop()
        try await waitUntil { await source.activeRequestCount == 0 }
    }

    func testConcurrentStopsDrainTheStreamAndQueuedRootRequests() async throws {
        let source = try IPTVTestHTTPServer { _ in
            .init(data: Data(repeating: 0x47, count: 131_072), delay: .seconds(30))
        }
        let origin = try await source.start()
        addTeardownBlock { await source.stop() }
        let proxy = try IPTVPlaybackProxy(origin: origin.appendingPathComponent("live.ts"), headers: [:])
        addTeardownBlock { await proxy.stop() }
        let url = try await proxy.start()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let first = Task { try await session.data(from: url) }
        try await waitUntil { await source.requestCount == 1 }
        let second = Task { try await session.data(from: url) }
        let start = ContinuousClock.now
        async let stopOne: Void = proxy.stop()
        async let stopTwo: Void = proxy.stop()
        _ = await (stopOne, stopTwo)
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
        _ = await (first.result, second.result)
        try await waitUntil { await source.activeRequestCount == 0 }
        XCTAssertNil(PlaybackDeliveryFailure.state(for: url))
        let count = await source.requestCount
        XCTAssertEqual(count, 1)
    }

    func testPreconnectCachesHLSManifestAndServesPlayerWithOneUpstreamFetch() async throws {
        let playlist = Data("#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2.0,\nseg0.ts\n".utf8)
        let source = try IPTVTestHTTPServer { _ in
            .init(data: playlist, headers: ["Content-Type": "application/vnd.apple.mpegurl"])
        }
        let origin = try await source.start().appendingPathComponent("live.m3u8")
        addTeardownBlock { await source.stop() }
        let proxy = try IPTVPlaybackProxy(origin: origin, headers: [:])
        addTeardownBlock { await proxy.stop() }
        let url = try await proxy.start()

        await proxy.preconnectDirectLive()
        try await waitUntil { await source.requestCount == 1 }

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let body = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(body.hasPrefix("#EXTM3U"))
        XCTAssertTrue(body.contains("http://127.0.0.1:"))
        let count = await source.requestCount
        XCTAssertEqual(count, 1, "Preconnected HLS manifest must serve the player without a second upstream fetch.")
    }

    func testPreconnectOnExtensionlessChannelServesProbeAndPlayerWithOneUpstreamFetch() async throws {
        var ts = Data(repeating: 0x00, count: 188 * 4)
        for index in 0..<4 { ts[index * 188] = 0x47 }
        let tsSource = try IPTVTestHTTPServer { _ in
            .init(data: ts, headers: ["Content-Type": "application/octet-stream"])
        }
        let tsOrigin = try await tsSource.start().appendingPathComponent("channel")
        addTeardownBlock { await tsSource.stop() }
        let tsProxy = try IPTVPlaybackProxy(origin: tsOrigin, headers: [:])
        addTeardownBlock { await tsProxy.stop() }
        let tsURL = try await tsProxy.start()

        await tsProxy.preconnectDirectLive()
        try await waitUntil { await tsSource.requestCount == 1 }

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var probe = URLRequest(url: tsURL)
        probe.setValue("1", forHTTPHeaderField: "X-Plozz-Format-Probe")
        let (probeData, probeResponse) = try await session.data(for: probe)
        XCTAssertEqual((probeResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertGreaterThanOrEqual(probeData.count, 377)

        var player = URLRequest(url: tsURL)
        player.setValue("bytes=0-", forHTTPHeaderField: "Range")
        let (streamData, streamResponse) = try await session.data(for: player)
        XCTAssertEqual((streamResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(streamData, ts)
        let tsRequests = await tsSource.requestCount
        XCTAssertEqual(tsRequests, 1, "Preconnect + format probe + TS player load must open only one upstream stream.")

        let hlsBody = Data("#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2.0,\nseg0.ts\n".utf8)
        let hlsSource = try IPTVTestHTTPServer { _ in
            .init(data: hlsBody, headers: ["Content-Type": "application/vnd.apple.mpegurl"])
        }
        let hlsOrigin = try await hlsSource.start().appendingPathComponent("channel")
        addTeardownBlock { await hlsSource.stop() }
        let hlsProxy = try IPTVPlaybackProxy(origin: hlsOrigin, headers: [:])
        addTeardownBlock { await hlsProxy.stop() }
        let hlsURL = try await hlsProxy.start()

        await hlsProxy.preconnectDirectLive()
        try await waitUntil { await hlsSource.requestCount == 1 }

        var hlsProbe = URLRequest(url: hlsURL)
        hlsProbe.setValue("1", forHTTPHeaderField: "X-Plozz-Format-Probe")
        let (hlsProbeData, _) = try await session.data(for: hlsProbe)
        let (hlsPlayerData, _) = try await session.data(from: hlsURL)
        XCTAssertEqual(hlsProbeData, hlsPlayerData)
        let hlsRequests = await hlsSource.requestCount
        XCTAssertEqual(hlsRequests, 1, "Preconnect + format probe + HLS player load must fetch upstream once.")
    }

    func testLoopbackHeadRequestSerializesWithInFlightAndHeldPreconnect() async throws {
        let delayedSource = try IPTVTestHTTPServer { _ in
            .init(
                data: Data(repeating: 0x47, count: 1_024),
                headers: ["Content-Type": "video/mp2t"],
                headerDelay: .milliseconds(200)
            )
        }
        let delayedOrigin = try await delayedSource.start().appendingPathComponent("live.ts")
        addTeardownBlock { await delayedSource.stop() }
        let delayedProxy = try IPTVPlaybackProxy(origin: delayedOrigin, headers: [:])
        addTeardownBlock { await delayedProxy.stop() }
        let delayedURL = try await delayedProxy.start()

        await delayedProxy.preconnectDirectLive()
        try await waitUntil { await delayedSource.activeRequestCount == 1 }

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var head = URLRequest(url: delayedURL)
        head.httpMethod = "HEAD"
        let (_, headResponse) = try await session.data(for: head)
        XCTAssertEqual((headResponse as? HTTPURLResponse)?.statusCode, 200)
        let delayedPeak = await delayedSource.peakActiveRequestCount
        XCTAssertEqual(delayedPeak, 1, "Loopback HEAD must cancel and drain in-flight preconnect before opening HEAD.")

        var heldData = Data(repeating: 0x00, count: 65_536)
        for index in stride(from: 0, to: heldData.count, by: 188) { heldData[index] = 0x47 }
        let heldSource = try IPTVTestHTTPServer { request in
            .init(
                data: heldData,
                headers: ["Content-Type": "video/mp2t"],
                delay: request.hasPrefix("HEAD ") ? .zero : .milliseconds(500),
                chunkSize: 512
            )
        }
        let heldOrigin = try await heldSource.start().appendingPathComponent("live.ts")
        addTeardownBlock { await heldSource.stop() }
        let heldProxy = try IPTVPlaybackProxy(origin: heldOrigin, headers: [:])
        addTeardownBlock { await heldProxy.stop() }
        let heldURL = try await heldProxy.start()

        await heldProxy.preconnectDirectLive()
        try await waitUntil { await heldSource.bodyBytesSent >= 512 }

        var secondHead = URLRequest(url: heldURL)
        secondHead.httpMethod = "HEAD"
        let (_, secondResponse) = try await session.data(for: secondHead)
        XCTAssertEqual((secondResponse as? HTTPURLResponse)?.statusCode, 200)
        try await waitUntil { await heldSource.activeRequestCount == 0 }
        let heldPeak = await heldSource.peakActiveRequestCount
        XCTAssertEqual(heldPeak, 1, "Loopback HEAD must close a held preconnect stream before opening HEAD.")
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, "The owned upstream request did not reach the expected lifecycle state.")
    }
}
