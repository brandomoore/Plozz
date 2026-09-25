import CoreModels
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI
@testable import FeaturePlayback

@MainActor
final class SubtitleControlAvoidanceHostedTests: XCTestCase {
    func testDisplayClockReleasesItsDisplayLinkAndDoesNotOwnThePlayer() async throws {
        let scene = try await activeScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        var engine: NativeVideoEngine? = NativeVideoEngine()
        var model: LiveSubtitleModel? = LiveSubtitleModel()
        var clock: SubtitleDisplayClockView? = SubtitleDisplayClockView()
        weak var weakEngine = engine
        weak var weakModel = model
        weak var weakClock = clock
        clock?.engine = engine
        clock?.subtitles = model
        window.rootViewController?.view.addSubview(try XCTUnwrap(clock))
        engine = nil
        model = nil
        XCTAssertNil(weakEngine)
        XCTAssertNil(weakModel)
        clock?.removeFromSuperview()
        clock = nil
        try await waitUntil { weakClock == nil }
    }

    func testSeparateControlsHostLiftsAndRestoresRenderedSubtitlesWithoutChangingSavedStyle() async throws {
        let scene = try await activeScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = LiveSubtitleModel()
        model.style.fontFamily = .system
        model.style.verticalPosition = 0.06
        model.style.followsSystemStyle = false
        let originalStyle = model.style
        model.loadPrimary(SubtitleCueParser.parse("WEBVTT\n\n00:00:00.000 --> 00:01:00.000\nA visible subtitle gyp.\n", id: 1))
        model.tick(1)
        let controls = PlayerControlsModel()
        let fixture = ControlsFixture()
        let root = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let captions = UIHostingController(rootView: LiveSubtitleOverlay(model: model, controls: controls))
        let chrome = UIHostingController(rootView: FixtureControls(model: fixture, layout: controls.subtitleLayout))
        for host in [captions as UIViewController, chrome as UIViewController] {
            root.addChild(host)
            host.view.backgroundColor = .clear
            host.view.frame = root.view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            root.view.addSubview(host.view)
            host.didMove(toParent: root)
        }
        captions.safeAreaRegions = []
        chrome.safeAreaRegions = []
        try await waitUntil {
            window.layoutIfNeeded()
            return !self.frames(in: captions.view, relativeTo: window).isEmpty
        }
        let resting = try XCTUnwrap(frames(in: captions.view, relativeTo: window).first)
        fixture.visible = true
        try await waitUntil {
            window.layoutIfNeeded()
            guard let obstruction = controls.subtitleLayout.frame,
                  let frame = self.frames(in: captions.view, relativeTo: window).first else { return false }
            return abs(frame.maxY - (obstruction.minY - SubtitleOverlayGeometry.controlsClearance)) <= 1
        }
        let raised = try XCTUnwrap(frames(in: captions.view, relativeTo: window).first)
        XCTAssertLessThan(raised.maxY, resting.maxY)
        XCTAssertEqual(raised.size, resting.size)
        XCTAssertEqual(model.style, originalStyle)

        fixture.height = 220
        try await waitUntil {
            window.layoutIfNeeded()
            guard let obstruction = controls.subtitleLayout.frame,
                  let frame = self.frames(in: captions.view, relativeTo: window).first else { return false }
            return abs(frame.maxY - (obstruction.minY - SubtitleOverlayGeometry.controlsClearance)) <= 1
                && frame.maxY < raised.maxY
        }
        fixture.visible = false
        try await waitUntil {
            window.layoutIfNeeded()
            guard let frame = self.frames(in: captions.view, relativeTo: window).first else { return false }
            return controls.subtitleLayout.frame == nil && abs(frame.maxY - resting.maxY) <= 1
        }
        XCTAssertEqual(model.style, originalStyle)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Restored subtitle position after controls hide"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    #if os(tvOS)
    func testRealTVTransportPublishesOnlyVisibleControlBounds() async throws {
        let scene = try await activeScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = PlayerControlsModel()
        model.controlsVisible = true
        model.title = "Synthetic caption fixture"
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: PlayerControls(
            model: model, palette: .dark, actions: PlayerOptionsActions(), onExitToSurface: {}
        ))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { model.subtitleLayout.frame != nil }
        let controls = try XCTUnwrap(model.subtitleLayout.frame)
        XCTAssertGreaterThan(controls.minY, window.bounds.midY, "Do not report the full-screen scrim as controls")
        XCTAssertLessThan(controls.minY, window.bounds.maxY)
        model.controlsVisible = false
        try await waitUntil { model.subtitleLayout.frame == nil }
        model.controlsVisible = true
        try await waitUntil { model.subtitleLayout.frame != nil }
    }
    #endif

    private func frames(in view: UIView, relativeTo window: UIWindow) -> [CGRect] {
        if let line = view as? SubtitleLineView { return [line.convert(line.bounds, to: window)] }
        return view.subviews.flatMap { frames(in: $0, relativeTo: window) }
    }

    private func activeScene() async throws -> UIWindowScene {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        return try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Subtitle/control layout did not settle")
    }
}

@MainActor @Observable
private final class ControlsFixture {
    var visible = false
    var height: CGFloat = 160
}

private struct FixtureControls: View {
    let model: ControlsFixture
    let layout: SubtitleControlsLayout
    var body: some View {
        VStack {
            Spacer(minLength: 0)
            Rectangle().fill(.black.opacity(0.8))
                .frame(height: model.height)
                .reportSubtitleControlsFrame(isVisible: model.visible) { layout.frame = $0 }
                .opacity(model.visible ? 1 : 0)
        }
        .ignoresSafeArea()
    }
}
