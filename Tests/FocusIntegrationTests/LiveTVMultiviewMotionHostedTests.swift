import CoreModels
import CoreUI
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import FeatureLiveTV
@testable import FeaturePlayback

@MainActor
final class LiveTVMultiviewMotionHostedTests: XCTestCase {
    func testFullscreenHandoffKeepsTheActualOutputVisibleUntilTheInlineHostLaysOut() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let output = fixture.model.engine.output
        let previousHost = try XCTUnwrap(output.superview as? VideoPresentationView)
        let originalFrame = output.convert(output.bounds, to: fixture.window)
        var completions = 0
        let handoff = try XCTUnwrap(VideoPresentationHandoff(engine: fixture.model.engine) {
            completions += 1
        })
        defer { handoff.cancel() }
        fixture.model.visible = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(output.superview === handoff)
        XCTAssertTrue(output.window === fixture.window, "Dismissing the old host must not blank the live renderer.")
        XCTAssertEqual(output.convert(output.bounds, to: fixture.window), originalFrame)
        previousHost.attach(fixture.model.engine, deferringOffscreenAttachment: true)
        XCTAssertTrue(output.superview === handoff)
        let nextHost = VideoPresentationView(frame: .zero)
        nextHost.attach(fixture.model.engine, deferringOffscreenAttachment: true)
        XCTAssertTrue(output.superview === handoff, "An offscreen inline host must not end the handoff.")
        fixture.window.addSubview(nextHost)
        nextHost.layoutIfNeeded()
        XCTAssertEqual(completions, 0, "A zero-sized host is not ready to animate.")
        XCTAssertTrue(output.superview === handoff)
        nextHost.frame = fixture.window.bounds
        nextHost.layoutIfNeeded()
        let deadline = ContinuousClock.now + .seconds(2)
        while completions == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(completions, 1)
        XCTAssertNil(handoff.superview)
        XCTAssertTrue(output.superview === nextHost)
        XCTAssertEqual(output.convert(output.bounds, to: fixture.window), originalFrame)
        XCTAssertEqual(fixture.model.engine.stops, 0)
    }

    func testCancelledFullscreenHandoffCannotStartMultiviewBeforeItsNewHostIsPresented() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        var completions = 0
        let handoff = try XCTUnwrap(VideoPresentationHandoff(engine: fixture.model.engine) {
            completions += 1
        })
        let nextHost = VideoPresentationView(frame: fixture.window.bounds)
        nextHost.attach(fixture.model.engine, deferringOffscreenAttachment: true)
        fixture.window.addSubview(nextHost)
        nextHost.layoutIfNeeded()
        handoff.cancel()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(completions, 0)
        XCTAssertNil(handoff.superview)
        XCTAssertNil(fixture.model.engine.output.superview)
        XCTAssertEqual(fixture.model.engine.stops, 0)
    }

    func testDeclinedMultiviewRestoresTheInlineRendererWithoutRestartingIt() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let output = fixture.model.engine.output
        let originalHost = output.superview
        let originalFrame = output.frame
        var completions = 0
        let handoff = try XCTUnwrap(VideoPresentationHandoff(engine: fixture.model.engine) {
            completions += 1
        })
        handoff.cancel(restoringOutput: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(completions, 0)
        XCTAssertTrue(output.superview === originalHost)
        XCTAssertEqual(output.frame, originalFrame)
        XCTAssertTrue(output.window === fixture.window)
        XCTAssertNil(handoff.superview)
        XCTAssertEqual(fixture.model.engine.stops, 0)
    }

    func testEnteringWindowClaimsOutputFromAnotherOffscreenLabel() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let engine = MotionEngine()
        let incoming = VideoPresentationView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        let preparedLabel = VideoPresentationView(frame: incoming.frame)
        incoming.attach(engine, deferringOffscreenAttachment: true)
        preparedLabel.attach(engine, deferringOffscreenAttachment: true)
        XCTAssertTrue(engine.output.superview === preparedLabel)
        fixture.window.addSubview(incoming)
        fixture.window.layoutIfNeeded()
        XCTAssertTrue(engine.output.superview === incoming)
        XCTAssertTrue(engine.output.window === fixture.window)
        XCTAssertEqual(engine.output.bounds.size, incoming.bounds.size)
        XCTAssertEqual(engine.stops, 0)
    }

    func testOffscreenNativeCardLabelCannotStealTheVisibleVideoOutput() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let output = fixture.model.engine.output
        let visibleParent = try XCTUnwrap(output.superview as? VideoPresentationView)
        let replacement = VideoPresentationView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        replacement.attach(fixture.model.engine, deferringOffscreenAttachment: true)
        XCTAssertTrue(output.superview === visibleParent)
        XCTAssertTrue(output.window === fixture.window)
        fixture.window.addSubview(replacement)
        fixture.window.layoutIfNeeded()
        XCTAssertTrue(output.superview === replacement)
        XCTAssertTrue(output.window === fixture.window)
        visibleParent.attach(fixture.model.engine, deferringOffscreenAttachment: true)
        XCTAssertTrue(output.superview === replacement, "An outgoing label must not steal back the live output.")
        visibleParent.removeFromSuperview()
        XCTAssertTrue(output.window === fixture.window)
        XCTAssertEqual(fixture.model.engine.stops, 0)
    }

    func testNativeCardCanLiftLiveVideoAndDisableItsEffectWhileRetainingFocus() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = NativeCardModel()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView: NativeCardPage(model: model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .seconds(1))
        window.layoutIfNeeded()
        let output = model.engine.output
        let focused = output.convert(output.bounds, to: window)
        let focus = UIFocusSystem.focusSystem(for: window)?.focusedItem
        XCTAssertNotNil(focus)
        XCTAssertGreaterThan(focused.width, 961, "Native card focus must lift the live video itself.")
        func capture(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        capture("native-live-video-focused")
        model.presentsFocus = false
        try await Task.sleep(for: .seconds(1))
        window.layoutIfNeeded()
        capture("native-live-video-effect-disabled")
        let idle = output.convert(output.bounds, to: window)
        XCTAssertEqual(idle.width, 960, accuracy: 1)
        XCTAssertNotNil(UIFocusSystem.focusSystem(for: window)?.focusedItem)
        XCTAssertTrue(output.window === window)
        XCTAssertEqual(model.engine.stops, 0)
        for enabled in [false, true, false, true] {
            model.enabled = enabled
            model.presentsFocus = enabled
            try await Task.sleep(for: .milliseconds(500))
            window.layoutIfNeeded()
            XCTAssertTrue(output.window === window, "Changing card ownership must preserve the windowed video.")
            XCTAssertEqual(model.engine.stops, 0)
        }
    }

    @Observable
    final class NativeCardModel {
        let engine = MotionEngine()
        var presentsFocus = true
        var enabled = true
    }

    private struct NativeCardPage: View {
        let model: NativeCardModel
        var body: some View {
            ZStack {
                Color.black
                VideoSurfaceContainer(engine: model.engine)
                    .videoCardFocusSurface()
                    .environment(\.videoCardFocus, model.enabled ? VideoCardFocus(
                        identifier: "native-video-card", title: "Live video", audible: true,
                        presentsEffect: model.presentsFocus, cornerRadius: 20, horizontalInset: 0,
                        request: 0, prefersFocus: true, focused: { _ in },
                        activate: {}, promote: {}, replace: {}) : nil)
                    .frame(width: 960, height: 540)
            }
            .ignoresSafeArea()
        }
    }

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
        try await waitForVideoSize(CGSize(width: 640, height: 360), in: fixture)
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

    func testFocusInsetAnimatesActualVideoBothWaysAndHonorsReduceMotion() async throws {
        for reduceMotion in [false, true] {
            let fixture = try await makeFixture(reduceMotion: reduceMotion)
            defer { fixture.close() }
            let full = fixture.model.frame
            let inset = LiveTVMultiviewGeometry.presentationFrame(
                in: full, aspectRatio: 16 / 9, focusActive: true)
            fixture.model.frame = inset
            let shrinking = try await sample(fixture, milliseconds: 420)
            XCTAssertEqual(fixture.model.engine.output.bounds.width, inset.width, accuracy: 1)
            fixture.model.frame = full
            let growing = try await sample(fixture, milliseconds: 420)
            for samples in [shrinking, growing] {
                let intermediate = samples.filter { $0.width > inset.width + 1 && $0.width < full.width - 1 }
                if reduceMotion {
                    XCTAssertTrue(intermediate.isEmpty)
                } else {
                    XCTAssertGreaterThan(intermediate.count, 2)
                }
            }
            XCTAssertEqual(fixture.model.engine.output.bounds.width, full.width, accuracy: 1)
            XCTAssertEqual(fixture.model.engine.stops, 0)
        }
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
        XCTAssertEqual(LiveTVMultiviewGeometry.videoCornerRadius, 20)
        let clip = PrototypeVideoClip(
            reflectionHeight: 0, cornerRadius: LiveTVMultiviewGeometry.videoCornerRadius)
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

    private func waitForVideoSize(_ size: CGSize, in fixture: Fixture) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while fixture.model.engine.output.bounds.size != size, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(16))
            fixture.window.layoutIfNeeded()
        }
        XCTAssertEqual(fixture.model.engine.output.bounds.size, size)
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
                        .clipShape(PrototypeVideoClip(
                            reflectionHeight: 0, cornerRadius: LiveTVMultiviewGeometry.videoCornerRadius))
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
