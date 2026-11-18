#if os(iOS)
import CoreModels
import CoreUI
@testable import FeaturePlayback
import SwiftUI
import UIKit
import XCTest

@MainActor
final class PlayerSkipMarkerNativeHostedTests: XCTestCase {
    func testNativePortraitAndWideTracksKeepTinyNeighborsContinuousAndRetainLegibleCuts() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Native Liquid Glass requires iOS 26.") }
        try XCTSkipIf(UIAccessibility.isReduceTransparencyEnabled, "Native glass needs Reduce Transparency off.")
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }

        for (viewport, width) in [(CGSize(width: 360, height: 780), CGFloat(240)),
                                  (CGSize(width: 1_024, height: 768), CGFloat(960))] {
            for (scheme, progress) in [
                (ColorScheme.dark, 0.0), (.dark, 0.5), (.dark, 1.0),
                (.light, 0.0), (.light, 0.5), (.light, 1.0)
            ] {
                window.frame = CGRect(origin: .zero, size: viewport)
                window.overrideUserInterfaceStyle = scheme == .light ? .light : .dark
                let probe = NativeSeekTrackProbe()
                window.rootViewController = UIHostingController(rootView:
                    NativeSeekTrackFixture(width: width, progressFraction: progress, probe: probe)
                        .environment(\.colorScheme, scheme)
                        .environment(\.plozzReducePanelGlass, false)
                        .environment(\.plozzReduceTransparency, false)
                )
                window.makeKeyAndVisible()
                let frame = try await settledFrame(in: window)
                let attachment = XCTAttachment(image: frame.image)
                attachment.name = "Native fill-only seek - \(width == 240 ? "portrait" : "wide") - \(scheme) - \(Int(progress * 100))%"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertEqual(probe.usesNativeGlass, true, "This must exercise native glass, not its flat proxy.")

                let retained: [CGFloat] = width == 240 ? [0.4, 0.75] : [0.25, 0.28125, 0.4, 0.55, 0.58125, 0.75]
                let suppressed: [CGFloat] = width == 240 ? [0.25, 0.28125, 0.55, 0.58125, 0.85, 0.855] : [0.85, 0.855]
                for (name, height) in [
                    ("touch", CGFloat(8)), ("dragging-track", CGFloat(20)),
                    ("live-touch", CGFloat(8)), ("live-dragging", CGFloat(20))
                ] {
                    let plain = try XCTUnwrap(probe.frames["\(name)-plain"])
                    let marked = try XCTUnwrap(probe.frames["\(name)-marked"])
                    XCTAssertEqual(marked.width, width, accuracy: 0.01)
                    XCTAssertEqual(marked.height, 44, accuracy: 0.01)
                    let backdrop = frame.color(x: 4, y: 4)
                    for fraction in suppressed + [0.1, 0.45, 0.65, 0.9] {
                        let actual = frame.color(x: marked.minX + fraction * width, y: marked.midY)
                        let reference = frame.color(x: plain.minX + fraction * width, y: plain.midY)
                        assertColor(actual, matches: reference, accuracy: 8,
                                    "Suppressed cuts retain the native surface instead of leaving slivers.")
                        XCTAssertGreaterThan(colorDistance(actual, backdrop), 8,
                                             "Continuous sections must contain visible glass, not transparent holes.")
                    }
                    for fraction in retained {
                        let besideCut = frame.color(
                            x: marked.minX + fraction * width + 2.5, y: marked.midY - height / 2 + 3
                        )
                        XCTAssertGreaterThan(colorDistance(besideCut, backdrop), 8,
                                             "The inner edge is filled below its small corner, even on the expanded track.")
                        for offset in stride(from: -height / 2 + 1, through: height / 2 - 1, by: 1) {
                            let gap = frame.color(x: marked.minX + fraction * width, y: marked.midY + offset)
                            assertColor(gap, matches: backdrop, accuracy: 2,
                                        "Retained cuts must reveal the picture over the full track height.")
                        }
                        let reference = frame.color(x: plain.minX + fraction * width, y: plain.midY)
                        XCTAssertGreaterThan(colorDistance(reference, backdrop), 8,
                                             "The cut must visibly differ from the uninterrupted native reference.")
                    }
                }
            }
        }
    }

    private func settledFrame(in window: UIWindow) async throws -> NativeSeekFrame {
        window.layoutIfNeeded()
        let deadline = ContinuousClock.now + .seconds(6)
        var frame = try capture(window)
        var stable = 0
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
            let next = try capture(window)
            stable = next.bytes == frame.bytes ? stable + 1 : 0
            frame = next
            if stable >= 3 { return frame }
        }
        XCTFail("Native seek-track compositing did not settle before the deadline.")
        return frame
    }

    private func capture(_ window: UIWindow) throws -> NativeSeekFrame {
        let format = UIGraphicsImageRendererFormat()
        format.scale = try XCTUnwrap(window.windowScene).screen.scale
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
                bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        return NativeSeekFrame(image: image, width: cgImage.width, height: cgImage.height, bytes: bytes)
    }

    private func colorDistance(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        zip(lhs, rhs).map { abs(Int($0.0) - Int($0.1)) }.max() ?? 0
    }

    private func assertColor(
        _ actual: [UInt8], matches expected: [UInt8], accuracy: Int, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(colorDistance(actual, expected), accuracy, message, file: file, line: line)
    }
}

