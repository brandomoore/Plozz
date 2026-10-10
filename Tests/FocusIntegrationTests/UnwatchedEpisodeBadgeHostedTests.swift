#if os(tvOS)
import CoreModels
@testable import CoreUI
import SwiftUI
import TVUIKit
import UIKit
import Vision
import XCTest

@MainActor
final class UnwatchedEpisodeBadgeHostedTests: XCTestCase {
    func testSharedBadgeRendersExactDigitsAndPreservesFallbacks() throws {
        for indicator in WatchStatusIndicator.allCases {
            try verifyDigitsAndFallbacks(indicator: indicator)
        }
    }

    private func verifyDigitsAndFallbacks(indicator: WatchStatusIndicator) throws {
        for scheme in [ColorScheme.dark, .light] {
            for count in [1, 8, 24, 12345] {
                let item = MediaItem(id: "show", title: "Show", kind: .series, playedPercentage: 0.3, unwatchedEpisodeCount: count)
                let image = try render(item, enabled: true, scheme: scheme, indicator: indicator)
                attach(image, name: "episode-count-\(indicator)-\(count)-\(scheme)")
                if count >= 10 {
                    let text = try recognizedText(image)
                    let badge = try XCTUnwrap(text.first { $0.text == "\(count)" }, "Expected \(count), got \(text.map(\.text))")
                    XCTAssertGreaterThan(badge.bounds.midX, 0.65)
                    XCTAssertGreaterThan(badge.bounds.midY, 0.8, "Count must occupy the existing top-right slot")
                }
                XCTAssertNotEqual(
                    image.pngData(), try render(item, enabled: false, scheme: scheme, indicator: indicator).pngData(),
                    "Enabling the known count must paint a badge")
                XCTAssertFalse(try recognizedText(render(item, enabled: false, scheme: scheme, indicator: indicator)).contains { $0.text == "\(count)" })
                XCTAssertFalse(try recognizedText(render(item, enabled: true, scheme: scheme, hidesStatus: true, indicator: indicator)).contains { $0.text == "\(count)" })
            }
        }
        let complete = MediaItem(id: "show", title: "Show", kind: .series, unwatchedEpisodeCount: 0, isPlayed: true)
        XCTAssertEqual(
            try render(complete, enabled: true, scheme: .dark, indicator: indicator).pngData(),
            try render(complete, enabled: false, scheme: .dark, indicator: indicator).pngData(),
            "Completed titles preserve the existing watched style")
        let unknown = MediaItem(id: "show", title: "Show", kind: .series)
        XCTAssertEqual(
            try render(unknown, enabled: true, scheme: .dark, indicator: indicator).pngData(),
            try render(unknown, enabled: false, scheme: .dark, indicator: indicator).pngData(),
            "Unknown counts preserve the existing indicator")
    }

    func testWhiteDesignsPreserveMovieFallbacksAndUnclippedCurvedShadow() throws {
        let show = MediaItem(id: "show", title: "Show", kind: .series, unwatchedEpisodeCount: 21)
        let unwatched = MediaItem(id: "movie", title: "Movie", kind: .movie, unwatchedEpisodeCount: 21)
        let watched = MediaItem(id: "movie", title: "Movie", kind: .movie, isPlayed: true)
        for indicator in WatchStatusIndicator.allCases {
            XCTAssertEqual(
                try render(unwatched, enabled: true, scheme: .dark, indicator: indicator).pngData(),
                try render(unwatched, enabled: false, scheme: .dark, indicator: indicator).pngData(),
                "Movies must keep their unnumbered state even if a provider supplies a count")
            let marked = indicator == .watched ? watched : unwatched
            let image = try render(marked, enabled: true, scheme: .dark, indicator: indicator)
            let sample = try pixel(image, at: indicator == .watched
                                   ? CGPoint(x: 203, y: 22) : CGPoint(x: 230, y: 5))
            XCTAssertGreaterThan(sample[0], 210)
            XCTAssertEqual(Int(sample[0]), Int(sample[1]), accuracy: 1)
            XCTAssertEqual(Int(sample[1]), Int(sample[2]), accuracy: 1, "Marks must be neutral, not blue")
        }
        let curved = try render(show, enabled: true, scheme: .dark, indicator: .unwatched, background: .white)
        attach(curved, name: "curved-count-white-artwork")
        XCTAssertLessThan(try pixel(curved, at: CGPoint(x: 170, y: 20))[0], 250,
                          "The soft shadow must extend left of the tile's 176pt boundary")
        XCTAssertLessThan(try pixel(curved, at: CGPoint(x: 226, y: 59))[0], 250,
                          "The shadow must extend below the tile's 56pt boundary")
        XCTAssertEqual(try pixel(curved, at: CGPoint(x: 145, y: 75))[0], 255)
        let pearl = try render(show, enabled: true, scheme: .dark, indicator: .watched, background: .white)
        XCTAssertEqual(try pixel(pearl, at: CGPoint(x: 230, y: 8))[0], 255,
                       "The floating Pearl tile must retain its top/right clearance")
        XCTAssertNotEqual(curved.pngData(), pearl.pngData())
    }

    func testTouchCountsFitSmallArtworkAcrossDisplaySizes() throws {
        let item = MediaItem(id: "show", title: "Show", kind: .series, unwatchedEpisodeCount: 12345)
        for density in UIDensity.allCases {
            let metrics = PlozzMetrics.touch(density: density).scalingPosters(by: 0.6)
            for indicator in WatchStatusIndicator.allCases {
                let image = try render(item, enabled: true, scheme: .dark, indicator: indicator,
                                       metrics: metrics, width: 86, radius: 12)
                attach(image, name: "touch-count-\(density)-\(indicator)")
                XCTAssertTrue(try recognizedText(image).contains { $0.text == "12345" },
                              "Exact counts must fit an 86pt touch poster at \(density)")
            }
        }
    }

