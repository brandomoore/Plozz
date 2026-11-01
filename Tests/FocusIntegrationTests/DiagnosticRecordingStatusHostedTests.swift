#if (os(tvOS) || os(iOS)) && DEBUG
@testable import CoreUI
import SwiftUI
import UIKit
import Vision
import XCTest
import notify

@MainActor
final class DiagnosticRecordingStatusHostedTests: XCTestCase {
    func testAppRootModifierSurvivesFullScreenPresentation() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
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
        let requestedAt = Date()
        XCTAssertEqual(notify_post(DiagnosticRecordingPhase.preparing.notification), UInt32(NOTIFY_STATUS_OK))
        await fulfillment(of: [visible], timeout: 2)
        let badge = try XCTUnwrap(scene.windows.flatMap {
            $0.rootViewController?.view.subviews ?? []
        }.first { $0.accessibilityIdentifier == "diagnostic-recording-status" })
        XCTAssertFalse(badge.window === window)
        XCTAssertGreaterThan(try XCTUnwrap(badge.window).windowLevel, window.windowLevel)
        try assertVisibleText("Preparing recording", in: scene)
        let directory = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
        let imageMap = directory.appendingPathComponent("Plozz/diagnostic-images-preparing.json")
        let deadline = ContinuousClock.now + .seconds(5)
        var exported = false
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: imageMap.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: imageMap.path)
                if let modified = attributes[.modificationDate] as? Date, modified >= requestedAt {
                    exported = true
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(exported, "Preparing must export a fresh map asynchronously.")
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: imageMap)) as? [String: Any])
        XCTAssertEqual(metadata["processIdentifier"] as? Int, Int(ProcessInfo.processInfo.processIdentifier))
        XCTAssertEqual(metadata["phase"] as? String, "preparing")
        XCTAssertFalse(try XCTUnwrap(metadata["images"] as? [[String: Any]]).isEmpty)
    }

    func testRecordingBadgeAcknowledgesVisibilityWithoutTakingFocusAndExpires() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
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
        #if os(tvOS)
        let focusSystem = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        let deadline = ContinuousClock.now + .seconds(5)
        while focusSystem.focusedItem == nil, ContinuousClock.now < deadline {
            window.layoutIfNeeded()
            focusSystem.requestFocusUpdate(to: host)
            focusSystem.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let focused = try XCTUnwrap(focusSystem.focusedItem)
        #endif
        let visible = expectation(description: "Recording indicator acknowledges its installed view")
        var token: Int32 = 0
        XCTAssertEqual(notify_register_dispatch(
            DiagnosticRecordingPhase.recording.acknowledgement, &token, .main
        ) { _ in visible.fulfill() }, UInt32(NOTIFY_STATUS_OK))
        defer { notify_cancel(token) }
        XCTAssertEqual(notify_post(DiagnosticRecordingPhase.recording.notification), UInt32(NOTIFY_STATUS_OK))
        await fulfillment(of: [visible], timeout: 2)
        let badge = try XCTUnwrap(controller.badge)
        let overlay = try XCTUnwrap(controller.overlayWindow)
        XCTAssertTrue(badge.window === overlay)
        XCTAssertFalse(overlay.canBecomeKey)
        XCTAssertFalse(overlay.isKeyWindow)
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertNil(overlay.hitTest(CGPoint(x: 40, y: 40), with: nil))
        XCTAssertFalse(badge.canBecomeFocused)
        XCTAssertFalse(badge.isUserInteractionEnabled)
        XCTAssertEqual(badge.accessibilityLabel, String(localized: DiagnosticRecordingPhase.recording.text))
        XCTAssertEqual(badge.text, "  \u{25CF}  Recording  ")
        XCTAssertEqual(
            badge.attributedText?.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? UIColor,
            .systemRed
        )
        #if os(tvOS)
        XCTAssertTrue(UIFocusSystem.focusSystem(for: window)?.focusedItem === focused)
        #endif
        XCTAssertTrue(overlay.bounds.contains(badge.convert(badge.bounds, to: overlay)))
        XCTAssertEqual(badge.layer.animation(forKey: "recording-expiry")?.duration, 15)
        let screenshot = try assertVisibleText("Recording", in: scene)
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
        XCTAssertNil(controller.overlayWindow)
    }

    func testBadgeStaysAboveSecondaryAppWindowAcrossEveryPhase() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let controller = DiagnosticRecordingController()
        controller.attach(to: window)
        let cover = UIWindow(windowScene: scene)
        cover.rootViewController = UIViewController()
        cover.rootViewController?.view.backgroundColor = .blue
        cover.windowLevel = .alert
        cover.makeKeyAndVisible()
        defer {
            controller.invalidate()
            cover.isHidden = true
            cover.rootViewController = nil
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        // Moving/detaching the root's probe must not replace the scene receiver.
        controller.attach(to: nil)
        controller.attach(to: cover)
        for phase in DiagnosticRecordingPhase.allCases {
            controller.receive(phase)
            try await Task.sleep(for: .milliseconds(100))
            let overlay = try XCTUnwrap(controller.overlayWindow)
            XCTAssertGreaterThan(overlay.windowLevel, cover.windowLevel)
            XCTAssertTrue(cover.isKeyWindow)
            XCTAssertNil(overlay.hitTest(overlay.bounds.origin, with: nil))
            XCTAssertEqual(controller.badge?.accessibilityLabel, String(localized: phase.text))
            try assertVisibleText(phase == .preparing ? "Preparing recording" : String(localized: phase.text), in: scene)
        }
        controller.clearBadge()
        XCTAssertNil(controller.overlayWindow)
        XCTAssertTrue(cover.isKeyWindow)
    }

    @discardableResult
    private func assertVisibleText(_ expected: String, in scene: UIWindowScene) throws -> UIImage {
        let image = UIGraphicsImageRenderer(bounds: scene.coordinateSpace.bounds).image { _ in
            for window in scene.windows.sorted(by: { $0.windowLevel < $1.windowLevel })
                where !window.isHidden && window.alpha > 0 {
                window.layoutIfNeeded()
                window.drawHierarchy(
                    in: window.convert(window.bounds, to: scene.coordinateSpace), afterScreenUpdates: true
                )
            }
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.008
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(text.contains(expected), "Composited scene must show \(expected); read \(text)")
        return image
    }
}
#endif
