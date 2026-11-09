import CoreModels
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import FeatureLiveTV
@testable import FeaturePlayback

@MainActor
final class LiveTVMultiviewMotionHostedTests: XCTestCase {
    func testEmbeddedVideoResizesThroughIntermediateBoundsWithoutReplacingOutput() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let output = fixture.model.engine.output
        let originalSuperview = output.superview
        let start = output.bounds.width
        fixture.model.frame = CGRect(x: 180, y: 120, width: 640, height: 360)
        let samples = try await sample(fixture, milliseconds: 420)
        XCTAssertGreaterThan(samples.filter { $0.width > 641 && $0.width < start - 1 }.count, 2,
                             "The actual engine view must resize, not just its SwiftUI wrapper.")
        XCTAssertEqual(output.bounds.width, 640, accuracy: 1)
        XCTAssertEqual(output.bounds.height, 360, accuracy: 1)
        XCTAssertTrue(output.superview === originalSuperview)
        XCTAssertEqual(originalSuperview?.subviews.filter { $0 === output }.count, 1)
        XCTAssertEqual(fixture.model.engine.stops, 0)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds, format: format).image { _ in
            XCTAssertTrue(fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Retained video with rounded picture corners"
        attachment.lifetime = .keepAlways
        add(attachment)
        let bitmap = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        func color(at point: CGPoint) throws -> [UInt8] {
            try pixel.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(
                    data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                let crop = try XCTUnwrap(bitmap.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return pixel
        }
        XCTAssertTrue(try color(at: CGPoint(x: 181, y: 121)).prefix(3).allSatisfy { $0 < 20 })
        XCTAssertGreaterThan(try color(at: CGPoint(x: 500, y: 121))[2], 200)
    }

    func testRapidLayoutReversalStartsFromVisibleVideoGeometry() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.frame = CGRect(x: 100, y: 100, width: 480, height: 270)
        _ = try await sample(fixture, milliseconds: 110)
        let midWidth = fixture.model.engine.output.bounds.width
        XCTAssertGreaterThan(midWidth, 481)
        XCTAssertLessThan(midWidth, 1919)
        fixture.model.frame = CGRect(x: 80, y: 40, width: 1600, height: 900)
        let samples = try await sample(fixture, milliseconds: 420)
        XCTAssertFalse(samples.contains { $0.width < 480 || $0.width > max(midWidth, 1600) + 2 })
        XCTAssertEqual(fixture.model.engine.output.bounds.width, 1600, accuracy: 1)
        XCTAssertEqual(fixture.model.engine.stops, 0)
    }

    func testReduceMotionUsesFinalVideoBoundsWithoutIntermediateLayouts() async throws {
        let fixture = try await makeFixture(reduceMotion: true)
        defer { fixture.close() }
        fixture.model.frame = CGRect(x: 100, y: 100, width: 640, height: 360)
        let samples = try await sample(fixture, milliseconds: 420)
        XCTAssertFalse(samples.contains { $0.width > 641 && $0.width < 1919 })
        XCTAssertEqual(fixture.model.engine.output.bounds.width, 640, accuracy: 1)
    }

    func testRoundedClipCutsPictureCornersButKeepsItsCenter() {
        let clip = PrototypeVideoClip(reflectionHeight: 0, cornerRadius: 10)
        let picture = LiveTVMultiviewGeometry.contentFrame(
            in: CGRect(x: 0, y: 0, width: 960, height: 1080), aspectRatio: 16 / 9)
        XCTAssertEqual(picture.size, CGSize(width: 960, height: 540))
        let bounds = CGRect(origin: .zero, size: picture.size)
        let path = clip.path(in: bounds)
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: 1)))
        XCTAssertTrue(path.contains(CGPoint(x: bounds.midX, y: 1)))
        XCTAssertTrue(path.contains(CGPoint(x: bounds.midX, y: bounds.midY)))
        XCTAssertTrue(PrototypeVideoClip(reflectionHeight: 0, cornerRadius: 0)
            .path(in: bounds).contains(CGPoint(x: 1, y: 1)))
    }

    func testPaneRemovalAnimatesItsExistingSurfaceBeforeDetaching() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let output = fixture.model.engine.output
        fixture.model.visible = false
        _ = try await sample(fixture, milliseconds: 80)
        XCTAssertNotNil(output.window, "The outgoing video must remain attached during its transition.")
        _ = try await sample(fixture, milliseconds: 400)
        XCTAssertNil(output.window)
        fixture.model.visible = true
        _ = try await sample(fixture, milliseconds: 420)
        XCTAssertTrue(output.window === fixture.window)
    }

    private func sample(_ fixture: Fixture, milliseconds: Int) async throws -> [CGSize] {
        var samples: [CGSize] = []
        let deadline = ContinuousClock.now + .milliseconds(milliseconds)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(16))
            fixture.window.layoutIfNeeded()
            samples.append(fixture.model.engine.output.bounds.size)
        }
        return samples
    }

    private func makeFixture(reduceMotion: Bool = false) async throws -> Fixture {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let fixture = Fixture(scene: scene, reduceMotion: reduceMotion)
        do {
            _ = try await sample(fixture, milliseconds: 180)
            XCTAssertEqual(fixture.model.engine.output.bounds.width, 1920, accuracy: 1)
            return fixture
        } catch {
            fixture.close()
            throw error
        }
    }

    @Observable
    final class Model {
        var frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var visible = true
        let engine = MotionEngine()
    }

    private struct Page: View {
        let model: Model
        let reduceMotion: Bool
        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.black
                if model.visible {
                    VideoSurfaceContainer(engine: model.engine)
                        .clipShape(PrototypeVideoClip(reflectionHeight: 0, cornerRadius: 10))
                        .modifier(PrototypeVideoPlacement(frame: model.frame))
                        .transition(reduceMotion ? .identity : .scale(scale: 0.94).combined(with: .opacity))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: model.frame)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: model.visible)
            .ignoresSafeArea()
        }
    }

    private final class Fixture {
        let model = Model()
        let window: UIWindow
        let previous: UIWindow?
        init(scene: UIWindowScene, reduceMotion: Bool) {
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = UIHostingController(rootView: Page(model: model, reduceMotion: reduceMotion))
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }
        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }

    final class MotionEngine: VideoEngine {
        let output = UIView()
        var stops = 0
        var status: VideoEngineStatus { .ready }
        var isPaused: Bool { false }
        var currentTime: TimeInterval { 0 }
        var duration: TimeInterval { 0 }
        var furthestObservedPosition: TimeInterval { 0 }
        var audioTracks: [MediaTrack] { [] }
        var subtitleTracks: [MediaTrack] { [] }
        var videoAspectRatio: Double? { 16 / 9 }
        var onProgress: (@MainActor () -> Void)?
        var onFailure: (@MainActor (AppError) -> Void)?
        var onEnded: (@MainActor () -> Void)?
        var onTracksChanged: (@MainActor () -> Void)?
        var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
        var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
        var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
        func load(request: PlaybackRequest, startPosition: TimeInterval) async {}
        func play() {}
        func pause() {}
        func stop() { stops += 1 }
        func seek(to seconds: TimeInterval) async {}
        func selectAudioTrack(_ track: MediaTrack?) {}
        func selectSubtitleTrack(_ track: MediaTrack?) {}
        func makeVideoOutputView() -> UIView {
            output.backgroundColor = .blue
            return output
        }
    }
}
