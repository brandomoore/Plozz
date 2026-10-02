#if os(tvOS)
import CoreModels
import SwiftUI
import UIKit

struct SystemPosterCaption: UIViewRepresentable {
    let title: NativePosterText
    let subtitle: String? // l10n:content — provider metadata and preformatted runtime
    let reservesSubtitleSpace: Bool
    let isFocused: Bool
    var providerKind: ProviderKind? = nil
    var mediaShareTransport: MediaShareTransportKind? = nil

    func makeUIView(context: Context) -> CaptionView { CaptionView() }

    func updateUIView(_ view: CaptionView, context: Context) {
        let previousHeight = view.intrinsicContentSize.height
        let metrics = context.environment.plozzMetrics
        let palette = context.environment.themePalette
        let color = UIColor(isFocused ? palette.primaryText : palette.secondaryText)
        let scrolls = isFocused && !context.environment.accessibilityReduceMotion
        let direction: UISemanticContentAttribute = context.environment.layoutDirection == .rightToLeft
            ? .forceRightToLeft : .forceLeftToRight
        if view.semanticContentAttribute != direction { view.semanticContentAttribute = direction }
        view.title.configure(
            text: title.resolve(locale: context.environment.locale),
            font: .systemFont(ofSize: metrics.cardTitleFontSize, weight: .semibold),
            color: color, scrolls: scrolls
        )
        view.subtitle.configure(
            text: subtitle ?? (reservesSubtitleSpace ? " " : ""),
            font: .systemFont(ofSize: metrics.cardSubtitleFontSize),
            color: color, scrolls: scrolls
        )
        view.setProviderBadge(
            providerKind, transport: mediaShareTransport, size: metrics.cardTitleFontSize,
            colorScheme: context.environment.colorScheme
        )
        if providerKind != nil { view.setNeedsLayout() }
        let hidesSubtitle = subtitle == nil && !reservesSubtitleSpace
        if view.subtitle.isHidden != hidesSubtitle { view.subtitle.isHidden = hidesSubtitle }
        if previousHeight != view.intrinsicContentSize.height {
            view.invalidateIntrinsicContentSize()
            view.setNeedsLayout()
        }
        view.setFocused(isFocused, travel: metrics.focusCaptionPush(for: .system),
                        animated: !context.environment.accessibilityReduceMotion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CaptionView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: max(0, width), height: uiView.intrinsicContentSize.height)
    }

    class CaptionView: UIView {
        private let content = UIView()
        let title = NativePosterCaptionLine()
        let subtitle = NativePosterCaptionLine()
        private(set) var providerBadge: (UIView & UIContentView)?
        private var badgeIdentity: BadgeIdentity?
        private var focusTravel: CGFloat = 0
        private var captionFocused = false
        private static let focusAnimationKey = "captionFocus"

        private struct BadgeIdentity: Equatable {
            let provider: ProviderKind
            let transport: MediaShareTransportKind?
            let size: CGFloat
            let colorScheme: ColorScheme
        }

        override var semanticContentAttribute: UISemanticContentAttribute {
            didSet {
                guard oldValue != semanticContentAttribute else { return }
                title.semanticContentAttribute = semanticContentAttribute
                subtitle.semanticContentAttribute = semanticContentAttribute
                title.setNeedsLayout()
                subtitle.setNeedsLayout()
                setNeedsLayout()
            }
        }

