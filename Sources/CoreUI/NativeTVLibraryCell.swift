#if os(tvOS)
import CoreModels
import SwiftUI
import TVUIKit
import UIKit

/// UICollectionView owns focus and delivers the real configuration state.
/// Only the image participates in TVUIKit's projection; captions remain outside.
public final class NativeTVLibraryCell: UICollectionViewCell, DetailTransitionFocusRequesting {
    public private(set) var item: MediaItem?
    public var onRequestFocus: (() -> Bool)?
    private var environment = EnvironmentValues()
    private var spoilerSettings = SpoilerSettings.default
    private var style = PosterCardView.Style.poster
    private var artwork: UIImage?
    private var artworkReferences: [ArtworkReference] = []
    private var artworkPolicyIdentity: String?
    private var artworkItemIdentity: String?
    private var imageTask: Task<Void, Never>?
    private var compositeTask: Task<Void, Never>?
    private var imageRevision = UUID()
    private let caption = SystemPosterCaption.CaptionView()
    private let nativeArtwork = TVMediaItemContentView(configuration: TVMediaItemContentConfiguration.wideCell())
    private let plate = UIView()
    private let marker = DetailTransitionSourceView()
    private let entryFocusRegion = NavigationEntryFocusRegionView()
    private let source = DetailTransitionSourceReference()
    private var overlay: (UIView & UIContentView)?
    private var overlayFocused = false
    private var isConfiguredForDisplay = false
    private var compositedArtwork: NativePosterImageView?
    private var compositeKey: NativeLibraryPosterBitmap.Key?
    private weak var compositeSource: UIImage?
    /// The item whose composite the image view shows, so another item never inherits it.
    private var compositeItem: String?
    /// The image view shows that item's artwork, composited or not, rather than a plain tile.
    private var showsArtwork = false
    private var needsCompositeUpdate = true

