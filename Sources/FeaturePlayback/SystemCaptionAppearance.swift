#if canImport(MediaAccessibility) && canImport(SwiftUI)
import CoreGraphics
import CoreModels
import CoreNetworking
import CoreText
import Foundation
import MediaAccessibility
import Observation
import UIKit

/// The caption look set for the whole device (Settings › Accessibility ›
/// Subtitles & Captioning), as the parts of a ``SubtitleStyle`` it decides.
/// "Use System Caption Style" draws Plozz's own subtitles with it, so the
/// device style applies to every title, whichever engine plays it.
struct SystemCaptionAppearance: Equatable {
    var textColor: SubtitleColor
    /// The typeface family the device names, or `nil` for the system font.
    var fontFamilyName: String?
    var fontDescriptor: UIFontDescriptor? = nil
    var allowsSourceColors: Bool = true
    var allowsSourceOpacity: Bool = true
    var allowsSourceFont: Bool = true
    var isBold: Bool
    /// Text size relative to the device's normal caption size (1 = normal).
    var relativeSize: Double
    var edge: SubtitleEdgeStyle
    /// Text-line background and enclosing window are independent Apple settings.
    var background: SubtitleColor?
    var windowColor: SubtitleColor? = nil
    var windowCornerRadius: Double = 0

    /// `style` drawn in this appearance. The device decides the typeface, size,
    /// colours, background and edge; `style` keeps where subtitles sit, the
    /// subtitle file's own positions and colours, HDR brightness and dual
    /// subtitles, which the device setting has no say in.
    func applied(to style: SubtitleStyle) -> SubtitleStyle {
        var resolved = style
        resolved.fontFamily = Self.family(named: fontFamilyName)
        resolved.fontWeight = isBold ? .bold : .regular
        if relativeSize.isFinite, relativeSize > 0 {
            resolved.fontScale = relativeSize
        } else {
            PlozzLog.playback.error("System caption size is invalid; using the normal caption size.")
            resolved.fontScale = 1
        }
        resolved.textColor = textColor
        resolved.usesSourceColors = style.usesSourceColors && allowsSourceColors
        resolved.opacity = 1
        resolved.edge = SubtitleStyle.Edge(style: edge)
        // The device's uniform edge is its outline; it has no second one.
        resolved.border.isEnabled = false
        resolved.background = SubtitleStyle.Background(
            isEnabled: windowColor != nil,
            color: windowColor ?? .clear,
            cornerRadius: windowCornerRadius
        )
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
        var fontBehavior = MACaptionAppearanceBehavior.useValue
        let font = MACaptionAppearanceCopyFontDescriptorForStyle(.user, &fontBehavior, .default).takeRetainedValue()
        let family = CTFontDescriptorCopyAttribute(font, kCTFontFamilyNameAttribute) as? String
        let traits = CTFontDescriptorCopyAttribute(font, kCTFontTraitsAttribute) as? [CFString: Any]
        let symbolic = (traits?[kCTFontSymbolicTrait] as? UInt32) ?? 0
        var foregroundBehavior = MACaptionAppearanceBehavior.useValue
        var opacityBehavior = MACaptionAppearanceBehavior.useValue
        let foreground = MACaptionAppearanceCopyForegroundColor(.user, &foregroundBehavior).takeRetainedValue()
        let foregroundOpacity = MACaptionAppearanceGetForegroundOpacity(.user, &opacityBehavior)

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
                foreground,
                opacity: foregroundOpacity
            ),
            fontFamilyName: family,
            fontDescriptor: font as UIFontDescriptor,
            allowsSourceColors: foregroundBehavior == .useContentIfAvailable,
            allowsSourceOpacity: opacityBehavior == .useContentIfAvailable,
            allowsSourceFont: fontBehavior == .useContentIfAvailable,
            isBold: symbolic & CTFontSymbolicTraits.traitBold.rawValue != 0,
            relativeSize: Double(MACaptionAppearanceGetRelativeCharacterSize(.user, nil)),
            edge: edgeStyle(MACaptionAppearanceGetTextEdgeStyle(.user, nil)),
            background: textBackground.alpha > 0 ? textBackground : nil,
            windowColor: window.alpha > 0 ? window : nil,
            windowCornerRadius: Double(MACaptionAppearanceGetWindowRoundedCornerRadius(.user, nil))
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

    private(set) var appearance: SystemCaptionAppearance
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let notifications: NotificationCenter

    init(
        readAppearance: @escaping @MainActor () -> SystemCaptionAppearance = { .current() },
        notifications: NotificationCenter = .default
    ) {
        self.notifications = notifications
        appearance = readAppearance()
        for name in [
            Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String),
            UIApplication.didBecomeActiveNotification
        ] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appearance = readAppearance() }
            })
        }
    }

    deinit {
        for observer in observers { notifications.removeObserver(observer) }
    }

    /// The style subtitles are drawn in: `style` itself, or the device's caption
    /// appearance applied to it when it follows the system style.
    func resolved(_ style: SubtitleStyle) -> SubtitleStyle {
        style.followsSystemStyle ? appearance.applied(to: style) : style
    }
}
#endif
