#if DEBUG && canImport(SwiftUI) && canImport(UIKit)
import CoreModels
import CoreUI
import SwiftUI
import UIKit
import XCTest
@testable import FeaturePlayback

@MainActor
final class LiveChannelControlsAppearanceTests: XCTestCase {
    func testScheduledChannelsDoNotClaimToBeLiveBroadcasts() {
        XCTAssertEqual(String(localized: LiveChannelPlaybackPhase.loading.activityLabel), "Loading channel…")
        XCTAssertEqual(
            String(localized: LiveChannelPlaybackPhase.playing.statusLabel(isAtLiveEdge: true, isScheduledChannel: true)),
            "ON NOW"
        )
        XCTAssertEqual(
            String(localized: LiveChannelPlaybackPhase.playing.statusLabel(isAtLiveEdge: false, isScheduledChannel: true)),
            "DELAYED"
        )
        XCTAssertEqual(
            String(localized: LibraryChannelPlaybackCopy.returnToCurrentTitle(isScheduledChannel: true)), "Jump to now"
        )
        XCTAssertEqual(String(localized: LiveChannelPlaybackPhase.playing.statusLabel(isAtLiveEdge: true)), "LIVE")
        XCTAssertEqual(
            String(localized: LibraryChannelPlaybackCopy.returnToCurrentTitle(isScheduledChannel: false)), "Go Live"
        )
    }

    func testNormalPlayerActionStyleKeepsFocusedLabelsBlackOnWhite() throws {
        for title in ["Pause", "Add to Favorites", "Remove from Favorites", "Try Again", "Close"] {
            let image = try render(title: title, focused: true)
            let pixels = try rgbaPixels(image)
            let ink = interiorPixelCount(pixels, image: image) { $0 < 12 && $1 < 12 && $2 < 12 }
            let backing = interiorPixelCount(pixels, image: image) { $0 > 243 && $1 > 243 && $2 > 243 }
            XCTAssertGreaterThan(ink, 30, title)
            XCTAssertGreaterThan(backing, 600, title)
        }
    }

    func testNormalPlayerActionStyleKeepsRestingLabelsWhiteOnDarkVideoScrim() throws {
        let image = try render(title: "Pause", focused: false)
        let pixels = try rgbaPixels(image)
        let ink = interiorPixelCount(pixels, image: image) { $0 > 243 && $1 > 243 && $2 > 243 }
        let backing = interiorPixelCount(pixels, image: image) { $0 < 45 && $1 < 45 && $2 < 45 }
        XCTAssertGreaterThan(ink, 30)
        XCTAssertGreaterThan(backing, 600)
    }

    func testNativeFocusStyleKeepsTheExistingRestingAppearance() throws {
        let native = try render(title: "Audio & Subtitles", focused: nil)
        let explicit = try render(title: "Audio & Subtitles", focused: false)
        XCTAssertEqual(native.width, explicit.width)
        XCTAssertEqual(native.height, explicit.height)
        XCTAssertEqual(try rgbaPixels(native), try rgbaPixels(explicit))
    }

    func testOnNowKeepsPlayerInsetsAndConcentricArtworkAcrossBrowsingDensities() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (name, metrics, radius) in [
            ("tv", PlayerCardMetrics.tv, CGFloat(18)),
            ("horizontal-wide", .horizontalWide, 26),
            ("horizontal-narrow", .horizontalNarrow, 8),
            ("vertical-wide", .verticalWide, 12),
            ("vertical-narrow", .verticalNarrow, 8)
        ] {
            for showsProgram in [false, true] {
                let program = showsProgram ? LiveChannelProgramInfo(
                    title: "Programme", start: now.addingTimeInterval(-900), end: now.addingTimeInterval(900)
                ) : nil
                let item = LiveChannelOnNowItem(channelID: "fixture", channelName: "", logoURL: nil, program: program)
                let textHeight = showsProgram
                    ? ((metrics.castNameSize + metrics.castRoleSize) * 1.25).rounded(.up) + 3
                    : (metrics.castNameSize * 1.25).rounded(.up)
                let artHeight = max(40, (metrics.cardHeight - metrics.contentPadding * 2 - textHeight - 10).rounded())
                let artWidth = (artHeight * 16 / 9).rounded()
                let maskRenderer = ImageRenderer(content:
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.white).frame(width: artWidth, height: artHeight)
                )
                maskRenderer.scale = 1
                let mask = try XCTUnwrap(maskRenderer.cgImage)
                let maskPixels = try rgbaPixels(mask)
                var reference: [UInt8]?
                for density in UIDensity.allCases {
                    let renderer = ImageRenderer(content:
                        LiveChannelOnNowCard(item: item, isCurrent: false, now: now, reservesDetailLine: showsProgram)
                            .environment(\.playerCardMetrics, metrics)
                            .environment(\.plozzMetrics, PlozzMetrics(density: density))
                            .environment(\.themePalette, .dark)
                            .environment(\.colorScheme, .dark)
                    )
                    renderer.scale = 1
                    let image = try XCTUnwrap(renderer.cgImage)
                    XCTAssertEqual(image.width, Int(artWidth + metrics.contentPadding * 2), name)
                    XCTAssertEqual(image.height, Int(metrics.cardHeight), name)
                    let pixels = try rgbaPixels(image)
                    if let reference {
                        XCTAssertTrue(pixels == reference, "Browsing density must not reshape player cards: \(name)")
                    } else {
                        reference = pixels
                        let attachment = XCTAttachment(image: UIImage(cgImage: image))
                        attachment.name = "on-now-\(name)-programme-\(showsProgram)"
                        attachment.lifetime = .keepAlways
                        add(attachment)
                    }
                    let inset = Int(metrics.contentPadding)
                    XCTAssertEqual(pixels[((inset - 1) * image.width + image.width / 2) * 4 + 3], 0)
                    for y in 0..<Int(radius + 2) {
                        for x in 0..<Int(radius + 2) {
                            for (mx, my) in [(x, y), (mask.width - x - 1, mask.height - y - 1)] {
                                let expected = maskPixels[(my * mask.width + mx) * 4 + 3]
                                guard expected == 0 || expected == 255 else { continue }
                                let actual = pixels[((my + inset) * image.width + mx + inset) * 4 + 3]
                                XCTAssertLessThanOrEqual(abs(Int(actual) - Int(expected)), 2,
                                                        "Artwork and progress must share the original \(radius)pt corner: \(name), \(mx),\(my)")
                            }
                        }
                    }
                }
            }
        }
    }

    private func render(title: String, focused: Bool?) throws -> CGImage {
        let button = Button {} label: {
            Text(title).font(.system(size: 26, weight: .semibold))
        }
        .buttonStyle(InfoActionButtonStyle(focused: focused, prominent: false))
        .foregroundStyle(.white)
        .background(.black)
        let renderer = ImageRenderer(content: button)
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    private func interiorPixelCount(
        _ pixels: [UInt8], image: CGImage,
        matching: (UInt8, UInt8, UInt8) -> Bool
    ) -> Int {
        var count = 0
        for y in 16..<(image.height - 16) {
            for x in 22..<(image.width - 22) {
                let offset = (y * image.width + x) * 4
                if matching(pixels[offset], pixels[offset + 1], pixels[offset + 2]) { count += 1 }
            }
        }
        return count
    }

    private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }
}
#endif
