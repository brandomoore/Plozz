#if os(tvOS) && DEBUG
@testable import CoreUI
import SwiftUI
import UIKit
import XCTest
import notify

@MainActor
final class DiagnosticRecordingStatusHostedTests: XCTestCase {
    func testAppRootModifierSurvivesFullScreenPresentation() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView:
            Button("Keep focus here") {}.diagnosticRecordingStatus()
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let cover = UIHostingController(rootView: Text("Full-screen cover"))
        cover.modalPresentationStyle = .fullScreen
        window.rootViewController?.present(cover, animated: false)
        try await Task.sleep(for: .milliseconds(200))
        let visible = expectation(description: "App-root modifier receives the device notification")
        var token: Int32 = 0
        XCTAssertEqual(notify_register_dispatch(
            DiagnosticRecordingPhase.preparing.acknowledgement, &token, .main
        ) { _ in visible.fulfill() }, UInt32(NOTIFY_STATUS_OK))
        defer { notify_cancel(token) }
        XCTAssertEqual(notify_post(DiagnosticRecordingPhase.preparing.notification), UInt32(NOTIFY_STATUS_OK))
        await fulfillment(of: [visible], timeout: 2)
        XCTAssertNotNil(window.subviews.first { $0.accessibilityIdentifier == "diagnostic-recording-status" })
    }

    func testRecordingBadgeAcknowledgesVisibilityWithoutTakingFocusAndExpires() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let host = UIHostingController(rootView: Button("Keep focus here") {})
        window.rootViewController = host
        window.makeKeyAndVisible()
        let controller = DiagnosticRecordingController()
        defer {
            controller.invalidate()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        controller.attach(to: window)
        let focusSystem = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        let deadline = ContinuousClock.now + .seconds(5)
        while focusSystem.focusedItem == nil, ContinuousClock.now < deadline {
            window.layoutIfNeeded()
            focusSystem.requestFocusUpdate(to: host)
            focusSystem.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let focused = try XCTUnwrap(focusSystem.focusedItem)
        let visible = expectation(description: "Recording indicator acknowledges its installed view")
        var token: Int32 = 0
        XCTAssertEqual(notify_register_dispatch(
            DiagnosticRecordingPhase.recording.acknowledgement, &token, .main
        ) { _ in visible.fulfill() }, UInt32(NOTIFY_STATUS_OK))
        defer { notify_cancel(token) }
        XCTAssertEqual(notify_post(DiagnosticRecordingPhase.recording.notification), UInt32(NOTIFY_STATUS_OK))
        await fulfillment(of: [visible], timeout: 2)
        let badge = try XCTUnwrap(controller.badge)
        XCTAssertTrue(badge.superview === window)
        XCTAssertFalse(badge.canBecomeFocused)
        XCTAssertFalse(badge.isUserInteractionEnabled)
        XCTAssertTrue(UIFocusSystem.focusSystem(for: window)?.focusedItem === focused)
        XCTAssertTrue(window.bounds.contains(badge.frame))
        XCTAssertEqual(badge.layer.animation(forKey: "recording-expiry")?.duration, 15)
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "Recording badge does not take focus"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Expiration is also armed in Core Animation, so a main-thread stall
        // cannot leave a stale red recording badge indefinitely.
        try await Task.sleep(for: .seconds(15.2))
        XCTAssertNil(controller.badge)
        XCTAssertNil(controller.phase)
        XCTAssertNil(badge.superview)
    }
}
#endif
