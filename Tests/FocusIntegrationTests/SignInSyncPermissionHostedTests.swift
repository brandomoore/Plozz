import CoreUI
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class SignInSyncPermissionHostedTests: XCTestCase {
    func testNativePermissionWaitsForSafePresentationAndWithdrawsWithItsRequest() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let model = PermissionFixture()
        let host = UIHostingController(rootView: PermissionFixtureView(model: model))
        window.rootViewController = host
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(host.presentedViewController)
        model.canPresent = true
        try await waitUntil { host.presentedViewController is UIAlertController }
        let alert = try XCTUnwrap(host.presentedViewController as? UIAlertController)
        XCTAssertEqual(alert.title, "Save Sign-ins to iCloud?")
        XCTAssertTrue(alert.message?.contains("iCloud account") == true)
        XCTAssertTrue(alert.message?.contains("Save these sign-ins to this device's iCloud account") == true)
        XCTAssertTrue(alert.message?.contains("sign in automatically on your other devices") == true)
        XCTAssertTrue(alert.message?.contains("Check the account in system Settings") == true)
        XCTAssertFalse(alert.message?.contains("permission to share") == true)
        XCTAssertTrue(alert.message?.contains("Living Room Server") == true)
        XCTAssertEqual(Set(alert.actions.compactMap(\.title)), ["Keep on This Device", "Save to iCloud"])
        XCTAssertEqual(alert.actions.first { $0.title == "Keep on This Device" }?.style, .cancel)
        try await waitUntil { !alert.isBeingPresented }
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "saved-sign-in-sync-permission"
        attachment.lifetime = .keepAlways
        add(attachment)

        model.request = nil
        try await waitUntil { host.presentedViewController == nil }
        XCTAssertEqual(model.responses, 0, "Withdrawal is not consent or rejection")
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(predicate())
    }
}

private struct PermissionRequest: Identifiable, Equatable {
    let id = UUID()
}

@MainActor
@Observable
private final class PermissionFixture {
    var request: PermissionRequest? = .init()
    var canPresent = false
    var responses = 0
}

private struct PermissionFixtureView: View {
    let model: PermissionFixture
    var body: some View {
        Text("Library")
            .signInSyncPermission(
                model.request, canPresent: model.canPresent, sourceNames: { _ in "Living Room Server" }
            ) { _, _ in
                model.responses += 1
                model.request = nil
            }
    }
}
