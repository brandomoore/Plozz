import AVFoundation
import CoreModels
import EnginePlozzigen
import Foundation
import UIKit
import XCTest
@testable import AppRuntime
@testable import FeaturePlayback
@testable import ProviderIPTV

@MainActor
final class IPTVContinuityHostedTests: XCTestCase {
    func testRollingTransportStreamHLSKeepsPresentingFrames() async throws {
        try await exercise(fragmented: false)
    }

    func testRollingFragmentedHLSKeepsPresentingFrames() async throws {
        try await exercise(fragmented: true, observationSeconds: 60)
    }

    func testExplicitLiveCushionRetainsRealMediaBehindThePublishedEdge() async throws {
        try await exercise(fragmented: true, buffer: .thirtySeconds)
    }

    func testLongRollingHLSRenewsRepeatedSessionsAndPreservesPauseAcrossBackground() async throws {
        try await exercise(fragmented: true, fault: .longSession, observationSeconds: 330)
    }

    func testRollingHLSRecoversFromADelayedSegment() async throws {
        try await exercise(fragmented: true, fault: .delayedSegment)
    }

    func testRollingHLSRenewsAnExpiredDeliverySession() async throws {
        try await exercise(fragmented: true, fault: .expiredSession)
    }

    func testGuideFailuresDoNotInterruptRollingPlayback() async throws {
        try await exercise(fragmented: true, fault: .guide)
    }

    func testRawTransportStreamRecoversFromAMidstreamDisconnect() async throws {
        try await exercise(fragmented: false, fault: .disconnect)
    }

    func testConnectionLimitReachesThePlayerWithoutExtraUpstreamRequests() async throws {
        try await assertProviderFailure(
            body: #"{"error":"All active M3U profiles have reached maximum connection limits"}"#,
            status: 503, expected: .conflict
        )
    }

