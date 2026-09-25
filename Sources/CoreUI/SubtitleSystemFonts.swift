#if canImport(UIKit) && canImport(MediaAccessibility)
import CoreModels
import CoreNetworking
import CoreText
import MediaAccessibility
import SwiftUI
import UIKit

@MainActor
public enum SubtitleSystemFonts {
    public struct Entry: Identifiable {
        public let id: SubtitleSystemFont
        public let name: Text
        public let descriptor: UIFontDescriptor

        public var preview: Font { Font(UIFont(descriptor: descriptor, size: 30)) }
    }

    public static let captionFonts: [Entry] = SubtitleSystemFont.CaptionFamily.allCases.map {
        Entry(id: .caption($0), name: Text($0.displayName), descriptor: captionDescriptor($0))
    }

    /// Use the installed font registry, not a hardcoded list from one OS release.
    /// Bundled Plozz faces stay in the main picker rather than appearing twice.
    public static let installedFonts: [Entry] = {
        let bundled = Set(SubtitleFontFamily.allCases.filter { !$0.usesSystemFont && $0 != .avenirNext }.map(\.displayName))
        return UIFont.familyNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .filter { !bundled.contains($0) }
            .compactMap { family in
                let faces = UIFont.fontNames(forFamilyName: family).compactMap { UIFont(name: $0, size: 30) }
                let font = faces.first { !$0.fontDescriptor.symbolicTraits.contains(.traitBold)
                    && !$0.fontDescriptor.symbolicTraits.contains(.traitItalic) } ?? faces.first
                guard let font else { return nil }
                return Entry(id: .named(font.fontName), name: Text(verbatim: family), descriptor: font.fontDescriptor)
            }
    }()

    public static var all: [Entry] { captionFonts + installedFonts }
    private static var unavailableFonts: Set<String> = []
    private static var capturedDescriptors: [UIFontDescriptor: SubtitleFontDescriptor] = [:]
    private static var restoredDescriptors: [Data: UIFontDescriptor] = [:]

