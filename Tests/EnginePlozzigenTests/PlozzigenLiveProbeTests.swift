import CoreModels
import Foundation
import XCTest
@testable import EnginePlozzigen
@testable import FeaturePlayback
@testable import TestSupportNetworking

@MainActor
final class PlozzigenLiveProbeTests: XCTestCase {
    func testProbedLiveFilePublishesSDRForSeamlessExpansion() async throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "no-chapters", withExtension: "mp4", subdirectory: "Fixtures"
        ))
        let engine = try PlozzigenVideoEngine()
        defer { engine.stop() }
        engine.configureLiveOutput(.init(suppressesDisplayMatching: true))
        var ranges: [SourceDynamicRange?] = []
        engine.onProbedSourceFactsChanged = { ranges.append($0.range) }
        await engine.loadLive(url: url, httpHeaders: [:])

        let facts = try XCTUnwrap(engine.probedSourceFacts)
        XCTAssertEqual(facts.range, .sdr)
        XCTAssertEqual(facts.videoWidth, 160)
        XCTAssertEqual(ranges, [.sdr])
        let transition = LiveChannelDisplayTransition()
        defer { transition.reset() }
        _ = transition.beginPlayback(
            isFullscreen: true, changesSource: false, range: facts.range, settings: .default
        )
        XCTAssertFalse(transition.veil.isVeiled)
    }

    func testNativeHLSPublishesLateSDRWithoutWaitingForFadeTimeout() async throws {
        try await verifyNativeHLSRange(.sdr, fixture: "LiveSDR")
    }

    func testNativeHLSDoesNotPublishProvisionalSDRBeforeDetectingHDR() async throws {
        try await verifyNativeHLSRange(.hdr10, fixture: "LiveHDR")
    }

    private func verifyNativeHLSRange(_ range: SourceDynamicRange, fixture: String) async throws {
        let directory = try XCTUnwrap(Bundle.module.url(
            forResource: "stream", withExtension: "m3u8", subdirectory: "Fixtures/\(fixture)"
        )).deletingLastPathComponent()
        var files: [String: Data] = [:]
        for name in ["stream.m3u8", "init.mp4", "segment0.m4s"] {
            files["/\(name)"] = try Data(contentsOf: directory.appendingPathComponent(name))
        }
        let responses = files
        let server = try LoopbackHTTPServer { request in
            guard let data = responses[request.target] else { return .init(status: 404) }
            return .init(
                headers: ["Content-Type": request.target.hasSuffix(".m3u8")
                    ? "application/vnd.apple.mpegurl" : "video/mp4"],
                body: data, delay: .milliseconds(100)
            )
        }
        addTeardownBlock { await server.stop() }
        let url = try await server.start().appendingPathComponent("stream.m3u8")
        let engine = try PlozzigenVideoEngine()
        defer { engine.stop() }
        engine.configureLiveOutput(.init(suppressesDisplayMatching: true))
        var ranges: [SourceDynamicRange?] = []
        engine.onProbedSourceFactsChanged = { ranges.append($0.range) }
        await engine.loadLive(url: url, httpHeaders: [:])
        XCTAssertNil(engine.probedSourceFacts, "An unprobed native mount is not confirmed SDR.")
        XCTAssertTrue(ranges.isEmpty)

        let transition = LiveChannelDisplayTransition(veil: .init(
            configuration: .init(maxBlackout: 60, minVeil: 0.01, veilFade: 0)
        ))
        defer { transition.reset() }
        let token = transition.beginPlayback(
            isFullscreen: true, changesSource: true, range: nil, settings: .default
        )
        let prepared = await transition.preparePlayback(token)
        XCTAssertTrue(prepared)
        transition.displayDidSettle()
        let deadline = ContinuousClock.now + .seconds(15)
        while engine.probedSourceFacts == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let facts = try XCTUnwrap(engine.probedSourceFacts)
        XCTAssertEqual(facts.range, range)
        XCTAssertFalse(ranges.isEmpty)
        XCTAssertTrue(ranges.allSatisfy { $0 == range }, "Do not publish the engine's SDR reset value.")
        transition.update(range: facts.range, hasPresentedFrame: false, failed: false)
        XCTAssertTrue(transition.veil.isVeiled)
        // Rendering is covered separately; exercise the actual adapter facts at the frame/settle seam.
        transition.update(range: facts.range, hasPresentedFrame: true, failed: false)
        let revealDeadline = ContinuousClock.now + .seconds(1)
        while transition.veil.isVeiled, ContinuousClock.now < revealDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(transition.veil.isVeiled, "Authoritative live facts must release the probe wait.")

        engine.stop()
        XCTAssertNil(engine.probedSourceFacts)
        let count = ranges.count
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(ranges.count, count, "Stopped generations cannot republish queued source facts.")
    }
}