        init() {
            super.init(frame: .zero)
            addSubview(content)
            content.addSubview(title)
            content.addSubview(subtitle)
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func setProviderBadge(
            _ provider: ProviderKind?, transport: MediaShareTransportKind?,
            size: CGFloat, colorScheme: ColorScheme
        ) {
            let identity = provider.map {
                BadgeIdentity(provider: $0, transport: transport, size: size, colorScheme: colorScheme)
            }
            guard identity != badgeIdentity else { return }
            badgeIdentity = identity
            defer { setNeedsLayout() }
            guard let identity else {
                providerBadge?.removeFromSuperview()
                providerBadge = nil
                return
            }
            let configuration = UIHostingConfiguration {
                ProviderBrandMark(
                    provider: identity.provider, size: identity.size,
                    mediaShareTransport: identity.transport
                )
                .environment(\.colorScheme, identity.colorScheme)
                .accessibilityHidden(true)
            }.margins(.all, 0)
            if let providerBadge {
                providerBadge.configuration = configuration
            } else {
                let badge = configuration.makeContentView()
                badge.isUserInteractionEnabled = false
                badge.accessibilityElementsHidden = true
                content.addSubview(badge)
                providerBadge = badge
            }
        }

        override var intrinsicContentSize: CGSize {
            CGSize(width: UIView.noIntrinsicMetric,
                   height: title.lineHeight + (subtitle.isHidden ? 0 : 2 + subtitle.lineHeight) + focusTravel)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            content.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - focusTravel)
            content.center = CGPoint(x: bounds.midX, y: (bounds.height - focusTravel) / 2)
            if let providerBadge, let identity = badgeIdentity {
                let size = min(identity.size, title.lineHeight, max(0, bounds.width))
                let spacing = min(PlozzTheme.Spacing.small, max(0, bounds.width - size))
                let textWidth = min(ceil(title.contentWidth), max(0, bounds.width - size - spacing))
                let start = (bounds.width - size - spacing - textWidth) / 2
                let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
                providerBadge.frame = CGRect(
                    x: rightToLeft ? start + textWidth + spacing : start,
                    y: (title.lineHeight - size) / 2, width: size, height: size
                )
                title.frame = CGRect(
                    x: rightToLeft ? start : start + size + spacing,
                    y: 0, width: textWidth, height: title.lineHeight
                )
            } else {
                title.frame = CGRect(x: 0, y: 0, width: bounds.width, height: title.lineHeight)
            }
            subtitle.frame = CGRect(x: 0, y: title.lineHeight + 2,
                                    width: bounds.width, height: subtitle.lineHeight)
        }