    public static func capture(_ descriptor: UIFontDescriptor) -> SubtitleFontDescriptor? {
        if let cached = capturedDescriptors[descriptor] { return cached }
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: descriptor, requiringSecureCoding: true)
            let font = CTFontCreateWithFontDescriptor(descriptor as CTFontDescriptor, 30, nil)
            let traits = CTFontCopyTraits(font) as NSDictionary
            let weight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
            let features = featureNames(font: font, descriptor: descriptor)
            let name = ([CTFontCopyDisplayName(font) as String] + features).joined(separator: " · ")
            let result = SubtitleFontDescriptor(
                archive: data, postScriptName: CTFontCopyPostScriptName(font) as String,
                displayName: name, weight: weight
            )
            if capturedDescriptors.count >= 64 { capturedDescriptors.removeAll() }
            capturedDescriptors[descriptor] = result
            return result
        } catch {
            PlozzLog.playback.error("Could not preserve the system caption font descriptor.")
            return nil
        }
    }

    public static func descriptor(for snapshot: SubtitleFontDescriptor) -> UIFontDescriptor? {
        if let cached = restoredDescriptors[snapshot.archive] { return cached }
        do {
            if let descriptor = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: UIFontDescriptor.self, from: snapshot.archive
            ) {
                if restoredDescriptors.count >= 64 { restoredDescriptors.removeAll() }
                restoredDescriptors[snapshot.archive] = descriptor
                return descriptor
            }
        } catch {
            PlozzLog.playback.error("Saved caption descriptor could not be restored; using its named face.")
        }
        return UIFont(name: snapshot.postScriptName, size: 30)?.fontDescriptor
    }

    public static func changingWeight(
        of snapshot: SubtitleFontDescriptor, to weight: SubtitleFontWeight
    ) -> SubtitleFontDescriptor? {
        if abs(snapshot.weight - Double(uiWeight(weight).rawValue)) < 0.001 { return snapshot }
        guard let descriptor = descriptor(for: snapshot) else { return nil }
        var traits = descriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any] ?? [:]
        traits[.weight] = uiWeight(weight)
        // A bold symbolic trait must not pin a selected lighter weight.
        var symbolic = descriptor.symbolicTraits
        symbolic.remove(.traitBold)
        if weight == .bold { symbolic.insert(.traitBold) }
        traits[.symbolic] = symbolic.rawValue
        var attributes = descriptor.fontAttributes
        attributes[.traits] = traits
        attributes[.family] = UIFont(descriptor: descriptor, size: 30).familyName
        attributes[.name] = nil
        attributes[.face] = nil
        attributes[.visibleName] = nil
        let variationKey = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        if var variations = attributes[variationKey] as? [NSNumber: NSNumber] {
            // "wght" is the edited axis. Width/optical-size/custom axes survive.
            variations.removeValue(forKey: NSNumber(value: 0x77676874))
            attributes[variationKey] = variations
        }
        return capture(UIFontDescriptor(fontAttributes: attributes))
    }

    public static func adjacentWeight(for style: SubtitleStyle, forward: Bool) -> SubtitleFontWeight {
        let weights = style.availableFontWeights
        guard let first = weights.first, let last = weights.last else {
            preconditionFailure("Subtitle fonts must provide at least one weight.")
        }
        let current = style.fontDescriptor?.weight ?? Double(uiWeight(style.fontWeight).rawValue)
        if forward {
            return weights.first { Double(uiWeight($0).rawValue) > current + 0.001 } ?? first
        }
        return weights.reversed().first { Double(uiWeight($0).rawValue) < current - 0.001 } ?? last
    }

    public static func weightDisplayName(_ weight: Double, locale: Locale) -> LocalizedStringResource {
        let names: [(UIFont.Weight, LocalizedStringResource)] = [
            (.ultraLight, LocalizedStringResource(
                "subtitleWeight.ultralight",
                defaultValue: "Ultralight",
                comment: "System subtitle font weight with extremely thin letter strokes; not brightness."
            )),
            (.thin, LocalizedStringResource(
                "subtitleWeight.thin",
                defaultValue: "Thin",
                comment: "System subtitle font weight describing thin letter strokes."
            )),
            (.light, LocalizedStringResource(
                "subtitleWeight.light",
                defaultValue: "Light",
                comment: "System subtitle font weight describing light, thin letter strokes; not brightness or a color."
            )),
            (.regular, SubtitleFontWeight.regular.displayName),
            (.medium, SubtitleFontWeight.medium.displayName),
            (.semibold, SubtitleFontWeight.semibold.displayName),
            (.bold, SubtitleFontWeight.bold.displayName),
            (.heavy, LocalizedStringResource(
                "subtitleWeight.heavy",
                defaultValue: "Heavy",
                comment: "System subtitle font weight with thicker letter strokes than Bold."
            )),
            (.black, LocalizedStringResource(
                "subtitleWeight.black",
                defaultValue: "Black",
                comment: "System subtitle font weight with very heavy letter strokes; not the color black."
            ))
        ]
        if let match = names.first(where: { abs(Double($0.0.rawValue) - weight) < 0.001 }) {
            return match.1
        }
        return LocalizedStringResource(
            "Font weight \(weight.formatted(.number.precision(.fractionLength(0...3)).locale(locale)))",
            comment: "A system font's normalized numeric weight when it does not match a named font weight."
        )
    }

    private static func featureNames(font: CTFont, descriptor: UIFontDescriptor) -> [String] {
        let settings = descriptor.object(forKey: .featureSettings) as? [[String: Any]] ?? []
        let features = CTFontCopyFeatures(font) as? [[String: Any]] ?? []
        return settings.compactMap { setting in
            let type = setting[kCTFontFeatureTypeIdentifierKey as String] as? Int
            let selector = setting[kCTFontFeatureSelectorIdentifierKey as String] as? Int
            let feature = features.first { ($0[kCTFontFeatureTypeIdentifierKey as String] as? Int) == type }
            let selectors = feature?[kCTFontFeatureTypeSelectorsKey as String] as? [[String: Any]]
            return selectors?.first {
                ($0[kCTFontFeatureSelectorIdentifierKey as String] as? Int) == selector
            }?[kCTFontFeatureSelectorNameKey as String] as? String
        }
    }

    public static func descriptor(for selection: SubtitleSystemFont, weight: SubtitleFontWeight = .regular) -> UIFontDescriptor? {
        let descriptor: UIFontDescriptor
        switch selection {
        case .caption(let family): descriptor = captionDescriptor(family)
        case .named(let name):
            guard let font = UIFont(name: name, size: 30) else {
                if unavailableFonts.insert(name).inserted {
                    PlozzLog.playback.error("Saved system subtitle font is unavailable on this device; using the selected Plozz fallback.")
                }
                return nil
            }
            descriptor = font.fontDescriptor
        }
        var traits = descriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any] ?? [:]
        traits[.weight] = uiWeight(weight)
        return descriptor.addingAttributes([.traits: traits])
    }

    private static func uiWeight(_ weight: SubtitleFontWeight) -> UIFont.Weight {
        switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }

    public static func displayName(for selection: SubtitleSystemFont) -> Text {
        switch selection {
        case .caption(let family): Text(family.displayName)
        case .named(let name): Text(verbatim: UIFont(name: name, size: 30)?.familyName ?? name)
        }
    }

    private static func captionDescriptor(_ family: SubtitleSystemFont.CaptionFamily) -> UIFontDescriptor {
        let style: MACaptionAppearanceFontStyle
        switch family {
        case .default: style = .default
        case .monospacedSerif: style = .monospacedWithSerif
        case .proportionalSerif: style = .proportionalWithSerif
        case .monospacedSansSerif: style = .monospacedWithoutSerif
        case .proportionalSansSerif: style = .proportionalWithoutSerif
        case .casual: style = .casual
        case .cursive: style = .cursive
        case .smallCapitals: style = .smallCapital
        }
        return MACaptionAppearanceCopyFontDescriptorForStyle(.default, nil, style).takeRetainedValue() as UIFontDescriptor
    }
}

public extension SubtitleStyle {
    @MainActor mutating func selectFontWeight(_ weight: SubtitleFontWeight) {
        fontWeight = weight
        if let fontDescriptor {
            self.fontDescriptor = SubtitleSystemFonts.changingWeight(of: fontDescriptor, to: weight)
        }
    }

    @MainActor var fontDisplayName: Text {
        if let fontDescriptor { return Text(verbatim: fontDescriptor.displayName) }
        return systemFont.map(SubtitleSystemFonts.displayName) ?? Text(verbatim: fontFamily.displayName)
    }

    @MainActor func fontWeightDisplayName(locale: Locale) -> LocalizedStringResource {
        fontDescriptor.map { SubtitleSystemFonts.weightDisplayName($0.weight, locale: locale) }
            ?? fontWeight.displayName
    }

    @MainActor var resolvedFontDescriptor: UIFontDescriptor? {
        if let fontDescriptor { return SubtitleSystemFonts.descriptor(for: fontDescriptor) }
        return systemFont.flatMap { SubtitleSystemFonts.descriptor(for: $0, weight: fontWeight) }
    }
}

#endif
