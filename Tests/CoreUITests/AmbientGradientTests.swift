import CoreModels
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI

@MainActor
final class AmbientGradientTests: XCTestCase {
    func testFullscreenHeroHalvesTintSaturationWithoutChangingHueBrightnessOrStockColors() {
        for palette in [ThemePalette.dark, .pureBlack, .light] {
            let tints: [Color] = [.red, .green, .blue, .purple]
            let standard = AmbientGradientBackground.meshColors(tint: tints, palette: palette)
            let subdued = AmbientGradientBackground.meshColors(
                tint: tints, palette: palette,
                tintSaturation: AmbientGradientBackground.fullscreenHeroTintSaturation
            )
            for (before, after) in zip(standard, subdued) {
                var h0: CGFloat = 0, s0: CGFloat = 0, b0: CGFloat = 0, a0: CGFloat = 0
                var h1: CGFloat = 0, s1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
                XCTAssertTrue(UIColor(before).getHue(&h0, saturation: &s0, brightness: &b0, alpha: &a0))
                XCTAssertTrue(UIColor(after).getHue(&h1, saturation: &s1, brightness: &b1, alpha: &a1))
                XCTAssertEqual(h0, h1, accuracy: 0.0001)
                XCTAssertEqual(s1, s0 * 0.5, accuracy: 0.0001)
                XCTAssertEqual(b0, b1, accuracy: 0.0001)
                XCTAssertEqual(a0, a1, accuracy: 0.0001)
            }
            for tint: [Color]? in [nil, []] {
                XCTAssertEqual(
                    AmbientGradientBackground.meshColors(tint: tint, palette: palette),
                    AmbientGradientBackground.meshColors(tint: tint, palette: palette, tintSaturation: 0.5)
                )
            }
        }
    }

    func testPaletteTraceFingerprintsDistinguishArtworkWithoutRevealingURLs() throws {
        let first = ArtworkReference.remote(try XCTUnwrap(URL(string: "https://private.example/art/one?token=secret")))
        let second = ArtworkReference.remote(try XCTUnwrap(URL(string: "https://private.example/art/two?token=secret")))
        let fingerprint = ArtworkPaletteDiagnostics.referenceID(first)
        XCTAssertEqual(fingerprint.count, 16)
        XCTAssertEqual(fingerprint, ArtworkPaletteDiagnostics.referenceID(first))
        XCTAssertNotEqual(fingerprint, ArtworkPaletteDiagnostics.referenceID(second))
        XCTAssertFalse(fingerprint.contains("secret"))
        XCTAssertFalse(fingerprint.contains("private"))
        XCTAssertNotEqual(
            ArtworkPaletteDiagnostics.keyID(AmbientArtworkKey(id: "title", reference: first)),
            ArtworkPaletteDiagnostics.keyID(AmbientArtworkKey(id: "title", reference: second))
        )
    }

