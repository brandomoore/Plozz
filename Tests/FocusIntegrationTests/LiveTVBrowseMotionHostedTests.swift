import Observation
import SwiftUI
import UIKit
import XCTest
@testable import FeatureLiveTV
@testable import CoreUI
@testable import FeaturePlayback

@MainActor
final class LiveTVBrowseMotionHostedTests: XCTestCase {
    func testDisappearanceStopsPlaybackUnlessActiveFullscreenOwnsIt() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        var stops = 0
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        fixture.window.rootViewController = host

        for (active, fullscreen) in [
            (true, true), (true, false), (false, true), (false, false)
        ] {
            host.rootView = AnyView(Color.black.modifier(LiveChannelPlayerView.LiveChannelActivityObserver(
                isActive: active, isAuthorized: true, scenePhase: .active, networkBlock: nil,
                currentModel: { nil }, fullscreenOwnsSurface: { fullscreen },
                updateSource: {}, stopPlayback: { stops += 1 }
            )))
            fixture.window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            let before = stops
            host.rootView = AnyView(EmptyView())
            fixture.window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(stops - before, active && fullscreen ? 0 : 1)
        }
    }

    func testSidebarOpeningAndClosingHaveIntermediatePresentedFrames() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let closed = try fixture.guideX()

        fixture.model.collapsed = false
        let opening = try await fixture.sample()
        let opened = try fixture.guideX()
        XCTAssertEqual(opened - closed, 408, accuracy: 1)
        XCTAssertTrue(opening.contains { $0 > closed + 12 && $0 < opened - 12 },
                      "Opening must animate, not jump between final layouts: \(opening)")

        fixture.model.collapsed = true
        let closing = try await fixture.sample()
        XCTAssertEqual(try fixture.guideX(), closed, accuracy: 1)
        XCTAssertTrue(closing.contains { $0 > closed + 12 && $0 < opened - 12 },
                      "Closing must animate, not jump between final layouts: \(closing)")
    }

    func testRapidReversalSettlesAtTheRequestedLayout() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let closed = try fixture.guideX()
        fixture.model.collapsed = false
        _ = try await fixture.sample(duration: .milliseconds(90))
        fixture.model.collapsed = true
        _ = try await fixture.sample()
        XCTAssertEqual(try fixture.guideX(), closed, accuracy: 1)
    }

    func testDisabledAnimationsSkipSidebarTravel() async throws {
        let fixture = try await makeFixture(disablesAnimations: true)
        defer { fixture.close() }
        let closed = try fixture.guideX()
        fixture.model.collapsed = false
        let samples = try await fixture.sample()
        let opened = try fixture.guideX()
        XCTAssertEqual(opened - closed, 408, accuracy: 1)
        XCTAssertFalse(samples.contains { $0 > closed + 1 && $0 < opened - 1 })
    }

    private func makeFixture(disablesAnimations: Bool = false) async throws -> Fixture {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let fixture = Fixture(scene: scene, disablesAnimations: disablesAnimations)
        _ = try await fixture.sample(duration: .milliseconds(100))
        return fixture
    }

    private final class Fixture {
        let model = Model()
        let window: UIWindow
        let previous: UIWindow?

        init(scene: UIWindowScene, disablesAnimations: Bool) {
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = UIHostingController(rootView: Page(model: model)
                .transaction { $0.disablesAnimations = disablesAnimations })
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }

        func guideX() throws -> CGFloat {
            let view = try XCTUnwrap(model.guide)
            var point = view.bounds.origin
            var current: CALayer? = view.layer
            while let layer = current, layer !== window.layer {
                let presented = layer.presentation() ?? layer
                XCTAssertTrue(CATransform3DIsAffine(presented.transform))
                point.x -= presented.bounds.minX + presented.anchorPoint.x * presented.bounds.width
                point.y -= presented.bounds.minY + presented.anchorPoint.y * presented.bounds.height
                point = point.applying(CATransform3DGetAffineTransform(presented.transform))
                point.x += presented.position.x
                point.y += presented.position.y
                current = layer.superlayer
            }
            XCTAssertTrue(current === window.layer)
            return point.x
        }

        func sample(duration: Duration = .milliseconds(450)) async throws -> [CGFloat] {
            let deadline = ContinuousClock.now + duration
            var samples: [CGFloat] = []
            while ContinuousClock.now < deadline {
                window.layoutIfNeeded()
                samples.append(try guideX())
                try await Task.sleep(for: .milliseconds(16))
            }
            return samples
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }

    @Observable final class Model {
        var collapsed = true
        @ObservationIgnored weak var guide: UIView?
    }

    private struct Page: View {
        let model: Model

        var body: some View {
            let layout = PrototypePreviewLayout(
                size: CGSize(width: 1920, height: 1080), hidesSidebar: model.collapsed
            )
            PrototypeBrowseLayout(layout: layout) {
                Color.blue.frame(height: layout.heroHeight)
            } sidebar: {
                Color.red
            } guide: {
                GuideMarker(model: model)
            }
            .frame(width: layout.contentFrame.width, height: layout.contentFrame.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
        }
    }

    private struct GuideMarker: UIViewRepresentable {
        let model: Model

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.backgroundColor = .green
            model.guide = view
            return view
        }

        func updateUIView(_ view: UIView, context: Context) {}
    }
}
