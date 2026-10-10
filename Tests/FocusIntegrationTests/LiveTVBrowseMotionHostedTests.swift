import Observation
import SwiftUI
import UIKit
import XCTest
import FeatureLiveTVCore
@testable import FeatureLiveTV
@testable import CoreUI
@testable import FeaturePlayback

@MainActor
final class LiveTVBrowseMotionHostedTests: XCTestCase {
    func testActualSidebarLabelsTravelTogetherDespiteButtonFocusTransactions() async throws {
        let fixture = try await makeFixture(realSidebar: true)
        defer { fixture.close() }
        fixture.model.collapsed = false
        _ = try await fixture.sample()
        let reference = try labelRightEdges(in: fixture.sidebarImage())
        XCTAssertEqual(reference.compactMap { $0 }.count, 3)
        fixture.model.collapsed = true
        var movingSamples = 0
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(16))
            let image = fixture.sidebarImage()
            let edges = try labelRightEdges(in: image)
            guard let category = edges[2], let originalCategory = reference[2] else { continue }
            let distance = category - originalCategory
            guard distance < -2, distance > -100 else { continue }
            movingSamples += 1
            for control in 0..<2 {
                guard let edge = edges[control], let original = reference[control] else {
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "Sidebar label disappeared before categories"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    XCTFail("Search and Multiviews must remain visible while the category label moves")
                    continue
                }
                XCTAssertEqual(Double(edge - original), Double(distance), accuracy: 2,
                               "Search, Multiviews, and categories must share one rendered displacement")
            }
        }
        XCTAssertGreaterThanOrEqual(movingSamples, 2, "Observe actual intermediate rendered frames")
    }

    private func labelRightEdges(in image: UIImage) throws -> [Int?] {
        let image = try XCTUnwrap(image.cgImage)
        let width = image.width
        var pixels = [UInt8](repeating: 0, count: width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
        return [20..<54, 100..<135, 188..<220].map { rows in
            (0..<240).last { x in
                rows.filter { y in
                    let index = (y * width + x) * 4
                    return min(pixels[index], pixels[index + 1], pixels[index + 2]) > 175
                }.count > 3
            }
        }
    }

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

    private func makeFixture(disablesAnimations: Bool = false, realSidebar: Bool = false) async throws -> Fixture {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let fixture = Fixture(scene: scene, disablesAnimations: disablesAnimations, realSidebar: realSidebar)
        var prepared = false
        defer { if !prepared { fixture.close() } }
        let displayDeadline = ContinuousClock.now + .seconds(2)
        while fixture.renderedGuideX(afterScreenUpdates: true) == nil, ContinuousClock.now < displayDeadline {
            try await Task.sleep(for: .milliseconds(16))
            fixture.window.layoutIfNeeded()
        }
        _ = try fixture.guideX()
        prepared = true
        return fixture
    }

    private final class Fixture {
        let model = Model()
        let window: UIWindow
        let previous: UIWindow?

        init(scene: UIWindowScene, disablesAnimations: Bool, realSidebar: Bool) {
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = UIHostingController(rootView: Page(model: model, realSidebar: realSidebar)
                .environment(\.themePalette, .dark)
                .environment(\.colorScheme, .dark)
                .transaction { $0.disablesAnimations = disablesAnimations })
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }

        func sidebarImage() -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: 384, height: 360), format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: false))
            }
        }

        func guideX() throws -> CGFloat {
            try XCTUnwrap(renderedGuideX(), "The guide must be present in the rendered frame")
        }

        func renderedGuideX(afterScreenUpdates: Bool = false) -> CGFloat? {
            guard let view = model.guide, !view.bounds.isEmpty else { return nil }
            let row = view.convert(view.bounds, to: window).midY
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            var drawn = false
            let image = UIGraphicsImageRenderer(
                size: CGSize(width: window.bounds.width, height: 1), format: format
            ).image { context in
                context.cgContext.translateBy(x: 0, y: -row)
                drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: afterScreenUpdates)
            }
            guard drawn, let pixels = image.cgImage else { return nil }
            var rgba = [UInt8](repeating: 0, count: pixels.width * 4)
            guard let context = CGContext(
                data: &rgba, width: pixels.width, height: 1, bitsPerComponent: 8,
                bytesPerRow: pixels.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: 1))
            let leading = (0..<pixels.width).first { x in
                rgba[x * 4 + 1] > 180 && rgba[x * 4] < 50 && rgba[x * 4 + 2] < 50
            }
            return leading.map(CGFloat.init)
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
        var sidebarActive = false
        let sidebar = LiveTVPrototypeModel(now: Date(), scenario: .noGuide, channels: [])
        @ObservationIgnored weak var guide: UIView?
    }

    private struct Page: View {
        let model: Model
        let realSidebar: Bool

        var body: some View {
            let layout = PrototypePreviewLayout(
                size: CGSize(width: 1920, height: 1080), hidesSidebar: model.collapsed
            )
            PrototypeBrowseLayout(layout: layout) {
                Color.blue.frame(height: layout.heroHeight)
            } sidebar: {
                if realSidebar {
                    PrototypeBrowseSidebar(
                        model: model.sidebar,
                        active: Binding(get: { model.sidebarActive }, set: { model.sidebarActive = $0 }),
                        focusRequest: 0, search: {}, enterGuide: {}, multiviews: {}
                    )
                    .disabled(true)
                } else {
                    Color.red
                }
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
