#if os(tvOS)
import CoreModels
import CoreImage
import CoreNetworking
@testable import CoreUI
@testable import AppShell
import FeatureAuth
import FeatureAuthCore
import ProviderSilo
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class SiloOnboardingHostedTests: XCTestCase {
    func testPairingLayoutsAndApprovalFocusesFirstProfile() async throws {
        try await wait {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
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
        for light in [false, true] {
            let url = URL(string: "https://silo.example.test")!
            let server = MediaServer(id: "fixture", name: "Silo", baseURL: url, provider: .silo)
            let http = OnboardingPreviewHTTP()
            let model = SiloAuthViewModel(
                server: server, deviceID: "fixture",
                service: SiloAuthentication(baseURL: url, http: http),
                onAuthenticated: { _ in XCTFail("Preview must not create a real account") }
            )
            let host = UIHostingController(rootView:
                SiloSignInView(viewModel: model, server: server, onCancel: {})
                    .environment(\.themePalette, light ? .light : .dark)
                    .preferredColorScheme(light ? .light : .dark)
                    .background(light ? Color.white : Color.black)
            )
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { model.cancel() }
            try await wait { if case .pairing = model.phase { return true }; return false }
            try await Task.sleep(for: .seconds(1))
            window.layoutIfNeeded()
            let pairingImage = capture(window, name: light ? "silo-pairing-light" : "silo-pairing-dark")
            let pairingText = try recognize(pairingImage)
            XCTAssertTrue(pairingText.contains("Scan with your phone"), pairingText)
            XCTAssertTrue(pairingText.contains("Or enter a code at"), pairingText)
            XCTAssertTrue(pairingText.contains("Before approving"), pairingText)
            XCTAssertTrue(pairingText.contains("calm river"), pairingText)
            XCTAssertFalse(pairingText.contains("Waiting for approval"), pairingText)
            XCTAssertFalse(pairingText.contains("Code expires in"), pairingText)
            let qrImage = try XCTUnwrap(pairingImage.cgImage)
            let payloads = await Task.detached {
                let detector = CIDetector(
                    ofType: CIDetectorTypeQRCode, context: nil,
                    options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
                )
                let image = CIImage(cgImage: qrImage)
                return [image, image.applyingFilter("CIColorInvert")].flatMap { candidate in
                    (detector?.features(in: candidate) ?? []).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
                }
            }.value
            XCTAssertTrue(payloads.contains("https://silo.example.test/pair?code=ABCD-EFGH"),
                          "The production QR must remain scannable in both themes.")
            await http.approve()
            try await wait { if case .profiles = model.phase { return true }; return false }
            try await wait {
                guard let focused = UIFocusSystem.focusSystem(for: window)?.focusedItem,
                      let frame = NavigationRowFocusRequester.frame(of: focused, relativeTo: window) else { return false }
                return frame.width > 600 && frame.height > 50 && frame.height < 150
            }
            let profilesImage = capture(window, name: light ? "silo-profiles-light" : "silo-profiles-dark")
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(profilesImage.cgImage)).perform([text])
            let alex = try XCTUnwrap(text.results?.first {
                $0.topCandidates(1).first?.string.hasSuffix("Alex") == true
            })
            let focused = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem)
            let frame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: focused, relativeTo: window))
            XCTAssertTrue(window.bounds.contains(frame),
                          "The first profile must be on-screen, not just assigned in FocusState")
            XCTAssertTrue(frame.contains(CGPoint(
                x: alex.boundingBox.midX * window.bounds.width,
                y: (1 - alex.boundingBox.midY) * window.bounds.height
            )), "The actual focused avatar row must be Alex.")
        }
    }

    private func recognize(_ image: UIImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func capture(_ window: UIWindow, name: String) -> UIImage {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }
}

#endif
