#if canImport(UIKit)
import CoreModels
import UIKit

/// The device's own fonts, offered under System Fonts beside Plozz's curated
/// subtitle typefaces, so a viewer can keep a font they chose for the device.
public enum InstalledSubtitleFonts {
    /// Font families installed on the device, alphabetically, without the ones
    /// the curated list already offers (bundled faces register as installed).
    public static var families: [String] {
        UIFont.familyNames
            .filter { curatedFamily(named: $0) == nil }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The curated typeface a device family name stands for, if Plozz offers it.
    public static func curatedFamily(named name: String) -> SubtitleFontFamily? {
        let name = name.lowercased()
        return SubtitleFontFamily.allCases.first {
            !$0.usesSystemFont && name == $0.displayName.lowercased()
        }
    }

    /// Whether `family` is installed, so a style naming it can be drawn.
    public static func isInstalled(_ family: String) -> Bool {
        !UIFont.fontNames(forFamilyName: family).isEmpty
    }

    /// The weights `family` actually has faces for, lightest first. A family
    /// without upright faces (or an unknown one) offers Regular only.
    public static func weights(forFamily family: String) -> [SubtitleFontWeight] {
        let found = Set(UIFont.fontNames(forFamilyName: family).compactMap { name -> SubtitleFontWeight? in
            guard let font = UIFont(name: name, size: 12) else { return nil }
            let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
            if let symbolic = traits?[.symbolic] as? UInt32,
               UIFontDescriptor.SymbolicTraits(rawValue: symbolic).contains(.traitItalic) {
                return nil
            }
            let weight = (traits?[.weight] as? CGFloat) ?? 0
            return SubtitleFontWeight.allCases.min {
                abs(uiWeight($0).rawValue - weight) < abs(uiWeight($1).rawValue - weight)
            }
        })
        let weights = SubtitleFontWeight.allCases.filter(found.contains)
        return weights.isEmpty ? [.regular] : weights
    }

    /// The weights the style's font offers: its installed family's, or the
    /// curated family's.
    public static func weights(for style: SubtitleStyle) -> [SubtitleFontWeight] {
        style.installedFontFamily.map(weights(forFamily:)) ?? style.fontFamily.availableWeights
    }

    /// The font's name as a viewer sees it in the Style screens.
    public static func displayName(for style: SubtitleStyle) -> String {  // l10n:content — font family names are proper nouns
        style.installedFontFamily ?? style.fontFamily.displayName
    }

    public static func uiWeight(_ weight: SubtitleFontWeight) -> UIFont.Weight {
        switch weight {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }

    /// A face of `family` at `weight` (italic when asked), or `nil` when the
    /// family isn't installed.
    public static func font(family: String, weight: SubtitleFontWeight, isItalic: Bool = false, size: CGFloat) -> UIFont? {
        guard isInstalled(family) else { return nil }
        var descriptor = UIFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [UIFontDescriptor.TraitKey.weight: uiWeight(weight)],
        ])
        if isItalic, let italic = descriptor.withSymbolicTraits(.traitItalic) {
            descriptor = italic
        }
        return UIFont(descriptor: descriptor, size: size)
    }
}
#endif
