#if os(tvOS)
import SwiftUI
import UIKit

struct SystemPosterCaption: UIViewRepresentable {
    let title: NativePosterText
    let subtitle: String?
    let reservesSubtitleSpace: Bool
    let isFocused: Bool

    func makeUIView(context: Context) -> CaptionView { CaptionView() }

    func updateUIView(_ view: CaptionView, context: Context) {
        let metrics = context.environment.plozzMetrics
        let palette = context.environment.themePalette
        let color = UIColor(isFocused ? palette.primaryText : palette.secondaryText)
        let scrolls = isFocused && !context.environment.accessibilityReduceMotion
        view.semanticContentAttribute = context.environment.layoutDirection == .rightToLeft
            ? .forceRightToLeft : .forceLeftToRight
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
        view.subtitle.isHidden = subtitle == nil && !reservesSubtitleSpace
        view.invalidateIntrinsicContentSize()
        view.setNeedsLayout()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CaptionView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: max(0, width), height: uiView.intrinsicContentSize.height)
    }

    final class CaptionView: UIView {
        let title = CaptionLine()
        let subtitle = CaptionLine()

        override var semanticContentAttribute: UISemanticContentAttribute {
            didSet {
                title.semanticContentAttribute = semanticContentAttribute
                subtitle.semanticContentAttribute = semanticContentAttribute
                title.setNeedsLayout()
                subtitle.setNeedsLayout()
            }
        }

        init() {
            super.init(frame: .zero)
            addSubview(title)
            addSubview(subtitle)
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: CGSize {
            CGSize(width: UIView.noIntrinsicMetric,
                   height: title.lineHeight + (subtitle.isHidden ? 0 : 2 + subtitle.lineHeight))
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            title.frame = CGRect(x: 0, y: 0, width: bounds.width, height: title.lineHeight)
            subtitle.frame = CGRect(x: 0, y: title.lineHeight + 2,
                                    width: bounds.width, height: subtitle.lineHeight)
        }
    }

    final class CaptionLine: UIView {
        private let label = UILabel()
        private let fade = CAGradientLayer()
        private var scrolls = false
        private var motion: Motion?
        private static let animationKey = "captionMarquee"
        var lineHeight: CGFloat { ceil(label.font.lineHeight) }

        private struct Motion: Equatable {
            let text: String
            let font: UIFont
            let width: CGFloat
            let rightToLeft: Bool
            let scrolls: Bool
        }

        init() {
            super.init(frame: .zero)
            clipsToBounds = true
            isAccessibilityElement = false
            label.isAccessibilityElement = false
            label.numberOfLines = 1
            addSubview(label)
            fade.startPoint = CGPoint(x: 0, y: 0.5)
            fade.endPoint = CGPoint(x: 1, y: 0.5)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(text: String, font: UIFont, color: UIColor, scrolls: Bool) {
            label.text = text
            label.font = font
            label.textColor = color
            self.scrolls = scrolls
            setNeedsLayout()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                label.layer.removeAnimation(forKey: Self.animationKey)
                motion = nil
            } else {
                setNeedsLayout()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
            let next = Motion(text: label.text ?? "", font: label.font, width: bounds.width,
                              rightToLeft: rightToLeft, scrolls: scrolls && window != nil)
            guard next != motion else { return }
            motion = next
            // The model stays at rest; removing this one animation restores it
            // immediately, including when a long scroll is interrupted by focus.
            label.layer.removeAnimation(forKey: Self.animationKey)
            let width = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: lineHeight)).width
            let overflows = width > bounds.width + 0.5
            let x = overflows ? (rightToLeft ? bounds.width - width : 0) : (bounds.width - width) / 2
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            label.frame = CGRect(x: x, y: 0, width: width, height: lineHeight)
            fade.frame = bounds
            let fadeWidth = min(12, bounds.width)
            if overflows, bounds.width > 0 {
                let edge = fadeWidth / bounds.width
                fade.colors = rightToLeft
                    ? [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
                    : [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
                fade.locations = rightToLeft ? [0, NSNumber(value: edge), 1] : [0, NSNumber(value: 1 - edge), 1]
                layer.mask = fade
            } else {
                layer.mask = nil
            }
            CATransaction.commit()
            guard next.scrolls, overflows, bounds.width > 0 else { return }
            let distance = width - bounds.width + fadeWidth
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
            animation.timingFunctions = [.init(name: .linear), .init(name: .easeInEaseOut),
                                         .init(name: .linear), .init(name: .easeInEaseOut), .init(name: .linear)]
            animation.duration = duration
            animation.repeatCount = .infinity
            label.layer.add(animation, forKey: Self.animationKey)
        }
    }
}
#endif
