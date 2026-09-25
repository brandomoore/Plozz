import CoreModels
@testable import CoreUI
@testable import FeaturePlayback
import SwiftUI
import UIKit
import XCTest

@MainActor
final class SubtitleStylePlayerBoundsHostedTests: XCTestCase {
    func testExpandedSystemStyleControlsScrollInsideThePlayerViewport() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = PlayerControlsModel()
        model.controlsVisible = true
        model.subtitleStyle = .profileDefault
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        PlayerScreenshotHook.pendingPanel = .subtitleStyle
        let host = UIHostingController(rootView: PlayerControls(
            model: model, palette: .dark, actions: PlayerOptionsActions(), onExitToSurface: {}
        ).background(.black))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            PlayerScreenshotHook.pendingPanel = nil
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        func scrolls(_ view: UIView) -> [UIScrollView] {
            let own = (view as? UIScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap(scrolls)
        }
        let ready = ContinuousClock.now + .seconds(5)
        var editor: UIScrollView?
        while ContinuousClock.now < ready {
            window.layoutIfNeeded()
            editor = scrolls(host.view).first {
                // UIKit adds focus margins outside the logical panel content.
                abs($0.contentSize.width - SubtitleStylePanel.panelWidth) < 1
                    && $0.bounds.height > 440
                    && $0.contentSize.height > $0.bounds.height + 40
            }
            if editor != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let diagnostics = scrolls(host.view).map {
            "bounds=\($0.bounds), content=\($0.contentSize), enabled=\($0.isScrollEnabled)"
        }.joined(separator: "; ")
        let scroll = try XCTUnwrap(editor, "panelOpen=\(model.isPanelOpen); \(diagnostics)")
        XCTAssertTrue(scroll.isScrollEnabled)
        let frame = scroll.convert(scroll.bounds, to: window)
        XCTAssertGreaterThan(frame.height, 440, "The style editor should use the larger available viewport.")
        XCTAssertGreaterThanOrEqual(frame.minY, 0)
        XCTAssertLessThanOrEqual(frame.maxY, window.bounds.maxY)
        XCTAssertNotNil(UIFocusSystem(for: window)?.focusedItem)
    }
}
