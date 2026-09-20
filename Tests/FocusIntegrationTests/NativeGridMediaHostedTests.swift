#if os(tvOS)
import CoreModels
@testable import CoreUI
import SwiftUI
import TVUIKit
import UIKit
import XCTest

@MainActor
final class NativeGridMediaHostedTests: XCTestCase {
    func testGridFocusKeepsNativePresentationAndBorderlessCaptionOutsideArtwork() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for style in [CardStyle.framed, .borderless] {
            let host = UIHostingController(rootView:
                PosterCardView(
                    item: MediaItem(id: "grid-poster", title: "Native library poster", kind: .movie),
                    enablesAsyncArtworkFallback: false,
                    action: {}
                )
                .environment(\.plozzNativeGridFocus, true)
                .environment(\.plozzCardFocusStyle, .system)
                .environment(\.plozzCardStyle, style)
                .environment(\.plozzMetrics, .standard)
                .environment(\.themePalette, .dark)
                .frame(width: 300)
            )
            let controller = UIViewController()
            window.rootViewController = controller
            controller.addChild(host)
            controller.view.addSubview(host.view)
            host.didMove(toParent: controller)
            let size = host.sizeThatFits(in: CGSize(width: 300, height: 1000))
            host.view.frame = CGRect(origin: CGPoint(x: 200, y: 180), size: size)
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            focus.requestFocusUpdate(to: host)
            focus.updateFocusIfNeeded()

            let deadline = ContinuousClock.now + .seconds(4)
            var media = descendant(TVMediaItemContentView.self, in: host.view)
            while (media?.superview as? any NativeGridFocusContainer)?.isMediaFocused != true,
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
                media = descendant(TVMediaItemContentView.self, in: host.view)
            }
            let native = try XCTUnwrap(media)
            XCTAssertTrue((native.superview as? any NativeGridFocusContainer)?.isMediaFocused == true)
            XCTAssertNotNil(focus.focusedItem)
            XCTAssertNil(descendant(TVLockupView.self, in: host.view),
                         "Recycled control-owned focus must not replace the stable grid focus owner.")
            XCTAssertGreaterThan(native.focusedFrameGuide.layoutFrame.width, native.bounds.width)
            XCTAssertGreaterThan(native.focusedFrameGuide.layoutFrame.height, native.bounds.height)
            if style == .borderless {
                XCTAssertEqual(native.bounds.height / native.bounds.width, 1.5, accuracy: 0.02)
                let caption = try XCTUnwrap(descendant(SystemPosterCaption.CaptionView.self, in: host.view))
                XCTAssertFalse(caption.isDescendant(of: native))
                let imageFrame = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: native, in: window))
                let captionFrame = caption.convert(caption.bounds, to: window)
                XCTAssertGreaterThanOrEqual(captionFrame.minY, imageFrame.maxY - 1)
            }
            XCTAssertEqual(host.view.bounds.width, size.width, accuracy: 0.5)
            XCTAssertEqual(host.view.bounds.height, size.height, accuracy: 0.5)
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
    }

    private func descendant<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }
}
#endif
