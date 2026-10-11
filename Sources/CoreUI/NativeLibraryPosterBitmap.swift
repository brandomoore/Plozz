#if os(tvOS)
import CoreModels
import CoreNetworking
import SwiftUI
import UIKit

private struct CompositedLibraryPostersKey: EnvironmentKey {
    static var defaultValue: Bool {
        #if DEBUG
        !ProcessInfo.processInfo.arguments.contains("--original-library-posters")
        #else
        true
        #endif
    }
}

extension EnvironmentValues {
    var compositedLibraryPosters: Bool {
        get { self[CompositedLibraryPostersKey.self] }
        set { self[CompositedLibraryPostersKey.self] = newValue }
    }
}

@MainActor
enum NativePosterArtworkBitmap {
    static let placeholder = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 3)).image {
        UIColor.darkGray.setFill()
        $0.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
    }

    static func image(
        source: UIImage?, overlay: UIImage? = nil, size: CGSize, scale: CGFloat,
        backgroundColor: UIColor? = nil
    ) -> UIImage? {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
              size.width > 0, size.height > 0, scale > 0,
              source.map({ $0.size.width > 0 && $0.size.height > 0 }) ?? true else {
            PlozzLog.app.error("Unable to prepare native poster artwork with invalid dimensions")
            return nil
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.preferredRange = .standard
        let bounds = CGRect(origin: .zero, size: size)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIBezierPath(
                roundedRect: bounds,
                cornerRadius: PlozzTheme.Metrics.nativePosterArtworkCornerRadius
            ).addClip()
            if let background = backgroundColor ?? (source == nil ? .darkGray : nil) {
                background.setFill()
                context.fill(bounds)
            }
            if let source {
                let ratio = max(size.width / source.size.width, size.height / source.size.height)
                let target = CGSize(width: source.size.width * ratio, height: source.size.height * ratio)
                source.draw(in: CGRect(
                    x: (size.width - target.width) / 2, y: (size.height - target.height) / 2,
                    width: target.width, height: target.height
                ))
            }
            overlay?.draw(in: bounds)
        }
    }
}

/// Artwork and its indicators share one native floating image without internal zoom.
@MainActor
enum NativeLibraryPosterBitmap {
    struct Presentation: Equatable {
        let playback: MediaPlaybackIndicatorState?
        let symbol: MediaArtworkPlaceholder.Symbol
        let title: String?
        let hidesStatus: Bool
        let metrics: PlozzMetrics
        let palette: ThemePalette
        let watchIndicator: WatchStatusIndicator
        let showsEpisodeCount: Bool
        let seerConnected: Bool
        let locale: Locale
        let layoutDirection: LayoutDirection
        let colorScheme: ColorScheme
        let contrast: ColorSchemeContrast
        let dynamicTypeSize: DynamicTypeSize
        let legibilityWeight: LegibilityWeight?

        init(item: MediaItem?, spoilerSettings: SpoilerSettings, environment: EnvironmentValues) {
            playback = item.map(MediaPlaybackIndicatorState.init)
            symbol = item.map { .init(for: $0) } ?? .playback
            title = environment.plozzCardCaptionsHidden ? item.map {
                $0.posterCaptionTitle(spoilerSettings: spoilerSettings).resolve(locale: environment.locale)
            } : nil
            hidesStatus = item.map(spoilerSettings.shouldHideThumbnail(for:)) ?? false
            metrics = environment.plozzMetrics
            palette = environment.themePalette
            watchIndicator = environment.plozzWatchStatusIndicator
            showsEpisodeCount = environment.plozzShowsUnwatchedEpisodeCount
            seerConnected = environment.plozzSeerConnected
            locale = environment.locale
            layoutDirection = environment.layoutDirection
            colorScheme = environment.colorScheme
            contrast = environment.colorSchemeContrast
            dynamicTypeSize = environment.dynamicTypeSize
            legibilityWeight = environment.legibilityWeight
        }
    }