    func testApprovedIndicatorsKeepRealNativeFocus() async throws {
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
        let artwork = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 3)).image {
            UIColor.white.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
        }
        let items = [
            MediaItem(id: "show", title: "Unwatched show", kind: .series, unwatchedEpisodeCount: 21),
            MediaItem(id: "complete", title: "Watched movie", kind: .movie, isPlayed: true),
            MediaItem(id: "new", title: "Unwatched movie", kind: .movie)
        ]
        for indicator in WatchStatusIndicator.allCases {
            let host = BadgeFocusHost(rootView: AnyView(
                HStack(spacing: 82) {
                    ForEach(items) { item in
                        NativeBadgeFixture(item: item, artwork: artwork)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .environment(\.plozzWatchStatusIndicator, indicator)
                .environment(\.plozzShowsUnwatchedEpisodeCount, true)
                .environment(\.colorScheme, .dark)
            ))
            window.rootViewController = host
            window.makeKeyAndVisible()
            let deadline = ContinuousClock.now + .seconds(5)
            while nativePosters(in: host.view).count != 3 && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(30))
                window.layoutIfNeeded()
            }
            let posters = nativePosters(in: host.view)
            XCTAssertEqual(posters.count, 3)
            let focusSystem = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            for poster in posters.prefix(2) {
                host.target = poster
                focusSystem.requestFocusUpdate(to: host)
                focusSystem.updateFocusIfNeeded()
                let focusDeadline = ContinuousClock.now + .seconds(3)
                while !poster.isFocused && ContinuousClock.now < focusDeadline {
                    try await Task.sleep(for: .milliseconds(30))
                }
                XCTAssertTrue(poster.isFocused)
                try await Task.sleep(for: .milliseconds(500))
                let image = snapshot(window)
                attach(image, name: "native-white-indicators-\(indicator)-\(poster === posters[0])")
                let artworkFrame = try XCTUnwrap(
                    NativeFocusProjection.artworkFrame(of: posters[0].imageView, in: window))
                let region = CGRect(x: artworkFrame.minX - 8, y: artworkFrame.minY - 8,
                                    width: artworkFrame.width + 16, height: 100)
                    .applying(CGAffineTransform(scaleX: image.scale, y: image.scale))
                let crop = try XCTUnwrap(image.cgImage?.cropping(to: region))
                let words = try recognizedText(UIImage(cgImage: crop)).map(\.text)
                XCTAssertTrue(words.contains("21"), "Expected the exact count in \(indicator), got \(words)")
            }
        }
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
        let configurations: [(Bool, WatchStatusIndicator)] = [
            (false, .watched), (true, .watched), (true, .unwatched), (false, .unwatched)
        ]
        for scheme in [ColorScheme.dark, .light] {
            environment.colorScheme = scheme
            environment.themePalette = scheme == .dark ? .dark : .light
            cell.frame = CGRect(x: 300, y: 200, width: 320, height: NativeTVLibraryCell.height(for: 320, environment: environment))
            for (enabled, indicator) in configurations {
                environment.plozzWatchStatusIndicator = indicator
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
                        attach(image, name: "native-episode-count-\(scheme)-\(indicator)-\(enabled)")
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
        _ item: MediaItem, enabled: Bool, scheme: ColorScheme, hidesStatus: Bool = false,
        indicator: WatchStatusIndicator = .watched, background: Color = .gray,
        metrics: PlozzMetrics = .standard, width: CGFloat = 240, radius: CGFloat = 21
    ) throws -> UIImage {
        let renderer = ImageRenderer(content:
            MediaCardPlaybackIndicators(item: item, hidesStatus: hidesStatus, badgeInset: 8, artworkCornerRadius: radius)
                .frame(width: width, height: width * 1.5)
                .background(background)
                .environment(\.plozzMetrics, metrics)
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.colorScheme, scheme)
                .environment(\.themePalette, scheme == .dark ? .dark : .light)
                .environment(\.plozzWatchStatusIndicator, indicator)
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

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [UInt8] {
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(
            x: point.x * image.scale, y: point.y * image.scale, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel
    }

    private func nativePosters(in view: UIView) -> [TVPosterView] {
        if let poster = view as? TVPosterView { return [poster] }
        return view.subviews.flatMap { nativePosters(in: $0) }
    }

    private final class BadgeFocusHost: UIHostingController<AnyView> {
        weak var target: UIView?
        override var preferredFocusEnvironments: [any UIFocusEnvironment] {
            target.map { [$0] } ?? super.preferredFocusEnvironments
        }
    }

    private struct NativeBadgeFixture: View {
        let item: MediaItem
        let artwork: UIImage
        @PlozzCardFocus private var focused: Bool
        var body: some View {
            VStack(spacing: 24) {
                NativeTVPoster(
                    image: artwork, treatment: .original, aspectRatio: 2.0 / 3, fallbackWidth: 240,
                    title: nil, subtitle: nil,
                    overlay: MediaCardPlaybackIndicators(
                        item: item, badgeInset: 8,
                        artworkCornerRadius: PlozzTheme.Metrics.nativePosterArtworkCornerRadius
                    ),
                    focus: $focused, action: {}
                )
                .frame(width: 240, height: 360)
                .focused($focused.focusState)
                Text(verbatim: item.title).font(.system(size: 20))
            }
        }
    }
}
#endif
