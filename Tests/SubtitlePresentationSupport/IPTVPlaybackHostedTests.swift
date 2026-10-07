import CoreModels
import EnginePlozzigen
import FeaturePlayback
import Foundation
import UIKit
import XCTest
@testable import ProviderIPTV

@MainActor
final class IPTVPlaybackHostedTests: XCTestCase {
    func testRawTransportStreamPlaysThroughAuthenticatedIPTVProxy() async throws {
        try await play(hls: false)
    }

    func testHLSPlaysThroughAuthenticatedIPTVProxy() async throws {
        try await play(hls: true)
    }

    func testFragmentedMP4HLSKeepsNativePlaybackThroughAuthenticatedProxy() async throws {
        try await play(hls: true, fragmented: true)
    }

    private func play(hls: Bool, fragmented: Bool = false) async throws {
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
            if request.contains("/master.m3u8") {
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
            origin: base.appendingPathComponent(hls ? "master.m3u8" : "channel.ts"),
            headers: ["Authorization": "Bearer fixture"]
        )
        addTeardownBlock { await proxy.stop() }
        let url = try await proxy.start()
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
        await engine.loadLive(url: url, httpHeaders: [:])
        let deadline = ContinuousClock.now + .seconds(25)
        while ContinuousClock.now < deadline, engine.liveSnapshot.phase != .failed {
            if engine.liveSnapshot.firstFrameReady, engine.liveSnapshot.position > 0.2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotEqual(engine.liveSnapshot.phase, .failed, "The actual production live engine must open this stream")
        XCTAssertTrue(engine.liveSnapshot.firstFrameReady, "Require a rendered frame, not just a successful URL request")
        XCTAssertGreaterThan(engine.liveSnapshot.position, 0.2)
    }
}
