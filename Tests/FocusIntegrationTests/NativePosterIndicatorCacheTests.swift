#if os(tvOS)
import CoreModels
@testable import CoreUI
import SwiftUI
import UIKit
import XCTest

@MainActor
final class NativePosterIndicatorCacheTests: XCTestCase {
    private typealias Key = NativePosterArtworkBitmap.IndicatorKey
    private let size = CGSize(width: 160, height: 240)

    func testForegroundReusePreservesPixelsAcrossProgressAndDownloadChanges() throws {
        for style in [WatchStatusIndicator.watched, .unwatched] {
            var environment = environment()
            environment.plozzWatchStatusIndicator = style
            let first = indicators(progress: 0.2)
            let changed = indicators(progress: 0.8, downloaded: true)
            let firstKey = Key(first, environment: environment, layer: .foreground)
            let changedKey = Key(changed, environment: environment, layer: .foreground)
            XCTAssertEqual(firstKey, changedKey)

            let fresh = try render(changedKey, environment: environment)
            purge()
            let initial = try render(firstKey, environment: environment)
            let reused = try render(changedKey, environment: environment)
            XCTAssertTrue(initial === reused, "Different titles with the same badge must share its pixels.")
            XCTAssertEqual(reused.pngData(), fresh.pngData(), "Reuse must match a cold render of the new inputs.")
        }
    }

    func testStatusGeometryAndEnvironmentRemainPartOfCacheIdentity() throws {
        let environment = environment()
        let input = indicators(progress: 0.2)
        let key = Key(input, environment: environment, layer: .foreground)
        for changed in [
            indicators(progress: 0.2, count: 9),
            indicators(progress: 0.2, hidden: true),
            indicators(progress: 0.2, inset: 25),
            indicators(progress: 0.2, corner: 5)
        ] {
            XCTAssertNotEqual(key, Key(changed, environment: environment, layer: .foreground))
        }
        let changes: [(inout EnvironmentValues) -> Void] = [
            { $0.plozzWatchStatusIndicator = .unwatched },
            { $0.plozzWatchIndicatorColor = .purple },
            { $0.plozzShowsUnwatchedEpisodeCount = false },
            { $0.plozzEpisodeCountBadgeStyle = .floating },
            { $0.plozzSeerConnected = true },
            { $0.locale = Locale(identifier: "ar") },
            { $0.layoutDirection = .rightToLeft },
            { $0.colorScheme = .light },
            { $0.dynamicTypeSize = .accessibility1 },
            { $0.legibilityWeight = .bold },
            { $0.themePalette = .light },
            { $0.plozzMetrics = PlozzMetrics(density: .compact) }
        ]
        for (index, change) in changes.enumerated() {
            var changed = environment
            change(&changed)
            XCTAssertNotEqual(key, Key(input, environment: changed, layer: .foreground), "Environment input \(index)")
        }
        let first = try render(key, environment: environment)
        let resized = try XCTUnwrap(NativePosterArtworkBitmap.indicatorImage(
            key: key, size: CGSize(width: 180, height: 270), scale: 1, environment: environment
        ))
        let scaled = try XCTUnwrap(NativePosterArtworkBitmap.indicatorImage(
            key: key, size: size, scale: 2, environment: environment
        ))
        XCTAssertFalse(first === resized)
        XCTAssertFalse(first === scaled)
        XCTAssertEqual(scaled.cgImage?.width, 320)
    }

    func testProgressStillInvalidatesCombinedAndBackgroundLayersAndWatchStatus() {
        let environment = environment()
        for layer in [NativePosterIndicatorLayer.combined, .background] {
            XCTAssertNotEqual(
                Key(indicators(progress: 0.2), environment: environment, layer: layer),
                Key(indicators(progress: 0.8), environment: environment, layer: layer)
            )
        }
        let watched = MediaItem(id: "movie", title: "Movie", kind: .movie, isPlayed: true)
        var resumed = watched
        resumed.resumePosition = 100
        resumed.playedPercentage = 0.2
        let watchedInputs = NativePosterIndicators.playback(MediaCardPlaybackIndicators(item: watched, badgeInset: 12).bitmapInputs)
        let resumedInputs = NativePosterIndicators.playback(MediaCardPlaybackIndicators(item: resumed, badgeInset: 12).bitmapInputs)
        XCTAssertNotEqual(
            Key(watchedInputs, environment: environment, layer: .foreground),
            Key(resumedInputs, environment: environment, layer: .foreground),
            "Progress that changes the visible watched status must not reuse that badge."
        )
    }