    private var usesCompositedArtwork: Bool {
        (environment.compositedLibraryPosters || item.map { PosterCardPresentation.preservesContainerArtwork(for: $0.kind) } == true)
            && environment.plozzCardFocusStyle.usesSystemEffect
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = false
        backgroundConfiguration = .clear()
        addSubview(plate)
        sendSubviewToBack(plate)
        // UIKit owns contentView's full-cell size; artwork excludes the caption.
        addSubview(nativeArtwork)
        addSubview(caption)
        addSubview(marker)
        addSubview(entryFocusRegion)
        entryFocusRegion.preference = .content
        entryFocusRegion.nativeFocusItem = self
        caption.isUserInteractionEnabled = false
        marker.isUserInteractionEnabled = false
        marker.accessibilityElementsHidden = true
        marker.reference = source
        source.view = marker
        source.focusRequester = self
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override var canBecomeFocused: Bool { isConfiguredForDisplay && environment.isEnabled }

    public static func height(
        for width: CGFloat, environment: EnvironmentValues, style: PosterCardView.Style = .poster
    ) -> CGFloat {
        let metrics = environment.plozzMetrics
        let inset = environment.plozzCardStyle == .framed ? metrics.cardInset : metrics.borderlessCardSideMargin
        let size = CGSize(
            width: max(1, width - inset * 2),
            height: max(1, width - inset * 2) * (style == .poster ? 1.5 : 9.0 / 16.0)
        )
        if environment.plozzCardCaptionsHidden {
            return size.height + focusClearance * 2
        }
        let title = UIFont.systemFont(ofSize: metrics.cardTitleFontSize, weight: .semibold)
        let subtitle = UIFont.systemFont(ofSize: metrics.cardSubtitleFontSize)
        return size.height + focusClearance + metrics.nativePosterCaptionSpacing
            + ceil(title.lineHeight) + 2 + ceil(subtitle.lineHeight)
            + metrics.nativePosterCaptionFocusTravel + metrics.posterCaptionInset
    }

    public func configure(
        item: MediaItem?, spoilerSettings: SpoilerSettings, environment: EnvironmentValues,
        style: PosterCardView.Style = .poster
    ) {
        let styleChanged = self.style != style
        self.style = style
        isConfiguredForDisplay = true
        self.item = item
        self.spoilerSettings = spoilerSettings
        self.environment = environment
        #if DEBUG
        accessibilityIdentifier = usesCompositedArtwork
            ? "native-library-poster-composited" : "native-library-poster-baseline"
        #endif
        source.itemKey = item?.stablePresentationID ?? ""
        source.artworkPolicy = environment.plozzArtworkPolicy.forArea(.details)
        source.cornerRadius =
            environment.plozzCardStyle == .framed
            ? PlozzTheme.Metrics.posterArtCornerRadius : environment.plozzMetrics.posterCardCornerRadius
        accessibilityLabel = item?.posterCaptionTitle(spoilerSettings: spoilerSettings).resolve(locale: environment.locale)
            ?? loadingTitle
        accessibilityValue = item?.posterCaptionSubtitle()
        if let item, var countLabel = MediaPlaybackIndicatorState(item).episodeCountAccessibilityLabel(
            enabled: environment.plozzShowsUnwatchedEpisodeCount,
            hidesStatus: spoilerSettings.shouldHideThumbnail(for: item)
        ) {
            countLabel.locale = environment.locale
            let count = String(localized: countLabel) // l10n:content — UIKit accessibility boundary; resolved from the current environment
            accessibilityValue = [accessibilityValue, count].compactMap { $0 }.joined(separator: ", ")
        }
        accessibilityTraits = item == nil || !environment.isEnabled ? [.button, .notEnabled] : .button
        accessibilityHint = nil
        if item?.kind == .folder {
            var value = LocalizedStringResource("Folder")
            var hint = LocalizedStringResource("Open folder")
            value.locale = environment.locale
            hint.locale = environment.locale
            accessibilityValue = String(localized: value) // l10n:content — UIKit boundary; resolved with the current environment locale on every update
            accessibilityHint = String(localized: hint) // l10n:content — UIKit boundary; resolved with the current environment locale on every update
        }
        accessibilityElementsHidden = false
        let references =
            item.map {
                spoilerSettings.shouldHideThumbnail(for: $0) && $0.kind == .episode
                    ? $0.seriesArtworkReferences(prefersPortrait: true)
                    : CardArtworkPolicy.standard.references(for: $0, style: style)
            } ?? []
        let variant: ArtworkImageVariant = style == .poster ? .posterCard : .landscapeCard
        let maxAspect: CGFloat? = style == .poster
            && item.map { !PosterCardPresentation.preservesContainerArtwork(for: $0.kind) } != false ? 0.9 : nil
        let policy = environment.plozzArtworkPolicy
        let fallback = item.flatMap { CardArtworkPolicy.standard.posterFallback(for: $0) }
        let identity = item.map { CardArtworkPolicy.standard.pinIdentity(for: $0) }
        if styleChanged || references != artworkReferences || artworkPolicyIdentity != policy.identity
            || artworkItemIdentity != identity {
            artworkItemIdentity = identity
            imageTask?.cancel()
            artworkReferences = references
            artworkPolicyIdentity = policy.identity
            // Adopt only the first candidate synchronously. A cached fallback must
            // never overtake a preferred image that has not finished loading.
            if !(policy.prefersOnlineArtwork && fallback != nil),
               let reference = references.first, case .remote(let url) = reference {
                artwork = ArtworkImageCache.shared.cachedImage(for: url, variant: variant)
            } else {
                // Network-file cache reads must pass the resolver's access gate.
                artwork = nil
            }
            if let artwork, artwork.size.height <= 0
                || maxAspect.map({ artwork.size.width / artwork.size.height > $0 }) == true {
                self.artwork = nil
            }
            let revision = UUID()
            imageRevision = revision
            if artwork == nil, !references.isEmpty || fallback != nil {
                imageTask = Task { [weak self] in
                    let result = await ArtworkFirstPaintResolver.resolve(
                        references: references, variant: variant, maxAspectRatio: maxAspect,
                        asyncOnlineURL: fallback.map { resolve in
                            {
                                await ArtworkSession.artworkResolveLimiter.run {
                                    guard !Task.isCancelled else { return nil }
                                    return await resolve()
                                }
                            }
                        },
                        prefersOnlineArtwork: policy.prefersOnlineArtwork
                    )
                    guard !Task.isCancelled, let self, self.imageRevision == revision else { return }
                    self.artwork = result?.image
                    self.updateOverlay()
                    self.setNeedsUpdateConfiguration()
                }
            }
        }
        updateOverlay()
        updateCaption(animated: false)
        setNeedsUpdateConfiguration()
        setNeedsLayout()
    }

    public override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        if usesCompositedArtwork {
            if !nativeArtwork.isHidden {
                nativeArtwork.isHidden = true
                nativeArtwork.configuration = TVMediaItemContentConfiguration.wideCell()
            }
            if compositedArtwork == nil {
                compositedArtwork = NativePosterImageView(masksFocusEffectToContents: false)
            }
            if let compositedArtwork, compositedArtwork.superview !== self {
                insertSubview(compositedArtwork, belowSubview: caption)
            }
            source.nativeArtworkView = compositedArtwork
            setNeedsLayout()
            return
        }
        compositeTask?.cancel()
        compositeTask = nil
        compositedArtwork?.removeFromSuperview()
        compositedArtwork?.image = nil
        compositedArtwork?.updateIndicator(nil, focused: false)
        compositeKey = nil
        compositeItem = nil
        showsArtwork = false
        nativeArtwork.isHidden = false
        var configuration = TVMediaItemContentConfiguration.wideCell()
        configuration.image = artwork ?? Self.placeholder
        configuration.overlayView = overlay
        nativeArtwork.configuration = configuration.updated(for: state)
        source.nativeArtworkView = nativeArtwork
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let metrics = environment.plozzMetrics
        let framed = environment.plozzCardStyle == .framed
        let inset = framed ? metrics.cardInset : metrics.borderlessCardSideMargin
        let width = max(1, bounds.width - inset * 2)
        let scale = traitCollection.displayScale
        // Keep native artwork and overlay projection on the same pixel-aligned surface.
        let aspectHeight = style == .poster ? 1.5 : 9.0 / 16.0
        let size = usesCompositedArtwork
            ? CGSize(width: ceil(width * scale) / scale, height: ceil(width * aspectHeight * scale) / scale)
            : CGSize(width: width, height: width * aspectHeight)
        let artworkFrame = CGRect(x: inset, y: Self.focusClearance, width: size.width, height: size.height)
        if usesCompositedArtwork, let compositedArtwork {
            if compositedArtwork.frame != artworkFrame { compositedArtwork.frame = artworkFrame }
            if needsCompositeUpdate || compositeKey?.size != size || compositeKey?.scale != scale {
                needsCompositeUpdate = false
                let key = NativeLibraryPosterBitmap.Key(
                    image: artwork,
                    presentation: .init(item: item, spoilerSettings: spoilerSettings, environment: environment),
                    size: size, scale: scale
                )
                if key != compositeKey || compositeSource !== artwork {
                    compositedArtwork.updateIndicator(
                        NativeLibraryPosterBitmap.overlay(key: key, environment: environment), focused: isFocused
                    )
                    compositeKey = key
                    compositeSource = artwork
                    compositeTask?.cancel()
                    compositeTask = nil
                    let itemKey = item?.stablePresentationID
                    if let cached = NativeLibraryPosterBitmap.cachedImage(source: artwork, key: key) {
                        compositedArtwork.image = cached
                        compositeItem = itemKey
                        showsArtwork = artwork != nil
                    } else {
                        // Drawing a full-size poster takes several milliseconds; keep it off the
                        // main thread. Meanwhile the decoded artwork alone stands in, so fast
                        // scrolling does not flash rows of blank tiles. Without artwork the same
                        // item keeps its previous composite, and any other item shows the tile.
                        if let artwork, compositeItem != itemKey || !showsArtwork,
                           abs(artwork.size.width / artwork.size.height - size.width / size.height) < 0.03 {
                            // Only when it already has the poster's shape: the image view scales to fill.
                            compositedArtwork.image = artwork
                            compositeItem = itemKey
                            showsArtwork = true
                        } else if compositedArtwork.image == nil || compositeItem != itemKey {
                            compositedArtwork.image = NativePosterArtworkBitmap.placeholder(
                                size: size, scale: scale, clipsToArtwork: false
                            )
                            compositeItem = itemKey
                            showsArtwork = false
                        }
                        let pending = artwork, environment = environment
                        compositeTask = Task { [weak self] in
                            let image = await NativeLibraryPosterBitmap.composite(
                                source: pending, key: key, environment: environment
                            )
                            guard !Task.isCancelled, let self, let image,
                                  self.compositeKey == key, self.compositeSource === pending else { return }
                            self.compositedArtwork?.image = image
                            self.compositeItem = itemKey
                            self.showsArtwork = pending != nil
                        }
                    }
                }
            }
        } else {
            if nativeArtwork.frame != artworkFrame { nativeArtwork.frame = artworkFrame }
            nativeArtwork.layoutIfNeeded()
        }
        caption.frame = CGRect(
            x: inset, y: artworkFrame.maxY + metrics.nativePosterCaptionSpacing,
            width: width, height: caption.intrinsicContentSize.height
        )
        marker.frame = artworkFrame
        entryFocusRegion.frame = bounds
        let plateTop = max(0, Self.focusClearance - metrics.cardInset)
        plate.frame = CGRect(x: 0, y: plateTop, width: bounds.width, height: bounds.height - plateTop)
        plate.backgroundColor = UIColor(environment.themePalette.raised.fill)
        plate.layer.cornerRadius = metrics.posterCardCornerRadius
        plate.isHidden = !framed
        sendSubviewToBack(plate)
    }

