#if canImport(MediaAccessibility) && canImport(SwiftUI)
import CoreGraphics
import CoreModels
import CoreNetworking
import CoreText
import CoreUI
import Foundation
import MediaAccessibility
import Observation
import UIKit

/// The caption look set for the whole device (Settings › Accessibility ›
/// Subtitles & Captioning), as the parts of a ``SubtitleStyle`` it decides.
/// "Use System Subtitle Style" draws Plozz's own subtitles with it, so the
/// device style applies to every title drawn by the owned overlay. Apple does
/// not expose its native point-size baseline, padding, line spacing, edge color
/// or edge dimensions; those remain renderer-defined, not sampled system values.
struct SystemCaptionAppearance: Equatable {
    var textColor: SubtitleColor
    /// The typeface family the device names, or `nil` for the system font.
    var fontFamilyName: String?
    var fontDescriptor: UIFontDescriptor? = nil
    var allowsSourceColors: Bool = true
    var allowsSourceOpacity: Bool = true
    var allowsSourceFont: Bool = true
    var otherSourceOverrides = SubtitleCaptionSourceOverrides()
    var isBold: Bool
    /// Text size relative to the device's normal caption size (1 = normal).
    var relativeSize: Double
    var edge: SubtitleEdgeStyle
    var edgeRawValue: Int? = nil
    /// Text-line background and enclosing window are independent Apple settings.
    var background: SubtitleColor?
    var windowColor: SubtitleColor? = nil
    var windowCornerRadius: Double = 0

