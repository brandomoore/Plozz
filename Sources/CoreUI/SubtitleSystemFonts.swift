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
        public let name: String
        public let descriptor: UIFontDescriptor

        public var preview: Font { Font(UIFont(descriptor: descriptor, size: 30)) }
    }

    public static let captionFonts: [Entry] = SubtitleSystemFont.CaptionFamily.allCases.map {
        Entry(id: .caption($0), name: String(localized: $0.displayName), descriptor: captionDescriptor($0))
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
                return Entry(id: .named(font.fontName), name: family, descriptor: font.fontDescriptor)
            }
    }()

    public static var all: [Entry] { captionFonts + installedFonts }
    private static var unavailableFonts: Set<String> = []

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
        let value: UIFont.Weight
        switch weight {
        case .regular: value = .regular
        case .medium: value = .medium
        case .semibold: value = .semibold
        case .bold: value = .bold
        }
        var traits = descriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any] ?? [:]
        traits[.weight] = value
        return descriptor.addingAttributes([.traits: traits])
    }

    public static func displayName(for selection: SubtitleSystemFont) -> String {
        switch selection {
        case .caption(let family): String(localized: family.displayName)
        case .named(let name): UIFont(name: name, size: 30)?.familyName ?? name
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
    @MainActor var fontDisplayName: String {
        systemFont.map(SubtitleSystemFonts.displayName) ?? fontFamily.displayName
    }
}

/// Shared native menu content for Settings; the player keeps its own preview rows.
public struct SubtitleFontSettingsPicker: View {
    @Binding private var style: SubtitleStyle

    public init(style: Binding<SubtitleStyle>) { _style = style }

    public var body: some View {
        Menu {
            ForEach(SubtitleFontFamily.allCases, id: \.self) { family in
                Button {
                    style.systemFont = nil
                    style.fontFamily = family
                } label: {
                    label(family.displayName, selected: style.systemFont == nil && style.fontFamily == family)
                }
            }
            Menu("System") {
                ForEach(SubtitleSystemFonts.all) { entry in
                    Button {
                        style.systemFont = entry.id
                    } label: {
                        label(entry.name, selected: style.systemFont == entry.id)
                    }
                }
            }
        } label: {
            HStack {
                Text("Font")
                Spacer()
                Text(verbatim: style.fontDisplayName)
            }
        }
    }

    private func label(_ name: String, selected: Bool) -> some View {
        HStack {
            Text(verbatim: name)
            if selected { Image(systemName: "checkmark") }
        }
    }
}
#endif