    public override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        compositedArtwork?.updateFocus(isFocused, coordinator: coordinator)
        source.isFocused = isFocused
        updateCaption(animated: true)
        if overlayFocused != isFocused {
            overlayFocused = isFocused
            if !usesCompositedArtwork { updateOverlay() }
        }
        if isFocused, let item { DetailTransitionNavigation.preloadBackdrop(for: item) }
    }

    public func prepareForSelection() {
        guard let item, item.kind != .folder else { return }
        source.prepare(for: item)
    }

    func requestFocus() -> Bool {
        if let onRequestFocus { return onRequestFocus() }
        guard canBecomeFocused, window != nil, let system = UIFocusSystem.focusSystem(for: self) else { return false }
        system.requestFocusUpdate(to: self)
        system.updateFocusIfNeeded()
        return isFocused
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
        compositeTask?.cancel()
        compositeTask = nil
        imageRevision = UUID()
        artworkReferences = []
        artworkPolicyIdentity = nil
        artworkItemIdentity = nil
        artwork = nil
        compositedArtwork?.image = nil
        compositedArtwork?.updateIndicator(nil, focused: false)
        compositeKey = nil
        compositeSource = nil
        compositeItem = nil
        showsArtwork = false
        needsCompositeUpdate = true
        item = nil
        isConfiguredForDisplay = false
        accessibilityElementsHidden = true
        onRequestFocus = nil
        source.itemKey = ""
        source.isFocused = false
        source.nativeArtworkView = nil
        overlayFocused = false
        caption.setFocused(false, travel: 0, animated: false)
    }

    public func cancelArtwork() {
        imageTask?.cancel()
        imageTask = nil
        // An off-screen cell stops drawing too; a redisplay composites again.
        if compositeTask != nil {
            compositeTask?.cancel()
            compositeTask = nil
            compositeKey = nil
        }
        // A redisplayed cell must resume a cancelled image request.
        if artwork == nil {
            artworkReferences = []
            artworkPolicyIdentity = nil
        }
    }

    private func updateCaption(animated: Bool) {
        caption.isHidden = environment.plozzCardCaptionsHidden
        let metrics = environment.plozzMetrics
        let palette = environment.themePalette
        let color = UIColor(isFocused ? palette.primaryText : palette.secondaryText)
        let scrolls = isFocused && !caption.isHidden && !environment.accessibilityReduceMotion
        caption.semanticContentAttribute =
            environment.layoutDirection == .rightToLeft
            ? .forceRightToLeft : .forceLeftToRight
        if let item {
            caption.title.configure(
                text: item.posterCaptionTitle(spoilerSettings: spoilerSettings).resolve(locale: environment.locale),
                font: .systemFont(ofSize: metrics.cardTitleFontSize, weight: .semibold),
                color: color, scrolls: scrolls
            )
            caption.subtitle.configure(
                text: item.posterCaptionSubtitle() ?? " ",
                font: .systemFont(ofSize: metrics.cardSubtitleFontSize),
                color: color, scrolls: scrolls
            )
        } else {
            caption.title.configurePlaceholder(
                font: .systemFont(ofSize: metrics.cardTitleFontSize, weight: .semibold),
                color: UIColor(palette.fill), widthFraction: 0.7, height: (16 * metrics.scale).rounded()
            )
            caption.subtitle.configurePlaceholder(
                font: .systemFont(ofSize: metrics.cardSubtitleFontSize),
                color: UIColor(palette.fill), widthFraction: 0.45, height: (13 * metrics.scale).rounded()
            )
        }
        caption.setFocused(
            isFocused, travel: metrics.nativePosterCaptionFocusTravel,
            animated: animated && !environment.accessibilityReduceMotion)
    }

    private func updateOverlay() {
        if usesCompositedArtwork {
            overlay = nil
            needsCompositeUpdate = true
            setNeedsLayout()
            return
        }
        guard item != nil else {
            overlay = nil
            return
        }
        let metrics = environment.plozzMetrics
        let indicators = item.map {
            MediaCardPlaybackIndicators(
                item: $0, hidesStatus: spoilerSettings.shouldHideThumbnail(for: $0),
                showsProgressBar: environment.plozzShowsProgressBars, badgeInset: 8, progressHeight: metrics.progressBarHeight,
                progressHorizontalInset: 16, progressBottomInset: 16,
                artworkCornerRadius: PlozzTheme.Metrics.nativePosterArtworkCornerRadius
            )
        }

        let configuration = UIHostingConfiguration {
            NativeLibraryArtworkOverlay(
                symbol: item.map { .init(for: $0) } ?? .playback,
                hasArtwork: artwork != nil, isFolder: item?.kind == .folder,
                isFocused: isFocused, indicators: indicators,
                title: environment.plozzCardCaptionsHidden ? item.map {
                    Text(verbatim: $0.posterCaptionTitle(spoilerSettings: spoilerSettings).resolve(locale: environment.locale))
                } : nil
            )
            .clipShape(RoundedRectangle(
                cornerRadius: PlozzTheme.Metrics.nativePosterArtworkCornerRadius, style: .continuous))
            .environment(\.self, environment)
            .plozzChromeFocused(isFocused)
        }.margins(.all, 0)
        if let overlay {
            overlay.configuration = configuration
        } else {
            overlay = configuration.makeContentView()
            overlay?.isUserInteractionEnabled = false
        }
    }

    private var loadingTitle: String {
        var title = LocalizedStringResource("Loading")
        title.locale = environment.locale
        return String(localized: title) // l10n:content — UIKit accessibility boundary; computed from the current environment locale
    }

    private static let placeholder = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 3)).image {
        UIColor.darkGray.setFill()
        $0.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
    }

    // Reserve breathing room before TVUIKit materializes its focused guide.
    // Measuring an off-window content view returns zero on its first layout.
    private static let focusClearance = PlozzTheme.Spacing.large
}

