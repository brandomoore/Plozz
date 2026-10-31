import CoreModels
@testable import CoreUI
import SwiftUI
import UIKit
import XCTest
#if os(tvOS)
@testable import FeatureHome
#else
@testable import AppShelliOS
#endif

@MainActor
final class ExtrasWatchIndicatorHostedTests: XCTestCase {
    func testExtrasHonorBothIndicatorModesAndLiveWatchStateChanges() async throws {
        let item = try await extraItem()
        for indicator in WatchStatusIndicator.allCases {
            for style in [CardStyle.borderless, .framed] {
                try await withFixture(item: item, indicator: indicator, style: style) { host, window in
                    for played in [false, true, false] {
                        var updated = item
                        updated.isPlayed = played
                        updated.playedPercentage = played ? 1 : nil
                        host.rootView.item = updated
                        let shouldShow = indicator != .hidden && (indicator == .watched ? played : !played)
                        try await assertBadge(shouldShow, in: window, label: "\(style)-\(indicator)-\(played)")
                    }
                }
            }
        }
    }

    func testContinueWatchingWithoutSeriesArtworkKeepsWatchMarksHidden() async throws {
        var item = try await extraItem()
        for indicator in WatchStatusIndicator.allCases {
            item.isPlayed = indicator == .watched
            item.playedPercentage = item.isPlayed ? 1 : nil
            try await withFixture(item: item, indicator: indicator, continueWatching: true) { _, window in
                try await assertBadge(false, in: window, label: "continue-watching-\(indicator)")
            }
        }
    }

    func testExtrasWithoutRuntimeStillShowWatchStatus() async throws {
        var item = try await extraItem()
        item.runtime = nil
        item.isPlayed = true
        try await withFixture(item: item, indicator: .watched) { _, window in
            try await assertBadge(true, in: window, label: "no-runtime-watched")
        }
    }

    func testInProgressExtrasKeepProgressWithoutCornerWatchMarks() async throws {
        var item = try await extraItem()
        item.resumePosition = 120
        item.playedPercentage = 0.4
        for indicator in WatchStatusIndicator.allCases {
            try await withFixture(item: item, indicator: indicator) { _, window in
                try await assertBadge(false, in: window, label: "in-progress-\(indicator)")
                let image = snapshot(window)
                let pixels = try PixelImage(image)
                let artwork = try pixels.artworkBounds()
                XCTAssertGreaterThan(pixels.whiteCount(in: CGRect(
                    x: artwork.minX + 8, y: artwork.maxY - 45,
                    width: artwork.width - 16, height: 45
                )), 30, "The resume chip must retain its visible progress/time content.")
            }
        }
    }