    final class Key: NSObject {
        let source: ObjectIdentifier?
        let presentation: Presentation
        let size: CGSize
        let scale: CGFloat

        init(image: UIImage?, presentation: Presentation, size: CGSize, scale: CGFloat) {
            source = image.map(ObjectIdentifier.init)
            self.presentation = presentation
            self.size = size
            self.scale = scale
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(source)
            hasher.combine(size.width)
            hasher.combine(size.height)
            hasher.combine(scale)
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return source == other.source && size == other.size && scale == other.scale
                && presentation == other.presentation
        }
    }

    private final class Entry {
        weak var source: UIImage?
        let image: UIImage
        let cost: Int
        var access: UInt64

        init(source: UIImage?, image: UIImage, cost: Int, access: UInt64) {
            self.source = source
            self.image = image
            self.cost = cost
            self.access = access
        }
    }

    static let byteLimit = 24 * 1024 * 1024
    static let countLimit = 64
    private(set) static var retainedBytes = 0
    private(set) static var renderCount = 0
    private static var cache: [Key: Entry] = [:]
    private static var clock: UInt64 = 0

    private struct Content: View {
        let presentation: Presentation
        let hasArtwork: Bool
        let size: CGSize
        let environment: EnvironmentValues

        var body: some View {
            NativeLibraryArtworkOverlay(
                symbol: presentation.symbol, hasArtwork: hasArtwork,
                isFolder: presentation.playback?.kind == .folder,
                isFocused: false,
                indicators: presentation.playback.map {
                    MediaCardPlaybackIndicators(
                        playback: $0, hidesStatus: presentation.hidesStatus,
                        showsProgressBar: true, badgeInset: 8,
                        progressHeight: presentation.metrics.progressBarHeight,
                        progressHorizontalInset: 16, progressBottomInset: 16,
                        artworkCornerRadius: PlozzTheme.Metrics.nativePosterArtworkCornerRadius
                    )
                },
                title: presentation.title.map { Text(verbatim: $0) }
            )
            .frame(width: size.width, height: size.height)
            .environment(\.self, environment)
            .plozzChromeFocused(false)
        }
    }

    static func image(source: UIImage?, key: Key, environment: EnvironmentValues) -> UIImage? {
        clock &+= 1
        if let entry = cache[key], entry.source === source {
            entry.access = clock
            return entry.image
        }
        let size = key.size
        guard size.width.isFinite, size.height.isFinite, key.scale.isFinite,
              size.width > 0, size.height > 0, key.scale > 0,
              source.map({ $0.size.width > 0 && $0.size.height > 0 }) ?? true else {
            PlozzLog.app.error("Unable to composite library artwork with invalid dimensions")
            return nil
        }
        // The full inherited environment can own library providers. Keep it out
        // of the shared cache and release the view graph after producing pixels.
        let active = ImageRenderer(content: Content(
            presentation: key.presentation, hasArtwork: source != nil, size: size, environment: environment
        ))
        active.scale = key.scale
        guard let overlay = active.uiImage else {
            PlozzLog.app.error("Unable to render composited library indicators")
            return nil
        }
        guard let image = NativePosterArtworkBitmap.image(
            source: source, overlay: overlay, size: size, scale: key.scale, backgroundColor: .darkGray
        ) else { return nil }
        renderCount += 1
        if let replaced = cache.removeValue(forKey: key) { retainedBytes -= replaced.cost }
        if let pixels = image.cgImage {
            let (cost, overflow) = pixels.bytesPerRow.multipliedReportingOverflow(by: pixels.height)
            if !overflow, cost <= byteLimit {
                while !cache.isEmpty && (retainedBytes + cost > byteLimit || cache.count >= countLimit) {
                    guard let oldest = cache.min(by: { $0.value.access < $1.value.access }) else { break }
                    retainedBytes -= oldest.value.cost
                    cache.removeValue(forKey: oldest.key)
                }
                cache[key] = Entry(source: source, image: image, cost: cost, access: clock)
                retainedBytes += cost
            }
        }
        return image
    }
}
#endif
