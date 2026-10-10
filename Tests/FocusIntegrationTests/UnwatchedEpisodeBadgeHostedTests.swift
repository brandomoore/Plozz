#if os(tvOS)
import CoreModels
@testable import CoreUI
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class UnwatchedEpisodeBadgeHostedTests: XCTestCase {
    func testSharedBadgeRendersExactDigitsAndPreservesFallbacks() throws {
        for scheme in [ColorScheme.dark, .light] {
            for count in [1, 8, 24, 12345] {
                let item = MediaItem(id: "show", title: "Show", kind: .series, playedPercentage: 0.3, unwatchedEpisodeCount: count)
                let image = try render(item, enabled: true, scheme: scheme)
                attach(image, name: "episode-count-\(count)-\(scheme)")
                if count >= 10 {
                    let text = try recognizedText(image)
                    let badge = try XCTUnwrap(text.first { $0.text == "\(count)" }, "Expected \(count), got \(text.map(\.text))")
                    XCTAssertGreaterThan(badge.bounds.midX, 0.65)
                    XCTAssertGreaterThan(badge.bounds.midY, 0.8, "Count must occupy the existing top-right slot")
                }
                XCTAssertNotEqual(
                    image.pngData(), try render(item, enabled: false, scheme: scheme).pngData(),
                    "Enabling the known count must paint a badge")
                XCTAssertFalse(try recognizedText(render(item, enabled: false, scheme: scheme)).contains { $0.text == "\(count)" })
                XCTAssertFalse(try recognizedText(render(item, enabled: true, scheme: scheme, hidesStatus: true)).contains { $0.text == "\(count)" })
            }
        }
        let complete = MediaItem(id: "show", title: "Show", kind: .series, unwatchedEpisodeCount: 0, isPlayed: true)
        XCTAssertEqual(
            try render(complete, enabled: true, scheme: .dark).pngData(),
            try render(complete, enabled: false, scheme: .dark).pngData(),
            "Completed titles preserve the existing watched style")
        let unknown = MediaItem(id: "show", title: "Show", kind: .series)
        XCTAssertEqual(
            try render(unknown, enabled: true, scheme: .dark).pngData(),
            try render(unknown, enabled: false, scheme: .dark).pngData(),
            "Unknown counts preserve the existing indicator")
    }

    func testNativeCellUpdatesPreferenceAndCountWithoutReplacingItsItemIdentity() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view.backgroundColor = .gray
        window.rootViewController = controller
        let cell = NativeTVLibraryCell(frame: .zero)
        controller.view.addSubview(cell)
        window.makeKeyAndVisible()
        defer {
            cell.prepareForReuse()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        var environment = EnvironmentValues()
        environment.locale = Locale(identifier: "en_US")
        environment.plozzCardStyle = .borderless
        environment.isEnabled = false
        var item = MediaItem(
            id: "same-show", title: "Show", kind: .series, playedPercentage: 0.3,
            unwatchedEpisodeCount: 8, allowsTitleBasedMetadataMatching: false)
        for scheme in [ColorScheme.dark, .light] {
            environment.colorScheme = scheme
            environment.themePalette = scheme == .dark ? .dark : .light
            cell.frame = CGRect(x: 300, y: 200, width: 320, height: NativeTVLibraryCell.height(for: 320, environment: environment))
            for enabled in [false, true, false, true] {
                environment.plozzShowsUnwatchedEpisodeCount = enabled
                if enabled { item.unwatchedEpisodeCount = 12345 }
                cell.configure(item: item, spoilerSettings: .default, environment: environment)
                cell.updateConfiguration(using: cell.configurationState)
                let deadline = ContinuousClock.now + .seconds(3)
                var hasCount = false
                repeat {
                    try await Task.sleep(for: .milliseconds(100))
                    window.layoutIfNeeded()
                    let image = snapshot(cell)
                    hasCount = try recognizedText(image).contains { $0.text == "12345" }
                    if hasCount == enabled {
                        attach(image, name: "native-episode-count-\(scheme)-\(enabled)")
                        break
                    }
                } while ContinuousClock.now < deadline
                XCTAssertEqual(hasCount, enabled)
                if enabled {
                    var label = try XCTUnwrap(MediaPlaybackIndicatorState(item).episodeCountAccessibilityLabel(
                        enabled: true, hidesStatus: false))
                    label.locale = environment.locale
                    XCTAssertTrue(cell.accessibilityValue?.contains(String(localized: label)) ?? false,
                                  "Actual native accessibility value: \(cell.accessibilityValue ?? "nil")")
                } else {
                    XCTAssertFalse(cell.accessibilityValue?.contains("Unwatched episodes:") ?? false)
                }
                XCTAssertEqual(cell.item?.id, "same-show")
            }
        }
    }

    private func render(
        _ item: MediaItem, enabled: Bool, scheme: ColorScheme, hidesStatus: Bool = false
    ) throws -> UIImage {
        let renderer = ImageRenderer(content:
            MediaCardPlaybackIndicators(item: item, hidesStatus: hidesStatus, badgeInset: 8)
                .frame(width: 240, height: 360)
                .background(Color.gray)
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.colorScheme, scheme)
                .environment(\.themePalette, scheme == .dark ? .dark : .light)
                .environment(\.plozzWatchStatusIndicator, .watched)
                .environment(\.plozzShowsUnwatchedEpisodeCount, enabled)
        )
        renderer.scale = 3
        return try XCTUnwrap(renderer.uiImage)
    }

    private func snapshot(_ view: UIView) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }

    private func recognizedText(_ image: UIImage) throws -> [(text: String, bounds: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { result in
            result.topCandidates(1).first.map { ($0.string, result.boundingBox) }
        }
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