        func setFocused(_ focused: Bool, travel: CGFloat, animated: Bool) {
            guard captionFocused != focused || focusTravel != travel || !animated else { return }
            let changesLayout = focusTravel != travel
            let old = (content.layer.presentation() ?? content.layer).transform.m42
            captionFocused = focused
            focusTravel = travel
            let destination = focused ? travel : 0
            content.layer.removeAnimation(forKey: Self.focusAnimationKey)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            content.layer.transform = CATransform3DMakeTranslation(0, destination, 0)
            CATransaction.commit()
            if animated, window != nil, old != destination {
                let animation = CABasicAnimation(keyPath: "transform.translation.y")
                animation.fromValue = old
                animation.toValue = destination
                animation.duration = 0.18
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                content.layer.add(animation, forKey: Self.focusAnimationKey)
            }
            if changesLayout {
                invalidateIntrinsicContentSize()
                setNeedsLayout()
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { content.layer.removeAnimation(forKey: Self.focusAnimationKey) }
        }
    }
}

/// The single-line marquee shared by native posters and player episode cards.
public final class NativePosterCaptionLine: UIView {
    private let label = UILabel()
    private let placeholder = UIView()
    private let fade = CAGradientLayer()
    private var scrolls = false
    private var centersShortText = true
    private var horizontalInset: CGFloat = 0
    private var placeholderWidthFraction: CGFloat?
    private var placeholderHeight: CGFloat = 0
    private var motion: Motion?
    private static let animationKey = "captionMarquee"
    public var lineHeight: CGFloat { ceil(label.font.lineHeight) }
    var contentWidth: CGFloat {
        label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: lineHeight)).width
    }

    private struct Motion: Equatable {
        let text: String
        let font: UIFont
        let width: CGFloat
        let rightToLeft: Bool
        let scrolls: Bool
        let centersShortText: Bool
        let horizontalInset: CGFloat
    }

    public init() {
        super.init(frame: .zero)
        clipsToBounds = true
        isAccessibilityElement = false
        label.isAccessibilityElement = false
        label.numberOfLines = 1
        addSubview(label)
        placeholder.isHidden = true
        placeholder.isUserInteractionEnabled = false
        placeholder.isAccessibilityElement = false
        addSubview(placeholder)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func configure(
        text: String, font: UIFont, color: UIColor, scrolls: Bool,
        centersShortText: Bool = true, horizontalInset: CGFloat = 0
    ) {
        let changesLayout =
            placeholderWidthFraction != nil
            || label.text != text || label.font != font || self.scrolls != scrolls
            || self.centersShortText != centersShortText
            || self.horizontalInset != horizontalInset
        placeholderWidthFraction = nil
        placeholder.isHidden = true
        label.isHidden = false
        if label.text != text { label.text = text }
        if label.font != font { label.font = font }
        if label.textColor != color { label.textColor = color }
        self.scrolls = scrolls
        self.centersShortText = centersShortText
        self.horizontalInset = horizontalInset
        if changesLayout { setNeedsLayout() }
    }

    func configurePlaceholder(font: UIFont, color: UIColor, widthFraction: CGFloat, height: CGFloat) {
        label.text = nil
        label.font = font
        label.isHidden = true
        label.layer.removeAnimation(forKey: Self.animationKey)
        motion = nil
        scrolls = false
        placeholderWidthFraction = widthFraction
        placeholderHeight = height
        placeholder.backgroundColor = color
        placeholder.isHidden = false
        setNeedsLayout()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            label.layer.removeAnimation(forKey: Self.animationKey)
            motion = nil
        } else {
            setNeedsLayout()
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        if let fraction = placeholderWidthFraction {
            let width = (bounds.width * fraction).rounded()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.mask = nil
            placeholder.frame = CGRect(
                x: (bounds.width - width) / 2, y: (lineHeight - placeholderHeight) / 2,
                width: width, height: placeholderHeight
            )
            placeholder.layer.cornerRadius = placeholderHeight / 2
            CATransaction.commit()
            return
        }
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let next = Motion(
            text: label.text ?? "", font: label.font, width: bounds.width,
            rightToLeft: rightToLeft, scrolls: scrolls && window != nil,
            centersShortText: centersShortText, horizontalInset: horizontalInset)
        guard next != motion else { return }
        motion = next
        // The model stays at rest; removing this one animation restores it
        // immediately, including when a long scroll is interrupted by focus.
        label.layer.removeAnimation(forKey: Self.animationKey)
        let width = contentWidth
        let inset = min(max(0, horizontalInset), bounds.width / 2)
        let availableWidth = bounds.width - inset * 2
        let overflows = width > availableWidth + 0.5
        let x =
            overflows || !centersShortText
            ? (rightToLeft ? bounds.width - inset - width : inset) : (bounds.width - width) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.frame = CGRect(x: x, y: 0, width: width, height: lineHeight)
        fade.frame = bounds
        let fadeWidth = inset > 0 ? inset : min(12, bounds.width)
        if overflows, bounds.width > 0 {
            let edge = fadeWidth / bounds.width
            if inset > 0 {
                fade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
                fade.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
            } else {
                // Edge-aligned poster captions keep the leading glyph visible at rest.
                fade.colors = rightToLeft
                    ? [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
                    : [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
                fade.locations = rightToLeft ? [0, NSNumber(value: edge), 1] : [0, NSNumber(value: 1 - edge), 1]
            }
            layer.mask = fade
        } else {
            layer.mask = nil
        }
        CATransaction.commit()
        guard next.scrolls, overflows, availableWidth > 0 else { return }
        let distance = width - availableWidth + (inset == 0 ? fadeWidth : 0)
        let outward = Double(distance) / PlozzTheme.Metrics.marqueePointsPerSecond
        let returning = Double(distance) / PlozzTheme.Metrics.marqueeReturnPointsPerSecond
        let pause = PlozzTheme.Metrics.marqueeStartDelay
        let end = pause + outward + PlozzTheme.Metrics.marqueeEndHold
        let duration = end + returning + PlozzTheme.Metrics.marqueeRestHold
        let offset = rightToLeft ? distance : -distance
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, 0, offset, offset, 0, 0]
        animation.keyTimes = [0, pause, pause + outward, end, end + returning, duration]
            .map { NSNumber(value: $0 / duration) }
        animation.timingFunctions = [
            .init(name: .linear), .init(name: .easeInEaseOut),
            .init(name: .linear), .init(name: .easeInEaseOut), .init(name: .linear),
        ]
        animation.duration = duration
        animation.repeatCount = .infinity
        label.layer.add(animation, forKey: Self.animationKey)
    }
}
#endif