    /// `style` drawn in this appearance. The device decides the typeface, size,
    /// colours, backgrounds, edge and per-field content-override policy. `style`
    /// keeps placement, Plozz padding, HDR brightness and dual subtitles, for
    /// which the device exposes no caption appearance preference.
    @MainActor func applied(to style: SubtitleStyle) -> SubtitleStyle {
        var resolved = style
        resolved.fontFamily = Self.family(named: fontFamilyName)
        resolved.systemFont = nil
        resolved.fontDescriptor = fontDescriptor.flatMap(SubtitleSystemFonts.capture)
        resolved.fontWeight = isBold ? .bold : .regular
        if relativeSize.isFinite, relativeSize > 0 {
            resolved.fontScale = relativeSize
        } else {
            PlozzLog.playback.error("System caption size is invalid; using the normal caption size.")
            resolved.fontScale = 1
        }
        resolved.textColor = textColor
        resolved.glyphBackground = background ?? .clear
        resolved.usesSourceColors = allowsSourceColors
        var sourceOverrides = otherSourceOverrides
        sourceOverrides.font = allowsSourceFont
        sourceOverrides.foregroundColor = allowsSourceColors
        sourceOverrides.foregroundOpacity = allowsSourceOpacity
        resolved.captionSourceOverrides = sourceOverrides
        resolved.opacity = 1
        resolved.edge = SubtitleStyle.Edge(style: edge)
        resolved.captionEdgeStyleRawValue = edgeRawValue
        // The device's uniform edge is its outline; it has no second one.
        resolved.border.isEnabled = false
        resolved.background.isEnabled = (windowColor?.alpha ?? 0) > 0
        resolved.background.color = windowColor ?? .clear
        resolved.background.cornerRadius = windowCornerRadius
        // Apple exposes neither caption padding nor outline color/thickness.
        // Keep Plozz's layout values, never label them as system measurements.
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
    @MainActor static func current() -> SystemCaptionAppearance {
        var fontBehavior = MACaptionAppearanceBehavior.useValue
        let font = MACaptionAppearanceCopyFontDescriptorForStyle(.user, &fontBehavior, .default).takeRetainedValue()
        let family = CTFontDescriptorCopyAttribute(font, kCTFontFamilyNameAttribute) as? String
        let traits = CTFontDescriptorCopyAttribute(font, kCTFontTraitsAttribute) as? [CFString: Any]
        let symbolic = (traits?[kCTFontSymbolicTrait] as? UInt32) ?? 0
        var foregroundBehavior = MACaptionAppearanceBehavior.useValue
        var opacityBehavior = MACaptionAppearanceBehavior.useValue
        let foreground = MACaptionAppearanceCopyForegroundColor(.user, &foregroundBehavior).takeRetainedValue()
        let foregroundOpacity = MACaptionAppearanceGetForegroundOpacity(.user, &opacityBehavior)

        var backgroundColorBehavior = MACaptionAppearanceBehavior.useValue
        var backgroundOpacityBehavior = MACaptionAppearanceBehavior.useValue
        var windowColorBehavior = MACaptionAppearanceBehavior.useValue
        var windowOpacityBehavior = MACaptionAppearanceBehavior.useValue
        var cornerBehavior = MACaptionAppearanceBehavior.useValue
        var sizeBehavior = MACaptionAppearanceBehavior.useValue
        var edgeBehavior = MACaptionAppearanceBehavior.useValue
        let textBackground = color(
            MACaptionAppearanceCopyBackgroundColor(.user, &backgroundColorBehavior).takeRetainedValue(),
            opacity: MACaptionAppearanceGetBackgroundOpacity(.user, &backgroundOpacityBehavior)
        )
        let window = color(
            MACaptionAppearanceCopyWindowColor(.user, &windowColorBehavior).takeRetainedValue(),
            opacity: MACaptionAppearanceGetWindowOpacity(.user, &windowOpacityBehavior)
        )
        let radius = MACaptionAppearanceGetWindowRoundedCornerRadius(.user, &cornerBehavior)
        let size = MACaptionAppearanceGetRelativeCharacterSize(.user, &sizeBehavior)
        let edge = MACaptionAppearanceGetTextEdgeStyle(.user, &edgeBehavior)
        var overrides = SubtitleCaptionSourceOverrides()
        overrides.backgroundColor = backgroundColorBehavior == .useContentIfAvailable
        overrides.backgroundOpacity = backgroundOpacityBehavior == .useContentIfAvailable
        overrides.windowColor = windowColorBehavior == .useContentIfAvailable
        overrides.windowOpacity = windowOpacityBehavior == .useContentIfAvailable
        overrides.windowCornerRadius = cornerBehavior == .useContentIfAvailable
        overrides.relativeSize = sizeBehavior == .useContentIfAvailable
        overrides.edge = edgeBehavior == .useContentIfAvailable
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
            otherSourceOverrides: overrides,
            isBold: symbolic & CTFontSymbolicTraits.traitBold.rawValue != 0,
            relativeSize: Double(size),
            edge: edgeStyle(edge),
            edgeRawValue: Int(edge.rawValue),
            background: textBackground,
            windowColor: window,
            windowCornerRadius: Double(radius)
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

    /// Both TV hosts and the mobile editor enter here *before* changing a value.
    /// An actual edit freezes the entire effective look, not stale custom fields.
    /// A no-op (including a slider reaching an endpoint) must not stop matching.
    func editing(_ style: SubtitleStyle, _ mutate: (inout SubtitleStyle) -> Void) -> SubtitleStyle {
        let effective = resolved(style)
        var next = effective
        mutate(&next)
        guard next != effective else { return style }
        if next.followsSystemStyle != effective.followsSystemStyle {
            return next.followsSystemStyle ? appearance.applied(to: next) : next
        }
        if next.fontFamily != effective.fontFamily || next.systemFont != effective.systemFont {
            next.fontDescriptor = nil
        } else if next.fontWeight != effective.fontWeight, next.fontDescriptor == effective.fontDescriptor,
                  let descriptor = next.fontDescriptor {
            next.fontDescriptor = SubtitleSystemFonts.changingWeight(of: descriptor, to: next.fontWeight)
        }
        if next.edge.style != effective.edge.style { next.captionEdgeStyleRawValue = nil }
        if next.usesSourceColors != effective.usesSourceColors {
            next.captionSourceOverrides?.foregroundColor = next.usesSourceColors
        } else if next.captionSourceOverrides?.foregroundColor != effective.captionSourceOverrides?.foregroundColor,
                  let allowsColor = next.captionSourceOverrides?.foregroundColor {
            next.usesSourceColors = allowsColor
        }
        if next.edge.style == .uniform, next.captionSourceOverrides == nil {
            // A newly selected uniform edge is not the retired two-outline
            // representation. Mark its source policy explicitly so legacy
            // decoding will not fold it away, without changing old file-alpha behavior.
            var policy = SubtitleCaptionSourceOverrides()
            policy.foregroundColor = next.usesSourceColors
            policy.foregroundOpacity = next.usesSourceColors
            next.captionSourceOverrides = policy
        }
        next.followsSystemStyle = false
        return next
    }
}
#endif