    func testWatchColorsInvalidateNativeRowAndLibraryCachesAndChangePixels() throws {
        for mode in WatchStatusIndicator.allCases where mode != .hidden {
            let item = MediaItem(id: "movie", title: "Movie", kind: .movie, isPlayed: mode == .watched)
            let inputs = NativePosterIndicators.playback(MediaCardPlaybackIndicators(item: item, badgeInset: 12).bitmapInputs)
            var environment = environment()
            environment.plozzWatchStatusIndicator = mode
            let whiteKey = Key(inputs, environment: environment)
            let whiteImage = try render(whiteKey, environment: environment)
            let whiteLibrary = NativeLibraryPosterBitmap.Presentation(
                item: item, spoilerSettings: .default, environment: environment
            )
            for color in WatchIndicatorColor.allCases where color != .white {
                environment.plozzWatchIndicatorColor = color
                let key = Key(inputs, environment: environment)
                XCTAssertNotEqual(key, whiteKey)
                XCTAssertNotEqual(try render(key, environment: environment).pngData(), whiteImage.pngData())
                XCTAssertNotEqual(NativeLibraryPosterBitmap.Presentation(
                    item: item, spoilerSettings: .default, environment: environment
                ), whiteLibrary)
            }
        }
    }

    func testEpisodeCountStyleInvalidatesBothNativeCachesIndependentlyOfWatchMode() throws {
        let item = MediaItem(id: "series", title: "Series", kind: .series, unwatchedEpisodeCount: 8)
        let input = indicators(progress: 0.2)
        for mode in WatchStatusIndicator.allCases {
            var attached = environment()
            attached.plozzWatchStatusIndicator = mode
            attached.plozzEpisodeCountBadgeStyle = .attached
            var floating = attached
            floating.plozzEpisodeCountBadgeStyle = .floating
            for layer in [NativePosterIndicatorLayer.combined, .background, .foreground] {
                let attachedKey = Key(input, environment: attached, layer: layer)
                let floatingKey = Key(input, environment: floating, layer: layer)
                XCTAssertNotEqual(attachedKey, floatingKey)
                if case .croppedCount = attachedKey.overlayPlacement {} else {
                    XCTFail("Attached counts must clip at the artwork boundary in both watch modes.")
                }
                if case .floating = floatingKey.overlayPlacement {} else {
                    XCTFail("Floating counts must retain their inset in both watch modes.")
                }
                XCTAssertNotEqual(try render(attachedKey, environment: attached).pngData(),
                                  try render(floatingKey, environment: floating).pngData())
            }
            XCTAssertNotEqual(
                NativeLibraryPosterBitmap.Presentation(item: item, spoilerSettings: .default, environment: attached),
                NativeLibraryPosterBitmap.Presentation(item: item, spoilerSettings: .default, environment: floating)
            )
        }
    }

    func testHiddenClearsCachedWatchMarksWithoutHidingCountsOrProgress() throws {
        purge()
        for mode in [WatchStatusIndicator.watched, .unwatched] {
            let item = MediaItem(id: "movie", title: "Movie", kind: .movie, isPlayed: mode == .watched)
            let inputs = NativePosterIndicators.media(MediaCardPlaybackIndicators(item: item, badgeInset: 12))
            var visible = environment()
            visible.plozzWatchStatusIndicator = mode
            var hidden = visible
            hidden.plozzWatchStatusIndicator = .hidden
            let visibleKey = Key(inputs, environment: visible)
            let hiddenKey = Key(inputs, environment: hidden)
            XCTAssertNotEqual(visibleKey, hiddenKey)
            XCTAssertNotEqual(try render(visibleKey, environment: visible).pngData(),
                              try render(hiddenKey, environment: hidden).pngData())
            let suppressed = NativePosterIndicators.media(
                MediaCardPlaybackIndicators(item: item, hidesStatus: true, badgeInset: 12)
            )
            XCTAssertEqual(try render(hiddenKey, environment: hidden).pngData(),
                           try render(Key(suppressed, environment: visible), environment: visible).pngData())
            let countAndProgress = indicators(progress: 0.4, downloaded: true)
            XCTAssertEqual(
                try render(Key(countAndProgress, environment: visible), environment: visible).pngData(),
                try render(Key(countAndProgress, environment: hidden), environment: hidden).pngData()
            )
        }
    }

