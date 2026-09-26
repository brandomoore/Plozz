import CoreModels
@testable import FeaturePlayback
import SwiftUI
import UIKit
import XCTest

@MainActor
final class SystemCaptionStyleConfirmationHostedTests: XCTestCase {
    func testOverwriteWarningOffersCancelWithoutChangingTheCustomStyle() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let confirmation = SystemCaptionStyleConfirmation()
        var style = SubtitleStyle.default
        style.fontScale = 1.37
        let original = style
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: Text("Subtitle style")
            .modifier(SystemCaptionStyleConfirmationDialog(confirmation: confirmation) {
                style.followsSystemStyle = $0
            }))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            confirmation.cancel()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        confirmation.request(true, currentlyMatching: false) { style.followsSystemStyle = $0 }
        try await waitUntil { host.presentedViewController is UIAlertController }
        let alert = try XCTUnwrap(host.presentedViewController as? UIAlertController)
        XCTAssertEqual(alert.message, "This will replace your custom subtitle style with your device's system subtitle style.")
        XCTAssertTrue(alert.actions.contains { $0.title == "Cancel" && $0.style == .cancel })
        XCTAssertTrue(alert.actions.contains { $0.title == "Use System Style" })
        XCTAssertEqual(style, original)
        confirmation.cancel()
        try await waitUntil { host.presentedViewController == nil }
        XCTAssertEqual(style, original)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }
}
