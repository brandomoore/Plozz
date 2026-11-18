#if os(tvOS)
@testable import AppShell
import CoreUI
import FeatureAuth
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class FirstRunProviderChoicesHostedTests: XCTestCase {
    func testSubsonicSignInUsesNativeAuthenticationSegments() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.rootViewController = UIHostingController(rootView:
            SubsonicSignInView(
                deviceID: "subsonic-sign-in-fixture", onAuthenticated: { _ in }, onCancel: {}
            )
            .environment(\.themePalette, .dark)
            .environment(\.locale, Locale(identifier: "en_US"))
            .preferredColorScheme(.dark)
        )
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(350))
        window.layoutIfNeeded()
        func segments(in view: UIView) -> UISegmentedControl? {
            if let control = view as? UISegmentedControl { return control }
            return view.subviews.lazy.compactMap { segments(in: $0) }.first
        }
        let control = try XCTUnwrap(segments(in: window))
        XCTAssertEqual(control.numberOfSegments, 2)
        XCTAssertEqual(control.titleForSegment(at: 0), "Password")
        XCTAssertEqual(control.titleForSegment(at: 1), "API Key")
        XCTAssertEqual(control.selectedSegmentIndex, 0)
        for index in [0, 1] {
            control.selectedSegmentIndex = index
            control.sendActions(for: .valueChanged)
            try await Task.sleep(for: .milliseconds(350))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = index == 0 ? "Subsonic-TV-password" : "Subsonic-TV-api-key"
            attachment.lifetime = .keepAlways
            add(attachment)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            XCTAssertEqual(labels.contains { $0.contains("Requires a server") }, index == 1, "\(labels)")
        }
    }

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
            XCTAssertTrue(labels.contains { $0.contains("Navidrome") }, "\(labels)")
            let music = try XCTUnwrap(request.results?.first {
                $0.topCandidates(1).first?.string.contains("Navidrome") == true
            })
            XCTAssertGreaterThan(music.boundingBox.minY * window.bounds.height, 140,
                                 "Music sign-in must leave space for the bottom transfer control")
            XCTAssertEqual(labels.contains("Add Source"), canReturnToApp, "\(labels)")
            if canReturnToApp {
                let heading = try XCTUnwrap(request.results?.first { $0.topCandidates(1).first?.string == "Add Source" })
                let firstProvider = try XCTUnwrap(request.results?.first { $0.topCandidates(1).first?.string == "Jellyfin" })
                XCTAssertGreaterThanOrEqual(
                    (heading.boundingBox.minY - firstProvider.boundingBox.maxY) * window.bounds.height, 60,
                    "The source heading must remain separated from the provider choices"
                )
            }
        }
    }
}
#endif