    func testCacheRemainsBoundedAndPurgesOnMemoryWarning() throws {
        let environment = environment()
        _ = try render(Key(indicators(progress: 0.2), environment: environment, layer: .foreground), environment: environment)
        purge()
        for count in 1...(NativePosterArtworkBitmap.indicatorCountLimit + 3) {
            _ = try render(Key(indicators(progress: 0.2, count: count), environment: environment, layer: .foreground),
                           environment: environment)
            XCTAssertLessThanOrEqual(NativePosterArtworkBitmap.indicatorCount, NativePosterArtworkBitmap.indicatorCountLimit)
            XCTAssertLessThanOrEqual(NativePosterArtworkBitmap.indicatorBytes, NativePosterArtworkBitmap.indicatorByteLimit)
        }
        purge()
        XCTAssertEqual(NativePosterArtworkBitmap.indicatorCount, 0)
        XCTAssertEqual(NativePosterArtworkBitmap.indicatorBytes, 0)
    }

    private func environment() -> EnvironmentValues {
        var result = EnvironmentValues()
        result.plozzShowsUnwatchedEpisodeCount = true
        result.plozzWatchStatusIndicator = .watched
        result.plozzSeerConnected = false
        result.colorScheme = .dark
        result.themePalette = .dark
        result.locale = Locale(identifier: "en_US")
        result.displayScale = 1
        return result
    }

    func testProgressVisibilityInvalidatesBottomCachesButPreservesStatusAndDownloads() throws {
        let visible = environment()
        var hidden = visible
        hidden.plozzShowsProgressBars = false
        let input = indicators(progress: 0.4, downloaded: true)
        for layer in [NativePosterIndicatorLayer.combined, .background] {
            let visibleKey = Key(input, environment: visible, layer: layer)
            let hiddenKey = Key(input, environment: hidden, layer: layer)
            XCTAssertNotEqual(visibleKey, hiddenKey)
            XCTAssertNotEqual(try render(visibleKey, environment: visible).pngData(),
                              try render(hiddenKey, environment: hidden).pngData())
            let withoutProgress = indicators(progress: 0, downloaded: true)
            XCTAssertEqual(try render(hiddenKey, environment: hidden).pngData(),
                           try render(Key(withoutProgress, environment: hidden, layer: layer), environment: hidden).pngData())
        }
        XCTAssertEqual(Key(input, environment: visible, layer: .foreground),
                       Key(input, environment: hidden, layer: .foreground))
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, playedPercentage: 0.4)
        XCTAssertNotEqual(
            NativeLibraryPosterBitmap.Presentation(item: item, spoilerSettings: .default, environment: visible),
            NativeLibraryPosterBitmap.Presentation(item: item, spoilerSettings: .default, environment: hidden)
        )
        var hosted = EnvironmentValues()
        hosted.copyHostedPresentation(from: hidden)
        XCTAssertFalse(hosted.plozzShowsProgressBars)
    }

    private func indicators(
        progress: Double, count: Int = 8, downloaded: Bool = false,
        hidden: Bool = false, inset: CGFloat = 12, corner: CGFloat? = nil
    ) -> NativePosterIndicators {
        .playback(MediaCardPlaybackIndicators(
            item: MediaItem(id: "series", title: "Series", kind: .series,
                            resumePosition: progress * 1_000, playedPercentage: progress, unwatchedEpisodeCount: count),
            hidesStatus: hidden, badgeInset: inset,
            progressHeight: downloaded ? 10 : 4,
            progressHorizontalInset: downloaded ? 20 : 0,
            progressBottomInset: downloaded ? 10 : 0,
            downloadState: downloaded ? .completed : nil,
            artworkCornerRadius: corner
        ).bitmapInputs)
    }

    private func render(_ key: Key, environment: EnvironmentValues) throws -> UIImage {
        try XCTUnwrap(NativePosterArtworkBitmap.indicatorImage(key: key, size: size, scale: 1, environment: environment))
    }

    private func purge() {
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }
}
#endif
