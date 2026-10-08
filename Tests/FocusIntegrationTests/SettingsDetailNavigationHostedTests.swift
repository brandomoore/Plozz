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
        window.rootViewController = UIHostingController(rootView:
            SettingsDetailPages(navigation: navigation) {
                PageMotionProbe(id: "root", probes: probes).background(.blue)
            } detail: {
                PageMotionProbe(id: "detail", probes: probes).background(.orange)
            }
            .environment(\.layoutDirection, direction)
            .ignoresSafeArea()
        )
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