    func testNonVideoSuccessReachesThePlayerWithoutExtraUpstreamRequests() async throws {
        for (body, format) in [
            ("<!DOCTYPE html><html>private</html>", PlaybackFailureDiagnostic.Format.html),
            (#"{"error":"private"}"#, .json), ("<?xml version=\"1.0\"?><error/>", .xml), ("", .empty)
        ] {
            try await assertProviderFailure(body: body, status: 200, expected: .invalidResponse, format: format)
        }
    }

    private func assertProviderFailure(
        body: String, status: Int, expected: AppError, format: PlaybackFailureDiagnostic.Format? = nil
    ) async throws {
        let server = try IPTVTestHTTPServer { _ in
            .init(
                data: Data(body.utf8), status: status,
                headers: ["Content-Type": status == 503 ? "application/json" : "video/mp2t"]
            )
        }
        addTeardownBlock { await server.stop() }
        let origin = try await server.start().appendingPathComponent("live.m3u8")
        let proxy = try IPTVPlaybackProxy(origin: origin, headers: [:])
        addTeardownBlock { await proxy.stop() }
        let url = try await proxy.start()
        let engine = try PlozzigenVideoEngine()
        let model = LiveChannelPlayerModel(engine: engine, streamURL: url, isAudible: false)
        defer { model.stop() }
        await model.start()
        let deadline = ContinuousClock.now + .seconds(25)
        while model.failureReport == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let report = try XCTUnwrap(model.failureReport)
        XCTAssertEqual(report.failure, .engine(expected))
        XCTAssertEqual(report.message, format?.nonVideoMessage ?? LiveChannelPlaybackFailure.engineMessage(expected))
        XCTAssertEqual(report.diagnostic?.httpStatus, status)
        if let format { XCTAssertEqual(report.diagnostic?.format, format) }
        let requests = await server.requestCount
        XCTAssertEqual(requests, 1)
        model.stop()
        await proxy.stop()
        await server.stop()
    }

    private func exercise(
        fragmented: Bool, fault: RollingIPTVSource.Fault = .none, observationSeconds: Int = 25,
        buffer: LivePlaybackBuffer = .automatic
    ) async throws {
        let source = try RollingIPTVSource(
            bundle: Bundle(for: Self.self), fragmented: fragmented, fault: fault,
            windowSegments: buffer.seconds.map { Int($0 / 2) + 8 }
        )
        XCTAssertGreaterThan(source.durationSeconds, observationSeconds + 30, "The source must not run out during observation.")
        let server = try IPTVTestHTTPServer(
            beforeBodyChunk: { try source.interruptConnectionIfNeeded() },
            respond: { source.response(to: $0) }
        )
        addTeardownBlock { await server.stop() }
        let base = try await server.start()
        source.setBase(base)
        // SQLite closes off-main; retain its files until the disposable test host is removed.
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("IPTVContinuity")
            .appendingPathComponent(UUID().uuidString)
        let credential = try IPTVCredential(
            mode: .playlist, address: base.appendingPathComponent("playlist.m3u"),
            headers: ["X-Fixture-Account": "private"],
            guideURL: base.appendingPathComponent("guide.xml"),
            guideHeaders: ["X-Fixture-Account": "private"]
        )
        let session = try await IPTVProvider.signIn(
            credential: credential, name: "Continuity", deviceID: "fixture", cacheDirectory: cache
        )
        let provider = try IPTVProvider(
            context: .init(
                session: session, accountID: "fixture", credentialRevision: .init(),
                localMediaContext: .init(accountID: "fixture", profileID: "fixture", profileNamespace: nil)
            ), cacheDirectory: cache, guideLoader: ManagedProviderRegistry.iptvGuideLoader
        )
        addTeardownBlock { await provider.teardown() }
        let channels = try await provider.liveTVChannels()
        let channel = try XCTUnwrap(channels.first)
        let lease = try await provider.openLiveTVChannel(id: channel.id)
        addTeardownBlock { await lease.close() }
        guard case .authenticatedHTTP(let locator) = lease.playbackSource else {
            return XCTFail("The real IPTV lease must own an authenticated relay.")
        }
        let url = try await provider.resolveHTTPResource(locator)
        let engine = try PlozzigenVideoEngine(liveBufferPreference: { buffer })
        let model = LiveChannelPlayerModel(
            engine: engine, channelID: channel.id, streamURL: url, isAudible: false, allowsDisplayMatching: false
        )
        defer { model.stop() }
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

        let started = ContinuousClock.now
        await model.start()
        var capture: (AVPlayerItem, AVPlayerItemVideoOutput)?
        defer { if let capture { capture.0.remove(capture.1) } }
        var firstFrame: ContinuousClock.Instant?
        var lastFrame = started
        var longestGap: Duration = .zero
        var changedFrames = 0
        var lastFingerprint: UInt64?
        var position = engine.liveSnapshot.position
        var advancement: TimeInterval = 0
        var guideCheck: Task<Void, Error>?
        defer { guideCheck?.cancel() }
        var pausedAt: ContinuousClock.Instant?
        var resumed = false
        var liveDistances: [Double] = []
        while ContinuousClock.now < (firstFrame.map { $0 + .seconds(observationSeconds) }
            ?? started + .seconds(30 + (buffer.seconds ?? 0))) {
            if let item = engine.nowPlayingPlayer?.currentItem, capture?.0 !== item {
                if let capture { capture.0.remove(capture.1) }
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ])
                item.add(output)
                capture = (item, output)
            }
            let now = ContinuousClock.now
            if let capture, let player = engine.nowPlayingPlayer,
               capture.1.hasNewPixelBuffer(forItemTime: player.currentTime()),
               let frame = capture.1.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) {
                let fingerprint = Self.fingerprint(frame)
                if fingerprint != lastFingerprint {
                    if firstFrame == nil {
                        firstFrame = now
                        position = engine.liveSnapshot.position
                        source.observedFirstFrame()
                    }
                    else { longestGap = max(longestGap, lastFrame.duration(to: now)) }
                    lastFrame = now
                    lastFingerprint = fingerprint
                    changedFrames += 1
                }
            }
            let nextPosition = engine.liveSnapshot.position
            if firstFrame != nil { advancement += max(0, nextPosition - position) }
            if firstFrame != nil, let player = engine.nowPlayingPlayer {
                let distance = source.publishedEdgeSeconds - player.currentTime().seconds
                if distance.isFinite { liveDistances.append(distance) }
            }
            position = nextPosition
            if fault == .longSession, let firstFrame {
                if pausedAt == nil, now >= firstFrame + .seconds(75) {
                    XCTAssertTrue(model.canPause, "The fixture must advertise a usable native time-shift window.")
                    model.togglePlayPause()
                    XCTAssertEqual(model.phase, .paused)
                    model.handleScenePhase(.inactive)
                    model.handleScenePhase(.background)
                    pausedAt = now
                } else if let pausedAt, !resumed, now >= pausedAt + .seconds(3) {
                    model.handleScenePhase(.active)
                    XCTAssertFalse(model.intendsPlayback, "Foregrounding must preserve explicit pause intent.")
                    XCTAssertEqual(model.phase, .paused)
                    model.togglePlayPause()
                    resumed = true
                }
            }
            if fault == .guide, guideCheck == nil, let firstFrame, now > firstFrame + .seconds(6) {
                // Guide retries must not suspend the decoded-frame sampler.
                guideCheck = Task { @MainActor in
                    let player = engine.nowPlayingPlayer
                    let initial = try await provider.liveTVGuide(
                        channelIDs: [channel.id], from: Date(timeIntervalSince1970: 100),
                        to: Date(timeIntervalSince1970: 500)
                    )
                    XCTAssertEqual(initial.map(\.title), ["Fixture programme"])
                    for status in [503, 200] {
                        source.failGuide(status: status)
                        do {
                            _ = try await provider.liveTVGuide(
                                channelIDs: [channel.id], from: Date(timeIntervalSince1970: 100),
                                to: Date(timeIntervalSince1970: 500)
                            )
                            XCTFail("A failed or malformed guide must remain an error.")
                        } catch {
                            XCTAssertFalse(error is CancellationError)
                            if status == 503 { XCTAssertEqual(error as? IPTVError, .httpStatus(503)) }
                        }
                    }
                    XCTAssertTrue(engine.nowPlayingPlayer === player)
                }
            }
            if model.failureReport != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        longestGap = max(longestGap, lastFrame.duration(to: .now))
        try await guideCheck?.value
        XCTAssertNotNil(firstFrame, "Readiness or a progressing clock is not a decoded picture.")
        XCTAssertNil(model.failureReport)
        XCTAssertTrue(model.hasPresentedFrame)
        XCTAssertEqual(model.manualRetryCount, 0)
        XCTAssertGreaterThan(changedFrames, observationSeconds * 5, "Require changing decoded images across the observation.")
        XCTAssertGreaterThan(advancement, Double(observationSeconds) * 0.72, "Playback must advance throughout observation.")
        if let requested = buffer.seconds {
            XCTAssertFalse(liveDistances.isEmpty)
            let sorted = liveDistances.sorted()
            if !sorted.isEmpty {
                let median = sorted[sorted.count / 2]
                XCTAssertGreaterThanOrEqual(median, requested - 4, "Measure real media distance, not just the option value.")
                XCTAssertLessThan(median, requested + 8)
                print("LIVE_BUFFER requested=\(requested) median_media_distance=\(median)")
            }
            XCTAssertTrue(model.isAtLiveEdge, "The intentional cushion must not appear as a user rewind.")
        }
        let gapLimit: Duration = fault == .none || fault == .guide ? .seconds(3)
            : fault == .disconnect || fault == .longSession ? .seconds(12) : .seconds(8)
        XCTAssertLessThan(longestGap, gapLimit)
        let counts = source.counts
        if fault != .disconnect { XCTAssertGreaterThanOrEqual(counts.sequences, 5) }
        if fault == .longSession {
            XCTAssertEqual(counts.opens, 4, "Three expired sessions must each be renewed exactly once.")
            XCTAssertGreaterThanOrEqual(counts.expired, 3)
            XCTAssertGreaterThanOrEqual(counts.sequences, observationSeconds / 3)
            XCTAssertTrue(resumed)
        } else if fault == .expiredSession {
            XCTAssertEqual(counts.opens, 2, "Only the expired session may re-open the origin.")
            XCTAssertGreaterThan(counts.expired, 0)
        } else if fault == .disconnect {
            XCTAssertTrue(counts.disconnected, "The outage must happen after a presented frame, not during a probe.")
            XCTAssertGreaterThanOrEqual(counts.opens, 2)
        } else {
            XCTAssertEqual(counts.opens, 1, "Healthy playback must retain its original delivery session.")
        }
        if fault == .delayedSegment { XCTAssertTrue(counts.delayed) }
        if fault == .guide { XCTAssertNotNil(guideCheck) }
        print("IPTV_CONTINUITY fragmented=\(fragmented) fault=\(fault.rawValue)"
            + " first_frame=\(firstFrame.map { started.duration(to: $0) } ?? .zero)"
            + " observed_seconds=\(observationSeconds)"
            + " changed_frames=\(changedFrames) advanced=\(advancement) longest_gap=\(longestGap)"
            + " opens=\(counts.opens) sequences=\(counts.sequences)")
        model.stop()
        await lease.close()
        let cleanupDeadline = ContinuousClock.now + .seconds(5)
        while await server.activeRequestCount != 0, ContinuousClock.now < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let remaining = await server.activeRequestCount
        XCTAssertEqual(remaining, 0)
        XCTAssertNil(PlaybackDeliveryFailure.state(for: url))
    }

    private static func fingerprint(_ buffer: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var result: UInt64 = 14_695_981_039_346_656_037
        for row in Swift.stride(from: 0, to: CVPixelBufferGetHeight(buffer), by: 8) {
            for column in Swift.stride(from: 0, to: CVPixelBufferGetWidth(buffer) * 4, by: 32) {
                result = (result ^ UInt64(bytes[row * stride + column])) &* 1_099_511_628_211
            }
        }
        return result
    }
}

