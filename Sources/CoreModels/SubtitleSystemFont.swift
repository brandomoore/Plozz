import Foundation

/// A portable caption-family choice or an installed font's PostScript name.
/// Picker selections are resolved on the playing device.
public enum SubtitleSystemFont: Codable, Equatable, Hashable, Sendable {
    case caption(CaptionFamily)
    case named(String)

    public enum CaptionFamily: String, Codable, CaseIterable, Sendable {
        case `default`, monospacedSerif, proportionalSerif, monospacedSansSerif
        case proportionalSansSerif, casual, cursive, smallCapitals

        public var displayName: LocalizedStringResource {
            switch self {
            case .default: "Default"
            case .monospacedSerif: "Monospaced Serif"
            case .proportionalSerif: "Proportional Serif"
            case .monospacedSansSerif: "Monospaced Sans Serif"
            case .proportionalSansSerif: "Proportional Sans Serif"
            case .casual: "Casual"
            case .cursive: "Cursive"
            case .smallCapitals: "Small Capitals"
            }
        }
    }
}

/// A secure, platform-created descriptor archive, not a font file. Keeping it as
/// data lets CoreModels preserve traits, variations, cascades and OpenType
/// features without depending on UIKit or guessing an equivalent font family.
public struct SubtitleFontDescriptor: Codable, Equatable, Sendable {
    public var archive: Data
    public var postScriptName: String
    public var displayName: String
    public var weight: Double

    public init(archive: Data, postScriptName: String, displayName: String, weight: Double) {
        self.archive = archive
        self.postScriptName = postScriptName
        self.displayName = displayName
        self.weight = weight
    }
}

/// `true` means MediaAccessibility permits content to override this individual
/// preference. Some cue formats do not supply all these attributes; in that
/// case the saved appearance remains the fallback, not an invented source value.
public struct SubtitleCaptionSourceOverrides: Codable, Equatable, Sendable {
    public var font = true
    public var relativeSize = true
    public var foregroundColor = true
    public var foregroundOpacity = true
    public var backgroundColor = true
    public var backgroundOpacity = true
    public var windowColor = true
    public var windowOpacity = true
    public var windowCornerRadius = true
    public var edge = true

    public init() {}
}
