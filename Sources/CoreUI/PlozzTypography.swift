#if canImport(SwiftUI)
import CoreModels
import SwiftUI

/// Semantic text metrics shared by SwiftUI, UIKit, placeholders, and previews.
public enum PlozzTypography {
    public struct Style: Equatable, Sendable {
        public let pointSize: CGFloat
        public let lineSpacing: CGFloat

        public func scaled(by scale: CGFloat) -> Self {
            precondition(scale.isFinite && scale > 0)
            return Self(pointSize: pointSize * scale, lineSpacing: lineSpacing * scale)
        }

        public func height(lineHeight: CGFloat, lines: Int) -> CGFloat {
            precondition(lines > 0)
            return lineHeight * CGFloat(lines) + lineSpacing * CGFloat(lines - 1)
        }
    }

    public static let heroDescription = Style(pointSize: 24, lineSpacing: 3)
    public static let heroMetadata = Style(pointSize: 23, lineSpacing: 0)
    public static let heroFallbackTitle = Style(pointSize: 64, lineSpacing: 0)
    public static let heroCredit = Style(pointSize: 24, lineSpacing: 0)
    public static let heroSchedule = Style(pointSize: 24, lineSpacing: 0)
    #if os(tvOS)
    public static let episodeDescription = heroDescription
    #else
    public static let episodeDescription = Style(pointSize: 20, lineSpacing: 2)
    #endif
    public static var episodeTitle: Style {
        Style(pointSize: PlozzMetrics.standard.cardTitleFontSize, lineSpacing: 0)
    }
    public static let detailDescriptionLines = 4

    /// Compose once at a surface boundary; children receive the resolved scale.
    public static func scale(local: Double, app: CGFloat = 1) -> CGFloat {
        precondition(local.isFinite && local > 0 && app.isFinite && app > 0)
        return CGFloat(local) * app
    }

    public static func heroScrimScale(textScale: CGFloat, logoSize: HeroLogoSize, lines: Int) -> Double {
        // Existing scrims were authored around three 22pt lines with 2pt spacing.
        let originalHeight: CGFloat = 22 * 3 + 2 * 2
        let style = heroDescription.scaled(by: textScale)
        let textHeight = style.height(lineHeight: style.pointSize, lines: lines)
        return max(1, logoSize.scale, Double(textHeight / originalHeight))
    }
}

private struct AppTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

public extension EnvironmentValues {
    /// Extension point for app-wide sizing. No global preference is exposed yet.
    var plozzAppTextScale: CGFloat {
        get { self[AppTextScaleKey.self] }
        set { self[AppTextScaleKey.self] = newValue }
    }
}
#endif
