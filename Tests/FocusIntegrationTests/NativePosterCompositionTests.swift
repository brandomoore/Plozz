#if os(tvOS)
import CoreModels
@testable import CoreUI
import SwiftUI
import UIKit
import XCTest

@MainActor
final class NativePosterCompositionTests: XCTestCase {
    func testMissingArtworkReusesPlaceholderWithoutSchedulingComposition() {
        let coordinator = NativeTVPoster<EmptyView>.Coordinator(focus: PlozzCardFocus().projectedValue, action: {})
        let size = CGSize(width: 260, height: 390)
        var environment = EnvironmentValues()
        environment.displayScale = 1
        let placeholder = NativePosterArtworkBitmap.placeholder(size: size, scale: 1, clipsToArtwork: false)
        let before = NativePosterArtworkBitmap.compositionCounts
        let result = coordinator.presentationImage(
            nil, treatment: .original, size: size, indicators: nil,
            artworkBackground: .init(), environment: environment
        )
        XCTAssertTrue(result === placeholder)
        XCTAssertEqual(NativePosterArtworkBitmap.compositionCounts.total, before.total)
    }

    func testBackgroundCompositionPreservesPixelsClippingDimmingAndScrim() async throws {
        let source = source(index: 3)
        for size in [CGSize(width: 160, height: 240), CGSize(width: 320, height: 180)] {
            for scale: CGFloat in [1, 2] {
                let background = NativePosterArtworkBackground(
                    dimming: 0.15, scrim: .init(top: true, bottom: true)
                )
                let clipped = size.width >= size.height
                let expected = try XCTUnwrap(NativePosterArtworkBitmap.image(
                    source: source, size: size, scale: scale, backgroundColor: .darkGray,
                    clipsToArtwork: clipped, artworkBackground: background
                ))
                let result = await NativePosterArtworkBitmap.composite(
                    source: source, overlay: nil, size: size, scale: scale, backgroundColor: .darkGray,
                    clipsToArtwork: clipped, artworkBackground: background
                )
                let actual = try XCTUnwrap(result)
                XCTAssertEqual(actual.pngData(), expected.pngData())
            }
        }
    }

    func testPendingRequestsCoalesceAndCompletedPixelsAreReused() async throws {
        let coordinator = NativeTVPoster<EmptyView>.Coordinator(focus: PlozzCardFocus().projectedValue, action: {})
        defer { coordinator.cancelPresentation() }
        let image = source(index: 2)
        let size = CGSize(width: 260, height: 390)
        var environment = EnvironmentValues()
        environment.displayScale = 1
        _ = NativePosterArtworkBitmap.placeholder(size: size, scale: 1, clipsToArtwork: false)
        let before = NativePosterArtworkBitmap.compositionCounts
        var outputs: [UIImage] = []
        for _ in 0..<20 {
            _ = coordinator.presentationImage(
                image, treatment: .original, size: size, indicators: nil,
                artworkBackground: .init(), environment: environment, onReady: { outputs.append($0) }
            )
        }
        XCTAssertTrue(outputs.isEmpty, "Layout must return before source conversion.")
        try await waitUntil { !outputs.isEmpty }
        XCTAssertEqual(outputs.count, 1)
        let cached = coordinator.presentationImage(
            image, treatment: .original, size: size, indicators: nil,
            artworkBackground: .init(), environment: environment
        )
        XCTAssertTrue(cached === outputs.first)
        XCTAssertEqual(NativePosterArtworkBitmap.compositionCounts.total - before.total, 1)
        XCTAssertEqual(NativePosterArtworkBitmap.compositionCounts.main - before.main, 0)
    }

    func testReplacementRejectsStaleCompletionAndCancellationReleasesCoordinator() async throws {
        var coordinator: NativeTVPoster<EmptyView>.Coordinator? = .init(
            focus: PlozzCardFocus().projectedValue, action: {}
        )
        weak var weakCoordinator = coordinator
        let first = source(index: 0), second = source(index: 8)
        let size = CGSize(width: 240, height: 360)
        var environment = EnvironmentValues()
        environment.displayScale = 1
        var staleCompletions = 0
        var current: UIImage?
        _ = coordinator?.presentationImage(
            first, treatment: .original, size: size, indicators: nil,
            artworkBackground: .init(), environment: environment, onReady: { _ in staleCompletions += 1 }
        )
        _ = coordinator?.presentationImage(
            second, treatment: .original, size: size, indicators: nil,
            artworkBackground: .init(), environment: environment, onReady: { current = $0 }
        )
        try await waitUntil { current != nil }
        XCTAssertEqual(staleCompletions, 0)
        let expected = try XCTUnwrap(NativePosterArtworkBitmap.image(
            source: second, size: size, scale: 1, backgroundColor: .darkGray, clipsToArtwork: false
        ))
        XCTAssertEqual(current?.pngData(), expected.pngData())
        _ = coordinator?.presentationImage(
            first, treatment: .original, size: size, indicators: nil,
            artworkBackground: .init(), environment: environment, onReady: { _ in staleCompletions += 1 }
        )
        coordinator?.cancelPresentation()
        coordinator = nil
        await Task.yield()
        XCTAssertNil(weakCoordinator)
        XCTAssertEqual(staleCompletions, 0)
    }