    private func extraItem() async throws -> MediaItem {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/extra-status-\(UUID()).png"))
        let data = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360)).pngData {
            UIColor(red: 0.04, green: 0.65, blue: 0.04, alpha: 1).setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        }
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        let request = URLRequest(url: url)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
        ))
        cache.storeCachedResponse(CachedURLResponse(response: response, data: data), for: request)
        addTeardownBlock { cache.removeCachedResponse(for: request) }
        let image = await ArtworkImageCache.shared.image(for: url, variant: .landscapeCard)
        _ = try XCTUnwrap(image)
        return MediaItem(
            id: "extra", title: "Making Of", kind: .video, runtime: 300,
            posterURL: url, allowsTitleBasedMetadataMatching: false
        )
    }

    private func withFixture(
        item: MediaItem, indicator: WatchStatusIndicator, style: CardStyle = .borderless,
        continueWatching: Bool = false,
        operation: (UIHostingController<ExtraStatusFixture>, UIWindow) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        let host = UIHostingController(rootView: ExtraStatusFixture(
            item: item, indicator: indicator, style: style, continueWatching: continueWatching
        ))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await operation(host, window)
    }

    private func assertBadge(_ expected: Bool, in window: UIWindow, label: String) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        var found = false
        var loaded = false
        repeat {
            try await Task.sleep(for: .milliseconds(100))
            let pixels = try PixelImage(artworkSnapshot(window))
            if let bounds = try? pixels.artworkBounds() {
                loaded = true
                let count = pixels.whiteCount(in: CGRect(
                    x: bounds.maxX - bounds.width * 0.35, y: bounds.minY,
                    width: bounds.width * 0.35, height: bounds.height * 0.4
                ))
                found = count > 30
                if found == expected { break }
            }
        } while ContinuousClock.now < deadline
        XCTAssertTrue(loaded, "Must observe loaded artwork, not a placeholder: \(label)")
        XCTAssertEqual(found, expected, "Incorrect extra watch badge: \(label)")
        let attachment = XCTAttachment(image: snapshot(window))
        attachment.name = "extra-watch-status-\(label)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func artworkSnapshot(_ window: UIWindow) -> UIImage {
        #if os(tvOS)
        func poster(in view: UIView) -> NativePosterButton? {
            (view as? NativePosterButton) ?? view.subviews.lazy.compactMap { poster(in: $0) }.first
        }
        if let image = poster(in: window)?.image { return image }
        #endif
        return snapshot(window)
    }

    private func snapshot(_ window: UIWindow) -> UIImage {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private struct PixelImage {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(_ image: UIImage) throws {
            let image = try XCTUnwrap(image.cgImage)
            width = image.width
            height = image.height
            let context = try XCTUnwrap(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            bytes = Array(UnsafeBufferPointer(
                start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self),
                count: width * height * 4
            ))
        }

        func artworkBounds() throws -> CGRect {
            var minX = width, minY = height, maxX = 0, maxY = 0
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    if bytes[offset + 1] > 80, bytes[offset] < 55, bytes[offset + 2] < 55 {
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
            guard maxX - minX > 80, maxY - minY > 40 else {
                throw NSError(domain: "MissingExtrasArtwork", code: 1)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }

        func whiteCount(in rect: CGRect) -> Int {
            var count = 0
            for y in max(0, Int(rect.minY))..<min(height, Int(rect.maxY)) {
                for x in max(0, Int(rect.minX))..<min(width, Int(rect.maxX)) {
                    let offset = (y * width + x) * 4
                    if bytes[offset] > 210, bytes[offset + 1] > 210, bytes[offset + 2] > 210 {
                        count += 1
                    }
                }
            }
            return count
        }
    }
}

private struct ExtraStatusFixture: View {
    var item: MediaItem
    let indicator: WatchStatusIndicator
    let style: CardStyle
    let continueWatching: Bool

    var body: some View {
        Group {
            if continueWatching {
                PosterCardView(
                    item: item, style: .landscape, enablesAsyncArtworkFallback: false,
                    playsOnSelect: true, showsResumeChip: true, action: {}
                )
                .frame(width: 400)
            } else {
                let extra = MediaExtra(item: item, kind: .behindTheScenes)
                #if os(tvOS)
                ExtrasRowView(
                    state: .loaded([extra]), leadingInset: 0, onSelect: { _ in }, onRetry: {}
                )
                #else
                PlozziOSExtrasSection(state: .loaded([extra]), inset: 0, onSelect: { _ in }, onRetry: {})
                #endif
            }
        }
        .environment(\.plozzArtworkArea, continueWatching ? .continueWatching : nil)
        .environment(\.plozzCardStyle, style)
        .environment(\.plozzCardFocusStyle, .system)
        .environment(\.plozzCardCaptionSettings, CardCaptionSettings(showsLabels: false))
        .environment(\.plozzWatchStatusIndicator, indicator)
        .environment(\.plozzMetrics, metrics)
        .environment(\.colorScheme, .dark)
        .environment(\.themePalette, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }

    private var metrics: PlozzMetrics {
        #if os(tvOS)
        .standard
        #else
        .touch(density: .standard)
        #endif
    }
}
