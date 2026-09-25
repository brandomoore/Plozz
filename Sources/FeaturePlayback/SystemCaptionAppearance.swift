#if canImport(MediaAccessibility) && canImport(SwiftUI)
import CoreGraphics
import CoreModels
import CoreText
import Foundation
import MediaAccessibility
import Observation

/// The caption look set for the whole device (Settings › Accessibility ›
/// Subtitles & Captioning), as the parts of a ``SubtitleStyle`` it decides.
/// "Use System Caption Style" draws Plozz's own subtitles with it, so the
/// device style applies to every title, whichever engine plays it.
struct SystemCaptionAppearance: Equatable {
    var textColor: SubtitleColor
    /// The typeface family the device names, or `nil` for the system font.
    var fontFamilyName: String?
    var isBold: Bool
    /// Text size relative to the device's normal caption size (1 = normal).
    var relativeSize: Double
    var edge: SubtitleEdgeStyle
    /// The box behind the text, or `nil` for none.
    var background: SubtitleColor?

    /// `style` drawn in this appearance. The device decides the typeface, size,
    /// colours, background and edge; `style` keeps where subtitles sit, the
    /// subtitle file's own positions and colours, HDR brightness and dual
    /// subtitles, which the device setting has no say in.
    func applied(to style: SubtitleStyle) -> SubtitleStyle {
        var resolved = style
        resolved.fontFamily = Self.family(named: fontFamilyName)
        resolved.fontWeight = isBold ? .bold : .regular
        resolved.fontScale = min(max(relativeSize, 0.4), 2.5)
        resolved.textColor = textColor
        resolved.opacity = 1
        resolved.edge = SubtitleStyle.Edge(style: edge)
        // The device's uniform edge is its outline; it has no second one.
        resolved.border.isEnabled = false
        resolved.background.isEnabled = background != nil
        if let background { resolved.background.color = background }
        return resolved
    }

    /// The Plozz typeface for a device font family. Families Plozz doesn't
    /// bundle fall back to the system font.
    static func family(named name: String?) -> SubtitleFontFamily {
        guard let name = name?.lowercased() else { return .system }
        if name.contains("avenir next") { return .avenirNext }
        if name.contains("rounded") { return .sfRounded }
        if let bundled = SubtitleFontFamily.allCases.first(where: {
            !$0.usesSystemFont && name.contains($0.displayName.lowercased())
        }) {
            return bundled
        }
        return .system
    }

    /// The appearance as the device has it now.
    static func current() -> SystemCaptionAppearance {
        let font = MACaptionAppearanceCopyFontDescriptorForStyle(.user, nil, .default).takeRetainedValue()
        let family = CTFontDescriptorCopyAttribute(font, kCTFontFamilyNameAttribute) as? String
        let traits = CTFontDescriptorCopyAttribute(font, kCTFontTraitsAttribute) as? [CFString: Any]
        let symbolic = (traits?[kCTFontSymbolicTrait] as? UInt32) ?? 0

        let textBackground = color(
            MACaptionAppearanceCopyBackgroundColor(.user, nil).takeRetainedValue(),
            opacity: MACaptionAppearanceGetBackgroundOpacity(.user, nil)
        )
        let window = color(
            MACaptionAppearanceCopyWindowColor(.user, nil).takeRetainedValue(),
            opacity: MACaptionAppearanceGetWindowOpacity(.user, nil)
        )
        return SystemCaptionAppearance(
            textColor: color(
                MACaptionAppearanceCopyForegroundColor(.user, nil).takeRetainedValue(),
                opacity: MACaptionAppearanceGetForegroundOpacity(.user, nil)
            ),
            fontFamilyName: family,
            isBold: symbolic & CTFontSymbolicTraits.traitBold.rawValue != 0,
            relativeSize: Double(MACaptionAppearanceGetRelativeCharacterSize(.user, nil)),
            edge: edgeStyle(MACaptionAppearanceGetTextEdgeStyle(.user, nil)),
            // Plozz draws one box: the text's own background, else the window.
            background: [textBackground, window].first { $0.alpha > 0.01 }
        )
    }

    private static func color(_ color: CGColor, opacity: CGFloat) -> SubtitleColor {
        let rgb = CGColorSpace(name: CGColorSpace.sRGB).flatMap {
            color.converted(to: $0, intent: .defaultIntent, options: nil)
        }
        let c = (rgb ?? color).components ?? []
        // Grey spaces carry one component plus alpha.
        let (r, g, b) = c.count >= 3 ? (c[0], c[1], c[2]) : (c.first ?? 1, c.first ?? 1, c.first ?? 1)
        return SubtitleColor(red: Double(r), green: Double(g), blue: Double(b), alpha: Double(opacity))
    }

    private static func edgeStyle(_ edge: MACaptionAppearanceTextEdgeStyle) -> SubtitleEdgeStyle {
        switch edge {
        case .none: return .none
        case .raised: return .raised
        case .depressed: return .depressed
        case .uniform: return .uniform
        case .dropShadow, .undefined: return .dropShadow
        @unknown default: return .dropShadow
        }
    }
}

/// Keeps the device's caption appearance current, so subtitles drawn in it
/// restyle as soon as the viewer changes it in Settings.
@MainActor
@Observable
final class SystemCaptionStyle {
    static let shared = SystemCaptionStyle()

    private(set) var appearance = SystemCaptionAppearance.current()

    private init() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appearance = .current() }
        }
    }

    /// The style subtitles are drawn in: `style` itself, or the device's caption
    /// appearance applied to it when it follows the system style.
    func resolved(_ style: SubtitleStyle) -> SubtitleStyle {
        style.followsSystemStyle ? appearance.applied(to: style) : style
    }
}
#endif