    func testSameArtworkKeepsCompletedPixelsWhileChromeIsRecomposed() async throws {
        for size in [CGSize(width: 260, height: 390), CGSize(width: 320, height: 210)] {
            let coordinator = NativeTVPoster<EmptyView>.Coordinator(focus: PlozzCardFocus().projectedValue, action: {})
            defer { coordinator.cancelPresentation() }
            let image = source(index: 4, size: CGSize(width: 520, height: 780))
            var environment = EnvironmentValues()
            environment.displayScale = 1
            environment.plozzShowsUnwatchedEpisodeCount = true
            var completed: UIImage?
            _ = coordinator.presentationImage(
                image, treatment: .original, size: size, indicators: nil,
                artworkBackground: .init(), environment: environment, onReady: { completed = $0 }
            )
            try await waitUntil { completed != nil }
            let initial = try XCTUnwrap(completed)
            let indicators = NativePosterIndicators.media(MediaCardPlaybackIndicators(
                item: MediaItem(id: "same-artwork", title: "Series", kind: .series, unwatchedEpisodeCount: 12345),
                badgeInset: 12
            ).statusOnly)
            for dimming: CGFloat in [0.1, 0.2] {
                for _ in 0..<3 {
                    let pending = coordinator.presentationImage(
                        image, treatment: .original, size: size, indicators: indicators,
                        artworkBackground: .init(dimming: dimming), environment: environment,
                        onReady: { completed = $0 }
                    )
                    XCTAssertTrue(pending === initial, "Chrome updates must not flash the loading tile over loaded artwork.")
                    XCTAssertNil(coordinator.displayedOverlay, "Do not show new digits before their matching tile is ready.")
                }
            }
            try await waitUntil { completed !== initial }
            let final = try XCTUnwrap(completed)
            XCTAssertNotNil(coordinator.displayedOverlay)
            XCTAssertNotEqual(final.pngData(), initial.pngData(), "The latest chrome must still finish rendering.")
            XCTAssertTrue(coordinator.presentationImage(
                image, treatment: .original, size: size, indicators: indicators,
                artworkBackground: .init(dimming: 0.2), environment: environment
            ) === final)
            let foreground = try XCTUnwrap(coordinator.displayedOverlay?.image)
            XCTAssertTrue(coordinator.presentationImage(
                image, treatment: .original, size: size, indicators: nil,
                artworkBackground: .init(dimming: 0.3), environment: environment, onReady: { completed = $0 }
            ) === final)
            XCTAssertTrue(coordinator.displayedOverlay?.image === foreground,
                          "Keep old digits with their old tile until both can be replaced.")
            try await waitUntil { completed !== final }
            XCTAssertNil(coordinator.displayedOverlay, "Removing a badge must remove both layers together.")
        }
    }

    func testArtworkReplacementAndProtectionDoNotKeepPreviousPixels() async throws {
        let image = source(index: 5, size: CGSize(width: 520, height: 780))
        let replacement = source(index: 6, size: CGSize(width: 520, height: 780))
        let size = CGSize(width: 260, height: 390)
        var environment = EnvironmentValues()
        environment.displayScale = 1
        let placeholder = NativePosterArtworkBitmap.placeholder(size: size, scale: 1, clipsToArtwork: false)
        for (nextImage, treatment) in [
            (replacement as UIImage?, NativePosterImageTreatment.original),
            (image, .blurred),
            (nil, .original)
        ] {
            let coordinator = NativeTVPoster<EmptyView>.Coordinator(focus: PlozzCardFocus().projectedValue, action: {})
            defer { coordinator.cancelPresentation() }
            var completed: UIImage?
            _ = coordinator.presentationImage(
                image, treatment: .original, size: size, indicators: nil,
                artworkBackground: .init(), environment: environment, onReady: { completed = $0 }
            )
            try await waitUntil { completed != nil }
            let pending = coordinator.presentationImage(
                nextImage, treatment: treatment, size: size, indicators: nil,
                artworkBackground: .init(), environment: environment
            )
            XCTAssertTrue(pending === placeholder, "A new source or spoiler treatment must hide the previous picture immediately.")
        }
    }