@MainActor
private final class NativeSeekTrackProbe {
    var frames: [String: CGRect] = [:]
    var usesNativeGlass: Bool?
}

private struct NativeSeekTrackFixture: View {
    let width: CGFloat
    let progressFraction: Double
    let probe: NativeSeekTrackProbe
    @Environment(\.playerUsesNativeGlass) private var usesNativeGlass

    private let segments: [MediaSegment] = [
        .init(kind: .intro, start: 25, end: 28.125),
        .init(kind: .recap, start: 40, end: 55),
        .init(kind: .commercial, start: 58.125, end: 75),
        .init(kind: .preview, start: 85, end: 85.5)
    ]

    var body: some View {
        VStack(spacing: 36) {
            touchTrack(segments: []).recordNativeTrack("touch-plain", probe: probe)
            touchTrack(segments: segments).recordNativeTrack("touch-marked", probe: probe)
            expandedTrack(segments: []).recordNativeTrack("dragging-track-plain", probe: probe)
            expandedTrack(segments: segments).recordNativeTrack("dragging-track-marked", probe: probe)
            liveTrack(marked: false, scrubbing: false).recordNativeTrack("live-touch-plain", probe: probe)
            liveTrack(marked: true, scrubbing: false).recordNativeTrack("live-touch-marked", probe: probe)
            liveTrack(marked: false, scrubbing: true).recordNativeTrack("live-dragging-plain", probe: probe)
            liveTrack(marked: true, scrubbing: true).recordNativeTrack("live-dragging-marked", probe: probe)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.15, green: 0.35, blue: 0.6))
        .ignoresSafeArea()
        .onAppear { probe.usesNativeGlass = usesNativeGlass }
    }

    private func touchTrack(segments: [MediaSegment]) -> some View {
        PlayerTouchScrubBar(
            currentSeconds: progressFraction * 100, duration: 100, bufferedFraction: 0, segments: segments,
            onScrub: { _ in XCTFail("A hosted snapshot must not seek.") },
            onScrubbingChanged: { _ in XCTFail("A hosted snapshot must not begin dragging.") }
        )
        .frame(width: width, height: 44)
    }

    private func expandedTrack(segments: [MediaSegment]) -> some View {
        PlayerTouchScrubTrack(
            width: width, progressFraction: progressFraction, bufferedFraction: 0,
            segments: segments, duration: 100, isTouching: true
        )
        .frame(width: width, height: 44)
    }

    private func liveTrack(marked: Bool, scrubbing: Bool) -> some View {
        let origin = Date(timeIntervalSince1970: 36_000)
        func program(_ start: TimeInterval, _ end: TimeInterval) -> LiveChannelProgramInfo {
            .init(title: "Programme", start: origin.addingTimeInterval(start), end: origin.addingTimeInterval(end))
        }
        let layout = LiveChannelTimelineLayout(
            now: origin.addingTimeInterval(100), program: program(marked ? 75 : 0, 100),
            earlierPrograms: marked ? [
                program(0, 25), program(25, 28.125), program(28.125, 40),
                program(40, 55), program(55, 58.125), program(58.125, 75)
            ] : [],
            seekWindowSeconds: 100, behindLiveSeconds: (1 - progressFraction) * 100
        )
        return LiveChannelTouchTrack(
            layout: layout, width: width, height: scrubbing ? 20 : 8, focused: false, scrubbing: scrubbing
        )
        .frame(width: width, height: 44)
    }
}

private extension View {
    func recordNativeTrack(_ name: String, probe: NativeSeekTrackProbe) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.frames[name] = $0 }
    }
}

private struct NativeSeekFrame {
    let image: UIImage
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func color(x: CGFloat, y: CGFloat) -> [UInt8] {
        let x = min(max(Int((x * image.scale).rounded(.down)), 0), width - 1)
        let y = min(max(Int((y * image.scale).rounded(.down)), 0), height - 1)
        let index = (y * width + x) * 4
        return Array(bytes[index..<(index + 3)])
    }
}
#endif
