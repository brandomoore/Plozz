#if os(tvOS)
@testable import AppShell
import CoreUI
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class FirstRunProviderChoicesHostedTests: XCTestCase {
    func testFirstRunAndAccountManagementChooseProvidersNotPlaybackDestinations() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for canReturnToApp in [false, true] {
            window.rootViewController = UIHostingController(rootView:
                AddAccountView(
                    deviceID: "first-run-choice-fixture", canReturnToApp: canReturnToApp,
                    onMediaBrowserServerSelected: { _ in }, onPlexAuthenticated: { _ in },
                    onCancel: {}, onSetUpFromAnotherDevice: {}
                )
                .environment(\.themePalette, .dark)
                .environment(\.locale, Locale(identifier: "en_US"))
                .preferredColorScheme(.dark)
            )
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(350))
            window.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = canReturnToApp ? "add-account-provider-choices" : "first-run-provider-choices"
            attachment.lifetime = .keepAlways
            add(attachment)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.customWords = ["IPTV", "Plozz"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            XCTAssertEqual(labels.filter { $0 == "IPTV" }.count, 1, "\(labels)")
            XCTAssertFalse(labels.contains { $0.contains("Live TV") }, "\(labels)")
            XCTAssertTrue(labels.contains("Jellyfin"), "\(labels)")
            XCTAssertTrue(labels.contains("Media Share"), "\(labels)")
        }
    }
}
#endif
