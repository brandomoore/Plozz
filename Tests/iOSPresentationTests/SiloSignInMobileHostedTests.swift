import CoreModels
import CoreUI
import FeatureAuth
import FeatureAuthCore
import ProviderSilo
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class SiloSignInMobileHostedTests: XCTestCase {
    func testMobileApprovalAndProfileRowsKeepPrimaryActionsReadable() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        for light in [false, true] {
            let http = OnboardingPreviewHTTP()
            let url = URL(string: "https://silo.example.test")!
            let server = MediaServer(id: "fixture", name: "Silo", baseURL: url, provider: .silo)
            let model = SiloAuthViewModel(
                server: server, deviceID: "fixture",
                service: SiloAuthentication(baseURL: url, http: http),
                onAuthenticated: { _ in XCTFail("The fixture must not authorize a real account.") }
            )
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView:
                SiloSignInView(viewModel: model, server: server, onCancel: {})
                    .environment(\.themePalette, light ? .light : .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .preferredColorScheme(light ? .light : .dark)
                    .background(light ? Color.white : Color.black)
            )
            window.makeKeyAndVisible()
            defer {
                model.cancel()
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            try await wait { if case .pairing = model.phase { return true }; return false }
            let pairing = try await capture(window, name: "silo-mobile-pairing-\(light)")
            XCTAssertTrue(pairing.contains("Open Silo to approve"), pairing)
            XCTAssertTrue(pairing.contains("Before approving"), pairing)
            XCTAssertFalse(pairing.contains("Or enter a code at"), "Manual alternatives stay in their disclosure.")
            await http.approve()
            try await wait { if case .profiles = model.phase { return true }; return false }
            let profiles = try await capture(window, name: "silo-mobile-profiles-\(light)")
            for name in ["Alex", "Sam", "Kids", "PIN"] { XCTAssertTrue(profiles.contains(name), profiles) }
            guard case let .profiles(choices) = model.phase,
                  let locked = choices.first(where: \.has_pin) else { return XCTFail("Missing protected profile.") }
            model.select(locked)
            XCTAssertEqual(model.phase, .pin(locked))
        }
    }

    private func capture(_ window: UIWindow, name: String) async throws -> String {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }
}
