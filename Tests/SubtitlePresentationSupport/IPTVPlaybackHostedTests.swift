import AVFoundation
import CoreModels
import EnginePlozzigen
import FeaturePlayback
import Foundation
import UIKit
import XCTest
@testable import ProviderIPTV

@MainActor
final class IPTVPlaybackHostedTests: XCTestCase {
    func testRepeatedNativeMovieReopensReleaseItemsAndStillAllowIPTVPlayback() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "embedded", withExtension: "mp4", subdirectory: "Fixtures"
        ))
        var retiredPlayers: [AVPlayer] = []
        for cycle in 0..<12 {
            let engine = NativeVideoEngine(startsMuted: true)
            defer { engine.stop() }
            await engine.load(request: .init(
                item: .init(id: "reopen", title: "Reopen fixture", kind: .movie),
                streamURL: file,
                sourceMetadata: .init(video: .init(codec: "h264")),
                sourceProvider: cycle.isMultiple(of: 2) ? .jellyfin : .plex
            ), startPosition: cycle.isMultiple(of: 2) ? 0 : 3)
            let player = try XCTUnwrap(engine.underlyingPlayer)
            let item = try XCTUnwrap(player.currentItem)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(output)
            let deadline = ContinuousClock.now + .seconds(15)
            var decoded = false
            while ContinuousClock.now < deadline, item.status != .failed {
                if output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) != nil {
                    decoded = true
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            item.remove(output)
            XCTAssertTrue(decoded, "Reopen \(cycle) must decode a frame, not merely construct a player.")
            engine.stop()
            retiredPlayers.append(player)
            XCTAssertTrue(retiredPlayers.allSatisfy { $0.currentItem == nil })
            XCTAssertTrue(item.outputs.isEmpty)
        }
        // Keep retired presentation references alive while the production live
        // engine opens an authenticated HLS stream in the same process.
        try await play(hls: true, fragmented: true)
        XCTAssertEqual(retiredPlayers.count, 12)
        XCTAssertTrue(retiredPlayers.allSatisfy { $0.currentItem == nil })
    }

    func testRawTransportStreamPlaysThroughAuthenticatedIPTVProxy() async throws {
        try await play(hls: false)
    }

    func testHLSPlaysThroughAuthenticatedIPTVProxy() async throws {
        try await play(hls: true)
    }

    func testDeclaredTransportStreamPlaysWithAnExtensionlessUpstream() async throws {
        try await play(hls: false, extensionless: true)
    }

    func testUndeclaredTransportStreamPlaysWithAnExtensionlessUpstream() async throws {
        try await play(hls: false, extensionless: true, declaresFormat: false)
    }

    func testUndeclaredFragmentedHLSPlaysWithAnExtensionlessUpstream() async throws {
        try await play(hls: true, fragmented: true, extensionless: true, declaresFormat: false)
    }

    func testRedirectedUndeclaredTransportStreamWithGenericMIMEUsesOneOriginStreamAtATime() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "iptv", withExtension: "ts", subdirectory: "Fixtures"
        ))
        let delivery = try IPTVTestHTTPServer { request in
            guard !request.lowercased().contains("x-fixture-account:") else { return .init(status: 403) }
            return .init(file: file, headers: ["Content-Type": "application/octet-stream"], delay: .milliseconds(10))
        }
        addTeardownBlock { await delivery.stop() }
        let destination = try await delivery.start().appendingPathComponent("opaque")
        let entrypoint = try IPTVTestHTTPServer { request in
            guard request.contains("X-Fixture-Account: private") else { return .init(status: 403) }
            return .init(status: 302, headers: ["Location": destination.absoluteString])
        }
        addTeardownBlock { await entrypoint.stop() }
        let origin = try await entrypoint.start().appendingPathComponent("channel")
        let proxy = try IPTVPlaybackProxy(origin: origin, headers: ["X-Fixture-Account": "private"])
        addTeardownBlock { await proxy.stop() }
        try await render(url: proxy.start())
        await proxy.stop()
        try await waitUntil { await delivery.activeRequestCount == 0 }
        let peak = await delivery.peakActiveRequestCount
        XCTAssertEqual(peak, 1, "Classification and playback must not occupy two provider streams.")
    }

    func testDirectUndeclaredTransportStreamAlsoUsesContentInsteadOfItsAddress() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "iptv", withExtension: "ts", subdirectory: "Fixtures"
        ))
        let server = try IPTVTestHTTPServer { _ in
            .init(file: file, headers: ["Content-Type": "application/octet-stream"], delay: .milliseconds(10))
        }
        addTeardownBlock { await server.stop() }
        let origin = try await server.start().appendingPathComponent("channel.php")
        try await render(url: origin)
        try await waitUntil { await server.activeRequestCount == 0 }
        let peak = await server.peakActiveRequestCount
        XCTAssertEqual(peak, 1)
    }

    func testStoppingUndeclaredStreamCancelsInspectionBeforeHeadersOrBody() async throws {
        for beforeHeaders in [true, false] {
            let server = try IPTVTestHTTPServer { _ in
                .init(
                    data: Data(repeating: 0x47, count: 131_072),
                    headerDelay: beforeHeaders ? .seconds(30) : .zero,
                    delay: beforeHeaders ? .zero : .seconds(30)
                )
            }
            addTeardownBlock { await server.stop() }
            let base = try await server.start()
            let proxy = try IPTVPlaybackProxy(origin: base.appendingPathComponent("channel"), headers: [:])
            addTeardownBlock { await proxy.stop() }
            let url = try await proxy.start()
            let engine = try PlozzigenVideoEngine()
            defer { engine.stop() }
            var failure: AppError?
            engine.onFailure = { failure = $0 }
            let load = Task { await engine.loadLive(url: url, httpHeaders: [:]) }
            try await waitUntil { await server.activeRequestCount == 1 }
            XCTAssertEqual(engine.liveSnapshot.phase, .loading)
            XCTAssertFalse(engine.liveSnapshot.firstFrameReady)
            engine.stop()
            await load.value
            try await waitUntil { await server.activeRequestCount == 0 }
            XCTAssertNil(failure)
            XCTAssertEqual(engine.liveSnapshot.phase, .idle)
            await proxy.stop()
        }
    }

    func testUndeclaredStreamRefusalIsTypedAndDoesNotStartAnotherRequest() async throws {
        let server = try IPTVTestHTTPServer { _ in .init(status: 451) }
        addTeardownBlock { await server.stop() }
        let base = try await server.start()
        let engine = try PlozzigenVideoEngine()
        defer { engine.stop() }
        var failure: AppError?
        engine.onFailure = { failure = $0 }
        await engine.loadLive(url: base.appendingPathComponent("channel"), httpHeaders: [:])
        try await waitUntil { failure != nil }
        XCTAssertEqual(failure, .accessRestricted)
        XCTAssertEqual(engine.liveSnapshot.phase, .failed)
        let requests = await server.requestCount
        XCTAssertEqual(requests, 1)
    }

    func testDeclaredFragmentedHLSPlaysWithAnExtensionlessUpstream() async throws {
        try await play(hls: true, fragmented: true, extensionless: true)
    }

    func testFragmentedMP4HLSKeepsNativePlaybackThroughAuthenticatedProxy() async throws {
        try await play(hls: true, fragmented: true)
    }

    func testProviderAccessRestrictionSurvivesNativePlaybackFailureWithoutRetryingUpstream() async throws {
        let server = try IPTVTestHTTPServer { _ in .init(data: Data("blocked".utf8), status: 451) }
        addTeardownBlock { await server.stop() }
        let base = try await server.start()
        let proxy = try IPTVPlaybackProxy(origin: base.appendingPathComponent("channel.m3u8"), headers: [:])
        addTeardownBlock { await proxy.stop() }
        let url = try await proxy.start()
        let engine = try PlozzigenVideoEngine()
        defer { engine.stop() }
        var failure: AppError?
        engine.onFailure = { failure = $0 }
        await engine.loadLive(url: url, httpHeaders: [:])
        let deadline = ContinuousClock.now + .seconds(25)
        while failure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(failure, .accessRestricted)
        let requests = await server.requestCount
        XCTAssertEqual(requests, 1, "Native engine retries must not repeatedly contact the rejecting provider.")
    }

    func testNativeHLSFailureRetainsSuccessfulPlaylistAndFailedChildWithoutPrivateData() async throws {
        let server = try IPTVTestHTTPServer { request in
            if request.contains("/private-channel.m3u8") {
                return .init(data: Data("""
                #EXTM3U
                #EXT-X-TARGETDURATION:6
                #EXT-X-MEDIA-SEQUENCE:100
                #EXTINF:6,
                private-segment.ts?token=secret
                #EXT-X-ENDLIST

                """.utf8), headers: ["Content-Type": "application/vnd.apple.mpegurl"])
            }
            return .init(data: Data("private failure".utf8), status: 404, headers: ["Content-Type": "text/html"])
        }
        addTeardownBlock { await server.stop() }
        let base = try await server.start()
        let proxy = try IPTVPlaybackProxy(origin: base.appendingPathComponent("private-channel.m3u8"), headers: [:])
        addTeardownBlock { await proxy.stop() }
        let engine = try PlozzigenVideoEngine()
        defer { engine.stop() }
        var report: LiveChannelFailureReport?
        engine.onFailure = { error in
            report = .init(failure: .engine(error), diagnostic: engine.livePlaybackFailureDiagnostic)
        }
        defer { engine.onFailure = nil }
        let url = try await proxy.start()
        await engine.loadLive(url: url, httpHeaders: [:])
        let deadline = ContinuousClock.now + .seconds(25)
        while report == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let failure = try XCTUnwrap(report)
        let evidence = try XCTUnwrap(failure.diagnostic?.evidence)
        XCTAssertEqual(evidence.firstFrameReady, false)
        XCTAssertNotNil(evidence.route)
        XCTAssertEqual(evidence.nativeCapture, .captured)
        XCTAssertFalse(evidence.nativeErrors.isEmpty, "Retain the actual native failure, not only the relay status.")
        XCTAssertEqual(evidence.delivery?.root?.format, .hls)
        XCTAssertEqual(evidence.delivery?.root?.playlist?.mediaSequence, 100)
        XCTAssertEqual(evidence.delivery?.firstFailure?.status, 404)
        XCTAssertEqual(evidence.delivery?.firstFailure?.resource, .child)
        let text = PlaybackDiagnosticReport.playback(failure).supportText
        XCTAssertTrue(text.contains("upstream_first_failure.http_status=404"))
        for secret in ["private", "token", "secret", base.absoluteString] {
            XCTAssertFalse(text.contains(secret))
        }
    }

    func testOptInTrialChannelSustainsPlaybackThroughTheProductionEngine() async throws {
        let control = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/iptv-performance-source.json")
        guard FileManager.default.fileExists(atPath: control.path) else {
            throw XCTSkip("An explicitly enabled, owned local relay is required.")
        }
        struct Source: Decodable { let liveURL: String?; let allowPlayback: Bool? }
        let source = try JSONDecoder().decode(Source.self, from: Data(contentsOf: control))
        guard source.allowPlayback == true else { throw XCTSkip("Trial playback was not explicitly enabled.") }
        let origin = try XCTUnwrap(source.liveURL.flatMap(URL.init(string:)))
        XCTAssertEqual(origin.host, "127.0.0.1")
        guard origin.host == "127.0.0.1" else { return }
        let proxy = try IPTVPlaybackProxy(origin: origin, headers: [:], formatHint: .init(container: "ts"))
        addTeardownBlock { await proxy.stop() }
        try await render(url: proxy.start(), sustainedSeconds: 20)
    }

    private func play(
        hls: Bool, fragmented: Bool = false, extensionless: Bool = false, declaresFormat: Bool = true
    ) async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "iptv", withExtension: "ts", subdirectory: "Fixtures"
        ))
        let initialization = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "iptv-init", withExtension: "mp4", subdirectory: "Fixtures"
        ))
        let segment = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "iptv-segment-0", withExtension: "m4s", subdirectory: "Fixtures"
        ))
        let server = try IPTVTestHTTPServer { request in
            guard request.contains("Authorization: Bearer fixture") else { return .init(status: 403) }
            if request.contains("/master.m3u8") || (hls && extensionless && request.contains("/channel HTTP")) {
                return .init(data: Data("""
                #EXTM3U
                #EXT-X-VERSION:\(fragmented ? 7 : 3)
                #EXT-X-TARGETDURATION:12
                #EXT-X-MEDIA-SEQUENCE:0
                \(fragmented ? "#EXT-X-MAP:URI=\"iptv-init.mp4\"" : "")
                #EXTINF:12,
                \(fragmented ? "iptv-segment-0.m4s" : "channel.ts")
                #EXT-X-ENDLIST

                """.utf8), headers: ["Content-Type": "application/vnd.apple.mpegurl"])
            }
            if request.contains("/iptv-init.mp4") {
                return .init(file: initialization, headers: ["Content-Type": "video/mp4"])
            }
            if request.contains("/iptv-segment-0.m4s") {
                return .init(file: segment, headers: ["Content-Type": "video/mp4"])
            }
            return .init(file: file, headers: ["Content-Type": "video/mp2t"])
        }
        addTeardownBlock { await server.stop() }
        let base = try await server.start()
        let proxy = try IPTVPlaybackProxy(
            origin: base.appendingPathComponent(extensionless ? "channel" : hls ? "master.m3u8" : "channel.ts"),
            headers: ["Authorization": "Bearer fixture"],
            formatHint: extensionless && declaresFormat ? .init(container: hls ? "m3u8" : "ts") : .init()
        )
        addTeardownBlock { await proxy.stop() }
        let url = try await proxy.start()
        try await render(url: url)
    }

    private func render(url: URL, sustainedSeconds: TimeInterval = 0) async throws {
        let engine = try PlozzigenVideoEngine()
        defer { engine.stop() }
        let sceneDeadline = ContinuousClock.now + .seconds(5)
        while UIApplication.shared.connectedScenes.isEmpty, ContinuousClock.now < sceneDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.frame = scene.coordinateSpace.bounds
        window.makeKeyAndVisible()
        let video = engine.makeVideoOutputView()
        video.frame = controller.view.bounds
        video.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(video)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let started = Date()
        await engine.loadLive(url: url, httpHeaders: [:])
        let deadline = ContinuousClock.now + .seconds(sustainedSeconds > 0 ? 60 : 25)
        while ContinuousClock.now < deadline, engine.liveSnapshot.phase != .failed {
            if engine.liveSnapshot.firstFrameReady, engine.liveSnapshot.position > 0.2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotEqual(engine.liveSnapshot.phase, .failed, "The actual production live engine must open this stream")
        XCTAssertTrue(engine.liveSnapshot.firstFrameReady, "Require a rendered frame, not just a successful URL request")
        XCTAssertGreaterThan(engine.liveSnapshot.position, 0.2)
        if sustainedSeconds > 0, engine.liveSnapshot.firstFrameReady {
            let firstFrameSeconds = Date().timeIntervalSince(started)
            let initialPosition = engine.liveSnapshot.position
            let until = Date().addingTimeInterval(sustainedSeconds)
            while Date() < until, engine.liveSnapshot.phase != .failed {
                try await Task.sleep(for: .milliseconds(200))
            }
            let advanced = engine.liveSnapshot.position - initialPosition
            XCTAssertNotEqual(engine.liveSnapshot.phase, .failed)
            XCTAssertGreaterThan(advanced, sustainedSeconds * 0.75, "Playback must keep advancing after startup.")
            print("IPTV_LIVE_PROBE first_frame_seconds=\(firstFrameSeconds) observed_seconds=\(sustainedSeconds) advanced_seconds=\(advanced)")
        }
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, "The owned playback request did not reach its expected lifecycle state.")
    }
}