    func testProgressiveUpgradeKeepsOnlyTheSameArtworkIdentity() async throws {
        let coordinator = NativeTVPoster<EmptyView>.Coordinator(focus: PlozzCardFocus().projectedValue, action: {})
        defer { coordinator.cancelPresentation() }
        let preview = source(index: 2, size: CGSize(width: 130, height: 195))
        let full = source(index: 2, size: CGSize(width: 520, height: 780))
        let size = CGSize(width: 260, height: 390)
        var environment = EnvironmentValues()
        environment.displayScale = 1
        var completed: UIImage?
        _ = coordinator.presentationImage(
            preview, identity: "account-a|movie", treatment: .original, size: size, indicators: nil,
            artworkBackground: .init(), environment: environment, onReady: { completed = $0 }
        )
        try await waitUntil { completed != nil }
        let initial = try XCTUnwrap(completed)
        let pending = coordinator.presentationImage(
            full, identity: "account-a|movie", treatment: .original, size: size, indicators: nil,
            artworkBackground: .init(), environment: environment, onReady: { completed = $0 }
        )
        XCTAssertTrue(pending === initial, "A higher-quality decode must not flash a placeholder over its preview.")
        try await waitUntil { completed !== initial }
        let placeholder = NativePosterArtworkBitmap.placeholder(size: size, scale: 1, clipsToArtwork: false)
        let replacement = source(index: 3, size: CGSize(width: 520, height: 780))
        XCTAssertTrue(coordinator.presentationImage(
            replacement, identity: "account-b|movie", treatment: .original, size: size, indicators: nil,
            artworkBackground: .init(), environment: environment
        ) === placeholder, "A different account/title must not retain the previous image.")
    }

    func testPerformanceNativePosterComposition() async throws {
        try PerformanceProbe.requireEnabled()
        let sources = (0..<12).map { source(index: $0) }
        var environment = EnvironmentValues()
        environment.displayScale = 1
        let size = CGSize(width: 320, height: 480)
        let coordinators = sources.map { _ in
            NativeTVPoster<EmptyView>.Coordinator(focus: PlozzCardFocus().projectedValue, action: {})
        }
        _ = NativePosterArtworkBitmap.placeholder(size: size, scale: 1, clipsToArtwork: false)
        var completed = 0
        var outputs: [UIImage] = []
        try await PerformanceProbe.measure(self, scenario: "native-poster-composition") {
            let before = NativePosterArtworkBitmap.compositionCounts
            completed = 0
            outputs.removeAll(keepingCapacity: true)
            let start = ContinuousClock.now
            for (index, coordinator) in coordinators.enumerated() {
                _ = coordinator.presentationImage(
                    sources[(index + rotation) % sources.count], treatment: .original, size: size,
                    indicators: nil, artworkBackground: .init(dimming: CGFloat(rotation + 1) / 100),
                    environment: environment,
                    onReady: { output in
                        outputs.append(output)
                        completed += 1
                    }
                )
            }
            let scheduling = start.duration(to: .now).components
            try await waitUntil { completed == sources.count }
            withExtendedLifetime(coordinators) {}
            XCTAssertEqual(outputs.count, sources.count)
            XCTAssertTrue(outputs.allSatisfy { $0.size == size && $0.cgImage != nil })
            rotation += 1
            let after = NativePosterArtworkBitmap.compositionCounts
            XCTAssertEqual(after.total - before.total, sources.count, "Every sample must compose all cold presentation keys.")
            return [
                "completedPosters": completed,
                "compositions": after.total - before.total,
                "mainThreadCompositions": after.main - before.main,
                "requestMicroseconds": Int(scheduling.seconds * 1_000_000 + scheduling.attoseconds / 1_000_000_000_000)
            ]
        }
    }

    private var rotation = 0

