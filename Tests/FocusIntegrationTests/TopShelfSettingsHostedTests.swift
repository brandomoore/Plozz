import CoreModels
@testable import CoreUI
@testable import FeatureSettings
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class TopShelfSettingsHostedTests: XCTestCase {
    func testBothCountsUseNativeDirectionalControlsAndPersistIndependently() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let suite = "TopShelfSettingsHostedTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = TopShelfSettingsModel(defaults: defaults)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let host = TopShelfFocusHost(rootView:
            TopShelfSettingsView(model: model)
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.themePalette, .dark)
                .frame(width: SettingsFormMetrics.pageWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { self.inputs(in: host).count == 2 }
        let inputs = inputs(in: host)
        defer { inputs.forEach { $0.stopRepeating() } }
        let system = try XCTUnwrap(UIFocusSystem(for: window))
        for (index, input) in inputs.enumerated() {
            let controller = try XCTUnwrap(input as? UIViewController)
            host.target = try XCTUnwrap(focusItems(in: controller.view).first)
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            try await waitUntil { input.ownsHorizontalNavigationInput }
            host.target = nil
            let focused = try XCTUnwrap(system.focusedItem)
            let key: WritableKeyPath<TopShelfSettings, Int> =
                index == 0 ? \.continueWatchingItems : \.recentlyAddedItems
            for _ in 0..<25 { press(.right, input) }
            try await waitUntil { model.settings[keyPath: key] == 20 }
            XCTAssertTrue(system.focusedItem === focused)
            for _ in 0..<25 { press(.left, input) }
            try await waitUntil { model.settings[keyPath: key] == 1 }
            XCTAssertTrue(system.focusedItem === focused)
            press(.right, input)
            try await waitUntil { model.settings[keyPath: key] == 2 }
            XCTAssertEqual(index == 0 ? model.settings.recentlyAddedItems : model.settings.continueWatchingItems,
                           index == 0 ? 4 : 2)
            XCTAssertEqual(TopShelfSettingsModel(defaults: defaults).settings, model.settings)
        }
        try await Task.sleep(for: .milliseconds(400))
        let image = DetailTransitionSnapshot.image(of: window)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Apple TV user’s Top Shelf settings"
        attachment.lifetime = .keepAlways
        add(attachment)
        let page = CGRect(
            x: (window.bounds.width - SettingsFormMetrics.pageWidth) / 2,
            y: 0, width: SettingsFormMetrics.pageWidth, height: window.bounds.height
        ).applying(CGAffineTransform(scaleX: image.scale, y: image.scale))
        let pageImage = try XCTUnwrap(image.cgImage?.cropping(to: page))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: pageImage).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        for label in [
            "Top Shelf", "Show Top Shelf", "Continue Watching", "Recently Added",
            "top row", "Home Screen", "current Apple TV user",
            "Posters", "Full Screen"
        ] {
            XCTAssertTrue(text.localizedCaseInsensitiveContains(label), "Missing settings copy \(label): \(text)")
        }
        XCTAssertFalse(text.contains("Applies to everyone on this device."))
        func textBounds(_ text: String) throws -> CGRect {
            let candidate = try XCTUnwrap(request.results?.compactMap { $0.topCandidates(1).first }
                .first { $0.string.localizedCaseInsensitiveContains(text) }, "Missing settings copy \(text)")
            let range = try XCTUnwrap(candidate.string.range(of: text, options: .caseInsensitive))
            return try XCTUnwrap(candidate.boundingBox(for: range)).boundingBox
        }
        let toggleTitle = try textBounds("Show Top Shelf")
        let description = try textBounds("Place Plozz")
        XCTAssertLessThan(description.maxY, toggleTitle.minY,
                          "The description belongs beneath the toggle title, not above the control.")
        XCTAssertEqual(description.minX, toggleTitle.minX, accuracy: 0.01,
                       "The description should align with the toggle title inside its label.")
        model.settings.usesFullScreen = true
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(TopShelfSettingsModel(defaults: defaults).settings,
                       .init(usesFullScreen: true, continueWatchingItems: 2, recentlyAddedItems: 2))
        let fullscreen = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
        fullscreen.name = "Top Shelf full-screen selection"
        fullscreen.lifetime = .keepAlways
        add(fullscreen)
        model.settings.usesFullScreen = false

        model.settings.isEnabled = false
        try await waitUntil { self.inputs(in: host).isEmpty }
        XCTAssertEqual(TopShelfSettingsModel(defaults: defaults).settings,
                       .init(isEnabled: false, continueWatchingItems: 2, recentlyAddedItems: 2))
        model.settings.isEnabled = true
        try await waitUntil { self.inputs(in: host).count == 2 }
        XCTAssertEqual(model.settings, .init(continueWatchingItems: 2, recentlyAddedItems: 2))
    }

    func testHomeScreenIconLoadsAsATemplateAtSettingsSizes() throws {
        let icon = try XCTUnwrap(UIImage(named: "TopShelfIcon"))
        let white = icon.withTintColor(.white, renderingMode: .alwaysOriginal)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 280, height: 140), format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 280, height: 140))
            for (x, size): (CGFloat, CGFloat) in [(24, 22), (80, 44), (160, 88)] {
                white.draw(in: CGRect(x: x, y: (140 - size) / 2, width: size, height: size))
            }
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Top Shelf Home Screen icon at 22, 44 and 88 points"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func press(_ direction: SettingsMoveCommandDirection, _ input: any SettingsAdjustmentRemoteInput) {
        input.beginPress(direction)
        input.stopRepeating()
    }

    private func inputs(in root: UIViewController) -> [any SettingsAdjustmentRemoteInput] {
        if let input = root as? any SettingsAdjustmentRemoteInput { return [input] }
        return root.children.flatMap { inputs(in: $0) }
    }

    private func focusItems(in view: UIView) -> [any UIFocusItem] {
        var containers: [any UIFocusItemContainer] = [view]
        var seen = Set<ObjectIdentifier>()
        var result: [any UIFocusItem] = []
        while let container = containers.popLast() {
            guard seen.insert(ObjectIdentifier(container)).inserted else { continue }
            let frame = container.coordinateSpace.convert(view.bounds, from: view)
            for item in container.focusItems(in: frame) {
                if let children = item.focusItemContainer { containers.append(children) }
                if let child = item as? UIView { containers.append(child) }
                if item.canBecomeFocused, !(item is UIScrollView) { result.append(item) }
            }
        }
        return result
    }

    private func waitUntil(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private final class TopShelfFocusHost<Content: View>: UIHostingController<Content> {
        weak var target: (any UIFocusEnvironment)?

        override var preferredFocusEnvironments: [any UIFocusEnvironment] {
            target.map { [$0] } ?? super.preferredFocusEnvironments
        }
    }
}