struct NativeLibraryArtworkOverlay: View {
    let symbol: MediaArtworkPlaceholder.Symbol
    let hasArtwork: Bool
    let isFolder: Bool
    let isFocused: Bool
    let indicators: MediaCardPlaybackIndicators?
    let title: Text?
    @Environment(\.plozzMetrics) private var metrics

    var body: some View {
        ZStack {
            if isFolder && !hasArtwork {
                FolderPlaceholderArtwork(
                    foreground: .primary, background: Color.primary.opacity(0.08),
                    isFocused: isFocused, iconSize: PosterCardPresentation.folderIconSize(for: .poster),
                    title: title
                )
            } else if !hasArtwork {
                MediaArtworkPlaceholder(
                    tint: .secondary, symbol: symbol,
                    cornerRadius: PlozzTheme.Metrics.posterArtCornerRadius,
                    title: title
                )
            }
            indicators
        }
        .overlay(alignment: .topTrailing) {
            if isFolder && hasArtwork {
                FolderNavigationBadge(size: metrics.folderNavigationBadgeSize)
                    .padding(8)
            }
        }
    }
}

extension MediaItem {
    func posterCaptionTitle(spoilerSettings: SpoilerSettings) -> NativePosterText {
        if kind == .episode, let parentTitle, !parentTitle.isEmpty { return .content(parentTitle) }
        if spoilerSettings.shouldHideText(for: self) { return .localized(spoilerSettings.maskedTitle(for: self)) }
        return .content(title)
    }
}
#endif
