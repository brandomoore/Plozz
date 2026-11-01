import CoreModels
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import CoreUI
@testable import FeaturePlayback

@MainActor
final class SubtitlePositionPresentationTests: XCTestCase {
    func testPositionAndVerticalOffsetLabelsRenderForBothReferences() async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }

        for (reference, title) in [
            (SubtitleStyle.PositionReference.screen, "Bottom of screen"),
            (.picture, "Bottom of video")
        ] {
            var style = SubtitleStyle.default
            style.followsSystemStyle = false
            style.fontFamily = .system
            style.positionReference = reference
            #if os(tvOS)
            let host = UIHostingController(rootView: NavigationStack {
                SubtitleStyleSettingsView(style: .constant(style))
            }.environment(\.themePalette, .dark).environment(\.locale, Locale(identifier: "en_US"))
                .preferredColorScheme(.dark))
            #else
            let controls = PlayerControlsModel()
            controls.subtitleStyle = style
            let host = UIHostingController(rootView: NavigationStack {
                MobileSubtitleStyleEditor(viewModel: SubtitleStyleEditingContext(
                    controls: controls, style: .constant(style), secondaryPreview: .constant(false)
                ))
            }.environment(\.themePalette, .dark).environment(\.locale, Locale(identifier: "en_US"))
                .preferredColorScheme(.dark))
            #endif
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .seconds(2))
            window.layoutIfNeeded()

            #if os(tvOS)
            let image = DetailTransitionSnapshot.image(of: window)
            #else
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            #endif
            let attachment = XCTAttachment(image: image)
            attachment.name = title
            attachment.lifetime = .keepAlways
            add(attachment)

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            for label in ["Position", title, "Vertical offset"] {
                XCTAssertTrue(text.contains(label), "Missing \(label): \(text)")
            }
            XCTAssertFalse(text.contains("Position relative to"))
        }
    }
}