private final class RollingIPTVSource: @unchecked Sendable {
    enum Fault: String { case none, delayedSegment, expiredSession, guide, disconnect, longSession }
    private let lock = NSLock()
    private let fault: Fault
    private let media: URL
    private let mediaBytes: Int
    private let map: String?
    private let segments: [[String]]
    private let windowSegments: Int
    private var publishedEnd = 0
    private var base: URL?
    private var started: TimeInterval?
    private var opens = 0
    private var expired = 0
    private var delayed = false
    private var disconnected = false
    private var interruptionAt: TimeInterval?
    private var sequences: Set<Int> = []
    private var guideFailure: Int?
    var durationSeconds: Int { segments.count * 2 }
    var publishedEdgeSeconds: Double { lock.withLock { Double(publishedEnd * 2) } }

    init(bundle: Bundle, fragmented: Bool, fault: Fault, windowSegments: Int? = nil) throws {
        self.fault = fault
        self.windowSegments = windowSegments ?? (fault == .longSession ? 8 : 4)
        media = try XCTUnwrap(bundle.url(
            forResource: "live-continuity", withExtension: fragmented ? "mp4" : "ts", subdirectory: "Fixtures"
        ))
        mediaBytes = try XCTUnwrap(media.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let playlist = try XCTUnwrap(bundle.url(
            forResource: fragmented ? "live-continuity-fmp4" : "live-continuity-ts",
            withExtension: "m3u8", subdirectory: "Fixtures"
        ))
        let lines = try String(contentsOf: playlist, encoding: .utf8).components(separatedBy: .newlines)
        map = lines.first { $0.hasPrefix("#EXT-X-MAP:") }
        segments = lines.indices.filter { lines[$0].hasPrefix("#EXTINF:") }.map { Array(lines[$0...($0 + 2)]) }
    }

    func setBase(_ value: URL) { lock.withLock { base = value } }
    func failGuide(status: Int) { lock.withLock { guideFailure = status } }
    func observedFirstFrame() {
        lock.withLock { interruptionAt = ProcessInfo.processInfo.systemUptime + 6 }
    }
    func interruptConnectionIfNeeded() throws {
        try lock.withLock {
            if fault == .disconnect, !disconnected, let interruptionAt,
               ProcessInfo.processInfo.systemUptime >= interruptionAt {
                disconnected = true
                throw URLError(.networkConnectionLost)
            }
        }
    }
    var counts: (opens: Int, expired: Int, delayed: Bool, disconnected: Bool, sequences: Int) {
        lock.withLock { (opens, expired, delayed, disconnected, sequences.count) }
    }

    func response(to request: String) -> IPTVTestHTTPServer.Response {
        lock.withLock {
            guard request.lowercased().contains("x-fixture-account: private"), let base else {
                return .init(status: 403)
            }
            if request.contains("/playlist.m3u ") {
                return .init(data: Data("""
                #EXTM3U
                #EXTINF:-1 tvg-id="fixture",Fixture
                \(base.appendingPathComponent(fault == .disconnect ? "raw.ts" : "entry.m3u8").absoluteString)

                """.utf8))
            }
            if request.contains("/guide.xml ") {
                if let guideFailure {
                    return .init(data: Data("not an XMLTV document".utf8), status: guideFailure)
                }
                return .init(data: Data("""
                <tv><channel id="fixture"><display-name>Fixture</display-name></channel>
                <programme channel="fixture" start="19700101000140 +0000" stop="19700101000640 +0000">
                <title>Fixture programme</title></programme></tv>
                """.utf8), headers: ["Cache-Control": "no-store"])
            }
            if request.contains("/raw.ts ") {
                opens += 1
                return .init(
                    file: media, headers: ["Content-Type": "video/mp2t"], delay: .seconds(2)
                )
            }
            if request.contains("/entry.m3u8 ") {
                opens += 1
                return .init(status: 302, headers: ["Location": base.appendingPathComponent("session-\(opens).m3u8").absoluteString])
            }
            let now = ProcessInfo.processInfo.systemUptime
            if request.contains(".m3u8 ") {
                if started == nil { started = now }
                let elapsed = now - (started ?? now)
                if fault == .expiredSession, let interruptionAt, now >= interruptionAt,
                   request.contains("/session-1.m3u8 ") {
                    expired += 1
                    return .init(status: 403)
                }
                if fault == .longSession, let interruptionAt {
                    for (index, seconds) in [30.0, 120.0, 240.0].enumerated()
                        where now >= interruptionAt - 6 + seconds
                            && request.contains("/session-\(index + 1).m3u8 ") {
                        expired += 1
                        return .init(status: 403)
                    }
                }
                // AVPlayer reserves three segments as live holdback; pause needs a usable range beyond it.
                let end = min(segments.count, windowSegments + Int(elapsed / 2))
                publishedEnd = end
                let first = max(0, end - windowSegments)
                sequences.insert(first)
                var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:2", "#EXT-X-MEDIA-SEQUENCE:\(first)"]
                if let map { lines.append(map) }
                lines += segments[first..<end].flatMap { $0 }
                return .init(
                    data: Data((lines.joined(separator: "\n") + "\n").utf8),
                    headers: ["Content-Type": "application/vnd.apple.mpegurl", "Cache-Control": "no-store"]
                )
            }
            guard request.contains("/live-continuity.") else { return .init(status: 404) }
            let rangeHeader = request.components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix("range: bytes=") }
            let numbers = rangeHeader?.split(separator: "=").last?.split(separator: "-", omittingEmptySubsequences: false)
            guard let numbers, numbers.count == 2, let lower = Int(numbers[0]), let upper = Int(numbers[1]),
                  lower >= 0, upper >= lower, upper < Int.max else { return .init(status: 416) }
            let injectDelay = fault == .delayedSegment && !delayed && interruptionAt.map { now >= $0 } == true
            if injectDelay { delayed = true }
            return .init(
                file: media, status: 206, headers: [
                    "Content-Type": map == nil ? "video/mp2t" : "video/mp4",
                    "Content-Range": "bytes \(lower)-\(upper)/\(mediaBytes)"
                ],
                headerDelay: injectDelay ? .seconds(5) : .zero, range: lower..<(upper + 1)
            )
        }
    }
}