    func testPaletteTraceDescribesPixelsAndActualColorComponents() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48))
        let red = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        }
        let green = renderer.image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        }
        XCTAssertEqual(ArtworkPaletteDiagnostics.imageSummary(red), ArtworkPaletteDiagnostics.imageSummary(red))
        XCTAssertNotEqual(ArtworkPaletteDiagnostics.imageSummary(red), ArtworkPaletteDiagnostics.imageSummary(green))
        XCTAssertTrue(ArtworkPaletteDiagnostics.imageSummary(red).contains("pixels="))
        XCTAssertFalse(ArtworkPaletteDiagnostics.imageSummary(red).contains("unavailable"))
        let colors = [Color(red: 1, green: 0, blue: 0), Color(red: 0, green: 1, blue: 0)]
        XCTAssertEqual(ArtworkPaletteDiagnostics.colors(colors), "[(1.0000,0.0000,0.0000,1.0000),(0.0000,1.0000,0.0000,1.0000)]")
        XCTAssertEqual(ArtworkPaletteDiagnostics.colors(nil), "none")
        XCTAssertEqual(ArtworkPaletteDiagnostics.colors([]), "[]")
    }

    func testAllThemesHaveLegibleGradientStopsAndBlackStaysDarker() {
        for scheme in [ColorScheme.light, .dark] {
            for theme in AppTheme.allCases {
                let palette = ThemePalette.palette(for: theme, systemColorScheme: scheme)
                for tint: [Color]? in [nil, [.red, .blue, .green], []] {
                    let colors = AmbientGradientBackground.meshColors(tint: tint, palette: palette)
                    XCTAssertEqual(colors.count, 9)
                    for color in colors {
                        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                        XCTAssertTrue(UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a))
                        XCTAssertEqual(a, 1)
                        if palette.isLight {
                            XCTAssertGreaterThan(min(r, g, b), 0.65)
                        } else if theme == .pureBlack {
                            XCTAssertLessThan(max(r, g, b), 0.105)
                        } else {
                            XCTAssertLessThan(max(r, g, b), 0.30)
                        }
                    }
                }
            }
        }
    }

    func testLightGradientIsUnchangedWithAndWithoutArtworkTint() throws {
        let original: [[Double]] = [
            [0.86, 0.89, 0.93], [0.88, 0.90, 0.93], [0.91, 0.90, 0.91],
            [0.88, 0.90, 0.92], [0.93, 0.93, 0.93], [0.92, 0.91, 0.90],
            [0.91, 0.89, 0.84], [0.94, 0.94, 0.92], [0.89, 0.92, 0.89]
        ]
        let untinted = AmbientGradientBackground.meshColors(tint: nil, palette: .light)
        let tinted = AmbientGradientBackground.meshColors(
            tint: [Color(red: 1, green: 0, blue: 0)], palette: .light
        )
        for index in original.indices {
            let baseline = original[index]
            let plain = channels(untinted[index])
            for channel in 0..<3 { XCTAssertEqual(plain[channel], baseline[channel], accuracy: 0.0001) }
            let red = try XCTUnwrap(baseline.max())
            let actual = channels(tinted[index])
            XCTAssertEqual(actual[0], red, accuracy: 0.0001)
            XCTAssertEqual(actual[1], red * 0.82, accuracy: 0.0001)
            XCTAssertEqual(actual[2], red * 0.82, accuracy: 0.0001)
        }
    }

    func testDarkIsSofterAndBlackIsMoreVisibleWithoutBecomingDark() throws {
        let dark = AmbientGradientBackground.meshColors(tint: nil, palette: .dark).map(channels)
        let black = AmbientGradientBackground.meshColors(tint: nil, palette: .pureBlack).map(channels)
        XCTAssertEqual(dark[0][2], 0.22088, accuracy: 0.0001)
        XCTAssertEqual(black[0][2], 0.08032, accuracy: 0.0001)
        XCTAssertEqual(black[0][2] / 0.1004, 0.8, accuracy: 0.0001)
        XCTAssertLessThan(dark[0][2], 0.251)
        XCTAssertGreaterThan(black[0][2], 0.251 * 0.22)
        for index in dark.indices {
            for channel in 0..<3 {
                XCTAssertLessThan(black[index][channel], dark[index][channel] * 0.5)
            }
        }
        let values = black.flatMap { $0 }
        let contrast = try XCTUnwrap(values.max()) - XCTUnwrap(values.min())
        XCTAssertGreaterThan(contrast, 0.03, "Black must retain visible variation instead of crushing the gradient.")
    }

    private func channels(_ color: Color) -> [Double] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a))
        return [Double(r), Double(g), Double(b)]
    }

    func testRapidNavigationCoalescesToOneSampleAndCachesArtworkIdentity() async {
        let model = AmbientBackdropModel()
        let counter = SampleCounter()
        let owner = UUID()
        var tasks: [Task<Void, Never>] = []
        for index in 0..<80 {
            tasks.append(Task {
                await model.update(owner: owner, key: key("\(index)"), delay: .milliseconds(40)) {
                    await counter.sample(.red)
                }
            })
        }
        for task in tasks { await task.value }
        let count = await counter.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.colors, [.red])
        await model.update(owner: owner, key: key("79"), delay: .zero) {
            await counter.sample(.blue)
        }
        let cachedCount = await counter.count
        XCTAssertEqual(cachedCount, 1)
        let changedArtwork = AmbientArtworkKey(id: "79", reference: .remote(URL(string: "https://other.example/art")!))
        await model.update(owner: owner, key: changedArtwork, delay: .zero) {
            await counter.sample(.blue)
        }
        XCTAssertEqual(model.colors, [.blue])
        let changedCount = await counter.count
        XCTAssertEqual(changedCount, 2)
    }

    func testLateCompletionAndOldOwnerCannotReplaceOrClearNewTint() async {
        let model = AmbientBackdropModel()
        let gate = SampleGate()
        let old = UUID(), current = UUID()
        let task = Task {
            await model.update(owner: old, key: key("old"), delay: .zero) { await gate.sample() }
        }
        await gate.waitUntilEntered()
        await model.update(owner: current, key: key("new"), delay: .zero) { [.blue] }
        model.release(owner: old)
        await gate.release()
        await task.value
        XCTAssertEqual(model.colors, [.blue])
        model.release(owner: current)
        XCTAssertNil(model.colors)
    }

    func testDisabledAndCancelledSourcesDoNotSampleAndCacheIsBounded() async {
        let model = AmbientBackdropModel()
        let counter = SampleCounter()
        let owner = UUID()
        await model.update(owner: owner, key: nil, delay: .zero) { await counter.sample(.red) }
        let cancelled = Task {
            await model.update(owner: owner, key: key("cancel"), delay: .milliseconds(100)) {
                await counter.sample(.red)
            }
        }
        cancelled.cancel()
        await cancelled.value
        let initial = await counter.count
        XCTAssertEqual(initial, 0)
        for index in 0..<25 {
            await model.update(owner: owner, key: key("\(index)"), delay: .zero) {
                await counter.sample(.red)
            }
        }
        await model.update(owner: owner, key: key("0"), delay: .zero) { await counter.sample(.blue) }
        XCTAssertEqual(model.colors, [.blue], "The oldest palette is evicted after 24 entries.")
    }

    func testMissingArtworkCanRecoverAndCancelledCacheHitCannotReplaceCurrentTint() async {
        let model = AmbientBackdropModel()
        let owner = UUID()
        await model.update(owner: owner, key: key("first"), delay: .zero) { nil }
        XCTAssertNil(model.colors)
        await model.update(owner: owner, key: key("first"), delay: .zero) { [.red] }
        XCTAssertEqual(model.colors, [.red])
        await model.update(owner: owner, key: key("second"), delay: .zero) { [.blue] }
        let stale = Task {
            await model.update(owner: owner, key: key("first"), delay: .zero) { [.red] }
        }
        stale.cancel()
        await stale.value
        XCTAssertEqual(model.colors, [.blue])
    }

    private func key(_ id: String) -> AmbientArtworkKey {
        AmbientArtworkKey(id: id, reference: .remote(URL(string: "https://art.example/\(id)")!))
    }
}

private actor SampleCounter {
    var count = 0
    func sample(_ color: Color) -> [Color] { count += 1; return [color] }
}
private actor SampleGate {
    private var entered = false
    private var continuation: CheckedContinuation<[Color], Never>?
    func sample() async -> [Color] {
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async {
        for _ in 0..<1_000 {
            if entered { return }
            await Task.yield()
        }
        XCTFail("Expected sample to start")
    }
    func release() { continuation?.resume(returning: [.red]); continuation = nil }
}