    func testPerformancePortraitReflectionPreparation() async throws {
        try PerformanceProbe.requireEnabled()
        let sources = (0..<12).map { source(index: $0, size: CGSize(width: 640, height: 960)) }
        let coordinators = sources.map { _ in
            NativeTVPoster<EmptyView>.Coordinator(focus: PlozzCardFocus().projectedValue, action: {})
        }
        try await PerformanceProbe.measure(self, scenario: "portrait-reflection-cold") {
            let width = CGFloat(280 + rotation)
            let size = CGSize(width: width, height: width * 1.5)
            rotation += 1
            var images: [UIImage] = []
            var longestPrepare = 0
            for (index, coordinator) in coordinators.enumerated() {
                let start = ContinuousClock.now
                let image = try XCTUnwrap(coordinator.prepare(
                    sources[index], treatment: .extendedPortrait(blurredReflection: true), size: size, scale: 1
                ))
                let elapsed = start.duration(to: .now).components
                longestPrepare = max(longestPrepare, Int(elapsed.seconds * 1_000_000
                    + elapsed.attoseconds / 1_000_000_000_000))
                XCTAssertEqual(image.size.width, size.width, accuracy: 1)
                XCTAssertEqual(image.size.height, size.height, accuracy: 1)
                XCTAssertNotNil(image.cgImage)
                images.append(image)
            }
            XCTAssertEqual(Set(images.map(ObjectIdentifier.init)).count, sources.count)
            return ["completedPosters": images.count, "maxPreparationMicroseconds": longestPrepare]
        }
    }

    func testPerformancePortraitReflectionReuse() async throws {
        try PerformanceProbe.requireEnabled()
        let sources = (0..<12).map { source(index: $0, size: CGSize(width: 640, height: 960)) }
        let size = CGSize(width: 280, height: 420)
        let prepared = try sources.map { source in
            let coordinator = NativeTVPoster<EmptyView>.Coordinator(focus: PlozzCardFocus().projectedValue, action: {})
            return try XCTUnwrap(coordinator.prepare(
                source, treatment: .extendedPortrait(blurredReflection: true), size: size, scale: 1
            ))
        }
        try await PerformanceProbe.measure(self, scenario: "portrait-reflection-warm") {
            var reused = 0
            for _ in 0..<24 {
                for (index, source) in sources.enumerated() {
                    let coordinator = NativeTVPoster<EmptyView>.Coordinator(
                        focus: PlozzCardFocus().projectedValue, action: {}
                    )
                    let image = try XCTUnwrap(coordinator.prepare(
                        source, treatment: .extendedPortrait(blurredReflection: true), size: size, scale: 1
                    ))
                    XCTAssertTrue(image === prepared[index], "Recreated cards must reuse the finished reflection.")
                    if image === prepared[index] { reused += 1 }
                }
            }
            XCTAssertEqual(reused, 288)
            return ["requests": 288, "reusedBitmaps": reused]
        }
    }

    func testPerformanceNativePosterIndicatorReuse() async throws {
        try PerformanceProbe.requireEnabled()
        var environment = EnvironmentValues()
        environment.displayScale = 1
        environment.plozzShowsUnwatchedEpisodeCount = true
        environment.plozzWatchStatusIndicator = .watched
        let coordinators = (0..<24).map { _ in
            NativeTVPoster<EmptyView>.Coordinator(focus: PlozzCardFocus().projectedValue, action: {})
        }
        let inputs = (0..<72).map { index in
            NativePosterIndicators.playback(MediaCardPlaybackIndicators(
                item: MediaItem(
                    id: "indicator-\(index)", title: "Series", kind: .series,
                    resumePosition: Double(index + 1) * 30,
                    playedPercentage: Double(index + 1) / 100,
                    unwatchedEpisodeCount: 8 + index % 3
                ),
                badgeInset: 12
            ).bitmapInputs)
        }
        try await PerformanceProbe.measure(self, scenario: "native-poster-indicators") {
            // Each sample starts with cold geometry, without clearing shared caches.
            let size = CGSize(width: 160 + rotation, height: 240 + rotation)
            rotation += 1
            var images: [UIImage] = []
            for (index, input) in inputs.enumerated() {
                let overlay = try XCTUnwrap(coordinators[index % coordinators.count].presentationOverlay(
                    size: size, indicators: input, environment: environment
                ))
                XCTAssertEqual(overlay.image.size, size)
                XCTAssertNotNil(overlay.image.cgImage)
                images.append(overlay.image)
            }
            XCTAssertEqual(images.count, inputs.count, "Every requested foreground must finish rendering.")
            return [
                "completedOverlays": images.count,
                "distinctBitmaps": Set(images.map(ObjectIdentifier.init)).count
            ]
        }
    }

    private func source(index: Int, size: CGSize = CGSize(width: 2160, height: 3240)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .extended
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(displayP3Red: CGFloat(index + 1) / 13, green: 0.35, blue: 0.8, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(x: CGFloat(index * 30) * size.width / 2160,
                                y: 400 * size.height / 3240, width: 300 * size.width / 2160,
                                height: 600 * size.height / 3240))
        }
    }

    private func waitUntil(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !ready(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(ready(), "All requested artwork must complete; placeholders do not count as finished work.")
    }
}
#endif
