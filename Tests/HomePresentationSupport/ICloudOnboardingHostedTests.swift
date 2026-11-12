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
        width: CGFloat, height: CGFloat, typeSize: DynamicTypeSize, scheme: ColorScheme,
        restorationFailure: Bool? = nil
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
            Group {
                if let restorationFailure {
                    ICloudRestorationView(
                        hasFailed: restorationFailure,
                        onRetry: { choices.append(true) },
                        onContinue: { choices.append(false) }
                    )
                } else {
                    ICloudOnboardingView { choices.append($0) }
                }
            }
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
        func spinners(in view: UIView) -> [UIActivityIndicatorView] {
            (view as? UIActivityIndicatorView).map { [$0] } ?? view.subviews.flatMap(spinners)
        }
        if restorationFailure == false, !UIAccessibility.isReduceMotionEnabled {
            try await waitUntil { !spinners(in: window).isEmpty }
        }
        // Only the native indeterminate spinner is allowed to keep animating during capture.
        try await waitForHostedLayout(window, ignoringAnimationIn: spinners(in: window).map(\.layer))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "iCloud-onboarding-\(Int(width))-\(typeSize)-\(scheme)-\(String(describing: restorationFailure))"
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let observations = request.results ?? []
        let strings = observations.compactMap { $0.topCandidates(1).first?.string }
        let text = strings.joined(separator: " ")
        let labels: [String]
        if let restorationFailure {
            labels = restorationFailure
                ? ["Couldn't restore your setup", "Retry", "Continue"]
                : ["Restoring your setup", "Continue"]
        } else {
            labels = ["iCloud Sync", "Enable iCloud Sync", "Not now", "Settings"]
        }
        for label in labels {
            XCTAssertTrue(text.contains(label), "Missing \(label): \(text)")
        }
        XCTAssertTrue(choices.isEmpty, "Rendering/default focus must never accept iCloud for the user.")
        #if os(tvOS)
        let expectedFocus = restorationFailure.map { $0 ? "Retry" : "Continue" } ?? "Enable iCloud Sync"
        let button = try XCTUnwrap(observations.first {
            $0.topCandidates(1).first?.string == expectedFocus
        })
        func frame(_ observation: VNRecognizedTextObservation) -> CGRect {
            CGRect(x: observation.boundingBox.minX * window.bounds.width,
                   y: (1 - observation.boundingBox.maxY) * window.bounds.height,
                   width: observation.boundingBox.width * window.bounds.width,
                   height: observation.boundingBox.height * window.bounds.height)
        }
        let focused = try XCTUnwrap(UIFocusSystem(for: window)?.focusedItem)
        var environment = focused.parentFocusEnvironment
        let focusedView = focused as? UIView
        var focusedFrame = focusedView.map { $0.convert($0.bounds, to: window) }
        while focusedFrame == nil, let current = environment {
            if let container = current.focusItemContainer {
                focusedFrame = container.coordinateSpace.convert(focused.frame, to: window)
                break
            }
            environment = current.parentFocusEnvironment
        }
        let nativeFrame = try XCTUnwrap(focusedFrame)
        // SwiftUI's virtual focus frame can exclude part of a centered glass label.
        // Each action owns a separate row; overlap must identify only the intended action.
        XCTAssertTrue(nativeFrame.intersects(frame(button)), "\(expectedFocus) must receive initial focus.")
        for observation in observations {
            guard let label = observation.topCandidates(1).first?.string,
                  ["Retry", "Continue", "Enable iCloud Sync", "Not now"].contains(label),
                  label != expectedFocus else { continue }
            XCTAssertFalse(nativeFrame.intersects(frame(observation)), "\(label) must not receive initial focus.")
        }
        #endif
    }

    func testRestorationAndFailureRenderWithAnAccessibleExit() async throws {
        #if os(tvOS)
        let sizes: [(CGFloat, CGFloat, DynamicTypeSize)] = [(1920, 1080, .large)]
        #else
        let sizes: [(CGFloat, CGFloat, DynamicTypeSize)] = [
            (393, 852, .large), (393, 852, .accessibility1), (1024, 1366, .large)
        ]
        #endif
        for failed in [false, true] {
            for scheme in [ColorScheme.dark, .light] {
                for (width, height, typeSize) in sizes {
                    try await render(width: width, height: height, typeSize: typeSize,
                                     scheme: scheme, restorationFailure: failed)
                }
            }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }
}
