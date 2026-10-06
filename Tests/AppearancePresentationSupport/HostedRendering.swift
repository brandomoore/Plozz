import UIKit
import XCTest

@MainActor
func waitForHostedLayout(
    _ window: UIWindow, timeout: Duration = .seconds(4)
) async throws {
    struct Geometry: Equatable {
        let identity: ObjectIdentifier
        let frame: CGRect
        let bounds: CGRect
        let opacity: Float
    }
    func geometry(_ model: CALayer) -> [Geometry] {
        let layer = model.presentation() ?? model
        return [Geometry(identity: ObjectIdentifier(model), frame: layer.frame,
                         bounds: layer.bounds, opacity: layer.opacity)]
            + (model.sublayers ?? []).flatMap(geometry)
    }
    func animating(_ layer: CALayer) -> Bool {
        !(layer.animationKeys() ?? []).isEmpty || (layer.sublayers ?? []).contains(where: animating)
    }
    let deadline = ContinuousClock.now + timeout
    var previous: [Geometry] = []
    var stableSamples = 0
    repeat {
        try await Task.sleep(for: .milliseconds(16))
        window.layoutIfNeeded()
        let current = geometry(window.layer)
        stableSamples = current == previous && !animating(window.layer) ? stableSamples + 1 : 0
        if stableSamples >= 2 { return }
        previous = current
    } while ContinuousClock.now < deadline
    throw HostedRenderingTimeout()
}

private struct HostedRenderingTimeout: Error, CustomStringConvertible {
    var description: String { "Hosted layout did not settle before capture" }
}

@MainActor
final class HostedRenderingTests: XCTestCase {
    func testLayoutWaitIncludesPendingUpdatesAndFiniteAnimation() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        window.rootViewController?.view.addSubview(view)
        try await waitForHostedLayout(window)
        var completed = false
        UIView.animate(withDuration: 0.15, animations: {
            view.frame.origin.x = 100
        }, completion: { _ in completed = true })
        try await waitForHostedLayout(window)
        XCTAssertTrue(completed)
        XCTAssertEqual(view.layer.presentation()?.frame.minX ?? view.frame.minX, 100, accuracy: 0.5)
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0
        animation.duration = 1
        animation.repeatCount = .infinity
        view.layer.add(animation, forKey: "nonsettling")
        defer { view.layer.removeAnimation(forKey: "nonsettling") }
        do {
            try await waitForHostedLayout(window, timeout: .milliseconds(100))
            XCTFail("An active animation must not be accepted as settled")
        } catch is HostedRenderingTimeout {
            // The bounded wait must fail rather than capture a transient frame.
        }
    }
}
