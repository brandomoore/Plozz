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
    private var artwork: UIImage?
    private var artworkReferences: [ArtworkReference] = []
    private var imageTask: Task<Void, Never>?
    private var imageRevision = UUID()
    private let caption = SystemPosterCaption.CaptionView()
    private let plate = UIView()
    private let marker = DetailTransitionSourceView()
    private let source = DetailTransitionSourceReference()
    private var overlay: (UIView & UIContentView)?
    private var overlayFocused = false
    private var isConfiguredForDisplay = false

    public override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = false
        backgroundConfiguration = .clear()
        addSubview(plate)
        sendSubviewToBack(plate)
        addSubview(caption)
        addSubview(marker)
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

    public static func height(for width: CGFloat, environment: EnvironmentValues) -> CGFloat {
        let metrics = environment.plozzMetrics
        let inset = environment.plozzCardStyle == .framed ? metrics.cardInset : metrics.borderlessCardSideMargin
        let size = CGSize(width: max(1, width - inset * 2), height: max(1, width - inset * 2) * 1.5)
        let title = UIFont.systemFont(ofSize: metrics.cardTitleFontSize, weight: .semibold)
        let subtitle = UIFont.systemFont(ofSize: metrics.cardSubtitleFontSize)
        return size.height + focusClearance * 2 + ceil(title.lineHeight) + 2 + ceil(subtitle.lineHeight)
            + metrics.focusCaptionPush(for: .system) + metrics.posterCaptionInset
    }

    public func configure(item: MediaItem?, spoilerSettings: SpoilerSettings, environment: EnvironmentValues) {
        isConfiguredForDisplay = true
        self.item = item
        self.spoilerSettings = spoilerSettings
        self.environment = environment
        source.itemKey = item?.stablePresentationID ?? ""
        source.cornerRadius =
            environment.plozzCardStyle == .framed
            ? PlozzTheme.Metrics.posterArtCornerRadius : environment.plozzMetrics.posterCardCornerRadius
        accessibilityLabel = item?.posterCaptionTitle(spoilerSettings: spoilerSettings).resolve(locale: environment.locale)
            ?? loadingTitle
        accessibilityValue = item?.posterCaptionSubtitle()
        accessibilityTraits = item == nil || !environment.isEnabled ? [.button, .notEnabled] : .button
        accessibilityHint = nil
        if item?.kind == .folder {
            var value = LocalizedStringResource("Folder")
            var hint = LocalizedStringResource("Open folder")
            value.locale = environment.locale
            hint.locale = environment.locale
            accessibilityValue = String(localized: value)
            accessibilityHint = String(localized: hint)
        }
        accessibilityElementsHidden = false
        let references =
            item.map {
                spoilerSettings.shouldHideThumbnail(for: $0) && $0.kind == .episode
                    ? $0.seriesArtworkReferences(prefersPortrait: true)
                    : CardArtworkPolicy.standard.references(for: $0, style: .poster)
            } ?? []
        if references != artworkReferences {
            imageTask?.cancel()
            artworkReferences = references
            // Adopt only the first candidate synchronously. A cached fallback must
            // never overtake a preferred image that has not finished loading.
            if let reference = references.first, case .remote(let url) = reference {
                artwork = ArtworkImageCache.shared.cachedImage(for: url, variant: .posterCard)
            } else {
                // Network-file cache reads must pass the resolver's access gate.
                artwork = nil
            }
            if let artwork, artwork.size.height <= 0 || artwork.size.width / artwork.size.height > 0.9 {
                self.artwork = nil
            }
            let revision = UUID()
            imageRevision = revision
            if artwork == nil, !references.isEmpty {
                imageTask = Task { [weak self] in
                    let result = await ArtworkFirstPaintResolver.resolve(
                        references: references, variant: .posterCard, maxAspectRatio: 0.9,
                        asyncOnlineURL: nil, maximumOnlineWait: 0, prefersOnlineArtwork: false
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
        var configuration = TVMediaItemContentConfiguration.wideCell()
        configuration.image = artwork ?? Self.placeholder
        configuration.overlayView = overlay
        contentConfiguration = configuration.updated(for: state)
        source.nativeArtworkView = contentView as? TVMediaItemContentView
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let metrics = environment.plozzMetrics
        let framed = environment.plozzCardStyle == .framed
        let inset = framed ? metrics.cardInset : metrics.borderlessCardSideMargin
        let width = max(1, bounds.width - inset * 2)
        let size = CGSize(width: width, height: width * 1.5)
        contentView.frame = CGRect(x: inset, y: Self.focusClearance, width: width, height: size.height)
        contentView.layoutIfNeeded()
        caption.frame = CGRect(
            x: inset, y: contentView.frame.maxY + Self.focusClearance,
            width: width, height: caption.intrinsicContentSize.height
        )
        marker.frame = contentView.frame
        let plateTop = max(0, Self.focusClearance - metrics.cardInset)
        plate.frame = CGRect(x: 0, y: plateTop, width: bounds.width, height: bounds.height - plateTop)
        plate.backgroundColor = UIColor(environment.themePalette.raised.fill)
        plate.layer.cornerRadius = metrics.posterCardCornerRadius
        plate.isHidden = !framed
        sendSubviewToBack(plate)
    }

    public override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        source.isFocused = isFocused
        updateCaption(animated: true)
        if overlayFocused != isFocused {
            overlayFocused = isFocused
            updateOverlay()
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
        imageRevision = UUID()
        artworkReferences = []
        artwork = nil
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
        // A redisplayed cell must resume a cancelled image request.
        if artwork == nil { artworkReferences = [] }
    }

    private func updateCaption(animated: Bool) {
        let metrics = environment.plozzMetrics
        let palette = environment.themePalette
        let color = UIColor(isFocused ? palette.primaryText : palette.secondaryText)
        let scrolls = isFocused && !environment.accessibilityReduceMotion
        caption.semanticContentAttribute =
            environment.layoutDirection == .rightToLeft
            ? .forceRightToLeft : .forceLeftToRight
        caption.title.configure(
            text: item?.posterCaptionTitle(spoilerSettings: spoilerSettings).resolve(locale: environment.locale) ?? loadingTitle,
            font: .systemFont(ofSize: metrics.cardTitleFontSize, weight: .semibold),
            color: color, scrolls: scrolls
        )
        caption.subtitle.configure(
            text: item?.posterCaptionSubtitle() ?? " ",
            font: .systemFont(ofSize: metrics.cardSubtitleFontSize),
            color: color, scrolls: scrolls
        )
        caption.setFocused(
            isFocused, travel: metrics.focusCaptionPush(for: .system),
            animated: animated && !environment.accessibilityReduceMotion)
    }

    private func updateOverlay() {
        let metrics = environment.plozzMetrics
        let indicators = item.map {
            MediaCardPlaybackIndicators(
                item: $0, hidesStatus: spoilerSettings.shouldHideThumbnail(for: $0),
                showsProgressBar: true, badgeInset: 8, progressHeight: metrics.progressBarHeight,
                progressHorizontalInset: 16, progressBottomInset: 16
            )
        }

        let configuration = UIHostingConfiguration {
            NativeLibraryArtworkOverlay(
                symbol: item.map { .init(for: $0) } ?? .playback,
                hasArtwork: artwork != nil, isFolder: item?.kind == .folder,
                isFocused: isFocused, indicators: indicators
            )
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
        return String(localized: title)
    }

    private static let placeholder = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 3)).image {
        UIColor.darkGray.setFill()
        $0.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
    }

    // Reserve breathing room before TVUIKit materializes its focused guide.
    // Measuring an off-window content view returns zero on its first layout.
    private static let focusClearance = PlozzTheme.Spacing.large
}

private struct NativeLibraryArtworkOverlay: View {
    let symbol: MediaArtworkPlaceholder.Symbol
    let hasArtwork: Bool
    let isFolder: Bool
    let isFocused: Bool
    let indicators: MediaCardPlaybackIndicators?
    @Environment(\.plozzMetrics) private var metrics

    var body: some View {
        ZStack {
            if isFolder && !hasArtwork {
                FolderPlaceholderArtwork(
                    foreground: .primary, background: Color.primary.opacity(0.08),
                    isFocused: isFocused, iconSize: PosterCardPresentation.folderIconSize(for: .poster)
                )
            } else if !hasArtwork {
                MediaArtworkPlaceholder(
                    tint: .secondary, symbol: symbol,
                    cornerRadius: PlozzTheme.Metrics.posterArtCornerRadius
                )
            }
            indicators
        }
        .overlay(alignment: .topTrailing) {
            if isFolder && hasArtwork {
                FolderNavigationBadge(size: metrics.watchedBadgeSize)
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
