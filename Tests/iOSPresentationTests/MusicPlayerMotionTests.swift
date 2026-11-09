#if os(iOS)
@testable import FeatureMusic
import SwiftUI
import UIKit
import XCTest

@MainActor
final class MusicPlayerMotionTests: XCTestCase {
    func testPlayPauseScalesBetweenGlyphsAtDockAndExpandedSizes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.frame = CGRect(x: 100, y: 100, width: 80, height: 80)
        for size in [30.0, 60.0] {
            for reducedMotion in [false, true] {
                let state = PlayPauseMotionState()
                window.rootViewController = UIHostingController(rootView:
                    PlayPauseMotionFixture(state: state, size: size)
                        .transaction { if reducedMotion { $0.disablesAnimations = true } }
                )
                window.overrideUserInterfaceStyle = .light
                window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(150))
                for playing in [true, false] {
                    let before = try inkBounds(in: snapshot(window), orange: false).height
                    state.playing = playing
                    var heights: [CGFloat] = []
                    for _ in 0..<12 {
                        try await Task.sleep(for: .milliseconds(20))
                        heights.append(try inkBounds(in: snapshot(window), orange: false).height)
                    }
                    try await Task.sleep(for: .milliseconds(450))
                    let after = try inkBounds(in: snapshot(window), orange: false).height
                    if reducedMotion {
                        XCTAssertTrue(heights.allSatisfy { abs($0 - after) <= 1 },
                                      "Reduce Motion must replace the glyph without a scale transition")
                    } else {
                        XCTAssertLessThan(try XCTUnwrap(heights.min()), min(before, after) - 0.5,
                                          "The outgoing and incoming glyphs must scale, not instantly swap")
                    }
                }
            }
        }
    }

    func testMeasuredArtworkSlotRetainsPanelAnimationInBothDirections() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.frame = CGRect(x: 0, y: 100, width: 800, height: 200)
        for reducedMotion in [false, true] {
            let state = PlayPauseMotionState()
            window.rootViewController = UIHostingController(rootView:
                ArtworkSlotMotionFixture(state: state, reducedMotion: reducedMotion)
            )
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(250))
            for opening in [true, false] {
                let before = try inkBounds(in: snapshot(window), orange: true).midX
                withAnimation(reducedMotion ? nil : NowPlayingMorphContainer.panelSpring) {
                    state.playing = opening
                }
                var positions: [CGFloat] = []
                for _ in 0..<12 {
                    try await Task.sleep(for: .milliseconds(35))
                    positions.append(try inkBounds(in: snapshot(window), orange: true).midX)
                }
                try await Task.sleep(for: .milliseconds(600))
                let after = try inkBounds(in: snapshot(window), orange: true).midX
                XCTAssertGreaterThan(abs(after - before), 100)
                XCTAssertEqual(after < before, opening)
                if reducedMotion {
                    XCTAssertTrue(positions.allSatisfy { abs($0 - after) <= 4 })
                } else {
                    let intermediate = positions.filter { $0 > min(before, after) + 10 && $0 < max(before, after) - 10 }
                    XCTAssertGreaterThanOrEqual(intermediate.count, 2, "Artwork must travel through intermediate positions")
                }
            }
        }
    }

    private func snapshot(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }

    private func inkBounds(in image: UIImage, orange: Bool) throws -> CGRect {
        let source = try XCTUnwrap(image.cgImage)
        let scale: CGFloat = orange ? 0.25 : 1
        let width = Int(CGFloat(source.width) * scale), height = Int(CGFloat(source.height) * scale)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        return try bytes.withUnsafeMutableBytes { pixels in
            let context = try XCTUnwrap(CGContext(
                data: pixels.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            var bounds = CGRect.null
            for row in 0..<height {
                for column in 0..<width {
                    let offset = (row * width + column) * 4
                    let r = pixels[offset], g = pixels[offset + 1], b = pixels[offset + 2]
                    let matches = orange ? r > 210 && g > 65 && g < 150 && b < 45 : max(r, g, b) < 190
                    if matches { bounds = bounds.union(CGRect(x: column, y: row, width: 1, height: 1)) }
                }
            }
            XCTAssertFalse(bounds.isNull, "Expected visible \(orange ? "artwork" : "transport glyph")")
            return bounds.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        }
    }

}

@MainActor @Observable
private final class PlayPauseMotionState {
    var playing = false
}

private struct PlayPauseMotionFixture: View {
    let state: PlayPauseMotionState
    let size: CGFloat
    var body: some View {
        PlayPauseButton(playing: state.playing, glyphSize: size, hitSize: size == 30 ? 30 : 72) {
            state.playing.toggle()
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white)
            .ignoresSafeArea()
    }
}

private struct ArtworkSlotMotionFixture: View {
    let state: PlayPauseMotionState
    let reducedMotion: Bool
    @State private var rect: CGRect?

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: 100, height: 100)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: ArtSlotKey.self, value: geometry.frame(in: .named("motion-fixture"))
                            )
                        }
                    }
                    .frame(width: state.playing ? 400 : 800)
                Spacer(minLength: 0)
            }
            .modifier(PlayerArtworkSlotObserver(
                rect: $rect, animation: reducedMotion ? nil : NowPlayingMorphContainer.panelSpring
            ))
            if let rect {
                Rectangle().fill(Color(red: 1, green: 0.4, blue: 0))
                    .frame(width: 100, height: 100)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .coordinateSpace(name: "motion-fixture")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white)
        .ignoresSafeArea()
    }
}
#endif
