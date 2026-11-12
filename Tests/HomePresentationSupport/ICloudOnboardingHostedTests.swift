import CoreUI
import FeatureSettings
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class ICloudOnboardingHostedTests: XCTestCase {
    func testChoicesRenderInBothThemesAndPrimaryReceivesTVFocus() async throws {
        #if os(tvOS)
        let sizes: [(CGFloat, CGFloat, DynamicTypeSize)] = [(1920, 1080, .large)]
        #else
        let sizes: [(CGFloat, CGFloat, DynamicTypeSize)] = [
            (393, 852, .large), (393, 852, .accessibility1), (1024, 1366, .large)
        ]
        #endif
        for scheme in [ColorScheme.dark, .light] {
            for (width, height, typeSize) in sizes {
                try await render(width: width, height: height, typeSize: typeSize, scheme: scheme)
            }
        }
    }

    private func render(
        width: CGFloat, height: CGFloat, typeSize: DynamicTypeSize, scheme: ColorScheme
    ) async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        var choices: [Bool] = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = UIHostingController(rootView:
            ICloudOnboardingView { choices.append($0) }
                .environment(\.themePalette, scheme == .dark ? .dark : .light)
                .environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.dynamicTypeSize, typeSize)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        #if os(tvOS)
        try await waitUntil { UIFocusSystem(for: window)?.focusedItem != nil }
        #endif
        try await waitForHostedLayout(window)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "iCloud-onboarding-\(Int(width))-\(typeSize)-\(scheme)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let observations = request.results ?? []
        let strings = observations.compactMap { $0.topCandidates(1).first?.string }
        let text = strings.joined(separator: "\n")
        for label in ["iCloud Sync", "Enable iCloud Sync", "Not now", "Settings"] {
            XCTAssertTrue(text.contains(label), "Missing \(label): \(text)")
        }
        XCTAssertTrue(choices.isEmpty, "Rendering/default focus must never accept iCloud for the user.")
        #if os(tvOS)
        let button = try XCTUnwrap(observations.first {
            $0.topCandidates(1).first?.string == "Enable iCloud Sync"
        })
        let center = CGPoint(x: button.boundingBox.midX * window.bounds.width,
                             y: (1 - button.boundingBox.midY) * window.bounds.height)
        let focused = try XCTUnwrap(UIFocusSystem(for: window)?.focusedItem)
        var environment: (any UIFocusEnvironment)? = focused
        var focusedFrame: CGRect?
        while let current = environment {
            if let container = current.focusItemContainer {
                focusedFrame = container.coordinateSpace.convert(focused.frame, to: window)
                break
            }
            environment = current.parentFocusEnvironment
        }
        XCTAssertTrue(try XCTUnwrap(focusedFrame).contains(center),
                      "Enable iCloud Sync, not Not now, must be the initial native focus target.")
        #endif
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }
}
