@testable import FeatureSettings
import SwiftUI
import UIKit
import XCTest

@MainActor
final class SettingsDetailNavigationHostedTests: XCTestCase {
    func testBothPagesSlideTogetherInBothDirectionsAndRetainTheRoot() async throws {
        try await verifySlides(direction: .leftToRight)
    }

    func testBothPagesMirrorTheirSlideInRightToLeftLayout() async throws {
        try await verifySlides(direction: .rightToLeft)
    }

    func testUnanimatedNavigationAndCancelledReturnsDoNotReleaseANewerTransition() async throws {
        try await withPages { navigation, probes, window in
            navigation.push(animated: false)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(try XCTUnwrap(probes.frame("root", in: window)).minX, -window.bounds.width, accuracy: 2)
            navigation.pop(animated: false)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(try XCTUnwrap(probes.frame("root", in: window)).minX, 0, accuracy: 2)
            XCTAssertEqual(navigation.returnFocusGeneration, 1)
            navigation.push(animated: false)
            try await Task.sleep(for: .milliseconds(100))
            navigation.pop(animated: true)
            navigation.reset()
            navigation.push(animated: false)
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertTrue(navigation.isPresented)
            XCTAssertTrue(navigation.awaitingFocus)
            XCTAssertEqual(navigation.returnFocusGeneration, 0)
        }
    }

    func testSlideViewportPreservesVerticalSafeAreaWithoutHorizontalBleed() async throws {
        try await withPages(verticalSafeArea: 40, horizontalInset: 80) { navigation, probes, window in
            for isDetail in [false, true, false] {
                if isDetail {
                    navigation.push(animated: true)
                } else if navigation.isPresented {
                    navigation.focusArrived()
                    navigation.pop(animated: true)
                }
                try await Task.sleep(for: .milliseconds(350))
                window.layoutIfNeeded()
                let frame = try XCTUnwrap(probes.frame(isDetail ? "detail" : "root", in: window))
                XCTAssertGreaterThan(frame.minY, 8)
                XCTAssertLessThan(frame.maxY + 8, window.bounds.maxY)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = isDetail ? "detail-safe-area" : "root-safe-area"
                attachment.lifetime = .keepAlways
                self.add(attachment)
                let expected = try self.pixel(image, at: CGPoint(x: frame.midX, y: frame.midY))
                let background = try self.pixel(image, at: CGPoint(x: 8, y: frame.midY))
                for y in [frame.minY - 8, frame.maxY + 8] {
                    XCTAssertEqual(
                        try self.pixel(image, at: CGPoint(x: frame.midX, y: y)), expected,
                        "The slide mask must not cut off content at the vertical safe-area boundary."
                    )
                }
                for x in [frame.minX - 8, frame.maxX + 8] {
                    let outside = try self.pixel(image, at: CGPoint(x: x, y: frame.midY))
                    XCTAssertEqual(outside, background,
                                   "Pages must remain clipped horizontally to preserve the slide.")
                }
            }
        }
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [UInt8] {
        let source = try XCTUnwrap(image.cgImage)
        let crop = try XCTUnwrap(source.cropping(to: CGRect(x: point.x, y: point.y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }

    private func verifySlides(direction: LayoutDirection) async throws {
        try await withPages(direction: direction) { navigation, probes, window in
            let width = window.bounds.width
            let sign: CGFloat = direction == .leftToRight ? 1 : -1
            let sampler = PageMotionSampler(probes: probes, window: window)
            sampler.start()
            defer { sampler.stop() }
            navigation.push(animated: true)
            try await Task.sleep(for: .milliseconds(350))
            self.assertIntermediatePages(sampler.samples, width: width, sign: sign)
            XCTAssertEqual(try XCTUnwrap(probes.frame("root", in: window)).minX, -sign * width, accuracy: 2)
            navigation.focusArrived()
            sampler.samples.removeAll()
            navigation.pop(animated: true)
            try await Task.sleep(for: .milliseconds(350))
            self.assertIntermediatePages(sampler.samples, width: width, sign: sign)
            XCTAssertEqual(try XCTUnwrap(probes.frame("root", in: window)).minX, 0, accuracy: 2)
            XCTAssertEqual(probes.creations["root"], 1, "The parent page must retain its view/state during navigation.")
            XCTAssertEqual(navigation.returnFocusGeneration, 1)
        }
    }

    private func assertIntermediatePages(_ samples: [PageMotionSampler.Sample], width: CGFloat, sign: CGFloat) {
        let moving = samples.filter {
            let root = $0.rootX * sign
            let detail = $0.detailX * sign
            return root < -width * 0.1 && root > -width * 0.9
                && detail > width * 0.1 && detail < width * 0.9
        }
        XCTAssertGreaterThanOrEqual(moving.count, 2, "Both pages must be visible and moving between endpoints: \(samples)")
        for sample in moving {
            XCTAssertEqual((sample.detailX - sample.rootX) * sign, width, accuracy: width * 0.03)
        }
        let attachment = XCTAttachment(string: String(describing: samples))
        attachment.name = "settings-page-motion"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func withPages(
        direction: LayoutDirection = .leftToRight,
        verticalSafeArea: CGFloat = 0,
        horizontalInset: CGFloat = 0,
        inspect: (SettingsDetailNavigation, PageMotionProbes, UIWindow) async throws -> Void
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 960, height: 540)
        let navigation = SettingsDetailNavigation()
        let probes = PageMotionProbes()
        let host = UIHostingController(rootView:
            SettingsDetailPages(navigation: navigation) {
                PageMotionProbe(id: "root", probes: probes)
                    .background {
                        Color.blue
                            .ignoresSafeArea(.container, edges: .vertical)
                            .padding(.horizontal, -24)
                    }
            } detail: {
                PageMotionProbe(id: "detail", probes: probes)
                    .background {
                        Color.orange
                            .ignoresSafeArea(.container, edges: .vertical)
                            .padding(.horizontal, -24)
                    }
            }
            .padding(.horizontal, horizontalInset)
            .background { Color.red.ignoresSafeArea() }
            .environment(\.layoutDirection, direction)
            .ignoresSafeArea(edges: verticalSafeArea > 0 ? .horizontal : .all)
        )
        host.additionalSafeAreaInsets = UIEdgeInsets(
            top: verticalSafeArea, left: 0, bottom: verticalSafeArea, right: 0
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(200))
        try await inspect(navigation, probes, window)
    }
}

@MainActor
private final class PageMotionProbes {
    var views: [String: UIView] = [:]
    var creations: [String: Int] = [:]

    func frame(_ id: String, in window: UIWindow) -> CGRect? {
        guard let view = views[id], view.window === window else { return nil }
        let layer = view.layer.presentation() ?? view.layer
        return layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer)
    }
}

private struct PageMotionProbe: UIViewRepresentable {
    let id: String
    let probes: PageMotionProbes

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        probes.views[id] = view
        probes.creations[id, default: 0] += 1
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

@MainActor
private final class PageMotionSampler: NSObject {
    struct Sample: CustomStringConvertible {
        let rootX: CGFloat
        let detailX: CGFloat
        var description: String { "root=\(rootX), detail=\(detailX)" }
    }

    var samples: [Sample] = []
    private let probes: PageMotionProbes
    private let window: UIWindow
    private var displayLink: CADisplayLink?

    init(probes: PageMotionProbes, window: UIWindow) {
        self.probes = probes
        self.window = window
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(sample))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func sample() {
        guard let root = probes.frame("root", in: window),
              let detail = probes.frame("detail", in: window) else { return }
        samples.append(Sample(rootX: root.minX, detailX: detail.minX))
    }
}
